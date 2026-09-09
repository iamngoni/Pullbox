//! Builds and sends ActivityKit APNs messages without owning download execution.
//!
//! Device tokens are sensitive and must never be formatted for logs or API responses.

use async_trait::async_trait;
use jsonwebtoken::{encode, Algorithm, EncodingKey, Header};
use serde::{Deserialize, Deserializer, Serialize, Serializer};
use serde_json::{json, Value};
use std::{
    collections::HashMap,
    fmt,
    fs::{self, OpenOptions},
    io::{self, Write},
    path::{Path, PathBuf},
    sync::{Arc, Mutex, RwLock, RwLockReadGuard, RwLockWriteGuard},
    time::Duration,
};
use thiserror::Error;
use tokio::sync::Notify;

/// A validated APNs device token whose formatting never exposes its bytes.
#[derive(Clone, Eq, Hash, PartialEq)]
pub struct DeviceToken(String);

impl DeviceToken {
    /// Parses the APNs hexadecimal wire representation.
    pub fn parse(value: &str) -> Result<Self, DeviceTokenError> {
        if value.is_empty()
            || !value.len().is_multiple_of(2)
            || !value.bytes().all(|byte| byte.is_ascii_hexdigit())
        {
            return Err(DeviceTokenError::InvalidHex);
        }
        Ok(Self(value.to_owned()))
    }

    /// Returns the token only for constructing the APNs request path.
    pub fn as_str(&self) -> &str {
        &self.0
    }
}

impl fmt::Debug for DeviceToken {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter.write_str("DeviceToken([REDACTED])")
    }
}

impl Serialize for DeviceToken {
    fn serialize<S>(&self, serializer: S) -> Result<S::Ok, S::Error>
    where
        S: Serializer,
    {
        serializer.serialize_str(&self.0)
    }
}

impl<'de> Deserialize<'de> for DeviceToken {
    fn deserialize<D>(deserializer: D) -> Result<Self, D::Error>
    where
        D: Deserializer<'de>,
    {
        let value = String::deserialize(deserializer)?;
        Self::parse(&value).map_err(serde::de::Error::custom)
    }
}

/// A token rejected before it reaches the registry or APNs client.
#[derive(Clone, Copy, Debug, Eq, Error, PartialEq)]
pub enum DeviceTokenError {
    #[error("device token must be nonempty even-length hexadecimal")]
    InvalidHex,
}

/// Maximum progress owned by yt-dlp and backend processing.
pub const MAX_SERVER_PROGRESS: f64 = 0.9;

/// Default ActivityKit APNs topic for the Pullbox app.
pub const DEFAULT_APNS_TOPIC: &str = "dev.iamngoni.pullbox.push-type.liveactivity";

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum ApnsEnvironment {
    Production,
    Sandbox,
}

/// Complete APNs token-auth configuration. Private key material is never debuggable.
#[derive(Clone)]
pub struct ApnsConfig {
    team_id: String,
    key_id: String,
    private_key_pem: String,
    topic: String,
    environment: ApnsEnvironment,
    provider_token: Arc<Mutex<Option<CachedProviderToken>>>,
}

#[derive(Clone)]
struct CachedProviderToken {
    issued_at: i64,
    value: String,
}

const PROVIDER_TOKEN_REFRESH_SECONDS: i64 = 50 * 60;

impl ApnsConfig {
    /// Parses optional environment values, requiring all credential fields together.
    pub fn from_values(
        team_id: Option<String>,
        key_id: Option<String>,
        private_key_pem: Option<String>,
        topic: Option<String>,
        environment: Option<String>,
    ) -> Result<Option<Self>, ApnsConfigError> {
        let (team_id, key_id, private_key_pem) = match (team_id, key_id, private_key_pem) {
            (None, None, None) => return Ok(None),
            (Some(team_id), Some(key_id), Some(private_key_pem))
                if !team_id.is_empty() && !key_id.is_empty() && !private_key_pem.is_empty() =>
            {
                (team_id, key_id, private_key_pem)
            }
            _ => return Err(ApnsConfigError::PartialCredentials),
        };
        let environment = match environment.as_deref().unwrap_or("production") {
            "production" => ApnsEnvironment::Production,
            "sandbox" => ApnsEnvironment::Sandbox,
            _ => return Err(ApnsConfigError::InvalidEnvironment),
        };
        let topic = topic.unwrap_or_else(|| DEFAULT_APNS_TOPIC.to_string());
        if topic.is_empty() {
            return Err(ApnsConfigError::EmptyTopic);
        }

        Ok(Some(Self {
            team_id,
            key_id,
            private_key_pem,
            topic,
            environment,
            provider_token: Arc::new(Mutex::new(None)),
        }))
    }

