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
use tokio::sync::{mpsc, watch, Notify};
use url::Url;

const MAX_DEVICE_TOKEN_HEX_LENGTH: usize = 256;
const MAX_REGISTRY_KEY_BYTES: usize = 128;
const MAX_ACTIVITY_TITLE_CHARACTERS: usize = 160;
const MAX_ACTIVITY_SOURCE_URL_BYTES: usize = 1_024;
const MAX_APNS_PAYLOAD_BYTES: usize = 4 * 1_024;
pub const TERMINAL_TOMBSTONE_TTL_SECONDS: i64 = 24 * 60 * 60;

/// A validated APNs device token whose formatting never exposes its bytes.
#[derive(Clone, Eq, Hash, PartialEq)]
pub struct DeviceToken(String);

impl DeviceToken {
    /// Parses the APNs hexadecimal wire representation.
    pub fn parse(value: &str) -> Result<Self, DeviceTokenError> {
        if value.is_empty()
            || value.len() > MAX_DEVICE_TOKEN_HEX_LENGTH
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
            (None, None, None) if topic.is_none() && environment.is_none() => return Ok(None),
            (Some(team_id), Some(key_id), Some(private_key_pem))
                if !team_id.is_empty() && !key_id.is_empty() && !private_key_pem.is_empty() =>
            {
                (team_id, key_id, private_key_pem)
            }
            _ => return Err(ApnsConfigError::PartialCredentials),
        };
        let environment = match environment.as_deref() {
            Some("production") => ApnsEnvironment::Production,
            Some("sandbox") => ApnsEnvironment::Sandbox,
            Some(_) => return Err(ApnsConfigError::InvalidEnvironment),
            None => return Err(ApnsConfigError::MissingEnvironment),
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
        let payload_size = serde_json::to_vec(&body)
            .map_err(ApnsRequestError::Serialization)?
            .len();
        if payload_size > MAX_APNS_PAYLOAD_BYTES {
            return Err(ApnsRequestError::PayloadTooLarge {
                actual: payload_size,
                maximum: MAX_APNS_PAYLOAD_BYTES,
            });
        }
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
    #[error("could not serialize APNs payload")]
    Serialization(#[source] serde_json::Error),
    #[error("APNs payload is {actual} bytes; maximum is {maximum}")]
    PayloadTooLarge { actual: usize, maximum: usize },
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
    #[error("PULLBOX_APNS_ENVIRONMENT must be set when APNs credentials are configured")]
    MissingEnvironment,
    #[error("PULLBOX_APNS_TOPIC must not be empty")]
    EmptyTopic,
}

#[derive(Clone, Default, Serialize)]
struct TokenMaps {
    push_to_start: HashMap<String, DeviceToken>,
    updates: HashMap<String, HashMap<String, DeviceToken>>,
    terminal_requests: HashMap<String, HashMap<String, i64>>,
}

#[derive(Default, Deserialize)]
struct StoredTokenMaps {
    #[serde(default)]
    push_to_start: HashMap<String, String>,
    #[serde(default)]
    updates: HashMap<String, HashMap<String, String>>,
    #[serde(default)]
    terminal_requests: HashMap<String, HashMap<String, i64>>,
}

impl StoredTokenMaps {
    fn validated(self) -> TokenMaps {
        let push_to_start = self
            .push_to_start
            .into_iter()
            .filter(|(client_id, _)| registry_key_is_valid(client_id))
            .filter_map(|(client_id, raw)| {
                DeviceToken::parse(&raw)
                    .ok()
                    .map(|token| (client_id, token))
            })
            .take(DEFAULT_MAX_REGISTERED_CLIENTS)
            .collect();
        let updates = self
            .updates
            .into_iter()
            .filter(|(client_id, _)| registry_key_is_valid(client_id))
            .filter_map(|(client_id, requests)| {
                let requests = requests
                    .into_iter()
                    .filter(|(request_id, _)| registry_key_is_valid(request_id))
                    .filter_map(|(request_id, raw)| {
                        DeviceToken::parse(&raw)
                            .ok()
                            .map(|token| (request_id, token))
                    })
                    .take(DEFAULT_MAX_UPDATE_TOKENS_PER_CLIENT)
                    .collect::<HashMap<_, _>>();
                (!requests.is_empty()).then_some((client_id, requests))
            })
            .take(DEFAULT_MAX_REGISTERED_CLIENTS)
            .collect();
        let terminal_requests = self
            .terminal_requests
            .into_iter()
            .filter(|(client_id, _)| registry_key_is_valid(client_id))
            .filter_map(|(client_id, requests)| {
                let requests = requests
                    .into_iter()
                    .filter(|(request_id, _)| registry_key_is_valid(request_id))
                    .take(DEFAULT_MAX_UPDATE_TOKENS_PER_CLIENT)
                    .collect::<HashMap<_, _>>();
                (!requests.is_empty()).then_some((client_id, requests))
            })
            .take(DEFAULT_MAX_REGISTERED_CLIENTS)
            .collect();
        TokenMaps {
            push_to_start,
            updates,
            terminal_requests,
        }
    }
}

fn registry_key_is_valid(value: &str) -> bool {
    let value = value.trim();
    !value.is_empty() && value.len() <= MAX_REGISTRY_KEY_BYTES
}

fn prune_expired_terminal_requests(maps: &mut TokenMaps, now: i64) {
    maps.terminal_requests.retain(|_, requests| {
        requests.retain(|_, expires_at| *expires_at > now);
        !requests.is_empty()
    });
}

const DEFAULT_MAX_REGISTERED_CLIENTS: usize = 10_000;
const DEFAULT_MAX_UPDATE_TOKENS_PER_CLIENT: usize = 128;

#[derive(Clone, Copy)]
struct TokenRegistryLimits {
    max_clients: usize,
    max_updates_per_client: usize,
}

impl Default for TokenRegistryLimits {
    fn default() -> Self {
        Self {
            max_clients: DEFAULT_MAX_REGISTERED_CLIENTS,
            max_updates_per_client: DEFAULT_MAX_UPDATE_TOKENS_PER_CLIENT,
        }
    }
}

/// Concurrency-safe APNs token storage with optional atomic file persistence.
#[derive(Clone)]
pub struct TokenRegistry {
    inner: Arc<RwLock<TokenMaps>>,
    storage_path: Option<Arc<PathBuf>>,
    update_notify: Arc<Notify>,
    limits: TokenRegistryLimits,
}

impl Default for TokenRegistry {
    fn default() -> Self {
        Self::with_limits(
            DEFAULT_MAX_REGISTERED_CLIENTS,
            DEFAULT_MAX_UPDATE_TOKENS_PER_CLIENT,
        )
    }
}

impl TokenRegistry {
    /// Creates an in-memory registry with explicit capacity limits.
    pub fn with_limits(max_clients: usize, max_updates_per_client: usize) -> Self {
        Self {
            inner: Arc::new(RwLock::new(TokenMaps::default())),
            storage_path: None,
            update_notify: Arc::new(Notify::new()),
            limits: TokenRegistryLimits {
                max_clients,
                max_updates_per_client,
            },
        }
    }

    /// Loads a registry from an owner-only file, or starts empty if it doesn't exist.
    pub fn persistent(path: impl AsRef<Path>) -> Result<Self, TokenRegistryError> {
        let path = path.as_ref().to_path_buf();
        match fs::symlink_metadata(&path) {
            Ok(metadata) => {
                if !metadata.file_type().is_file() {
                    return Err(io::Error::new(
                        io::ErrorKind::InvalidInput,
                        "Live Activity token store must be a regular file",
                    )
                    .into());
                }
                #[cfg(unix)]
                {
                    use std::os::unix::fs::PermissionsExt;
                    fs::set_permissions(&path, fs::Permissions::from_mode(0o600))?;
                }
            }
            Err(error) if error.kind() == io::ErrorKind::NotFound => {}
            Err(error) => return Err(error.into()),
        }
        let (maps, existed) = match fs::read(&path) {
            Ok(bytes) => {
                let stored: StoredTokenMaps = serde_json::from_slice(&bytes)?;
                (stored.validated(), true)
            }
            Err(error) if error.kind() == io::ErrorKind::NotFound => (TokenMaps::default(), false),
            Err(error) => return Err(error.into()),
        };
        let registry = Self {
            inner: Arc::new(RwLock::new(maps.clone())),
            storage_path: Some(Arc::new(path)),
            update_notify: Arc::new(Notify::new()),
            limits: TokenRegistryLimits::default(),
        };
        if existed {
            registry.persist(&maps)?;
        }
        Ok(registry)
    }

    /// Replaces the push-to-start token for one client installation.
    pub fn register_push_to_start(
        &self,
        client_id: &str,
        token: DeviceToken,
    ) -> Result<(), TokenRegistryError> {
        let mut maps = self.write();
        if !maps.push_to_start.contains_key(client_id)
            && maps.push_to_start.len() >= self.limits.max_clients
        {
            return Err(TokenRegistryError::CapacityExceeded);
        }
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
        prune_expired_terminal_requests(&mut maps, unix_timestamp());
        if maps
            .terminal_requests
            .get(client_id)
            .is_some_and(|requests| requests.contains_key(request_id))
        {
            if let Err(error) = self.persist(&maps) {
                *maps = original;
                return Err(error);
            }
            return Ok(());
        }
        if !maps.updates.contains_key(client_id)
            && maps.updates.len() >= self.limits.max_clients
        {
            *maps = original;
            return Err(TokenRegistryError::CapacityExceeded);
        }
        if maps
            .updates
            .get(client_id)
            .is_some_and(|requests| {
                !requests.contains_key(request_id)
                    && requests.len() >= self.limits.max_updates_per_client
            })
        {
            *maps = original;
            return Err(TokenRegistryError::CapacityExceeded);
        }
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

    /// Marks a request terminal, removes its token, and prevents late re-registration.
    pub fn mark_terminal(
        &self,
        client_id: &str,
        request_id: &str,
    ) -> Result<(), TokenRegistryError> {
        let mut maps = self.write();
        let original = maps.clone();
        prune_expired_terminal_requests(&mut maps, unix_timestamp());
        if let Some(requests) = maps.updates.get_mut(client_id) {
            requests.remove(request_id);
            if requests.is_empty() {
                maps.updates.remove(client_id);
            }
        }
        maps.terminal_requests
            .entry(client_id.to_owned())
            .or_default()
            .insert(
                request_id.to_owned(),
                unix_timestamp().saturating_add(TERMINAL_TOMBSTONE_TTL_SECONDS),
            );
        if let Err(error) = self.persist(&maps) {
            *maps = original;
            return Err(error);
        }
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
        wait: Duration,
    ) -> Option<DeviceToken> {
        let deadline = tokio::time::Instant::now() + wait;
        loop {
            if let Some(token) = self.update_token(client_id, request_id) {
                return Some(token);
            }

            let notified = self.update_notify.notified();
            if let Some(token) = self.update_token(client_id, request_id) {
                return Some(token);
            }

            if tokio::time::timeout_at(deadline, notified).await.is_err() {
                return None;
            }
        }
    }

    /// Removes a per-download token after the backend's final use and persists the change.
    pub fn remove_update(
        &self,
        client_id: &str,
        request_id: &str,
    ) -> Result<bool, TokenRegistryError> {
        let mut maps = self.write();
        let original = maps.clone();
        let removed = maps
            .updates
            .get_mut(client_id)
            .and_then(|requests| requests.remove(request_id))
            .is_some();
        if maps.updates.get(client_id).is_some_and(HashMap::is_empty) {
            maps.updates.remove(client_id);
        }
        if removed {
            if let Err(error) = self.persist(&maps) {
                *maps = original;
                return Err(error);
            }
        }
        Ok(removed)
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
            if let Some(parent) = path.parent() {
                fs::File::open(parent)?.sync_all()?;
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
    #[error("the Live Activity token registry reached its capacity")]
    CapacityExceeded,
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

    fn mark_terminal(&self, context: &ActivityNotificationContext) {
        if let Err(error) = self
            .registry
            .mark_terminal(&context.client_id, &context.activity.request_id)
        {
            log::error!("Could not persist completed Live Activity state: {error}");
        }
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
        let result = self
            .send_update(
                context,
                ApnsEvent::Update,
                build_server_ready_payload(&context.activity, timestamp),
                timestamp,
            )
            .await;
        self.mark_terminal(context);
        result
    }

    async fn failed(
        &self,
        context: &ActivityNotificationContext,
        message: &str,
        timestamp: i64,
    ) -> Result<NotificationOutcome, ApnsSendError> {
        let result = self
            .send_update(
                context,
                ApnsEvent::End,
                build_failure_payload(&context.activity, timestamp, message),
                timestamp,
            )
            .await;
        self.mark_terminal(context);
        result
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

/// Best-effort lifecycle events placed on a fixed-capacity control queue.
enum NotificationLifecycleEvent {
    Start,
    Ready,
    Failed(String),
}

/// Best-effort notification lifecycle for one synchronous media response.
/// APNs delivery runs on an independent task and can never delay media processing.
pub struct DownloadNotificationSession {
    lifecycle_sender: Option<mpsc::Sender<NotificationLifecycleEvent>>,
    progress_sender: Option<watch::Sender<Option<f64>>>,
}

impl DownloadNotificationSession {
    /// Queues the remote start before expensive work without awaiting APNs.
    pub async fn begin(
        context: Option<ActivityNotificationContext>,
        notifier: Option<ActivityNotifierHandle>,
    ) -> Self {
        let (Some(context), Some(notifier)) = (context, notifier) else {
            return Self {
                lifecycle_sender: None,
                progress_sender: None,
            };
        };

        // At most start + one terminal event can be pending. Progress is a
        // coalescing latest-value channel, so notification memory is bounded.
        let (lifecycle_sender, mut lifecycle_receiver) = mpsc::channel(2);
        let (progress_sender, mut progress_receiver) = watch::channel(None::<f64>);
        lifecycle_sender
            .try_send(NotificationLifecycleEvent::Start)
            .expect("new notification lifecycle queue has capacity");

        actix_web::rt::spawn(async move {
            let Some(NotificationLifecycleEvent::Start) = lifecycle_receiver.recv().await else {
                return;
            };
            if let Err(error) = notifier.0.start(&context, unix_timestamp()).await {
                log::warn!("Live Activity start was not accepted: {error}");
            }

            let mut last_progress = None;
            loop {
                tokio::select! {
                    lifecycle = lifecycle_receiver.recv() => {
                        let Some(lifecycle) = lifecycle else { return; };
                        let latest = *progress_receiver.borrow_and_update();
                        publish_latest_progress(
                            &notifier,
                            &context,
                            latest,
                            &mut last_progress,
                        ).await;
                        match lifecycle {
                            NotificationLifecycleEvent::Start => {}
                            NotificationLifecycleEvent::Ready => {
                                if let Err(error) = notifier.0.ready(&context, unix_timestamp()).await {
                                    log::warn!("Live Activity server-ready update was not accepted: {error}");
                                }
                                return;
                            }
                            NotificationLifecycleEvent::Failed(message) => {
                                if let Err(error) = notifier
                                    .0
                                    .failed(&context, &message, unix_timestamp())
                                    .await
                                {
                                    log::warn!("Live Activity failure update was not accepted: {error}");
                                }
                                return;
                            }
                        }
                    }
                    changed = progress_receiver.changed() => {
                        if changed.is_err() {
                            return;
                        }
                        let latest = *progress_receiver.borrow_and_update();
                        publish_latest_progress(
                            &notifier,
                            &context,
                            latest,
                            &mut last_progress,
                        ).await;
                    }
                }
            }
        });

        Self {
            lifecycle_sender: Some(lifecycle_sender),
            progress_sender: Some(progress_sender),
        }
    }

    pub async fn progress(&self, progress: f64) {
        if let Some(sender) = &self.progress_sender {
            sender.send_replace(Some(progress));
        }
    }

    /// Leaves the activity active at 0.9 for the client-owned transfer and save phases.
    pub async fn ready(&self) {
        if let Some(sender) = &self.lifecycle_sender {
            let _ = sender.try_send(NotificationLifecycleEvent::Ready);
        }
    }

    /// Ends the activity only because server-side processing failed.
    pub async fn failed(&self, message: &str) {
        if let Some(sender) = &self.lifecycle_sender {
            let _ = sender.try_send(NotificationLifecycleEvent::Failed(message.to_owned()));
        }
    }
}

async fn publish_latest_progress(
    notifier: &ActivityNotifierHandle,
    context: &ActivityNotificationContext,
    latest: Option<f64>,
    last_progress: &mut Option<f64>,
) {
    let Some(progress) = latest else { return; };
    if last_progress.is_some_and(|previous| progress <= previous) {
        return;
    }
    *last_progress = Some(progress);
    if let Err(error) = notifier
        .0
        .progress(context, progress, unix_timestamp())
        .await
    {
        log::warn!("Live Activity progress was not accepted: {error}");
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
    /// Creates a descriptor with APNs-safe display metadata while retaining request identity.
    pub fn new(
        request_id: impl Into<String>,
        title: impl Into<String>,
        source_url: impl Into<String>,
    ) -> Self {
        let title = title.into();
        let source_url = source_url.into();
        Self {
            request_id: request_id.into(),
            title: bounded_activity_title(&title),
            source_url: bounded_activity_source_url(&source_url),
        }
    }
}

fn bounded_activity_title(title: &str) -> String {
    if title.chars().count() <= MAX_ACTIVITY_TITLE_CHARACTERS {
        return title.to_owned();
    }
    title
        .chars()
        .take(MAX_ACTIVITY_TITLE_CHARACTERS - 1)
        .chain(std::iter::once('…'))
        .collect()
}

fn bounded_activity_source_url(source_url: &str) -> String {
    if source_url.len() <= MAX_ACTIVITY_SOURCE_URL_BYTES {
        return source_url.to_owned();
    }
    activity_source_origin(source_url)
}

fn activity_source_origin(source_url: &str) -> String {
    Url::parse(source_url)
        .ok()
        .filter(|url| matches!(url.scheme(), "http" | "https"))
        .map(|url| format!("{}/", url.origin().ascii_serialization()))
        .filter(|origin| origin.len() <= MAX_ACTIVITY_SOURCE_URL_BYTES)
        .unwrap_or_else(|| "https://pullbox.invalid/".to_string())
}

/// Builds an iOS 18+ push-to-start payload for Pullbox's ActivityKit schema.
pub fn build_start_payload(activity: &ActivityDescriptor, timestamp: i64) -> Value {
    let payload = build_start_payload_value(activity, timestamp);
    if serialized_payload_fits(&payload) {
        return payload;
    }

    let mut bounded = activity.clone();
    while !bounded.title.is_empty() {
        bounded.title.pop();
        let payload = build_start_payload_value(&bounded, timestamp);
        if serialized_payload_fits(&payload) {
            return payload;
        }
    }

    bounded.title = activity.title.clone();
    bounded.source_url = activity_source_origin(&bounded.source_url);
    let mut payload = build_start_payload_value(&bounded, timestamp);
    while !serialized_payload_fits(&payload) && !bounded.title.is_empty() {
        bounded.title.pop();
        payload = build_start_payload_value(&bounded, timestamp);
    }
    payload
}

fn serialized_payload_fits(payload: &Value) -> bool {
    serde_json::to_vec(payload)
        .map(|bytes| bytes.len() <= 4 * 1024)
        .unwrap_or(false)
}

fn build_start_payload_value(activity: &ActivityDescriptor, timestamp: i64) -> Value {
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
