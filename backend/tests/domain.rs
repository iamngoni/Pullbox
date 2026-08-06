use pullbox_backend::{choose_format, validate_http_url};

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
    assert_eq!(choose_format(None), "bv*[ext=mp4]+ba[ext=m4a]/b[ext=mp4]/b");
}

#[test]
fn explicit_format_is_passed_through() {
    assert_eq!(choose_format(Some("18")), "18");
}