    /// Reads the optional APNs configuration from process environment variables.
    pub fn from_env() -> Result<Option<Self>, ApnsConfigError> {
        Self::from_values(
            std::env::var("PULLBOX_APNS_TEAM_ID").ok(),
            std::env::var("PULLBOX_APNS_KEY_ID").ok(),
            std::env::var("PULLBOX_APNS_PRIVATE_KEY_PEM").ok(),
            std::env::var("PULLBOX_APNS_TOPIC").ok(),
            std::env::var("PULLBOX_APNS_ENVIRONMENT").ok(),
        )
    }

    /// Creates a signed APNs HTTP/2 request description without sending it.
    pub fn prepare_request(
        &self,
        token: &DeviceToken,
        event: ApnsEvent,
        body: Value,
        issued_at: i64,
    ) -> Result<PreparedApnsRequest, ApnsRequestError> {
        let jwt = self.provider_token(issued_at)?;
        let headers = HashMap::from([
            ("authorization".to_string(), format!("bearer {jwt}")),
            ("apns-push-type".to_string(), "liveactivity".to_string()),
            ("apns-topic".to_string(), self.topic.clone()),
            ("apns-priority".to_string(), event.priority().to_string()),
        ]);

        Ok(PreparedApnsRequest {
            url: format!("{}/3/device/{}", self.base_url(), token.as_str()),
            headers,
            body,
        })
    }

    fn provider_token(&self, issued_at: i64) -> Result<String, ApnsRequestError> {
        let mut cached = self
            .provider_token
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        if let Some(token) = cached.as_ref() {
            let age = issued_at.checked_sub(token.issued_at);
            if age.is_some_and(|age| (0..PROVIDER_TOKEN_REFRESH_SECONDS).contains(&age)) {
                return Ok(token.value.clone());
            }
        }

        #[derive(Serialize)]
        struct Claims<'a> {
            iss: &'a str,
            iat: i64,
        }

        let mut header = Header::new(Algorithm::ES256);
        header.kid = Some(self.key_id.clone());
        let signing_key = EncodingKey::from_ec_pem(self.private_key_pem.as_bytes())
            .map_err(ApnsRequestError::Signing)?;
        let value = encode(
            &header,
            &Claims {
                iss: &self.team_id,
                iat: issued_at,
            },
            &signing_key,
        )
        .map_err(ApnsRequestError::Signing)?;
        *cached = Some(CachedProviderToken {
            issued_at,
            value: value.clone(),
        });
        Ok(value)
    }

    fn base_url(&self) -> &'static str {
        match self.environment {
            ApnsEnvironment::Production => "https://api.push.apple.com",
            ApnsEnvironment::Sandbox => "https://api.sandbox.push.apple.com",
        }
    }
}

/// APNs event kind, including Apple's required priority policy.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum ApnsEvent {
    Start,
    Update,
    End,
}

impl ApnsEvent {
    fn priority(self) -> u8 {
        match self {
            Self::Start | Self::End => 10,
            Self::Update => 5,
        }
    }
}

/// A fully signed APNs request ready for an HTTP/2 transport.
pub struct PreparedApnsRequest {
    pub url: String,
    pub headers: HashMap<String, String>,
    pub body: Value,
}

/// Minimal APNs response data needed to distinguish acceptance from rejection.
pub struct ApnsTransportResponse {
    pub status: u16,
    pub reason: Option<String>,
}

