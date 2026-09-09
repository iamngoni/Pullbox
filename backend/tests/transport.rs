//! Verifies APNs delivery plumbing through a fake HTTP/2 boundary.

use async_trait::async_trait;
use p256::pkcs8::{EncodePrivateKey, LineEnding};
use pullbox_backend::apns::{
    ActivityNotificationContext, ActivityNotifier, ApnsActivityNotifier, ApnsClient, ApnsConfig,
    ApnsEvent, ApnsTransport, ApnsTransportError, ApnsTransportResponse, DeviceToken,
    NotificationOutcome, PreparedApnsRequest, ReqwestApnsTransport, TokenRegistry,
};
use serde_json::json;
use std::sync::{Arc, Mutex};

struct FakeTransport {
    requests: Mutex<Vec<PreparedApnsRequest>>,
    status: u16,
    reason: Option<String>,
}

#[async_trait]
impl ApnsTransport for FakeTransport {
    async fn send(
        &self,
        request: PreparedApnsRequest,
    ) -> Result<ApnsTransportResponse, ApnsTransportError> {
        self.requests.lock().unwrap().push(request);
        Ok(ApnsTransportResponse {
            status: self.status,
            reason: self.reason.clone(),
        })
    }
}

fn test_config() -> ApnsConfig {
    let secret = p256::SecretKey::from_slice(&[9_u8; 32]).expect("test P-256 key");
    let private_key = secret
        .to_pkcs8_pem(LineEnding::LF)
        .expect("test PKCS#8 PEM")
        .to_string();
    ApnsConfig::from_values(
        Some("TEAM123".to_string()),
        Some("KEY123".to_string()),
        Some(private_key),
        None,
        Some("sandbox".to_string()),
    )
    .expect("valid config")
    .expect("enabled config")
}

#[actix_rt::test]
async fn apns_client_does_not_treat_rejection_as_delivery_success() {
    let transport = Arc::new(FakeTransport {
        requests: Mutex::new(Vec::new()),
        status: 410,
        reason: Some("Unregistered".to_string()),
    });
    let client = ApnsClient::new(test_config(), transport.clone());

    let error = client
        .send(
            &DeviceToken::parse("aabbccdd").unwrap(),
            ApnsEvent::End,
            json!({"aps": {"event": "end"}}),
            1_725_000_000,
        )
        .await
        .expect_err("APNs rejection must remain a failure");

    assert_eq!(
        error.to_string(),
        "APNs rejected the request (410 Unregistered)"
    );
    assert_eq!(transport.requests.lock().unwrap().len(), 1);
}

#[test]
fn production_apns_http2_transport_configuration_builds() {
    ReqwestApnsTransport::new().expect("reqwest HTTP/2 transport");
}

#[actix_rt::test]
async fn activity_notifier_routes_start_updates_and_ready_to_the_right_tokens() {
    let registry = TokenRegistry::default();
    registry
        .register_push_to_start("client-123", DeviceToken::parse("aabbccdd").unwrap())
        .unwrap();
    let transport = Arc::new(FakeTransport {
        requests: Mutex::new(Vec::new()),
        status: 200,
        reason: None,
    });
    let client = Arc::new(ApnsClient::new(test_config(), transport.clone()));
    let notifier = ApnsActivityNotifier::new(registry.clone(), client);
    let context = ActivityNotificationContext::new(
        "client-123",
        "request-456",
        "Example clip",
        "https://example.com/video",
    );

    assert_eq!(
        notifier.start(&context, 1_725_000_000).await.unwrap(),
        NotificationOutcome::Accepted
    );
    registry
        .register_update(
            "client-123",
            "request-456",
            DeviceToken::parse("11223344").unwrap(),
        )
        .unwrap();
    assert_eq!(
        notifier
            .progress(&context, 0.42, 1_725_000_010)
            .await
            .unwrap(),
        NotificationOutcome::Accepted
    );
    assert_eq!(
        notifier.ready(&context, 1_725_000_020).await.unwrap(),
        NotificationOutcome::Accepted
    );

    let requests = transport.requests.lock().unwrap();
    assert_eq!(requests.len(), 3);
    assert!(requests[0].url.ends_with("/aabbccdd"));
    assert_eq!(requests[0].body["aps"]["event"], "start");
    assert!(requests[1].url.ends_with("/11223344"));
    assert_eq!(requests[1].body["aps"]["event"], "update");
    assert_eq!(requests[1].body["aps"]["content-state"]["progress"], 0.42);
    assert_eq!(requests[2].body["aps"]["event"], "update");
    assert_eq!(requests[2].body["aps"]["content-state"]["progress"], 0.9);
    assert_eq!(requests[2].headers["apns-priority"], "5");
    assert!(!requests[2]
        .body
        .to_string()
        .to_ascii_lowercase()
        .contains("saved"));
    assert!(registry.update_token("client-123", "request-456").is_none());
}

