//! Serves Pullbox media analysis/download routes and Live Activity token registration.
//!
//! APNs delivery is best-effort and never changes the existing media response contract.

pub mod apns;
pub mod progress;

use actix_web::{web, HttpResponse, Responder};
use serde::{Deserialize, Serialize};
use serde_json::Value;
use std::path::Path;
use tokio::process::Command;
use url::Url;

pub fn validate_http_url(value: &str) -> Result<Url, &'static str> {
    let parsed = Url::parse(value).map_err(|_| "Enter a valid URL")?;
    match parsed.scheme() {
        "http" | "https" => Ok(parsed),
        _ => Err("Only HTTP and HTTPS URLs are supported"),
    }
}

pub fn choose_format(format_id: Option<&str>) -> &str {
    format_id.unwrap_or(
        "bv*[ext=mp4][vcodec^=avc1]+ba[ext=m4a]/b[ext=mp4][vcodec^=avc1]/bv*[ext=mp4]+ba[ext=m4a]/b[ext=mp4]/b",
    )
}

/// Platform-specific cookie jar detection. Users drop Netscape-format
/// `cookies.txt` exports (from a logged-in browser session) into the
/// COOKIES_DIR volume as `<platform>.txt` — e.g. `instagram.txt`,
/// `tiktok.txt`, `twitter.txt`. yt-dlp picks them up via `--cookies`.
fn platform_cookies(url: &str) -> Option<String> {
    let dir = std::env::var("COOKIES_DIR").ok()?;
    let host = Url::parse(url).ok()?.host_str()?.to_ascii_lowercase();
    let name = if host.contains("instagram") {
        "instagram"
    } else if host.contains("tiktok") {
        "tiktok"
    } else if host.contains("twitter") || host.contains("x.com") {
        "twitter"
    } else if host.contains("facebook") || host.contains("fb.watch") {
        "facebook"
    } else if host.contains("youtube") {
        "youtube"
    } else {
        return None;
    };
    let path = format!("{dir}/{name}.txt");
    Path::new(&path).exists().then_some(path)
}

pub fn public_media_error(raw: &str, fallback: &str) -> String {
    let normalized = raw.to_ascii_lowercase();

    if normalized.contains("there is no video in this post")
        || normalized.contains("no video formats found")
    {
        return "Pullbox couldn’t create a video for this photo post. Try again — if it’s a public photo with music we’ll convert it to a Photos-compatible video.".to_string();
    }

    if normalized.contains("login required")
        || normalized.contains("log in")
        || normalized.contains("cookies")
        || normalized.contains("private")
    {
        return "This media needs a login or isn’t public. Pullbox can only save publicly available media.".to_string();
    }

    if normalized.contains("unsupported url") {
        return "Pullbox doesn’t support this link yet.".to_string();
    }

    fallback.to_string()
}

fn normalize_url(url: &str) -> String {
    let mut normalized = url.to_string();
    if normalized.contains("tiktok.com") && normalized.contains("/photo/") {
        normalized = normalized.replace("/photo/", "/video/");
    }
    normalized
}