/// HTTP/2 boundary used by production and fake APNs transports.
#[async_trait]
pub trait ApnsTransport: Send + Sync {
    async fn send(
        &self,
        request: PreparedApnsRequest,
    ) -> Result<ApnsTransportResponse, ApnsTransportError>;
}

/// Reqwest transport configured for TLS, HTTP/2 negotiation, and bounded calls.
pub struct ReqwestApnsTransport {
    client: reqwest::Client,
}

impl ReqwestApnsTransport {
    pub fn new() -> Result<Self, ApnsTransportBuildError> {
        let client = reqwest::Client::builder()
            .https_only(true)
            .http2_adaptive_window(true)
            .connect_timeout(std::time::Duration::from_secs(10))
            .timeout(std::time::Duration::from_secs(30))
            .build()
            .map_err(|_| ApnsTransportBuildError)?;
        Ok(Self { client })
    }
}

#[async_trait]
impl ApnsTransport for ReqwestApnsTransport {
    async fn send(
        &self,
        request: PreparedApnsRequest,
    ) -> Result<ApnsTransportResponse, ApnsTransportError> {
        let mut builder = self.client.post(request.url).json(&request.body);
        for (name, value) in request.headers {
            builder = builder.header(name, value);
        }
        let response = builder
            .send()
            .await
            .map_err(|_| ApnsTransportError::Network)?;
        let status = response.status().as_u16();
        let bytes = response
            .bytes()
            .await
            .map_err(|_| ApnsTransportError::Network)?;
        if bytes.len() > 16 * 1024 {
            return Err(ApnsTransportError::OversizedResponse);
        }
        let reason = serde_json::from_slice::<Value>(&bytes)
            .ok()
            .and_then(|body| body["reason"].as_str().map(str::to_owned));
        Ok(ApnsTransportResponse { status, reason })
    }
}

/// The production HTTP/2 client could not be constructed.
#[derive(Clone, Copy, Debug, Eq, Error, PartialEq)]
#[error("could not build APNs HTTP/2 transport")]
pub struct ApnsTransportBuildError;

/// A configured APNs client that reports acceptance, never device delivery.
pub struct ApnsClient {
    config: ApnsConfig,
    transport: Arc<dyn ApnsTransport>,
}

impl ApnsClient {
    pub fn new(config: ApnsConfig, transport: Arc<dyn ApnsTransport>) -> Self {
        Self { config, transport }
    }

    /// Signs and submits one request, returning success only for APNs HTTP 200 acceptance.
    pub async fn send(
        &self,
        token: &DeviceToken,
        event: ApnsEvent,
        body: Value,
        issued_at: i64,
    ) -> Result<ApnsAccepted, ApnsSendError> {
        let request = self
            .config
            .prepare_request(token, event, body, issued_at)
            .map_err(ApnsSendError::Request)?;
        let response = self
            .transport
            .send(request)
            .await
            .map_err(ApnsSendError::Transport)?;
        if response.status == 200 {
            return Ok(ApnsAccepted);
        }

        Err(ApnsSendError::Rejected {
            status: response.status,
            reason: response
                .reason
                .unwrap_or_else(|| "unknown reason".to_string()),
        })
    }
}

/// Proof that APNs accepted a request; it does not prove device delivery.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct ApnsAccepted;

/// The owned HTTP transport failed without retaining a token-bearing URL.
#[derive(Clone, Copy, Debug, Eq, Error, PartialEq)]
pub enum ApnsTransportError {
    #[error("APNs HTTP/2 transport failed")]
    Network,
    #[error("APNs returned an oversized response")]
    OversizedResponse,
}

