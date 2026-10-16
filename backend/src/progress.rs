//! Parses and streams yt-dlp progress while preserving the file-response lifecycle.
//!
//! Backend progress is capped at 0.9; iOS owns response transfer and Photos completion.

use crate::apns::MAX_SERVER_PROGRESS;
use std::{
    future::Future,
    io,
    process::{ExitStatus, Stdio},
};
use tokio::{
    io::{AsyncBufReadExt, AsyncReadExt, BufReader},
    process::Command,
    sync::watch,
};

const PROGRESS_PREFIX: &str = "PULLBOX_PROGRESS=";

/// Enables newline-delimited progress even though yt-dlp's `--print` otherwise
/// implies quiet/no-progress output.
pub(crate) fn configure_ytdlp_progress(command: &mut Command) {
    command.args([
        "--progress",
        "--newline",
        "--progress-template",
        "download:PULLBOX_PROGRESS=%(progress._percent_str)s",
    ]);
}

/// Maps one yt-dlp percentage line into Pullbox's server-owned progress range.
pub fn parse_ytdlp_progress(line: &str) -> Option<f64> {
    let percentage = line
        .trim()
        .strip_prefix(PROGRESS_PREFIX)?
        .trim()
        .strip_suffix('%')?
        .trim()
        .parse::<f64>()
        .ok()?;
    if !percentage.is_finite() {
        return None;
    }

    Some(percentage.clamp(0.0, 100.0) / 100.0 * MAX_SERVER_PROGRESS)
}

/// Captured command result with yt-dlp progress-control lines removed from stdout.
pub(crate) struct ProgressCommandOutput {
    pub(crate) status: ExitStatus,
    pub(crate) stdout: String,
    pub(crate) stderr: String,
}

/// Runs a command with both pipes drained while publishing parsed progress as it arrives.
pub(crate) async fn run_command_with_progress<F, Fut>(
    command: &mut Command,
    mut on_progress: F,
) -> io::Result<ProgressCommandOutput>
where
    F: FnMut(f64) -> Fut,
    Fut: Future<Output = ()>,
{
    command.stdout(Stdio::piped()).stderr(Stdio::piped());
    let mut child = command.spawn()?;
    let stdout = child
        .stdout
        .take()
        .ok_or_else(|| io::Error::other("command stdout was not piped"))?;
    let mut stderr = child
        .stderr
        .take()
        .ok_or_else(|| io::Error::other("command stderr was not piped"))?;
    let stderr_task = tokio::spawn(async move {
        let mut bytes = Vec::new();
        stderr.read_to_end(&mut bytes).await?;
        Ok::<_, io::Error>(bytes)
    });

    // A latest-value channel keeps APNs latency from back-pressuring yt-dlp's
    // stdout pipe. Intermediate percentages may be coalesced, but ordering is
    // preserved and the most recent value remains available to the publisher.
    let (progress_sender, mut progress_receiver) = watch::channel(None::<f64>);
    let read_stdout = async move {
        let mut reader = BufReader::new(stdout);
        let mut captured_stdout = String::new();
        let mut line = String::new();
        let mut high_water_progress: Option<f64> = None;
        while reader.read_line(&mut line).await? != 0 {
            if let Some(progress) = parse_ytdlp_progress(&line) {
                if high_water_progress.is_none_or(|previous| progress > previous) {
                    high_water_progress = Some(progress);
                    progress_sender.send_replace(Some(progress));
                }
            } else {
                captured_stdout.push_str(&line);
            }
            line.clear();
        }
        Ok::<_, io::Error>(captured_stdout)
    };
    let publish_progress = async {
        while progress_receiver.changed().await.is_ok() {
            let progress = *progress_receiver.borrow_and_update();
            if let Some(progress) = progress {
                on_progress(progress).await;
            }
        }
    };
    let (captured_stdout, ()) = tokio::join!(read_stdout, publish_progress);
    let captured_stdout = captured_stdout?;

    let status = child.wait().await?;
    let stderr = stderr_task.await.map_err(io::Error::other)??;
    Ok(ProgressCommandOutput {
        status,
        stdout: captured_stdout,
        stderr: String::from_utf8_lossy(&stderr).into_owned(),
    })
}