#[derive(Debug, Deserialize)]
pub struct UrlRequest {
    pub url: String,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct MediaInfo {
    pub title: String,
    pub thumbnail: Option<String>,
    pub duration: Option<f64>,
    pub source_url: String,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct DownloadRequest {
    pub url: String,
    pub format_id: Option<String>,
    pub request_id: Option<String>,
    pub title: Option<String>,
    pub client_id: Option<String>,
}

impl DownloadRequest {
    /// Returns a notification context only when every backwards-compatible field is present.
    pub fn activity_context(&self, source_url: &Url) -> Option<apns::ActivityNotificationContext> {
        let request_id = self
            .request_id
            .as_deref()
            .filter(|value| !value.trim().is_empty())?;
        let title = self
            .title
            .as_deref()
            .filter(|value| !value.trim().is_empty())?;
        let client_id = self
            .client_id
            .as_deref()
            .filter(|value| !value.trim().is_empty())?;
        Some(apns::ActivityNotificationContext::new(
            client_id,
            request_id,
            title,
            source_url.as_str(),
        ))
    }
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct PushToStartTokenRequest {
    client_id: String,
    token: String,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct UpdateTokenRequest {
    client_id: String,
    request_id: String,
    token: String,
}

#[derive(Debug, Serialize)]
pub struct ErrorBody {
    pub error: String,
}

pub fn configure(config: &mut web::ServiceConfig) {
    config
        .route("/health", web::get().to(health))
        .route("/api/analyze", web::post().to(analyze))
        .route("/api/download", web::post().to(download))
        .route(
            "/api/live-activity/push-to-start-token",
            web::post().to(register_push_to_start_token),
        )
        .route(
            "/api/live-activity/update-token",
            web::post().to(register_update_token),
        );
}

async fn register_push_to_start_token(
    registry: Option<web::Data<apns::TokenRegistry>>,
    body: web::Json<PushToStartTokenRequest>,
) -> HttpResponse {
    let Some(registry) = registry else {
        return HttpResponse::ServiceUnavailable().json(ErrorBody {
            error: "Live Activity token registration is unavailable".to_string(),
        });
    };
    if body.client_id.trim().is_empty() {
        return HttpResponse::BadRequest().json(ErrorBody {
            error: "clientId must not be empty".to_string(),
        });
    }
    let token = match apns::DeviceToken::parse(&body.token) {
        Ok(token) => token,
        Err(error) => {
            return HttpResponse::BadRequest().json(ErrorBody {
                error: error.to_string(),
            });
        }
    };

    if let Err(error) = registry.register_push_to_start(&body.client_id, token) {
        log::error!("Could not persist Live Activity token: {error}");
        return HttpResponse::InternalServerError().json(ErrorBody {
            error: "Could not save Live Activity registration".to_string(),
        });
    }
    HttpResponse::NoContent().finish()
}

async fn register_update_token(
    registry: Option<web::Data<apns::TokenRegistry>>,
    body: web::Json<UpdateTokenRequest>,
) -> HttpResponse {
    let Some(registry) = registry else {
        return HttpResponse::ServiceUnavailable().json(ErrorBody {
            error: "Live Activity token registration is unavailable".to_string(),
        });
    };
    if body.client_id.trim().is_empty() || body.request_id.trim().is_empty() {
        return HttpResponse::BadRequest().json(ErrorBody {
            error: "clientId and requestId must not be empty".to_string(),
        });
    }
    let token = match apns::DeviceToken::parse(&body.token) {
        Ok(token) => token,
        Err(error) => {
            return HttpResponse::BadRequest().json(ErrorBody {
                error: error.to_string(),
            });
        }
    };

    if let Err(error) = registry.register_update(&body.client_id, &body.request_id, token) {
        log::error!("Could not persist Live Activity token: {error}");
        return HttpResponse::InternalServerError().json(ErrorBody {
            error: "Could not save Live Activity registration".to_string(),
        });
    }
    HttpResponse::NoContent().finish()
}

async fn health() -> impl Responder {
    HttpResponse::Ok().json(serde_json::json!({ "status": "ready" }))
}

async fn analyze(body: web::Json<UrlRequest>) -> impl Responder {
    let extraction_url = normalize_url(&body.url);
    let parsed = match validate_http_url(&extraction_url) {
        Ok(url) => url,
        Err(message) => {
            return HttpResponse::BadRequest().json(ErrorBody {
                error: message.to_string(),
            });
        }
    };

    let mut cmd = Command::new("yt-dlp");
    cmd.args([
        "--dump-single-json",
        "--skip-download",
        "--no-playlist",
        "--ignore-no-formats-error",
    ]);
    if let Some(jar) = platform_cookies(parsed.as_str()) {
        cmd.arg("--cookies").arg(jar);
    }
    let output = cmd.arg(parsed.as_str()).output().await;

    let output = match output {
        Ok(value) if value.status.success() => value,
        Ok(value) => {
            let detail = String::from_utf8_lossy(&value.stderr)
                .lines()
                .last()
                .unwrap_or("Could not analyze that URL")
                .to_string();
            if !value.stdout.is_empty() {
                if let Ok(metadata) = serde_json::from_slice::<Value>(&value.stdout) {
                    return HttpResponse::Ok().json(MediaInfo {
                        title: metadata["title"]
                            .as_str()
                            .unwrap_or("Untitled download")
                            .to_string(),
                        thumbnail: metadata["thumbnail"].as_str().map(str::to_string),
                        duration: metadata["duration"].as_f64(),
                        source_url: parsed.to_string(),
                    });
                }
            }
            let message = public_media_error(
                &detail,
                "Pullbox couldn’t find downloadable media at this link.",
            );
            return HttpResponse::UnprocessableEntity().json(ErrorBody { error: message });
        }
        Err(error) => {
            return HttpResponse::InternalServerError().json(ErrorBody {
                error: format!("Could not start yt-dlp: {error}"),
            });
        }
    };

    let metadata: Value = match serde_json::from_slice(&output.stdout) {
        Ok(value) => value,
        Err(error) => {
            return HttpResponse::InternalServerError().json(ErrorBody {
                error: format!("yt-dlp returned invalid metadata: {error}"),
            });
        }
    };

    HttpResponse::Ok().json(MediaInfo {
        title: metadata["title"]
            .as_str()
            .unwrap_or("Untitled download")
            .to_string(),
        thumbnail: metadata["thumbnail"].as_str().map(str::to_string),
        duration: metadata["duration"].as_f64(),
        source_url: parsed.to_string(),
    })
}

async fn failed_download_response(
    notifications: &apns::DownloadNotificationSession,
    status: actix_web::http::StatusCode,
    error: String,
) -> HttpResponse {
    notifications
        .failed("Pullbox couldn’t finish this download.")
        .await;
    HttpResponse::build(status).json(ErrorBody { error })
}

async fn download(
    body: web::Json<DownloadRequest>,
    notifier: Option<web::Data<apns::ActivityNotifierHandle>>,
) -> impl Responder {
    let extraction_url = normalize_url(&body.url);
    let parsed = match validate_http_url(&extraction_url) {
        Ok(url) => url,
        Err(message) => {
            return HttpResponse::BadRequest().json(ErrorBody {
                error: message.to_string(),
            });
        }
    };

    let notifications = apns::DownloadNotificationSession::begin(
        body.activity_context(&parsed),
        notifier.map(|handle| handle.get_ref().clone()),
    )
    .await;

    let directory = match tempfile::tempdir() {
        Ok(value) => value,
        Err(error) => {
            return failed_download_response(
                &notifications,
                actix_web::http::StatusCode::INTERNAL_SERVER_ERROR,
                format!("Could not create temporary storage: {error}"),
            )
            .await;
        }
    };
    let output_template = directory.path().join("source-%(id)s.%(ext)s");
    let output_template = output_template.to_string_lossy().into_owned();
    let format = choose_format(body.format_id.as_deref()).to_string();

    let mut cmd = Command::new("yt-dlp");
    cmd.arg("--no-playlist");
    progress::configure_ytdlp_progress(&mut cmd);
    cmd.args([
        "--write-thumbnail",
        "--convert-thumbnails",
        "jpg",
        "--ignore-no-formats-error",
        "--merge-output-format",
        "mp4",
        "--print",
        "after_move:filepath",
        "-f",
        &format,
        "-o",
        &output_template,
    ]);
    if let Some(jar) = platform_cookies(parsed.as_str()) {
        cmd.arg("--cookies").arg(&jar);
    }
    cmd.arg(parsed.as_str());
    let output =
        progress::run_command_with_progress(&mut cmd, |value| notifications.progress(value)).await;

    let output = match output {
        Ok(value) if value.status.success() => value,
        Ok(value) => {
            let detail = value.stderr.clone();
            let lower = detail.to_ascii_lowercase();
            if lower.contains("there is no video in this post")
                || lower.contains("no video formats found")
            {
                let mut retry_cmd = Command::new("yt-dlp");
                retry_cmd.arg("--no-playlist");
                progress::configure_ytdlp_progress(&mut retry_cmd);
                retry_cmd.args([
                    "--write-thumbnail",
                    "--convert-thumbnails",
                    "jpg",
                    "--ignore-no-formats-error",
                    "--merge-output-format",
                    "mp4",
                    "--print",
                    "after_move:filepath",
                    "-o",
                    &output_template,
                ]);
                if let Some(jar) = platform_cookies(parsed.as_str()) {
                    retry_cmd.arg("--cookies").arg(&jar);
                }
                retry_cmd.arg(parsed.as_str());
                let retry = progress::run_command_with_progress(&mut retry_cmd, |value| {
                    notifications.progress(value)
                })
                .await;
                match retry {
                    Ok(r) if r.status.success() => r,
                    Ok(r) => {
                        let d = r
                            .stderr
                            .lines()
                            .last()
                            .unwrap_or("Download failed")
                            .to_string();
                        let msg = public_media_error(
                            &d,
                            "Pullbox couldn’t download media from this link.",
                        );
                        return failed_download_response(
                            &notifications,
                            actix_web::http::StatusCode::UNPROCESSABLE_ENTITY,
                            msg,
                        )
                        .await;
                    }
                    Err(e) => {
                        return failed_download_response(
                            &notifications,
                            actix_web::http::StatusCode::INTERNAL_SERVER_ERROR,
                            format!("Could not start yt-dlp: {e}"),
                        )
                        .await;
                    }
                }
            } else {
                let d = detail
                    .lines()
                    .last()
                    .unwrap_or("Download failed")
                    .to_string();
                let message = public_media_error(
                    &d,
                    "Pullbox couldn’t download a playable video from this link.",
                );
                return failed_download_response(
                    &notifications,
                    actix_web::http::StatusCode::UNPROCESSABLE_ENTITY,
                    message,
                )
                .await;
            }
        }
        Err(error) => {
            return failed_download_response(
                &notifications,
                actix_web::http::StatusCode::INTERNAL_SERVER_ERROR,
                format!("Could not start yt-dlp: {error}"),
            )
            .await;
        }
    };

    let path = output
        .stdout
        .lines()
        .rfind(|line| !line.trim().is_empty())
        .map(str::trim)
        .unwrap_or_default()
        .to_string();
    if path.is_empty() {
        return failed_download_response(
            &notifications,
            actix_web::http::StatusCode::INTERNAL_SERVER_ERROR,
            "yt-dlp completed without returning a file".to_string(),
        )
        .await;
    }

    let main_path = Path::new(&path);
    let dir = directory.path();

    // Find the largest thumbnail image written by --write-thumbnail (for photo posts)
    let thumbnail = std::fs::read_dir(dir).ok().and_then(|rd| {
        rd.filter_map(|e| e.ok())
            .filter(|e| {
                let name = e.file_name().to_string_lossy().to_lowercase();
                name.ends_with(".jpg")
                    || name.ends_with(".jpeg")
                    || name.ends_with(".png")
                    || name.ends_with(".webp")
            })
            .max_by_key(|e| e.metadata().ok().map(|m| m.len()).unwrap_or(0))
            .map(|e| e.path())
    });

    let ext = main_path
        .extension()
        .and_then(|e| e.to_str())
        .unwrap_or("")
        .to_ascii_lowercase();
    let is_image_ext = matches!(
        ext.as_str(),
        "jpg" | "jpeg" | "png" | "webp" | "heic" | "avif"
    );

    let has_video = if let Ok(probe) = Command::new("ffprobe")
        .args([
            "-v",
            "error",
            "-select_streams",
            "v:0",
            "-show_entries",
            "stream=codec_type",
            "-of",
            "csv=p=0",
            &path,
        ])
        .output()
        .await
    {
        !String::from_utf8_lossy(&probe.stdout).trim().is_empty()
    } else {
        false
    };

    let has_audio = if let Ok(probe) = Command::new("ffprobe")
        .args([
            "-v",
            "error",
            "-select_streams",
            "a:0",
            "-show_entries",
            "stream=codec_type",
            "-of",
            "csv=p=0",
            &path,
        ])
        .output()
        .await
    {
        !String::from_utf8_lossy(&probe.stdout).trim().is_empty()
    } else {
        false
    };

    // Image-only photo post (no video, no audio): just save the image
    let image_only = is_image_ext || (!has_video && !has_audio);
    if image_only {
        let image_source = if is_image_ext {
            main_path.to_path_buf()
        } else if let Some(thumb) = thumbnail.clone() {
            thumb
        } else {
            main_path.to_path_buf()
        };

        let compatible_image = dir.join("pullbox-photos.jpg");
        // Convert to JPEG for Photos compatibility if needed
        let convert = Command::new("ffmpeg")
            .args(["-nostdin", "-hide_banner", "-loglevel", "error", "-y", "-i"])
            .arg(&image_source)
            .args(["-q:v", "2"])
            .arg(&compatible_image)
            .output()
            .await;
        let final_image = match convert {
            Ok(o) if o.status.success() && compatible_image.exists() => compatible_image,
            _ => image_source.clone(),
        };

        let bytes = match tokio::fs::read(&final_image).await {
            Ok(v) => v,
            Err(e) => {
                return failed_download_response(
                    &notifications,
                    actix_web::http::StatusCode::INTERNAL_SERVER_ERROR,
                    format!("Could not read image: {e}"),
                )
                .await;
            }
        };
        // Detect content type from extension
        let ct = if final_image
            .extension()
            .and_then(|e| e.to_str())
            .unwrap_or("jpg")
            .eq_ignore_ascii_case("png")
        {
            "image/png"
        } else {
            "image/jpeg"
        };
        let filename = "pullbox.jpg".to_string();
        notifications.ready().await;
        return HttpResponse::Ok()
            .content_type(ct)
            .insert_header((
                "Content-Disposition",
                format!("attachment; filename=\"{}\"", filename),
            ))
            .body(bytes);
    }

    // Image + audio -> synthesize video (TikTok/Instagram photo with music)
    if !has_video && has_audio {
        if let Some(thumb) = thumbnail {
            let compatible_path = dir.join("pullbox-photos.mp4");
            let ffmpeg_out = Command::new("ffmpeg")
                .args([
                    "-nostdin",
                    "-hide_banner",
                    "-loglevel",
                    "error",
                    "-y",
                    "-loop",
                    "1",
                    "-i",
                ])
                .arg(&thumb)
                .args(["-i"])
                .arg(main_path)
                .args([
                    "-c:v",
                    "libx264",
                    "-preset",
                    "veryfast",
                    "-crf",
                    "21",
                    "-pix_fmt",
                    "yuv420p",
                    "-c:a",
                    "aac",
                    "-b:a",
                    "160k",
                    "-shortest",
                    "-movflags",
                    "+faststart",
                ])
                .arg(&compatible_path)
                .output()
                .await;
            match ffmpeg_out {
                Ok(o) if o.status.success() => {
                    let bytes = match tokio::fs::read(&compatible_path).await {
                        Ok(v) => v,
                        Err(e) => {
                            return failed_download_response(
                                &notifications,
                                actix_web::http::StatusCode::INTERNAL_SERVER_ERROR,
                                format!("Could not read video: {e}"),
                            )
                            .await;
                        }
                    };
                    notifications.ready().await;
                    return HttpResponse::Ok()
                        .content_type("video/mp4")
                        .insert_header((
                            "Content-Disposition",
                            "attachment; filename=\"pullbox.mp4\"",
                        ))
                        .body(bytes);
                }
                Ok(o) => {
                    let err = String::from_utf8_lossy(&o.stderr)
                        .lines()
                        .last()
                        .unwrap_or("ffmpeg error")
                        .to_string();
                    return failed_download_response(
                        &notifications,
                        actix_web::http::StatusCode::INTERNAL_SERVER_ERROR,
                        format!("Failed to create video from image + audio: {err}"),
                    )
                    .await;
                }
                Err(e) => {
                    return failed_download_response(
                        &notifications,
                        actix_web::http::StatusCode::INTERNAL_SERVER_ERROR,
                        format!("Could not start ffmpeg for image+audio: {e}"),
                    )
                    .await;
                }
            }
        }
    }

    // Standard video path
    let compatible_path = dir.join("pullbox-photos.mp4");
    if let Err(message) = transcode_for_photos(main_path, &compatible_path).await {
        return failed_download_response(
            &notifications,
            actix_web::http::StatusCode::INTERNAL_SERVER_ERROR,
            message,
        )
        .await;
    }

    let bytes = match tokio::fs::read(&compatible_path).await {
        Ok(value) => value,
        Err(error) => {
            return failed_download_response(
                &notifications,
                actix_web::http::StatusCode::INTERNAL_SERVER_ERROR,
                format!("Could not read the Photos-compatible video: {error}"),
            )
            .await;
        }
    };

    notifications.ready().await;
    HttpResponse::Ok()
        .content_type("video/mp4")
        .insert_header((
            "Content-Disposition",
            "attachment; filename=\"pullbox.mp4\"",
        ))
        .body(bytes)
}

async fn transcode_for_photos(source: &Path, destination: &Path) -> Result<(), String> {
    let output = Command::new("ffmpeg")
        .args(["-nostdin", "-hide_banner", "-loglevel", "error", "-y", "-i"])
        .arg(source)
        .args([
            "-map",
            "0:v:0",
            "-map",
            "0:a:0?",
            "-c:v",
            "libx264",
            "-preset",
            "veryfast",
            "-crf",
            "21",
            "-pix_fmt",
            "yuv420p",
            "-c:a",
            "aac",
            "-b:a",
            "160k",
            "-movflags",
            "+faststart",
        ])
        .arg(destination)
        .output()
        .await
        .map_err(|error| format!("Could not start the iPhone video converter: {error}"))?;

    if output.status.success() {
        return Ok(());
    }

    log::warn!(
        "Photos-compatible conversion failed with status {}",
        output.status
    );
    Err("Pullbox downloaded the media but couldn’t convert it for Photos.".to_string())
}