/// A request was not accepted by APNs.
#[derive(Debug, Error)]
pub enum ApnsSendError {
    #[error(transparent)]
    Request(#[from] ApnsRequestError),
    #[error(transparent)]
    Transport(#[from] ApnsTransportError),
    #[error("APNs rejected the request ({status} {reason})")]
    Rejected { status: u16, reason: String },
}

/// APNs request construction failed before any network call.
#[derive(Debug, Error)]
pub enum ApnsRequestError {
    #[error("could not create APNs ES256 authentication token")]
    Signing(#[source] jsonwebtoken::errors::Error),
}

/// Invalid optional APNs process configuration without exposing secret values.
#[derive(Clone, Copy, Debug, Eq, Error, PartialEq)]
pub enum ApnsConfigError {
    #[error(
        "PULLBOX_APNS_TEAM_ID, PULLBOX_APNS_KEY_ID, and PULLBOX_APNS_PRIVATE_KEY_PEM must be set together"
    )]
    PartialCredentials,
    #[error("PULLBOX_APNS_ENVIRONMENT must be production or sandbox")]
    InvalidEnvironment,
    #[error("PULLBOX_APNS_TOPIC must not be empty")]
    EmptyTopic,
}

#[derive(Clone, Default, Deserialize, Serialize)]
struct TokenMaps {
    push_to_start: HashMap<String, DeviceToken>,
    updates: HashMap<String, HashMap<String, DeviceToken>>,
}

/// Concurrency-safe APNs token storage with optional atomic file persistence.
#[derive(Clone)]
pub struct TokenRegistry {
    inner: Arc<RwLock<TokenMaps>>,
    storage_path: Option<Arc<PathBuf>>,
    update_notify: Arc<Notify>,
}

impl Default for TokenRegistry {
    fn default() -> Self {
        Self {
            inner: Arc::new(RwLock::new(TokenMaps::default())),
            storage_path: None,
            update_notify: Arc::new(Notify::new()),
        }
    }
}

impl TokenRegistry {
    /// Loads a registry from an owner-only file, or starts empty if it doesn't exist.
    pub fn persistent(path: impl AsRef<Path>) -> Result<Self, TokenRegistryError> {
        let path = path.as_ref().to_path_buf();
        let maps = match fs::read(&path) {
            Ok(bytes) => serde_json::from_slice(&bytes)?,
            Err(error) if error.kind() == io::ErrorKind::NotFound => TokenMaps::default(),
            Err(error) => return Err(error.into()),
        };
        Ok(Self {
            inner: Arc::new(RwLock::new(maps)),
            storage_path: Some(Arc::new(path)),
            update_notify: Arc::new(Notify::new()),
        })
    }

    /// Replaces the push-to-start token for one client installation.
    pub fn register_push_to_start(
        &self,
        client_id: &str,
        token: DeviceToken,
    ) -> Result<(), TokenRegistryError> {
        let mut maps = self.write();
        let original = maps.clone();
        maps.push_to_start.insert(client_id.to_owned(), token);
        if let Err(error) = self.persist(&maps) {
            *maps = original;
            return Err(error);
        }
        Ok(())
    }

    /// Replaces the per-activity update token for one client request.
    pub fn register_update(
        &self,
        client_id: &str,
        request_id: &str,
        token: DeviceToken,
    ) -> Result<(), TokenRegistryError> {
        let mut maps = self.write();
        let original = maps.clone();
        maps.updates
            .entry(client_id.to_owned())
            .or_default()
            .insert(request_id.to_owned(), token);
        if let Err(error) = self.persist(&maps) {
            *maps = original;
            return Err(error);
        }
        drop(maps);
        self.update_notify.notify_waiters();
        Ok(())
    }

    /// Retrieves a cloned token so no registry lock is held during network I/O.
    pub fn push_to_start(&self, client_id: &str) -> Option<DeviceToken> {
        self.read().push_to_start.get(client_id).cloned()
    }

    /// Retrieves a cloned token so no registry lock is held during network I/O.
    pub fn update_token(&self, client_id: &str, request_id: &str) -> Option<DeviceToken> {
        self.read()
            .updates
            .get(client_id)
            .and_then(|requests| requests.get(request_id))
            .cloned()
    }

    /// Waits briefly for iOS to register the per-activity token after push-to-start.
    pub async fn wait_for_update_token(
        &self,
        client_id: &str,
        request_id: &str,
        maximum_wait: Duration,
    ) -> Option<DeviceToken> {
        if let Some(token) = self.update_token(client_id, request_id) {
            return Some(token);
        }

        let notified = self.update_notify.notified();
        if let Some(token) = self.update_token(client_id, request_id) {
            return Some(token);
        }

        let _ = actix_web::rt::time::timeout(maximum_wait, notified).await;
        self.update_token(client_id, request_id)
    }

