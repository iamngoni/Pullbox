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
fn registry_capacity_is_bounded_but_existing_tokens_can_rotate() {
    let registry = TokenRegistry::with_limits(2, 2);
    registry
        .register_push_to_start("client-a", DeviceToken::parse("0011").unwrap())
        .unwrap();
    registry
        .register_push_to_start("client-b", DeviceToken::parse("2233").unwrap())
        .unwrap();

    assert!(registry
        .register_push_to_start("client-c", DeviceToken::parse("4455").unwrap())
        .is_err());
    registry
        .register_push_to_start("client-a", DeviceToken::parse("6677").unwrap())
        .expect("existing push token rotates at capacity");
    assert_eq!(
        registry
            .push_to_start("client-a")
            .expect("rotated start token")
            .as_str(),
        "6677"
    );

    registry
        .register_update("client-a", "request-a", DeviceToken::parse("0011").unwrap())
        .unwrap();
    registry
        .register_update("client-a", "request-b", DeviceToken::parse("2233").unwrap())
        .unwrap();
    assert!(registry
        .register_update("client-a", "request-c", DeviceToken::parse("4455").unwrap())
        .is_err());
    registry
        .register_update("client-a", "request-a", DeviceToken::parse("8899").unwrap())
        .expect("existing update token rotates at capacity");
}

#[test]
fn terminal_request_rejects_a_late_update_token_without_persisting_it() {
    let directory = tempfile::tempdir().expect("temporary directory");
    let path = directory.path().join("activity-tokens.json");
    let registry = TokenRegistry::persistent(&path).expect("persistent registry");

    registry
        .mark_terminal("client-a", "request-a")
        .expect("persist terminal marker");
    registry
        .register_update("client-a", "request-a", DeviceToken::parse("2233").unwrap())
        .expect("accept late registration as no-op");

    assert!(registry.update_token("client-a", "request-a").is_none());
    drop(registry);
    let reloaded = TokenRegistry::persistent(path).expect("reload persistent registry");
    assert!(reloaded.update_token("client-a", "request-a").is_none());
}

#[test]
fn expired_terminal_tombstones_do_not_block_future_registration() {
    let directory = tempfile::tempdir().expect("temporary directory");
    let path = directory.path().join("activity-tokens.json");
    let fixture = serde_json::json!({
        "push_to_start": {},
        "updates": {},
        "terminal_requests": {"client-a": {"request-a": 0}}
    });
    std::fs::write(&path, serde_json::to_vec(&fixture).unwrap()).expect("seed expired marker");
    let registry = TokenRegistry::persistent(&path).expect("persistent registry");

    registry
        .register_update("client-a", "request-a", DeviceToken::parse("2233").unwrap())
        .expect("register after tombstone expiry");

    assert_eq!(
        registry
            .update_token("client-a", "request-a")
            .expect("stored token")
            .as_str(),
        "2233"
    );
}

#[test]
fn marking_a_terminal_request_garbage_collects_expired_tombstones() {
    let directory = tempfile::tempdir().expect("temporary directory");
    let path = directory.path().join("activity-tokens.json");
    let fixture = serde_json::json!({
        "push_to_start": {},
        "updates": {},
        "terminal_requests": {"expired-client": {"expired-request": 0}}
    });
    std::fs::write(&path, serde_json::to_vec(&fixture).unwrap()).expect("seed expired marker");
    let registry = TokenRegistry::persistent(&path).expect("persistent registry");

    registry
        .mark_terminal("current-client", "current-request")
        .expect("mark current request terminal");

    let persisted: serde_json::Value =
        serde_json::from_slice(&std::fs::read(path).expect("persisted store")).unwrap();
    assert!(persisted["terminal_requests"]
        .get("expired-client")
        .is_none());
    assert!(persisted["terminal_requests"]["current-client"]
        .get("current-request")
        .is_some());
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

#[cfg(unix)]
#[test]
fn persistent_registry_rejects_a_symlinked_token_store() {
    use std::os::unix::fs::symlink;

    let directory = tempfile::tempdir().expect("temporary directory");
    let target = directory.path().join("target.json");
    let path = directory.path().join("activity-tokens.json");
    std::fs::write(&target, r#"{"push_to_start":{},"updates":{}}"#)
        .expect("seed target token file");
    symlink(&target, &path).expect("create token-store symlink");

    assert!(
        TokenRegistry::persistent(path).is_err(),
        "token registry followed a symlinked store"
    );
}

#[test]
fn persistent_registry_migrates_oversized_identifier_keys() {
    let directory = tempfile::tempdir().expect("temporary directory");
    let path = directory.path().join("activity-tokens.json");
    let oversized = "x".repeat(1_024);
    let fixture = serde_json::json!({
        "push_to_start": {
            "valid-client": "0011",
            oversized.clone(): "2233"
        },
        "updates": {
            "valid-client": {"valid-request": "4455", oversized.clone(): "6677"},
            oversized.clone(): {"valid-request": "8899"}
        },
        "terminal_requests": {
            oversized.clone(): {"valid-request": i64::MAX},
            "valid-client": {oversized.clone(): i64::MAX}
        }
    });
    std::fs::write(&path, serde_json::to_vec(&fixture).unwrap()).expect("seed legacy store");

    let registry = TokenRegistry::persistent(&path).expect("migrated registry");

    assert!(registry.push_to_start(&oversized).is_none());
    assert!(registry.update_token("valid-client", &oversized).is_none());
    assert!(registry.update_token(&oversized, "valid-request").is_none());
    let rewritten: serde_json::Value =
        serde_json::from_slice(&std::fs::read(path).expect("rewritten store")).unwrap();
    assert!(rewritten["push_to_start"].get(&oversized).is_none());
    assert!(rewritten["updates"].get(&oversized).is_none());
    assert!(rewritten["updates"]["valid-client"].get(&oversized).is_none());
    assert!(rewritten["terminal_requests"].get(&oversized).is_none());
    assert!(rewritten["terminal_requests"]["valid-client"]
        .get(&oversized)
        .is_none());
}

#[test]
fn persistent_registry_migrates_legacy_oversized_tokens_without_aborting() {
    let directory = tempfile::tempdir().expect("temporary directory");
    let path = directory.path().join("activity-tokens.json");
    let fixture = serde_json::json!({
        "push_to_start": {
            "valid-client": "0011",
            "legacy-client": "aa".repeat(129)
        },
        "updates": {
            "valid-client": {"valid-request": "2233"},
            "legacy-client": {"legacy-request": "aa".repeat(129)}
        }
    });
    std::fs::write(&path, serde_json::to_vec(&fixture).unwrap()).expect("seed legacy store");

    let registry = TokenRegistry::persistent(&path).expect("migrated registry");

    assert_eq!(
        registry
            .push_to_start("valid-client")
            .expect("valid token survives")
            .as_str(),
        "0011"
    );
    assert!(registry.push_to_start("legacy-client").is_none());
    assert!(registry
        .update_token("legacy-client", "legacy-request")
        .is_none());
    let rewritten: serde_json::Value =
        serde_json::from_slice(&std::fs::read(path).expect("rewritten store")).unwrap();
    assert!(rewritten["push_to_start"].get("legacy-client").is_none());
    assert!(rewritten["updates"].get("legacy-client").is_none());
}
