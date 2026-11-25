use std::sync::Arc;
use std::sync::atomic::{AtomicU64, Ordering};
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use futures_util::{SinkExt, StreamExt};
use nanokvm_core::{InputTransportReport, NanoKvmClient, VideoCodec, VideoPacket};
use serde::Serialize;
use tauri::{AppHandle, Emitter, Runtime};
use tokio::sync::{mpsc, watch};
use tokio_tungstenite::tungstenite::client::IntoClientRequest;
use tokio_tungstenite::tungstenite::{Message, http::HeaderValue};
use tokio_tungstenite::{Connector, connect_async_tls_with_config};

use crate::video_backend::create_backend;

const PING_INTERVAL: Duration = Duration::from_secs(5);
const STALL_TIMEOUT: Duration = Duration::from_secs(15);
const MAX_RECONNECT_DELAY: Duration = Duration::from_secs(30);

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct RealtimeStatus {
    pub device_id: String,
    pub channel: &'static str,
    pub connected: bool,
    pub attempts: u32,
    pub error: Option<String>,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct StreamStats {
    pub device_id: String,
    pub codec: String,
    pub packets: u64,
    pub bytes: u64,
    pub keyframes: u64,
    pub timestamp_micros: u64,
    pub width: Option<u32>,
    pub height: Option<u32>,
}

#[derive(Clone)]
pub(crate) struct RealtimeControl {
    hid_sender: mpsc::Sender<Vec<u8>>,
    stop: watch::Sender<bool>,
}

impl RealtimeControl {
    pub(crate) fn send_hid(&self, report: InputTransportReport) -> Result<(), String> {
        self.hid_sender
            .try_send(report.0)
            .map_err(|error| format!("HID transport is unavailable: {error}"))
    }

    pub(crate) fn stop(&self) {
        if let Ok(keyboard) =
            InputTransportReport::keyboard(nanokvm_core::SOURCE_BROWSER_KEYBOARD, 0, &[], 0, 0)
        {
            let _ = self.hid_sender.try_send(keyboard.0);
        }
        if let Ok(pointer) = InputTransportReport::pointer_release(0, 0) {
            let _ = self.hid_sender.try_send(pointer.0);
        }
        let _ = self.stop.send(true);
    }
}

pub(crate) fn start<R: Runtime>(
    app: AppHandle<R>,
    device_id: uuid::Uuid,
    client: NanoKvmClient,
    codec: VideoCodec,
    video_last_packet: Arc<AtomicU64>,
) -> Result<RealtimeControl, String> {
    if !client.is_authenticated() {
        return Err("connect and authenticate the device before starting realtime input".into());
    }
    let (hid_sender, hid_receiver) = mpsc::channel(128);
    let (stop, stop_receiver) = watch::channel(false);
    let app_video = app.clone();
    let video_client = client.clone();
    let video_device_id = device_id.to_string();
    let video_stop = stop_receiver.clone();
    tauri::async_runtime::spawn(async move {
        supervise_video(
            app_video,
            video_device_id,
            video_client,
            codec,
            video_stop,
            video_last_packet,
        )
        .await;
    });
    let app_hid = app;
    let hid_device_id = device_id.to_string();
    tauri::async_runtime::spawn(async move {
        supervise_hid(app_hid, hid_device_id, client, hid_receiver, stop_receiver).await;
    });
    Ok(RealtimeControl { hid_sender, stop })
}

async fn supervise_video<R: Runtime>(
    app: AppHandle<R>,
    device_id: String,
    client: NanoKvmClient,
    codec: VideoCodec,
    mut stop: watch::Receiver<bool>,
    video_last_packet: Arc<AtomicU64>,
) {
    let path = match codec {
        VideoCodec::H264 => "/stream/h264/direct",
        VideoCodec::H265 => "/stream/h265/direct",
    };
    let mut attempts = 0;
    loop {
        attempts += 1;
        let result = run_video_socket(
            &app,
            &device_id,
            &client,
            path,
            codec,
            attempts,
            &mut stop,
            &video_last_packet,
        )
        .await;
        if *stop.borrow() {
            break;
        }
        emit_status(&app, &device_id, "video", false, attempts, result.err());
        if wait_reconnect(&mut stop, attempts).await {
            break;
        }
    }
}

async fn run_video_socket<R: Runtime>(
    app: &AppHandle<R>,
    device_id: &str,
    client: &NanoKvmClient,
    path: &str,
    codec: VideoCodec,
    attempts: u32,
    stop: &mut watch::Receiver<bool>,
    video_last_packet: &AtomicU64,
) -> Result<(), String> {
    let mut backend = create_backend();
    backend
        .configure(codec)
        .map_err(|error| error.to_string())?;
    let mut socket = connect(client, path, true).await?;
    emit_status(app, device_id, "video", true, attempts, None);
    let mut last_data = tokio::time::Instant::now();
    let mut ping = tokio::time::interval(PING_INTERVAL);
    ping.tick().await;
    let mut packets = 0_u64;
    let mut bytes = 0_u64;
    let mut keyframes = 0_u64;

    loop {
        tokio::select! {
            changed = stop.changed() => {
                if changed.is_err() || *stop.borrow() {
                    return Ok(());
                }
            }
            _ = ping.tick() => {
                socket.send(Message::Ping(Vec::new().into())).await.map_err(|error| error.to_string())?;
                if last_data.elapsed() > STALL_TIMEOUT {
                    return Err("video stream stalled for more than 15 seconds".into());
                }
            }
            message = socket.next() => {
                let Some(message) = message else {
                    return Err("video WebSocket closed".into());
                };
                match message.map_err(|error| error.to_string())? {
                    Message::Binary(payload) => {
                        let packet = VideoPacket::parse(codec, &payload)
                            .map_err(|error| error.to_string())?;
                        backend.submit(codec, &packet.annex_b)
                            .map_err(|error| error.to_string())?;
                        last_data = tokio::time::Instant::now();
                        packets += 1;
                        bytes += packet.annex_b.len() as u64;
                        keyframes += u64::from(packet.keyframe);
                        video_last_packet.store(timestamp_ms() as u64, Ordering::Release);
                        let _ = app.emit("realtime://stats", StreamStats {
                            device_id: device_id.to_owned(),
                            codec: match codec { VideoCodec::H264 => "h264", VideoCodec::H265 => "h265" }.into(),
                            packets,
                            bytes,
                            keyframes,
                            timestamp_micros: packet.timestamp_micros,
                            width: backend.dimensions().map(|size| size.0),
                            height: backend.dimensions().map(|size| size.1),
                        });
                    }
                    Message::Close(_) => return Err("video WebSocket closed".into()),
                    Message::Ping(payload) => {
                        socket.send(Message::Pong(payload)).await.map_err(|error| error.to_string())?;
                    }
                    _ => {}
                }
            }
        }
    }
}

async fn supervise_hid<R: Runtime>(
    app: AppHandle<R>,
    device_id: String,
    client: NanoKvmClient,
    mut receiver: mpsc::Receiver<Vec<u8>>,
    mut stop: watch::Receiver<bool>,
) {
    let mut attempts = 0;
    loop {
        attempts += 1;
        let result = run_hid_socket(
            &app,
            &device_id,
            &client,
            &mut receiver,
            attempts,
            &mut stop,
        )
        .await;
        if *stop.borrow() {
            break;
        }
        emit_status(&app, &device_id, "hid", false, attempts, result.err());
        if wait_reconnect(&mut stop, attempts).await {
            break;
        }
    }
}

async fn run_hid_socket<R: Runtime>(
    app: &AppHandle<R>,
    device_id: &str,
    client: &NanoKvmClient,
    receiver: &mut mpsc::Receiver<Vec<u8>>,
    attempts: u32,
    stop: &mut watch::Receiver<bool>,
) -> Result<(), String> {
    let mut socket = connect(client, "/ws", true).await?;
    emit_status(app, device_id, "hid", true, attempts, None);
    let mut heartbeat = tokio::time::interval(PING_INTERVAL);
    heartbeat.tick().await;
    loop {
        tokio::select! {
            changed = stop.changed() => {
                if changed.is_err() || *stop.borrow() {
                    let _ = socket.send(Message::Binary(vec![0].into())).await;
                    return Ok(());
                }
            }
            _ = heartbeat.tick() => {
                socket.send(Message::Binary(vec![0].into())).await
                    .map_err(|error| error.to_string())?;
            }
            report = receiver.recv() => {
                let report = report.ok_or_else(|| "HID report queue closed".to_owned())?;
                socket.send(Message::Binary(report.into())).await
                    .map_err(|error| error.to_string())?;
            }
            message = socket.next() => {
                let Some(message) = message else {
                    return Err("HID WebSocket closed".into());
                };
                match message.map_err(|error| error.to_string())? {
                    Message::Close(_) => return Err("HID WebSocket closed".into()),
                    Message::Ping(payload) => {
                        socket.send(Message::Pong(payload)).await.map_err(|error| error.to_string())?;
                    }
                    _ => {}
                }
            }
        }
    }
}

type WebSocket =
    tokio_tungstenite::WebSocketStream<tokio_tungstenite::MaybeTlsStream<tokio::net::TcpStream>>;

async fn connect(
    client: &NanoKvmClient,
    path: &str,
    accept_self_signed_tls: bool,
) -> Result<WebSocket, String> {
    let endpoint = client
        .websocket_endpoint(path)
        .map_err(|error| error.to_string())?;
    let mut request = endpoint
        .url
        .clone()
        .into_client_request()
        .map_err(|error| error.to_string())?;
    request.headers_mut().insert(
        "Origin",
        HeaderValue::from_str(&endpoint.origin).map_err(|error| error.to_string())?,
    );
    request.headers_mut().insert(
        "Referer",
        HeaderValue::from_str(&format!("{}/", endpoint.origin.trim_end_matches('/')))
            .map_err(|error| error.to_string())?,
    );
    if let Some(cookie) = endpoint.cookie {
        request.headers_mut().insert(
            "Cookie",
            HeaderValue::from_str(&cookie).map_err(|error| error.to_string())?,
        );
    } else {
        return Err("the authenticated cookie is missing".into());
    }
    let connector = if endpoint.url.starts_with("wss://") && accept_self_signed_tls {
        let tls = native_tls::TlsConnector::builder()
            .danger_accept_invalid_certs(true)
            .build()
            .map_err(|error| error.to_string())?;
        Some(Connector::NativeTls(tls))
    } else {
        None
    };
    connect_async_tls_with_config(request, None, false, connector)
        .await
        .map(|(socket, _)| socket)
        .map_err(|error| error.to_string())
}

async fn wait_reconnect(stop: &mut watch::Receiver<bool>, attempts: u32) -> bool {
    let delay = realtime_delay_for_attempts(attempts);
    tokio::select! {
        changed = stop.changed() => changed.is_err() || *stop.borrow(),
        _ = tokio::time::sleep(delay) => false,
    }
}

fn emit_status<R: Runtime>(
    app: &AppHandle<R>,
    device_id: &str,
    channel: &'static str,
    connected: bool,
    attempts: u32,
    error: Option<String>,
) {
    let _ = app.emit(
        "realtime://status",
        RealtimeStatus {
            device_id: device_id.to_owned(),
            channel,
            connected,
            attempts,
            error,
        },
    );
}

pub(crate) fn timestamp_ms() -> u32 {
    (SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_millis()
        & u32::MAX as u128) as u32
}

#[cfg(test)]
mod tests {
    use super::wait_reconnect;

    #[test]
    fn reconnect_delay_stays_bounded() {
        let delay = super::realtime_delay_for_attempts(100);
        assert_eq!(delay, super::MAX_RECONNECT_DELAY);
    }

    #[tokio::test]
    async fn stop_interrupts_reconnect_wait() {
        let (sender, mut receiver) = tokio::sync::watch::channel(false);
        sender.send(true).unwrap();
        assert!(wait_reconnect(&mut receiver, 1).await);
    }
}

fn realtime_delay_for_attempts(attempts: u32) -> Duration {
    let exponent = attempts.saturating_sub(1).min(6);
    Duration::from_millis(500 * 2_u64.saturating_pow(exponent)).min(MAX_RECONNECT_DELAY)
}