    fn persist(&self, maps: &TokenMaps) -> Result<(), TokenRegistryError> {
        let Some(path) = self.storage_path.as_deref() else {
            return Ok(());
        };
        if let Some(parent) = path.parent() {
            fs::create_dir_all(parent)?;
        }
        let temporary = path.with_extension(format!("tmp-{}", uuid::Uuid::new_v4()));
        let result = (|| {
            let mut options = OpenOptions::new();
            options.create_new(true).write(true);
            #[cfg(unix)]
            {
                use std::os::unix::fs::OpenOptionsExt;
                options.mode(0o600);
            }
            let mut file = options.open(&temporary)?;
            file.write_all(&serde_json::to_vec(maps)?)?;
            file.sync_all()?;
            fs::rename(&temporary, path)?;
            #[cfg(unix)]
            {
                use std::os::unix::fs::PermissionsExt;
                fs::set_permissions(path, fs::Permissions::from_mode(0o600))?;
            }
            Ok::<(), TokenRegistryError>(())
        })();
        if result.is_err() {
            let _ = fs::remove_file(&temporary);
        }
        result
    }

    fn read(&self) -> RwLockReadGuard<'_, TokenMaps> {
        self.inner
            .read()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
    }

    fn write(&self) -> RwLockWriteGuard<'_, TokenMaps> {
        self.inner
            .write()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
    }
}

#[derive(Debug, Error)]
pub enum TokenRegistryError {
    #[error("could not access the Live Activity token store")]
    Io(#[from] io::Error),
    #[error("the Live Activity token store is invalid")]
    Json(#[from] serde_json::Error),
}

/// Correlates one download request with its client installation and ActivityKit attributes.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct ActivityNotificationContext {
    client_id: String,
    activity: ActivityDescriptor,
}

impl ActivityNotificationContext {
    pub fn new(
        client_id: impl Into<String>,
        request_id: impl Into<String>,
        title: impl Into<String>,
        source_url: impl Into<String>,
    ) -> Self {
        Self {
            client_id: client_id.into(),
            activity: ActivityDescriptor::new(request_id, title, source_url),
        }
    }

    pub fn client_id(&self) -> &str {
        &self.client_id
    }

    pub fn request_id(&self) -> &str {
        &self.activity.request_id
    }

    pub fn title(&self) -> &str {
        &self.activity.title
    }

    pub fn source_url(&self) -> &str {
        &self.activity.source_url
    }
}

/// Honest result of attempting a notification; acceptance is not device delivery.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum NotificationOutcome {
    Accepted,
    MissingToken,
    Disabled,
}

/// Live Activity notification boundary used by downloads and fakes.
#[async_trait]
pub trait ActivityNotifier: Send + Sync {
    async fn start(
        &self,
        context: &ActivityNotificationContext,
        timestamp: i64,
    ) -> Result<NotificationOutcome, ApnsSendError>;

    async fn progress(
        &self,
        context: &ActivityNotificationContext,
        progress: f64,
        timestamp: i64,
    ) -> Result<NotificationOutcome, ApnsSendError>;

    async fn ready(
        &self,
        context: &ActivityNotificationContext,
        timestamp: i64,
    ) -> Result<NotificationOutcome, ApnsSendError>;

    async fn failed(
        &self,
        context: &ActivityNotificationContext,
        message: &str,
        timestamp: i64,
    ) -> Result<NotificationOutcome, ApnsSendError>;
}

/// Registry-backed ActivityKit notifier using push-to-start then per-activity tokens.
pub struct ApnsActivityNotifier {
    registry: TokenRegistry,
    client: Arc<ApnsClient>,
}

impl ApnsActivityNotifier {
    pub fn new(registry: TokenRegistry, client: Arc<ApnsClient>) -> Self {
        Self { registry, client }
    }

