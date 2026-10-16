use actix_web::{http::StatusCode, test, web, App};
use pullbox_backend::{apns::TokenRegistry, configure};

#[actix_rt::test]
async fn health_endpoint_is_ready() {
    let app = test::init_service(App::new().configure(configure)).await;
    let request = test::TestRequest::get().uri("/health").to_request();
    let response = test::call_service(&app, request).await;
    assert_eq!(response.status(), StatusCode::OK);
}

#[actix_rt::test]
async fn analyze_rejects_non_http_urls_before_running_downloader() {
    let app = test::init_service(App::new().configure(configure)).await;
    let request = test::TestRequest::post()
        .uri("/api/analyze")
        .set_json(serde_json::json!({ "url": "file:///etc/passwd" }))
        .to_request();
    let response = test::call_service(&app, request).await;
    assert_eq!(response.status(), StatusCode::BAD_REQUEST);
}

#[actix_rt::test]
async fn download_rejects_non_http_urls_before_running_downloader() {
    let app = test::init_service(App::new().configure(configure)).await;
    let request = test::TestRequest::post()
        .uri("/api/download")
        .set_json(serde_json::json!({ "url": "file:///etc/passwd" }))
        .to_request();
    let response = test::call_service(&app, request).await;
    assert_eq!(response.status(), StatusCode::BAD_REQUEST);
}

#[actix_rt::test]
async fn download_accepts_metadata_bodies_larger_than_the_token_registration_limit() {
    let app = test::init_service(App::new().configure(configure)).await;
    let request = test::TestRequest::post()
        .uri("/api/download")
        .set_json(serde_json::json!({
            "url": "file:///etc/passwd",
            "requestId": "request-456",
            "clientId": "client-123",
            "title": "x".repeat(20 * 1024)
        }))
        .to_request();

    let response = test::call_service(&app, request).await;

    assert_eq!(response.status(), StatusCode::BAD_REQUEST);
}

#[actix_rt::test]
async fn push_to_start_registration_stores_token_without_echoing_it() {
    let registry = TokenRegistry::default();
    let app = test::init_service(
        App::new()
            .app_data(web::Data::new(registry.clone()))
            .configure(configure),
    )
    .await;
    let request = test::TestRequest::post()
        .uri("/api/live-activity/push-to-start-token")
        .set_json(serde_json::json!({
            "clientId": "client-123",
            "token": "aabbccdd"
        }))
        .to_request();

    let response = test::call_service(&app, request).await;

    assert_eq!(response.status(), StatusCode::NO_CONTENT);
    assert!(test::read_body(response).await.is_empty());
    assert_eq!(
        registry
            .push_to_start("client-123")
            .expect("registered token")
            .as_str(),
        "aabbccdd"
    );
}

#[actix_rt::test]
async fn update_token_registration_keys_token_by_client_and_request() {
    let registry = TokenRegistry::default();
    let app = test::init_service(
        App::new()
            .app_data(web::Data::new(registry.clone()))
            .configure(configure),
    )
    .await;
    let request = test::TestRequest::post()
        .uri("/api/live-activity/update-token")
        .set_json(serde_json::json!({
            "clientId": "client-123",
            "requestId": "request-456",
            "token": "11223344"
        }))
        .to_request();

    let response = test::call_service(&app, request).await;

    assert_eq!(response.status(), StatusCode::NO_CONTENT);
    assert!(test::read_body(response).await.is_empty());
    assert_eq!(
        registry
            .update_token("client-123", "request-456")
            .expect("registered update token")
            .as_str(),
        "11223344"
    );
}

#[actix_rt::test]
async fn registration_endpoints_reject_malformed_tokens_without_echoing_them() {
    let registry = TokenRegistry::default();
    let app = test::init_service(
        App::new()
            .app_data(web::Data::new(registry.clone()))
            .configure(configure),
    )
    .await;
    let cases = [
        (
            "/api/live-activity/push-to-start-token",
            serde_json::json!({"clientId": "client-123", "token": "not-hex"}),
        ),
        (
            "/api/live-activity/update-token",
            serde_json::json!({
                "clientId": "client-123",
                "requestId": "request-456",
                "token": "abc"
            }),
        ),
    ];

    for (uri, body) in cases {
        let request = test::TestRequest::post()
            .uri(uri)
            .set_json(body)
            .to_request();
        let response = test::call_service(&app, request).await;
        assert_eq!(response.status(), StatusCode::BAD_REQUEST);
        let response_body = test::read_body(response).await;
        assert!(!String::from_utf8_lossy(&response_body).contains("not-hex"));
    }
    assert!(registry.push_to_start("client-123").is_none());
    assert!(registry.update_token("client-123", "request-456").is_none());
}

#[actix_rt::test]
async fn registration_endpoints_reject_oversized_identifiers() {
    let registry = TokenRegistry::default();
    let app = test::init_service(
        App::new()
            .app_data(web::Data::new(registry.clone()))
            .configure(configure),
    )
    .await;
    let oversized = "x".repeat(1_024);
    let cases = [
        (
            "/api/live-activity/push-to-start-token",
            serde_json::json!({"clientId": oversized, "token": "aabbccdd"}),
        ),
        (
            "/api/live-activity/update-token",
            serde_json::json!({
                "clientId": "client-123",
                "requestId": "x".repeat(1_024),
                "token": "11223344"
            }),
        ),
    ];

    for (uri, body) in cases {
        let request = test::TestRequest::post()
            .uri(uri)
            .set_json(body)
            .to_request();
        let response = test::call_service(&app, request).await;
        assert_eq!(response.status(), StatusCode::BAD_REQUEST);
    }
    assert!(registry.push_to_start(&"x".repeat(1_024)).is_none());
    assert!(registry
        .update_token("client-123", &"x".repeat(1_024))
        .is_none());
}

#[actix_rt::test]
async fn json_requests_above_sixteen_kib_are_rejected_before_deserialization() {
    let registry = TokenRegistry::default();
    let app = test::init_service(
        App::new()
            .app_data(web::Data::new(registry))
            .configure(configure),
    )
    .await;
    let payload = serde_json::json!({
        "clientId": "client-oversized",
        "token": "aa".repeat(9_000)
    })
    .to_string();
    let request = test::TestRequest::post()
        .uri("/api/live-activity/push-to-start-token")
        .insert_header(("content-type", "application/json"))
        .set_payload(payload)
        .to_request();

    let response = test::call_service(&app, request).await;

    assert_eq!(response.status(), StatusCode::PAYLOAD_TOO_LARGE);
}
