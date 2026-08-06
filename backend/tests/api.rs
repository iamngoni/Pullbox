use actix_web::{App, http::StatusCode, test};
use pullbox_backend::configure;

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