    async fn send_update(
        &self,
        context: &ActivityNotificationContext,
        event: ApnsEvent,
        payload: Value,
        timestamp: i64,
    ) -> Result<NotificationOutcome, ApnsSendError> {
        let Some(token) = self
            .registry
            .wait_for_update_token(
                &context.client_id,
                &context.activity.request_id,
                Duration::from_secs(5),
            )
            .await
        else {
            return Ok(NotificationOutcome::MissingToken);
        };
        self.client.send(&token, event, payload, timestamp).await?;
        Ok(NotificationOutcome::Accepted)
    }
}

#[async_trait]
impl ActivityNotifier for ApnsActivityNotifier {
    async fn start(
        &self,
        context: &ActivityNotificationContext,
        timestamp: i64,
    ) -> Result<NotificationOutcome, ApnsSendError> {
        let Some(token) = self.registry.push_to_start(&context.client_id) else {
            return Ok(NotificationOutcome::MissingToken);
        };
        self.client
            .send(
                &token,
                ApnsEvent::Start,
                build_start_payload(&context.activity, timestamp),
                timestamp,
            )
            .await?;
        Ok(NotificationOutcome::Accepted)
    }

    async fn progress(
        &self,
        context: &ActivityNotificationContext,
        progress: f64,
        timestamp: i64,
    ) -> Result<NotificationOutcome, ApnsSendError> {
        self.send_update(
            context,
            ApnsEvent::Update,
            build_update_payload(&context.activity, timestamp, progress),
            timestamp,
        )
        .await
    }

    async fn ready(
        &self,
        context: &ActivityNotificationContext,
        timestamp: i64,
    ) -> Result<NotificationOutcome, ApnsSendError> {
        self.send_update(
            context,
            ApnsEvent::Update,
            build_server_ready_payload(&context.activity, timestamp),
            timestamp,
        )
        .await
    }

    async fn failed(
        &self,
        context: &ActivityNotificationContext,
        message: &str,
        timestamp: i64,
    ) -> Result<NotificationOutcome, ApnsSendError> {
        self.send_update(
            context,
            ApnsEvent::End,
            build_failure_payload(&context.activity, timestamp, message),
            timestamp,
        )
        .await
    }
}

/// Disabled notifier used when no complete APNs credential set is configured.
pub struct DisabledActivityNotifier;

#[async_trait]
impl ActivityNotifier for DisabledActivityNotifier {
    async fn start(
        &self,
        _context: &ActivityNotificationContext,
        _timestamp: i64,
    ) -> Result<NotificationOutcome, ApnsSendError> {
        Ok(NotificationOutcome::Disabled)
    }

    async fn progress(
        &self,
        _context: &ActivityNotificationContext,
        _progress: f64,
        _timestamp: i64,
    ) -> Result<NotificationOutcome, ApnsSendError> {
        Ok(NotificationOutcome::Disabled)
    }

    async fn ready(
        &self,
        _context: &ActivityNotificationContext,
        _timestamp: i64,
    ) -> Result<NotificationOutcome, ApnsSendError> {
        Ok(NotificationOutcome::Disabled)
    }

    async fn failed(
        &self,
        _context: &ActivityNotificationContext,
        _message: &str,
        _timestamp: i64,
    ) -> Result<NotificationOutcome, ApnsSendError> {
        Ok(NotificationOutcome::Disabled)
    }
}

/// Cloneable Actix application-data wrapper around a notification implementation.
#[derive(Clone)]
pub struct ActivityNotifierHandle(Arc<dyn ActivityNotifier>);

impl ActivityNotifierHandle {
    pub fn new(notifier: Arc<dyn ActivityNotifier>) -> Self {
        Self(notifier)
    }
}

/// Best-effort notification lifecycle for one synchronous media response.
pub struct DownloadNotificationSession {
    context: Option<ActivityNotificationContext>,
    notifier: Option<ActivityNotifierHandle>,
}

impl DownloadNotificationSession {
    /// Starts the remote activity before any expensive download work when metadata is complete.
    pub async fn begin(
        context: Option<ActivityNotificationContext>,
        notifier: Option<ActivityNotifierHandle>,
    ) -> Self {
        let session = Self { context, notifier };
        if let (Some(context), Some(notifier)) = (&session.context, &session.notifier) {
            if let Err(error) = notifier.0.start(context, unix_timestamp()).await {
                log::warn!("Live Activity start was not accepted: {error}");
            }
        }
        session
    }