#[actix_rt::test]
async fn terminal_server_failure_releases_the_activity_update_token() {
    let registry = TokenRegistry::default();
    registry
        .register_update(
            "client-failed",
            "request-failed",
            DeviceToken::parse("11223344").unwrap(),
        )
        .unwrap();
    let transport = Arc::new(FakeTransport {
        requests: Mutex::new(Vec::new()),
        status: 200,
        reason: None,
    });
    let client = Arc::new(ApnsClient::new(test_config(), transport));
    let notifier = ApnsActivityNotifier::new(registry.clone(), client);
    let context = ActivityNotificationContext::new(
        "client-failed",
        "request-failed",
        "Failed clip",
        "https://example.com/video",
    );

    assert_eq!(
        notifier
            .failed(&context, "Download failed", 1_725_000_020)
            .await
            .unwrap(),
        NotificationOutcome::Accepted
    );
    assert!(registry
        .update_token("client-failed", "request-failed")
        .is_none());
}

#[actix_rt::test]
async fn first_update_waits_for_the_token_registered_after_push_start() {
    use std::time::Duration;

    let registry = TokenRegistry::default();
    let transport = Arc::new(FakeTransport {
        requests: Mutex::new(Vec::new()),
        status: 200,
        reason: None,
    });
    let client = Arc::new(ApnsClient::new(test_config(), transport.clone()));
    let notifier = Arc::new(ApnsActivityNotifier::new(registry.clone(), client));
    let context = ActivityNotificationContext::new(
        "client-late",
        "request-late",
        "Late token clip",
        "https://example.com/video",
    );

    let pending_notifier = notifier.clone();
    let pending_context = context.clone();
    let pending = actix_rt::spawn(async move {
        pending_notifier
            .progress(&pending_context, 0.42, 1_725_000_010)
            .await
    });

    actix_rt::time::sleep(Duration::from_millis(20)).await;
    registry
        .register_update(
            "client-late",
            "request-late",
            DeviceToken::parse("55667788").unwrap(),
        )
        .unwrap();

    let outcome = actix_rt::time::timeout(Duration::from_secs(1), pending)
        .await
        .expect("token wait timed out")
        .expect("progress task")
        .expect("APNs update");
    assert_eq!(outcome, NotificationOutcome::Accepted);
    assert_eq!(transport.requests.lock().unwrap().len(), 1);
}

#[actix_rt::test]
async fn ready_without_a_token_prevents_late_registration_from_leaking() {
    let registry = TokenRegistry::default();
    let transport = Arc::new(FakeTransport {
        requests: Mutex::new(Vec::new()),
        status: 200,
        reason: None,
    });
    let client = Arc::new(ApnsClient::new(test_config(), transport.clone()));
    let notifier = ApnsActivityNotifier::new(registry.clone(), client);
    let context = ActivityNotificationContext::new(
        "client-late-terminal",
        "request-late-terminal",
        "Late terminal clip",
        "https://example.com/video",
    );

    let outcome = notifier
        .ready(&context, 1_725_000_020)
        .await
        .expect("ready outcome");
    registry
        .register_update(
            "client-late-terminal",
            "request-late-terminal",
            DeviceToken::parse("55667788").unwrap(),
        )
        .expect("late registration is an accepted no-op");

    assert_eq!(outcome, NotificationOutcome::MissingToken);
    assert!(registry
        .update_token("client-late-terminal", "request-late-terminal")
        .is_none());
    assert!(transport.requests.lock().unwrap().is_empty());
}
