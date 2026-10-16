//! Verifies Pullbox's server-authored ActivityKit APNs contract.

use jsonwebtoken::{decode, decode_header, Algorithm, DecodingKey, Validation};
use p256::pkcs8::{EncodePrivateKey, EncodePublicKey, LineEnding};
use pullbox_backend::apns::{
    build_failure_payload, build_server_ready_payload, build_start_payload, build_update_payload,
    ActivityDescriptor, ApnsConfig, ApnsEvent, DeviceToken, MAX_SERVER_PROGRESS,
};
use serde_json::json;

#[derive(Debug, serde::Deserialize)]
struct ProviderClaims {
    iss: String,
    iat: i64,
}

#[test]
fn start_payload_matches_activitykit_contract() {
    let activity =
        ActivityDescriptor::new("request-123", "Example clip", "https://example.com/video");

    let payload = build_start_payload(&activity, 1_725_000_000);

    assert_eq!(
        payload,
        json!({
            "aps": {
                "timestamp": 1_725_000_000,
                "event": "start",
                "content-state": {
                    "status": "preparing",
                    "progress": null,
                    "title": "Example clip",
                    "errorMessage": null
                },
                "attributes-type": "PullboxDownloadAttributes",
                "attributes": {
                    "id": "request-123",
                    "sourceURL": "https://example.com/video"
                },
                "alert": {
                    "title": "Example clip",
                    "body": "Pullbox is preparing your download."
                },
                "input-push-token": 1
            }
        })
    );
}

#[test]
fn start_payload_bounds_display_metadata_without_changing_request_identity() {
    let activity = ActivityDescriptor::new(
        "request-123",
        "🦀".repeat(1_000),
        format!("https://example.com/video?signature={}", "a".repeat(10_000)),
    );

    let payload = build_start_payload(&activity, 1_725_000_000);
    let encoded = serde_json::to_vec(&payload).expect("encode payload");
    let title = payload["aps"]["content-state"]["title"]
        .as_str()
        .expect("bounded title");

    assert!(title.chars().count() <= 160);
    assert_eq!(payload["aps"]["attributes"]["id"], "request-123");
    assert_eq!(
        payload["aps"]["attributes"]["sourceURL"],
        "https://example.com/"
    );
    assert!(encoded.len() <= 4 * 1024);
}

#[test]
fn start_payload_enforces_the_serialized_apns_byte_limit() {
    let source_url = format!("https://example.com/?q={}", "\\".repeat(990));
    assert_eq!(source_url.len(), 1_013);
    let activity = ActivityDescriptor::new(
        "734B31C0-6CD7-47FB-B769-A03B73C468D2",
        "\u{0001}".repeat(160),
        source_url,
    );

    let encoded =
        serde_json::to_vec(&build_start_payload(&activity, 1_725_000_000)).expect("encode payload");

    assert!(
        encoded.len() <= 4 * 1024,
        "payload was {} bytes",
        encoded.len()
    );
}

#[test]
fn start_payload_trims_the_duplicated_title_before_losing_the_tap_target() {
    let source_url = format!("https://example.com/?q={}", "\\".repeat(990));
    let activity = ActivityDescriptor::new(
        "734B31C0-6CD7-47FB-B769-A03B73C468D2",
        "\u{0001}".repeat(160),
        source_url.clone(),
    );

    let payload = build_start_payload(&activity, 1_725_000_000);
    let encoded = serde_json::to_vec(&payload).expect("encode payload");
    let retained_title = payload["aps"]["content-state"]["title"]
        .as_str()
        .expect("title");

    assert_eq!(payload["aps"]["attributes"]["sourceURL"], source_url);
    assert_eq!(payload["aps"]["alert"]["title"], retained_title);
    assert!(retained_title.chars().count() < 160);
    assert!(
        encoded.len() <= 4 * 1024,
        "payload was {} bytes",
        encoded.len()
    );
}