    pub async fn progress(&self, progress: f64) {
        if let (Some(context), Some(notifier)) = (&self.context, &self.notifier) {
            if let Err(error) = notifier
                .0
                .progress(context, progress, unix_timestamp())
                .await
            {
                log::warn!("Live Activity progress was not accepted: {error}");
            }
        }
    }

    /// Leaves the activity active at 0.9 for the client-owned transfer and save phases.
    pub async fn ready(&self) {
        if let (Some(context), Some(notifier)) = (&self.context, &self.notifier) {
            if let Err(error) = notifier.0.ready(context, unix_timestamp()).await {
                log::warn!("Live Activity server-ready update was not accepted: {error}");
            }
        }
    }

    /// Ends the activity only because server-side processing failed.
    pub async fn failed(&self, message: &str) {
        if let (Some(context), Some(notifier)) = (&self.context, &self.notifier) {
            if let Err(error) = notifier.0.failed(context, message, unix_timestamp()).await {
                log::warn!("Live Activity failure update was not accepted: {error}");
            }
        }
    }
}

fn unix_timestamp() -> i64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .ok()
        .and_then(|duration| i64::try_from(duration.as_secs()).ok())
        .unwrap_or(0)
}

/// Metadata shared by every notification for one download Live Activity.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct ActivityDescriptor {
    request_id: String,
    title: String,
    source_url: String,
}

impl ActivityDescriptor {
    /// Creates a descriptor from server-validated request metadata.
    pub fn new(
        request_id: impl Into<String>,
        title: impl Into<String>,
        source_url: impl Into<String>,
    ) -> Self {
        Self {
            request_id: request_id.into(),
            title: title.into(),
            source_url: source_url.into(),
        }
    }
}

/// Builds an iOS 18+ push-to-start payload for Pullbox's ActivityKit schema.
pub fn build_start_payload(activity: &ActivityDescriptor, timestamp: i64) -> Value {
    json!({
        "aps": {
            "timestamp": timestamp,
            "event": "start",
            "content-state": {
                "status": "preparing",
                "progress": null,
                "title": activity.title,
                "errorMessage": null
            },
            "attributes-type": "PullboxDownloadAttributes",
            "attributes": {
                "id": activity.request_id,
                "sourceURL": activity.source_url
            },
            "alert": {
                "title": activity.title,
                "body": "Pullbox is preparing your download."
            },
            "input-push-token": 1
        }
    })
}

/// Builds a quiet update containing only honest server-side download progress.
pub fn build_update_payload(activity: &ActivityDescriptor, timestamp: i64, progress: f64) -> Value {
    let progress = progress.clamp(0.0, MAX_SERVER_PROGRESS);
    json!({
        "aps": {
            "timestamp": timestamp,
            "event": "update",
            "content-state": {
                "status": "downloading",
                "progress": progress,
                "title": activity.title,
                "errorMessage": null
            }
        }
    })
}

/// Marks backend processing complete while leaving final transfer and success to iOS.
pub fn build_server_ready_payload(activity: &ActivityDescriptor, timestamp: i64) -> Value {
    json!({
        "aps": {
            "timestamp": timestamp,
            "event": "update",
            "content-state": {
                "status": "downloading",
                "progress": MAX_SERVER_PROGRESS,
                "title": activity.title,
                "errorMessage": null
            }
        }
    })
}

/// Ends a Live Activity with a caller-supplied, user-safe failure message.
pub fn build_failure_payload(
    activity: &ActivityDescriptor,
    timestamp: i64,
    message: &str,
) -> Value {
    json!({
        "aps": {
            "timestamp": timestamp,
            "event": "end",
            "content-state": {
                "status": "failed",
                "progress": null,
                "title": activity.title,
                "errorMessage": message
            },
            "alert": {
                "title": "Download failed",
                "body": message
            }
        }
    })
}
