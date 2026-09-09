use pullbox_backend::{choose_format, public_media_error, validate_http_url};

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