#[test]
fn update_payload_reports_fractional_server_download_progress() {
    let activity =
        ActivityDescriptor::new("request-123", "Example clip", "https://example.com/video");

    let payload = build_update_payload(&activity, 1_725_000_010, 0.42);

    assert_eq!(
        payload,
        json!({
            "aps": {
                "timestamp": 1_725_000_010,
                "event": "update",
                "content-state": {
                    "status": "downloading",
                    "progress": 0.42,
                    "title": "Example clip",
                    "errorMessage": null
                }
            }
        })
    );
}

#[test]
fn server_progress_is_bounded_to_the_server_owned_range() {
    let activity =
        ActivityDescriptor::new("request-123", "Example clip", "https://example.com/video");

    let above = build_update_payload(&activity, 1_725_000_011, 1.0);
    let below = build_update_payload(&activity, 1_725_000_012, -0.5);

    assert_eq!(
        above["aps"]["content-state"]["progress"],
        MAX_SERVER_PROGRESS
    );
    assert_eq!(below["aps"]["content-state"]["progress"], 0.0);
}

#[test]
fn server_processing_completion_reserves_terminal_success_for_ios() {
    let activity =
        ActivityDescriptor::new("request-123", "Example clip", "https://example.com/video");

    let payload = build_server_ready_payload(&activity, 1_725_000_020);

    assert_eq!(MAX_SERVER_PROGRESS, 0.9);
    assert_eq!(payload["aps"]["event"], "update");
    assert_eq!(payload["aps"]["content-state"]["status"], "downloading");
    assert_eq!(
        payload["aps"]["content-state"]["progress"],
        MAX_SERVER_PROGRESS
    );
    assert!(payload["aps"].get("alert").is_none());
    assert!(!payload.to_string().to_ascii_lowercase().contains("photos"));
    assert!(!payload.to_string().to_ascii_lowercase().contains("saved"));
    assert!(!payload.to_string().contains("succeeded"));
}

#[test]
fn failure_payload_ends_with_a_safe_error_state() {
    let activity =
        ActivityDescriptor::new("request-123", "Example clip", "https://example.com/video");

    let payload = build_failure_payload(
        &activity,
        1_725_000_030,
        "Pullbox couldn't finish this download.",
    );

    assert_eq!(payload["aps"]["event"], "end");
    assert_eq!(payload["aps"]["content-state"]["status"], "failed");
    assert_eq!(payload["aps"]["content-state"]["progress"], json!(null));
    assert_eq!(
        payload["aps"]["content-state"]["errorMessage"],
        "Pullbox couldn't finish this download."
    );
    assert_eq!(payload["aps"]["alert"]["title"], "Download failed");
}

#[test]
fn apns_config_is_optional_but_rejects_partial_credentials() {
    let disabled = ApnsConfig::from_values(None, None, None, None, None)
        .expect("fully absent APNs credentials");
    assert!(disabled.is_none());

    let partial = ApnsConfig::from_values(Some("TEAM123".to_string()), None, None, None, None);
    let error = match partial {
        Err(error) => error,
        Ok(_) => panic!("partial config must fail"),
    };
    assert_eq!(
        error.to_string(),
        "PULLBOX_APNS_TEAM_ID, PULLBOX_APNS_KEY_ID, and PULLBOX_APNS_PRIVATE_KEY_PEM must be set together"
    );
}

#[test]
fn apns_config_rejects_settings_without_credentials() {
    let configured_environment = ApnsConfig::from_values(
        None,
        None,
        None,
        None,
        Some("sandbox".to_string()),
    );

    let error = match configured_environment {
        Err(error) => error,
        Ok(_) => panic!("APNs settings without credentials must fail"),
    };
    assert_eq!(
        error.to_string(),
        "PULLBOX_APNS_TEAM_ID, PULLBOX_APNS_KEY_ID, and PULLBOX_APNS_PRIVATE_KEY_PEM must be set together"
    );
}

#[test]
fn enabled_apns_requires_an_explicit_environment() {
    let configured = ApnsConfig::from_values(
        Some("TEAM123".to_string()),
        Some("KEY123".to_string()),
        Some("private-key".to_string()),
        None,
        None,
    );

    let error = match configured {
        Err(error) => error,
        Ok(_) => panic!("enabled APNs must require an explicit environment"),
    };
    assert_eq!(
        error.to_string(),
        "PULLBOX_APNS_ENVIRONMENT must be set when APNs credentials are configured"
    );
}

