//! Verifies yt-dlp phase progress parsing without invoking external media tools.

use pullbox_backend::progress::parse_ytdlp_progress;

#[test]
fn yt_dlp_percentages_map_into_the_server_owned_zero_to_point_nine_range() {
    let parsed = parse_ytdlp_progress("PULLBOX_PROGRESS= 42.5%").expect("progress line");
    assert!((parsed - 0.3825).abs() < f64::EPSILON);
    assert_eq!(parse_ytdlp_progress("PULLBOX_PROGRESS=100.0%"), Some(0.9));
    assert_eq!(parse_ytdlp_progress("PULLBOX_PROGRESS=110.0%"), Some(0.9));
    assert_eq!(parse_ytdlp_progress("[download] destination"), None);
    assert_eq!(parse_ytdlp_progress("PULLBOX_PROGRESS=N/A"), None);
}
