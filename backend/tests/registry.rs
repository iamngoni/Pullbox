//! Verifies sensitive APNs token validation and concurrent registration lookup.

use pullbox_backend::apns::{DeviceToken, TokenRegistry};

#[test]
fn device_tokens_require_nonempty_even_length_hex_and_redact_debug_output() {
    let token = DeviceToken::parse("A0ff12").expect("valid mixed-case hex token");

    assert_eq!(token.as_str(), "A0ff12");
    assert_eq!(format!("{token:?}"), "DeviceToken([REDACTED])");
    assert!(DeviceToken::parse("").is_err());
    assert!(DeviceToken::parse("abc").is_err());
    assert!(DeviceToken::parse("gg").is_err());
}

#[test]
fn device_tokens_reject_oversized_hex_payloads() {
    let oversized = "aa".repeat(129);
    assert!(DeviceToken::parse(&oversized).is_err());
}

#[test]
fn registry_keys_start_tokens_by_client_and_update_tokens_by_request() {
    let registry = TokenRegistry::default();
    registry
        .register_push_to_start("client-a", DeviceToken::parse("0011").unwrap())
        .unwrap();
    registry
        .register_update("client-a", "request-a", DeviceToken::parse("2233").unwrap())
        .unwrap();
    registry
        .register_update("client-a", "request-b", DeviceToken::parse("4455").unwrap())
        .unwrap();

    assert_eq!(
        registry
            .push_to_start("client-a")
            .expect("start token")
            .as_str(),
        "0011"
    );
    assert_eq!(
        registry
            .update_token("client-a", "request-a")
            .expect("request A token")
            .as_str(),
        "2233"
    );
    assert_eq!(
        registry
            .update_token("client-a", "request-b")
            .expect("request B token")
            .as_str(),
        "4455"
    );
    assert!(registry.update_token("client-b", "request-a").is_none());
}

#[test]
fn registry_accepts_concurrent_registrations_without_losing_entries() {
    let registry = TokenRegistry::default();
    let workers = (0..32)
        .map(|index| {
            let registry = registry.clone();
            std::thread::spawn(move || {
                let client_id = format!("client-{index}");
                let request_id = format!("request-{index}");
                let token = DeviceToken::parse(&format!("{index:04x}")).unwrap();
                registry
                    .register_update(&client_id, &request_id, token)
                    .unwrap();
            })
        })
        .collect::<Vec<_>>();

    for worker in workers {
        worker.join().expect("registration thread");
    }
    for index in 0..32 {
        let token = registry
            .update_token(&format!("client-{index}"), &format!("request-{index}"))
            .expect("concurrently registered token");
        assert_eq!(token.as_str(), format!("{index:04x}"));
    }
}

#[test]
fn persistent_registry_survives_restart_without_exposing_token_file() {
    let directory = tempfile::tempdir().expect("temporary directory");
    let path = directory.path().join("activity-tokens.json");

    let registry = TokenRegistry::persistent(&path).expect("persistent registry");
    registry
        .register_push_to_start("client-a", DeviceToken::parse("0011").unwrap())
        .expect("persist push-to-start token");
    registry
        .register_update("client-a", "request-a", DeviceToken::parse("2233").unwrap())
        .expect("persist update token");
    drop(registry);

    let reloaded = TokenRegistry::persistent(&path).expect("reload persistent registry");
    assert_eq!(
        reloaded
            .push_to_start("client-a")
            .expect("reloaded start token")
            .as_str(),
        "0011"
    );
    assert_eq!(
        reloaded
            .update_token("client-a", "request-a")
            .expect("reloaded update token")
            .as_str(),
        "2233"
    );

    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        assert_eq!(
            std::fs::metadata(&path)
                .expect("token file metadata")
                .permissions()
                .mode()
                & 0o777,
            0o600
        );
    }
}

#[cfg(unix)]
#[test]
fn persistent_registry_secures_an_existing_permissive_token_file() {
    use std::os::unix::fs::PermissionsExt;

    let directory = tempfile::tempdir().expect("temporary directory");
    let path = directory.path().join("activity-tokens.json");
    std::fs::write(&path, r#"{"push_to_start":{},"updates":{}}"#).expect("seed token file");
    std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o644))
        .expect("set permissive fixture mode");

    let _registry = TokenRegistry::persistent(&path).expect("persistent registry");

    assert_eq!(
        std::fs::metadata(path)
            .expect("token file metadata")
            .permissions()
            .mode()
            & 0o777,
        0o600
    );
}