#[test]
fn prepared_apns_request_has_activitykit_headers_and_es256_auth() {
    let secret = p256::SecretKey::from_slice(&[7_u8; 32]).expect("test P-256 key");
    let private_key = secret
        .to_pkcs8_pem(LineEnding::LF)
        .expect("test PKCS#8 PEM")
        .to_string();
    let public_key = secret
        .public_key()
        .to_public_key_pem(LineEnding::LF)
        .expect("test public key");
    let config = ApnsConfig::from_values(
        Some("TEAM123".to_string()),
        Some("KEY123".to_string()),
        Some(private_key),
        None,
        Some("sandbox".to_string()),
    )
    .expect("valid config")
    .expect("enabled config");
    let device_token = DeviceToken::parse("aabbccdd").unwrap();
    let payload = json!({"aps": {"event": "start"}});

    let request = config
        .prepare_request(
            &device_token,
            ApnsEvent::Start,
            payload.clone(),
            1_725_000_000,
        )
        .expect("signed request");

    assert_eq!(
        request.url,
        "https://api.sandbox.push.apple.com/3/device/aabbccdd"
    );
    assert_eq!(request.headers["apns-push-type"], "liveactivity");
    assert_eq!(
        request.headers["apns-topic"],
        "dev.iamngoni.pullbox.push-type.liveactivity"
    );
    assert_eq!(request.headers["apns-priority"], "10");
    let token = request.headers["authorization"]
        .strip_prefix("bearer ")
        .expect("bearer JWT");
    let header = decode_header(token).expect("JWT header");
    assert_eq!(header.alg, Algorithm::ES256);
    assert_eq!(header.kid.as_deref(), Some("KEY123"));
    let mut validation = Validation::new(Algorithm::ES256);
    validation.required_spec_claims.clear();
    validation.validate_exp = false;
    let claims = decode::<ProviderClaims>(
        token,
        &DecodingKey::from_ec_pem(public_key.as_bytes()).expect("test decoding key"),
        &validation,
    )
    .expect("valid provider JWT")
    .claims;
    assert_eq!(claims.iss, "TEAM123");
    assert_eq!(claims.iat, 1_725_000_000);
    assert_eq!(request.body, payload);

    let update = config
        .prepare_request(&device_token, ApnsEvent::Update, json!({}), 1_725_000_001)
        .expect("update request");
    assert_eq!(update.headers["apns-priority"], "5");
    assert_eq!(
        update.headers["authorization"], request.headers["authorization"],
        "APNs provider tokens must be reused instead of regenerated per progress event"
    );

    let rotated = config
        .prepare_request(&device_token, ApnsEvent::Update, json!({}), 1_725_003_601)
        .expect("rotated request");
    assert_ne!(
        rotated.headers["authorization"], request.headers["authorization"],
        "expired APNs provider tokens must be rotated"
    );

    let end = config
        .prepare_request(&device_token, ApnsEvent::End, json!({}), 1_725_000_002)
        .expect("end request");
    assert_eq!(end.headers["apns-priority"], "10");
}

#[test]
fn apns_request_preparation_rejects_serialized_bodies_over_four_kib() {
    let secret = p256::SecretKey::from_slice(&[9_u8; 32]).expect("test P-256 key");
    let private_key = secret
        .to_pkcs8_pem(LineEnding::LF)
        .expect("test PKCS#8 PEM")
        .to_string();
    let config = ApnsConfig::from_values(
        Some("TEAM123".to_string()),
        Some("KEY123".to_string()),
        Some(private_key),
        None,
        Some("sandbox".to_string()),
    )
    .expect("valid config")
    .expect("enabled config");
    let device_token = DeviceToken::parse("aabbccdd").expect("valid test token");

    let result = config.prepare_request(
        &device_token,
        ApnsEvent::Start,
        json!({"aps": {"content-state": {"title": "x".repeat(5_000)}}}),
        1_725_000_000,
    );

    assert!(result.is_err(), "oversized payload reached APNs transport");
}