#[cfg(test)]
mod tests {
    use super::{configure_ytdlp_progress, run_command_with_progress};
    use std::sync::{Arc, Mutex};
    use tokio::process::Command;

    #[test]
    fn yt_dlp_progress_configuration_overrides_prints_implicit_quiet_mode() {
        let mut command = Command::new("yt-dlp");

        configure_ytdlp_progress(&mut command);

        let arguments = command
            .as_std()
            .get_args()
            .map(|argument| argument.to_string_lossy().into_owned())
            .collect::<Vec<_>>();
        assert_eq!(
            arguments,
            [
                "--progress",
                "--newline",
                "--progress-template",
                "download:PULLBOX_PROGRESS=%(progress._percent_str)s",
            ]
        );
    }

    #[tokio::test]
    async fn command_runner_streams_progress_and_preserves_non_progress_output() {
        let values = Arc::new(Mutex::new(Vec::new()));
        let captured_values = values.clone();
        let mut command = Command::new("/bin/sh");
        command.args([
            "-c",
            "printf 'PULLBOX_PROGRESS=50.0%%\\n/tmp/file.mp4\\n'; printf 'warning\\n' >&2",
        ]);

        let output = run_command_with_progress(&mut command, move |progress| {
            let values = captured_values.clone();
            async move {
                values.lock().unwrap().push(progress);
            }
        })
        .await
        .expect("command output");

        assert!(output.status.success());
        assert_eq!(output.stdout, "/tmp/file.mp4\n");
        assert_eq!(output.stderr, "warning\n");
        assert_eq!(*values.lock().unwrap(), vec![0.45]);
    }

    #[tokio::test]
    async fn command_runner_keeps_published_progress_monotonic_across_format_resets() {
        let values = Arc::new(Mutex::new(Vec::new()));
        let captured_values = values.clone();
        let mut command = Command::new("/bin/sh");
        command.args([
            "-c",
            "printf 'PULLBOX_PROGRESS=50.0%%\\n'; sleep 0.05; printf 'PULLBOX_PROGRESS=25.0%%\\n'; sleep 0.05; printf 'PULLBOX_PROGRESS=100.0%%\\n'",
        ]);

        let output = run_command_with_progress(&mut command, move |progress| {
            let values = captured_values.clone();
            async move {
                values.lock().unwrap().push(progress);
            }
        })
        .await
        .expect("command output");

        assert!(output.status.success());
        assert_eq!(*values.lock().unwrap(), vec![0.45, 0.9]);
    }

    #[tokio::test]
    async fn blocked_progress_delivery_does_not_block_command_stdout_drain() {
        let directory = tempfile::tempdir().expect("temporary directory");
        let sentinel = directory.path().join("stdout-drained");
        let script = format!(
            "printf 'PULLBOX_PROGRESS=1.0%%\\n'; i=0; while [ $i -lt 100000 ]; do printf 'payload-payload-payload-payload\\n'; i=$((i + 1)); done; : > '{}'",
            sentinel.display()
        );
        let mut command = Command::new("/bin/sh");
        command.args(["-c", &script]);

        let runner = tokio::spawn(async move {
            run_command_with_progress(&mut command, |_| async {
                std::future::pending::<()>().await;
            })
            .await
        });
        let sentinel_for_poll = sentinel.clone();
        let drained = tokio::task::spawn_blocking(move || {
            for _ in 0..200 {
                if sentinel_for_poll.exists() {
                    return true;
                }
                std::thread::sleep(std::time::Duration::from_millis(10));
            }
            false
        })
        .await
        .expect("sentinel poll");
        runner.abort();
        let cancelled = match runner.await {
            Err(error) => error.is_cancelled(),
            Ok(_) => false,
        };
        assert!(cancelled, "runner task should be cancelled");

        assert!(
            drained,
            "stdout pipe filled while progress delivery was blocked"
        );
    }
}
