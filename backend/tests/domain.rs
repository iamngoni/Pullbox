use pullbox_backend::{choose_format, public_media_error, validate_http_url, DownloadRequest};

#[test]
fn accepts_public_http_and_https_urls() {
    assert!(validate_http_url("https://example.com/video").is_ok());
    assert!(validate_http_url("http://example.com/video").is_ok());
}

#[test]
fn rejects_non_http_urls() {
    assert!(validate_http_url("file:///etc/passwd").is_err());
    assert!(validate_http_url("javascript:alert(1)").is_err());
}

#[test]
fn default_format_prefers_ios_compatible_mp4() {
    assert_eq!(
        choose_format(None),
        "bv*[ext=mp4][vcodec^=avc1]+ba[ext=m4a]/b[ext=mp4][vcodec^=avc1]/bv*[ext=mp4]+ba[ext=m4a]/b[ext=mp4]/b"
    );
}

#[test]
fn explicit_format_is_passed_through() {
    assert_eq!(choose_format(Some("18")), "18");
}

#[test]
fn instagram_no_video_error_does_not_expose_extractor_details() {
    let message = public_media_error(
        "ERROR: [Instagram] abc123: There is no video in this post",
        "fallback",
    );

    // Photo posts are now converted to video (image + music), so we no longer claim it's impossible.
    assert_eq!(
        message,
        "Pullbox couldn’t create a video for this photo post. Try again — if it’s a public photo with music we’ll convert it to a Photos-compatible video."
    );
    assert!(!message.contains("abc123"));
}

#[test]
fn access_control_error_explains_public_media_limit() {
    let message = public_media_error("Login required; use cookies", "fallback");
    assert_eq!(
        message,
        "This media needs a login or isn’t public. Pullbox can only save publicly available media."
    );
}

#[test]
fn unknown_extractor_error_uses_safe_fallback() {
    assert_eq!(
        public_media_error("ERROR: extractor internals", "Could not analyze"),
        "Could not analyze"
    );
}

#[test]
fn download_request_accepts_new_camel_case_metadata() {
    let request: DownloadRequest = serde_json::from_value(serde_json::json!({
        "url": "https://example.com/video",
        "requestId": "request-123",
        "title": "Example clip",
        "clientId": "client-456"
    }))
    .expect("extended request");

    assert_eq!(request.request_id.as_deref(), Some("request-123"));
    assert_eq!(request.title.as_deref(), Some("Example clip"));
    assert_eq!(request.client_id.as_deref(), Some("client-456"));
}

#[test]
fn download_request_remains_compatible_with_url_only_callers() {
    let request: DownloadRequest = serde_json::from_value(serde_json::json!({
        "url": "https://example.com/video"
    }))
    .expect("legacy request");

    assert_eq!(request.url, "https://example.com/video");
    assert!(request.format_id.is_none());
    assert!(request.request_id.is_none());
    assert!(request.title.is_none());
    assert!(request.client_id.is_none());
}

#[test]
fn notification_context_requires_all_download_metadata() {
    let complete: DownloadRequest = serde_json::from_value(serde_json::json!({
        "url": "https://example.com/video",
        "requestId": "request-123",
        "title": "Example clip",
        "clientId": "client-456"
    }))
    .unwrap();
    let parsed_url = validate_http_url(&complete.url).unwrap();
    let context = complete
        .activity_context(&parsed_url)
        .expect("complete metadata");
    assert_eq!(context.client_id(), "client-456");
    assert_eq!(context.request_id(), "request-123");
    assert_eq!(context.title(), "Example clip");
    assert_eq!(context.source_url(), "https://example.com/video");

    let missing: DownloadRequest = serde_json::from_value(serde_json::json!({
        "url": "https://example.com/video",
        "requestId": "request-123",
        "clientId": "client-456"
    }))
    .unwrap();
    assert!(missing.activity_context(&parsed_url).is_none());
}
