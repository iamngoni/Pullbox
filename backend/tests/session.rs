//! Verifies the download lifecycle publishes only server-owned ActivityKit phases.

use async_trait::async_trait;
use pullbox_backend::apns::{
    ActivityNotificationContext, ActivityNotifier, ActivityNotifierHandle, ApnsSendError,
    DownloadNotificationSession, NotificationOutcome,
};
use std::{
    sync::{Arc, Mutex},
    time::Duration,
};

struct RecordingNotifier {
    events: Mutex<Vec<String>>,
}

#[async_trait]
impl ActivityNotifier for RecordingNotifier {
    async fn start(
        &self,
        _context: &ActivityNotificationContext,
        _timestamp: i64,
    ) -> Result<NotificationOutcome, ApnsSendError> {
        self.events.lock().unwrap().push("start".to_string());
        Ok(NotificationOutcome::Accepted)
    }

    async fn progress(
        &self,
        _context: &ActivityNotificationContext,
        progress: f64,
        _timestamp: i64,
    ) -> Result<NotificationOutcome, ApnsSendError> {
        self.events
            .lock()
            .unwrap()
            .push(format!("progress:{progress}"));
        Ok(NotificationOutcome::Accepted)
    }

    async fn ready(
        &self,
        _context: &ActivityNotificationContext,
        _timestamp: i64,
    ) -> Result<NotificationOutcome, ApnsSendError> {
        self.events.lock().unwrap().push("ready".to_string());
        Ok(NotificationOutcome::Accepted)
    }

    async fn failed(
        &self,
        _context: &ActivityNotificationContext,
        _message: &str,
        _timestamp: i64,
    ) -> Result<NotificationOutcome, ApnsSendError> {
        self.events.lock().unwrap().push("failed".to_string());
        Ok(NotificationOutcome::Accepted)
    }
}

struct BlockingNotifier;

#[async_trait]
impl ActivityNotifier for BlockingNotifier {
    async fn start(
        &self,
        _context: &ActivityNotificationContext,
        _timestamp: i64,
    ) -> Result<NotificationOutcome, ApnsSendError> {
        std::future::pending().await
    }

    async fn progress(
        &self,
        _context: &ActivityNotificationContext,
        _progress: f64,
        _timestamp: i64,
    ) -> Result<NotificationOutcome, ApnsSendError> {
        std::future::pending().await
    }

    async fn ready(
        &self,
        _context: &ActivityNotificationContext,
        _timestamp: i64,
    ) -> Result<NotificationOutcome, ApnsSendError> {
        std::future::pending().await
    }

    async fn failed(
        &self,
        _context: &ActivityNotificationContext,
        _message: &str,
        _timestamp: i64,
    ) -> Result<NotificationOutcome, ApnsSendError> {
        std::future::pending().await
    }
}

#[actix_rt::test]
async fn apns_delivery_never_blocks_the_media_response_lifecycle() {
    let context = ActivityNotificationContext::new(
        "client-blocked",
        "request-blocked",
        "Blocked APNs",
        "https://example.com/video",
    );
    let handle = ActivityNotifierHandle::new(Arc::new(BlockingNotifier));

    let session = actix_rt::time::timeout(
        Duration::from_millis(50),
        DownloadNotificationSession::begin(Some(context), Some(handle)),
    )
    .await
    .expect("APNs start blocked the media lifecycle");
    actix_rt::time::timeout(Duration::from_millis(50), session.ready())
        .await
        .expect("APNs ready blocked the media lifecycle");
}

#[actix_rt::test]
async fn download_notification_session_starts_then_reports_progress_and_server_ready() {
    let recorder = Arc::new(RecordingNotifier {
        events: Mutex::new(Vec::new()),
    });
    let handle = ActivityNotifierHandle::new(recorder.clone());
    let context = ActivityNotificationContext::new(
        "client-123",
        "request-456",
        "Example clip",
        "https://example.com/video",
    );

    let session = DownloadNotificationSession::begin(Some(context), Some(handle)).await;
    session.progress(0.45).await;
    session.ready().await;

    for _ in 0..100 {
        if recorder
            .events
            .lock()
            .unwrap()
            .last()
            .is_some_and(|event| event == "ready")
        {
            break;
        }
        actix_rt::time::sleep(Duration::from_millis(10)).await;
    }

    assert_eq!(
        *recorder.events.lock().unwrap(),
        vec!["start", "progress:0.45", "ready"]
    );
}
