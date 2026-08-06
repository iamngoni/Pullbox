use actix_web::{HttpResponse, Responder, web};
use serde::{Deserialize, Serialize};
use serde_json::Value;
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
    format_id.unwrap_or("bv*[ext=mp4]+ba[ext=m4a]/b[ext=mp4]/b")
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
}

#[derive(Debug, Serialize)]
pub struct ErrorBody {
    pub error: String,
}

pub fn configure(config: &mut web::ServiceConfig) {
    config
        .route("/health", web::get().to(health))
        .route("/api/analyze", web::post().to(analyze))
        .route("/api/download", web::post().to(download));
}

async fn health() -> impl Responder {
    HttpResponse::Ok().json(serde_json::json!({ "status": "ready" }))
}

async fn analyze(body: web::Json<UrlRequest>) -> impl Responder {
    let parsed = match validate_http_url(&body.url) {
        Ok(url) => url,
        Err(message) => {
            return HttpResponse::BadRequest().json(ErrorBody {
                error: message.to_string(),
            });
        }
    };

    let output = Command::new("yt-dlp")
        .args(["--dump-single-json", "--skip-download", "--no-playlist"])
        .arg(parsed.as_str())
        .output()
        .await;

    let output = match output {
        Ok(value) if value.status.success() => value,
        Ok(value) => {
            let message = String::from_utf8_lossy(&value.stderr)
                .lines()
                .last()
                .unwrap_or("Could not analyze that URL")
                .to_string();
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

async fn download(body: web::Json<DownloadRequest>) -> impl Responder {
    let parsed = match validate_http_url(&body.url) {
        Ok(url) => url,
        Err(message) => {
            return HttpResponse::BadRequest().json(ErrorBody {
                error: message.to_string(),
            });
        }
    };

    let directory = match tempfile::tempdir() {
        Ok(value) => value,
        Err(error) => {
            return HttpResponse::InternalServerError().json(ErrorBody {
                error: format!("Could not create temporary storage: {error}"),
            });
        }
    };
    let output_template = directory.path().join("pullbox-%(id)s.%(ext)s");
    let output_template = output_template.to_string_lossy().into_owned();
    let format = choose_format(body.format_id.as_deref()).to_string();

    let output = Command::new("yt-dlp")
        .args([
            "--no-playlist",
            "--no-progress",
            "--merge-output-format",
            "mp4",
            "--print",
            "after_move:filepath",
            "-f",
            &format,
            "-o",
            &output_template,
        ])
        .arg(parsed.as_str())
        .output()
        .await;

    let output = match output {
        Ok(value) if value.status.success() => value,
        Ok(value) => {
            let message = String::from_utf8_lossy(&value.stderr)
                .lines()
                .last()
                .unwrap_or("Download failed")
                .to_string();
            return HttpResponse::UnprocessableEntity().json(ErrorBody { error: message });
        }
        Err(error) => {
            return HttpResponse::InternalServerError().json(ErrorBody {
                error: format!("Could not start yt-dlp: {error}"),
            });
        }
    };

    let path = String::from_utf8_lossy(&output.stdout)
        .lines()
        .rfind(|line| !line.trim().is_empty())
        .map(str::trim)
        .unwrap_or_default()
        .to_string();
    if path.is_empty() {
        return HttpResponse::InternalServerError().json(ErrorBody {
            error: "yt-dlp completed without returning a file".to_string(),
        });
    }

    let bytes = match tokio::fs::read(&path).await {
        Ok(value) => value,
        Err(error) => {
            return HttpResponse::InternalServerError().json(ErrorBody {
                error: format!("Could not read downloaded file: {error}"),
            });
        }
    };
    let extension = std::path::Path::new(&path)
        .extension()
        .and_then(|value| value.to_str())
        .unwrap_or("mp4");
    let content_type = match extension {
        "mp4" | "m4v" => "video/mp4",
        "mov" => "video/quicktime",
        "m4a" => "audio/mp4",
        "mp3" => "audio/mpeg",
        _ => "application/octet-stream",
    };

    HttpResponse::Ok()
        .content_type(content_type)
        .insert_header((
            "Content-Disposition",
            format!("attachment; filename=\"pullbox.{extension}\""),
        ))
        .body(bytes)
}
