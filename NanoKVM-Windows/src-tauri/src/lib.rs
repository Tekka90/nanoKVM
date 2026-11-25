use std::collections::HashMap;
use std::path::PathBuf;
use std::sync::atomic::{AtomicU32, AtomicU64, Ordering};
use std::sync::{Arc, Mutex};

use nanokvm_core::{
    ClientConfig, Credentials, EdidBuilder, FeatureState, InputTransportReport, JigglerRequest,
    LoginResult, MountImageRequest, NameRequest, NanoKvmClient, PasteRequest, PointerMode,
    RateControl, SavedDevice, ScriptRunRequest, SensitiveActionRequest, SessionState,
    StaticIpRequest, TwoFactorVerifyRequest, UploadMetadata, UsbIdRequest, UsbNetworkRequest,
    WakeOnLanHost, WifiConnectRequest,
};
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use tauri::{Emitter, Manager, State};

mod discovery;
mod realtime;
mod storage;
mod video_backend;

use realtime::{RealtimeControl, timestamp_ms};
use storage::{DeviceCatalog, SecretStore};
use video_backend::{VideoCapabilities, create_backend};

const CREDENTIAL_SERVICE: &str = "org.jupille.NanoKVM.Windows";

struct AppState {
    catalog_path: PathBuf,
    devices: Mutex<DeviceCatalog>,
    secrets: Box<dyn SecretStore>,
    sessions: Mutex<HashMap<uuid::Uuid, NanoKvmClient>>,
    login_challenges: Mutex<HashMap<uuid::Uuid, String>>,
    realtime: Mutex<HashMap<uuid::Uuid, RealtimeControl>>,
    hid_sequence: AtomicU32,
    video_last_packet: Arc<AtomicU64>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "snake_case")]
enum LoginStatus {
    Authenticated,
    RequiresTwoFactor,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
struct LoginCommandResult {
    status: LoginStatus,
}

#[tauri::command]
fn app_features() -> Vec<FeatureState> {
    vec![
        FeatureState {
            name: "screen",
            available: false,
            detail: "Authenticated WebSocket supervision is implemented; native Media Foundation presentation requires Windows.",
        },
        FeatureState {
            name: "authentication",
            available: true,
            detail: "Typed login and 2FA exchange; token remains in Rust.",
        },
        FeatureState {
            name: "devices",
            available: true,
            detail: "Persistent device catalog, sessions, reconnect and Tauri commands.",
        },
        FeatureState {
            name: "security",
            available: cfg!(windows),
            detail: "Windows Credential Manager; non-Windows builds use memory-only test storage.",
        },
    ]
}

#[tauri::command]
fn validate_session_state(session: SessionState) -> Result<SessionState, String> {
    Ok(session)
}

#[tauri::command]
fn video_capabilities() -> VideoCapabilities {
    create_backend().capabilities()
}

#[tauri::command]
fn list_devices(state: State<'_, AppState>) -> Result<Vec<SavedDevice>, String> {
    Ok(state
        .devices
        .lock()
        .map_err(|_| "device catalog lock poisoned".to_owned())?
        .devices()
        .to_vec())
}

#[tauri::command]
async fn discover_devices() -> Result<Vec<discovery::DiscoveredDevice>, String> {
    tauri::async_runtime::spawn_blocking(discovery::discover)
        .await
        .map_err(|error| format!("network discovery task failed: {error}"))?
}

#[tauri::command]
fn save_device(
    state: State<'_, AppState>,
    id: Option<String>,
    name: String,
    address: String,
    username: String,
    password: Option<String>,
) -> Result<SavedDevice, String> {
    let is_new = id.is_none();
    let id = match id {
        Some(id) => uuid::Uuid::parse_str(&id)
            .map_err(|error| format!("invalid device identifier: {error}"))?,
        None => uuid::Uuid::new_v4(),
    };
    let device =
        SavedDevice::new(id, name, address, username).map_err(|error| error.to_string())?;
    if let Some(password) = password {
        if password.is_empty() {
            return Err("password cannot be empty".to_owned());
        }
        state
            .secrets
            .set(CREDENTIAL_SERVICE, &id.to_string(), &password)?;
    } else if is_new {
        return Err("a password is required when adding a device".to_owned());
    }

    let mut devices = state
        .devices
        .lock()
        .map_err(|_| "device catalog lock poisoned".to_owned())?;
    devices.upsert(device.clone())?;
    devices.save(&state.catalog_path)?;
    Ok(device)
}

#[tauri::command]
fn remove_device(state: State<'_, AppState>, id: String) -> Result<(), String> {
    let id = uuid::Uuid::parse_str(&id)
        .map_err(|error| format!("invalid device identifier: {error}"))?;
    let mut devices = state
        .devices
        .lock()
        .map_err(|_| "device catalog lock poisoned".to_owned())?;
    if !devices.remove(id) {
        return Err("device was not found".to_owned());
    }
    devices.save(&state.catalog_path)?;
    state.secrets.delete(CREDENTIAL_SERVICE, &id.to_string())
}

#[tauri::command]
async fn connect_device(
    state: State<'_, AppState>,
    id: String,
) -> Result<LoginCommandResult, String> {
    let id = uuid::Uuid::parse_str(&id)
        .map_err(|error| format!("invalid device identifier: {error}"))?;
    let device = state
        .devices
        .lock()
        .map_err(|_| "device catalog lock poisoned".to_owned())?
        .devices()
        .iter()
        .find(|device| device.id == id)
        .cloned()
        .ok_or_else(|| "device was not found".to_owned())?;
    let password = state.secrets.get(CREDENTIAL_SERVICE, &id.to_string())?;
    let credentials =
        Credentials::new(device.username, password).map_err(|error| error.to_string())?;
    let client = NanoKvmClient::new(ClientConfig::new(device.address).with_self_signed_tls(true))
        .map_err(|error| error.to_string())?;

    let result = client
        .login(&credentials)
        .await
        .map_err(|error| error.to_string())?;
    state
        .sessions
        .lock()
        .map_err(|_| "session lock poisoned".to_owned())?
        .insert(id, client);
    match result {
        LoginResult::Authenticated => Ok(LoginCommandResult {
            status: LoginStatus::Authenticated,
        }),
        LoginResult::RequiresTwoFactor { challenge } => {
            state
                .login_challenges
                .lock()
                .map_err(|_| "2FA state lock poisoned".to_owned())?
                .insert(id, challenge);
            Ok(LoginCommandResult {
                status: LoginStatus::RequiresTwoFactor,
            })
        }
    }
}

#[tauri::command]
async fn complete_two_factor(
    state: State<'_, AppState>,
    id: String,
    code: String,
) -> Result<LoginCommandResult, String> {
    let id = uuid::Uuid::parse_str(&id)
        .map_err(|error| format!("invalid device identifier: {error}"))?;
    if code.trim().is_empty() {
        return Err("the two-factor code is empty".to_owned());
    }
    let client = state
        .sessions
        .lock()
        .map_err(|_| "session lock poisoned".to_owned())?
        .get(&id)
        .cloned()
        .ok_or_else(|| "no login attempt exists for this device".to_owned())?;
    let challenge = state
        .login_challenges
        .lock()
        .map_err(|_| "2FA state lock poisoned".to_owned())?
        .get(&id)
        .cloned()
        .ok_or_else(|| "no two-factor challenge exists for this device".to_owned())?;
    client
        .complete_two_factor_login(&TwoFactorVerifyRequest { challenge, code })
        .await
        .map_err(|error| error.to_string())?;
    state
        .login_challenges
        .lock()
        .map_err(|_| "2FA state lock poisoned".to_owned())?
        .remove(&id);
    state
        .sessions
        .lock()
        .map_err(|_| "session lock poisoned".to_owned())?
        .insert(id, client);
    Ok(LoginCommandResult {
        status: LoginStatus::Authenticated,
    })
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(tag = "kind", rename_all = "snake_case")]
enum HidInput {
    Keyboard {
        modifiers: u8,
        keys: Vec<u8>,
    },
    AbsolutePointer {
        buttons: u8,
        x: f64,
        y: f64,
        wheel: i32,
    },
    RelativePointer {
        buttons: u8,
        dx: i32,
        dy: i32,
        wheel: i32,
    },
    Release,
}

#[derive(Debug, Clone, Serialize)]
struct DeviceActionResult {
    value: Value,
}

#[derive(Debug, Clone, Serialize)]
struct PageSnapshot {
    values: HashMap<String, Value>,
    errors: HashMap<String, String>,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
struct UploadProgress {
    upload_id: String,
    chunk_index: u64,
    total_chunks: u64,
    bytes_sent: u64,
    total_bytes: u64,
}

fn device_id(value: &str) -> Result<uuid::Uuid, String> {
    uuid::Uuid::parse_str(value).map_err(|error| format!("invalid device identifier: {error}"))
}

fn client_for(state: &AppState, id: uuid::Uuid) -> Result<NanoKvmClient, String> {
    state
        .sessions
        .lock()
        .map_err(|_| "session lock poisoned".to_owned())?
        .get(&id)
        .cloned()
        .ok_or_else(|| "connect the device before running this action".to_owned())
}

fn field_string(payload: &Value, key: &str) -> Result<String, String> {
    payload
        .get(key)
        .and_then(Value::as_str)
        .map(str::to_owned)
        .ok_or_else(|| format!("missing or invalid field: {key}"))
}

fn field_bool(payload: &Value, key: &str) -> Result<bool, String> {
    payload
        .get(key)
        .and_then(Value::as_bool)
        .ok_or_else(|| format!("missing or invalid field: {key}"))
}

fn field_u64(payload: &Value, key: &str) -> Result<u64, String> {
    payload
        .get(key)
        .and_then(Value::as_u64)
        .ok_or_else(|| format!("missing or invalid field: {key}"))
}

fn field_u32(payload: &Value, key: &str) -> Result<u32, String> {
    let value = field_u64(payload, key)?;
    u32::try_from(value).map_err(|_| format!("field {key} is outside the supported range"))
}

fn sensitive_action(action: &str, payload: &Value) -> Option<&'static str> {
    match action {
        "password-change" => Some("change_password"),
        "ssh" => Some(if field_bool(payload, "enabled").unwrap_or(false) {
            "enable_ssh"
        } else {
            "disable_ssh"
        }),
        "tailscale-logout" => Some("tailscale_logout"),
        action if action.starts_with("tailscale-") => Some(match action {
            "tailscale-install" => "tailscale_install",
            "tailscale-login" => "tailscale_login",
            "tailscale-up" => "tailscale_up",
            "tailscale-down" => "tailscale_down",
            "tailscale-start" => "tailscale_start",
            "tailscale-stop" => "tailscale_stop",
            "tailscale-restart" => "tailscale_restart",
            _ => return None,
        }),
        "tailscale-exit-node" => Some("tailscale_set_exit_node"),
        "tailscale-subnet-route" => Some("tailscale_set_subnet_route"),
        "mcp-copy-config" => Some("mcp_show_key"),
        "mcp-regenerate" => Some("mcp_regenerate_key"),
        "mcp-enable" => Some(if field_bool(payload, "enabled").unwrap_or(false) {
            "mcp_enable"
        } else {
            "mcp_disable"
        }),
        "reboot" => Some("nanokvm_restart"),
        "image-delete" => Some("delete_image"),
        "timelapse" if field_bool(payload, "enabled").unwrap_or(false) => {
            Some("screen_timelapse_enable")
        }
        "signature-verification" => Some("update_signature_verification"),
        "script-foreground" | "script-background" => Some("run_script"),
        "script-delete" => Some("delete_script"),
        "finger-press" | "finger-release" => Some("target_power"),
        _ => None,
    }
}

fn requires_confirmation(action: &str) -> bool {
    matches!(
        action,
        "ssh"
            | "wifi-connect"
            | "wifi-disconnect"
            | "tailscale-logout"
            | "tailscale-install"
            | "tailscale-login"
            | "tailscale-up"
            | "tailscale-down"
            | "tailscale-start"
            | "tailscale-stop"
            | "tailscale-restart"
            | "wol-delete"
            | "script-delete"
            | "image-delete"
            | "mcp-regenerate"
            | "timelapse"
            | "firmware-update"
            | "reboot"
            | "virtual-network"
            | "virtual-disk"
            | "virtual-audio"
            | "static-ip"
            | "wifi-preset"
            | "signature-verification"
            | "finger-press"
            | "edid-upload"
            | "edid-set"
            | "edid-delete"
            | "edid-match-display"
    )
}

async fn snapshot_entry(
    snapshot: &mut PageSnapshot,
    name: &str,
    value: nanokvm_core::Result<Value>,
) {
    match value {
        Ok(value) => {
            snapshot.values.insert(name.into(), value);
        }
        Err(error) => {
            snapshot.errors.insert(name.into(), error.to_string());
        }
    }
}

#[tauri::command]
async fn load_page_state(
    state: State<'_, AppState>,
    id: String,
    page: String,
) -> Result<PageSnapshot, String> {
    let client = client_for(&state, device_id(&id)?)?;
    let mut snapshot = PageSnapshot {
        values: HashMap::new(),
        errors: HashMap::new(),
    };
    match page.as_str() {
        "Screen" => {
            snapshot_entry(&mut snapshot, "encoder", client.stream_encoder().await).await;
            snapshot_entry(
                &mut snapshot,
                "pointer_mode",
                client.hid_pointer_mode().await,
            )
            .await;
        }
        "Media" => {
            snapshot_entry(&mut snapshot, "images", client.storage_images().await).await;
            snapshot_entry(&mut snapshot, "mounted", client.storage_mounted().await).await;
        }
        "Wake" => {
            snapshot_entry(&mut snapshot, "hosts", client.wol_hosts().await).await;
        }
        "Network" => {
            snapshot_entry(&mut snapshot, "hostname", client.vm_hostname().await).await;
            snapshot_entry(&mut snapshot, "ssh", client.ssh().await).await;
            snapshot_entry(&mut snapshot, "mdns", client.mdns().await).await;
            snapshot_entry(&mut snapshot, "wifi", client.wifi_status().await).await;
            snapshot_entry(&mut snapshot, "tailscale", client.tailscale_status().await).await;
        }
        "Services" => {
            snapshot_entry(&mut snapshot, "ai", client.ai_config().await).await;
            snapshot_entry(&mut snapshot, "memory_fabric", client.memory_fabric().await).await;
            snapshot_entry(&mut snapshot, "timelapse", client.timelapse().await).await;
            snapshot_entry(&mut snapshot, "scripts", client.scripts().await).await;
        }
        "Device" => {
            snapshot_entry(&mut snapshot, "info", client.vm_info().await).await;
            snapshot_entry(&mut snapshot, "hardware", client.vm_hardware().await).await;
            snapshot_entry(&mut snapshot, "web_title", client.vm_web_title().await).await;
            snapshot_entry(&mut snapshot, "low_power", client.low_power().await).await;
            snapshot_entry(&mut snapshot, "swap", client.swap().await).await;
            snapshot_entry(&mut snapshot, "timezone", client.vm_timezone().await).await;
            snapshot_entry(&mut snapshot, "preview", client.preview().await).await;
            snapshot_entry(&mut snapshot, "version", client.version().await).await;
        }
        "Advanced" => {
            snapshot_entry(&mut snapshot, "usb_id", client.usb_id().await).await;
            snapshot_entry(&mut snapshot, "usb_network", client.usb_network().await).await;
            snapshot_entry(
                &mut snapshot,
                "virtual_devices",
                client.usb_virtual_device().await,
            )
            .await;
            for (name, path) in [
                ("cdrom_name", "/vm/disk-inquiry-cdrom"),
                ("disk_name", "/vm/disk-inquiry"),
                ("audio_name", "/vm/uac2-function-name"),
            ] {
                snapshot_entry(&mut snapshot, name, client.reported_name(path).await).await;
            }
            snapshot_entry(&mut snapshot, "static_ip", client.static_ip().await).await;
            snapshot_entry(&mut snapshot, "wifi_preset", client.wifi_preset().await).await;
            snapshot_entry(
                &mut snapshot,
                "download",
                client.image_download_status().await,
            )
            .await;
            snapshot_entry(&mut snapshot, "signature", client.signature().await).await;
            snapshot_entry(
                &mut snapshot,
                "two_factor",
                client.two_factor_status().await,
            )
            .await;
            snapshot_entry(&mut snapshot, "finger", client.finger_robot().await).await;
            snapshot_entry(&mut snapshot, "apps", client.apps().await).await;
        }
        "Settings" => {
            snapshot_entry(&mut snapshot, "encoder", client.stream_encoder().await).await;
            snapshot_entry(&mut snapshot, "edid", client.edid().await).await;
            snapshot_entry(&mut snapshot, "custom_edid", client.custom_edid().await).await;
            snapshot_entry(&mut snapshot, "hdmi_capture", client.hdmi_capture().await).await;
            snapshot_entry(
                &mut snapshot,
                "pointer_mode",
                client.hid_pointer_mode().await,
            )
            .await;
            snapshot_entry(&mut snapshot, "mouse_jiggler", client.mouse_jiggler().await).await;
        }
        _ => return Err(format!("unsupported page: {page}")),
    }
    Ok(snapshot)
}

#[tauri::command]
async fn device_action(
    state: State<'_, AppState>,
    id: String,
    action: String,
    payload: Value,
    confirmed: bool,
    two_factor_code: Option<String>,
    password: Option<String>,
) -> Result<DeviceActionResult, String> {
    let id = device_id(&id)?;
    if requires_confirmation(&action) && !confirmed {
        return Err(format!(
            "the action {action} requires explicit confirmation"
        ));
    }
    let client = client_for(&state, id)?;
    if let Some(sensitive) = sensitive_action(&action, &payload) {
        let code = two_factor_code.unwrap_or_default().trim().to_owned();
        if code.is_empty() {
            return Err(format!(
                "two-factor code required for sensitive action {sensitive}"
            ));
        }
        client
            .verify_sensitive_action(&SensitiveActionRequest {
                action: sensitive.to_owned(),
                code,
                password,
            })
            .await
            .map_err(|error| error.to_string())?;
    }

    let value = match action.as_str() {
        "hid-paste" => {
            client
                .paste(&PasteRequest {
                    content: field_string(&payload, "content")?,
                })
                .await
        }
        "wol-list" => client.wol_hosts().await,
        "wol-save" => {
            client
                .add_wol_host(&WakeOnLanHost {
                    mac: field_string(&payload, "mac")?,
                    name: field_string(&payload, "name")?,
                })
                .await
        }
        "wol-wake" => client.wake_host(&field_string(&payload, "mac")?).await,
        "wol-delete" => {
            client
                .delete_wol_host(&NameRequest {
                    name: field_string(&payload, "name")?,
                })
                .await
        }
        "hostname" => {
            client
                .set_vm_hostname(&nanokvm_core::HostnameRequest {
                    hostname: field_string(&payload, "hostname")?,
                })
                .await
        }
        "mdns" => client.set_mdns(field_bool(&payload, "enabled")?).await,
        "ssh" => client.set_ssh(field_bool(&payload, "enabled")?).await,
        "wifi-scan" => client.scan_wifi().await,
        "wifi-connect" => {
            client
                .connect_wifi(&WifiConnectRequest {
                    ssid: field_string(&payload, "ssid")?,
                    password: field_string(&payload, "password")?,
                })
                .await
        }
        "wifi-disconnect" => client.disconnect_wifi().await,
        "tailscale-status" => client.tailscale_status().await,
        "tailscale-exit-node" => {
            client
                .set_tailscale_exit_node(field_bool(&payload, "enabled")?)
                .await
        }
        "tailscale-subnet-route" => {
            client
                .set_tailscale_subnet_route(field_bool(&payload, "enabled")?)
                .await
        }
        "tailscale-logout" => client.tailscale_action("logout".into()).await,
        "tailscale-install" | "tailscale-login" | "tailscale-up" | "tailscale-down"
        | "tailscale-start" | "tailscale-stop" | "tailscale-restart" => {
            client
                .tailscale_action(
                    action
                        .strip_prefix("tailscale-")
                        .expect("matched prefix")
                        .into(),
                )
                .await
        }
        "mcp-enable" => {
            client
                .set_ai_config(&json!({"mcpEnabled": field_bool(&payload, "enabled")?}))
                .await
        }
        "mcp-copy-config" => client.mcp_key().await,
        "mcp-regenerate" => client.regenerate_mcp_key().await,
        "memory-fabric" => client.set_memory_fabric(&payload).await,
        "timelapse" => client.set_timelapse(&payload).await,
        "scripts-list" => client.scripts().await,
        "script-foreground" | "script-background" => {
            client
                .run_script(&ScriptRunRequest {
                    name: field_string(&payload, "name")?,
                    run_type: if action == "script-background" {
                        "background"
                    } else {
                        "foreground"
                    }
                    .into(),
                })
                .await
        }
        "script-delete" => {
            client
                .delete_script(&NameRequest {
                    name: field_string(&payload, "name")?,
                })
                .await
        }
        "low-power" => client.set_low_power(field_bool(&payload, "enabled")?).await,
        "swap" => client.set_swap(field_bool(&payload, "enabled")?).await,
        "time-sync" => client.sync_time().await,
        "preview-updates" => client.set_preview(field_bool(&payload, "enabled")?).await,
        "firmware-update" => client.update().await,
        "reboot" => client.reboot().await,
        "virtual-refresh" => client.refresh_usb().await,
        "virtual-disk-disable" => client.set_usb_disk_disabled().await,
        "virtual-network" => {
            client
                .set_usb_virtual_device(&json!({"device": "network"}))
                .await
        }
        "virtual-disk" => {
            if field_bool(&payload, "enabled")? {
                client
                    .set_usb_virtual_device(&json!({"device": "disk"}))
                    .await
            } else {
                client.set_usb_disk_disabled().await
            }
        }
        "virtual-audio" => {
            client
                .set_usb_virtual_device(&json!({
                    "device": "audio",
                    "mode": field_string(&payload, "mode")?
                }))
                .await
        }
        "usb-name-cdrom" | "usb-name-disk" | "usb-name-audio" => {
            let path = match action.as_str() {
                "usb-name-cdrom" => "/vm/disk-inquiry-cdrom",
                "usb-name-disk" => "/vm/disk-inquiry",
                _ => "/vm/uac2-function-name",
            };
            client.set_usb_reported_name(path, &payload).await
        }
        "static-ip" => {
            client
                .set_static_ip(&StaticIpRequest {
                    enabled: field_bool(&payload, "enabled")?,
                    ip: field_string(&payload, "ip")?,
                })
                .await
        }
        "wifi-preset" => client.network_preset(&payload).await,
        "image-download" => client.start_image_download(&payload).await,
        "image-download-pause" => client.pause_image_download().await,
        "image-download-resume" => client.resume_image_download().await,
        "image-download-cancel" => client.cancel_image_download().await,
        "signature-verification" => {
            client
                .set_signature_verification(field_bool(&payload, "enabled")?)
                .await
        }
        "finger-press" => client.finger_robot_press().await,
        "finger-release" => client.finger_robot_release().await,
        "stream-quality" => {
            client
                .set_stream_quality(field_u32(&payload, "value")?)
                .await
        }
        "stream-gop" => client.set_stream_gop(field_u32(&payload, "value")?).await,
        "stream-fps" => client.set_stream_fps(field_u32(&payload, "value")?).await,
        "stream-rate-control" => {
            let mode = match field_string(&payload, "value")?.as_str() {
                "cbr" => RateControl::Cbr,
                "vbr" => RateControl::Vbr,
                "cqp" => RateControl::Cqp,
                other => return Err(format!("unsupported rate control: {other}")),
            };
            client.set_stream_rate_control(mode).await
        }
        "stream-codec" => {
            client
                .set_stream_mode(field_string(&payload, "value")?)
                .await
        }
        "hdmi-capture" => {
            client
                .set_hdmi_capture(field_bool(&payload, "enabled")?)
                .await
        }
        "edid-match-display" => client.set_edid(&field_string(&payload, "name")?).await,
        "edid-set" => client.set_edid(&field_string(&payload, "name")?).await,
        "edid-delete" => client.delete_edid(&field_string(&payload, "name")?).await,
        "pointer-mode" => {
            let mode = match field_string(&payload, "value")?.as_str() {
                "absolute" => PointerMode::Absolute,
                "relative" => PointerMode::Relative,
                other => return Err(format!("unsupported pointer mode: {other}")),
            };
            client.set_hid_pointer_mode(mode).await
        }
        "hid-reset" => client.reset_hid().await,
        "mouse-jiggler" => {
            client
                .set_mouse_jiggler(&JigglerRequest {
                    enabled: field_bool(&payload, "enabled")?,
                    mode: field_string(&payload, "mode").unwrap_or_else(|_| "relative".into()),
                })
                .await
        }
        "image-list" => client.storage_images().await,
        "image-mounted" => client.storage_mounted().await,
        "image-mount" | "image-unmount" => {
            client
                .mount_image(&MountImageRequest {
                    file: if action == "image-unmount" {
                        String::new()
                    } else {
                        field_string(&payload, "file")?
                    },
                    cdrom: field_bool(&payload, "cdrom").unwrap_or(false),
                    read_only: field_bool(&payload, "read_only").unwrap_or(false),
                })
                .await
        }
        "image-delete" => client.delete_image(&field_string(&payload, "file")?).await,
        "usb-id" => {
            let request: UsbIdRequest =
                serde_json::from_value(payload).map_err(|error| error.to_string())?;
            client.set_usb_id(&request).await
        }
        "usb-network" => {
            let request: UsbNetworkRequest =
                serde_json::from_value(payload).map_err(|error| error.to_string())?;
            client.set_usb_network(&request).await
        }
        "password-change" => {
            client
                .update_password(
                    &field_string(&payload, "username")?,
                    &field_string(&payload, "new_password")?,
                )
                .await
        }
        _ => return Err(format!("unsupported device action: {action}")),
    }
    .map_err(|error| error.to_string())?;
    Ok(DeviceActionResult { value })
}

#[tauri::command]
async fn upload_file(
    app: tauri::AppHandle,
    state: State<'_, AppState>,
    id: String,
    kind: String,
    file_name: String,
    content_type: Option<String>,
    bytes: Vec<u8>,
) -> Result<Value, String> {
    let client = client_for(&state, device_id(&id)?)?;
    if bytes.is_empty() {
        return Err("the selected file is empty".into());
    }
    let metadata = UploadMetadata {
        file_name,
        content_type,
    };
    match kind.as_str() {
        "image" => {
            const CHUNK_SIZE: usize = 8 * 1024 * 1024;
            let upload_id = uuid::Uuid::new_v4().to_string();
            let total_bytes = bytes.len() as u64;
            let total_chunks = bytes.len().div_ceil(CHUNK_SIZE) as u64;
            let mut latest = Value::Null;
            for (chunk_index, chunk) in bytes.chunks(CHUNK_SIZE).enumerate() {
                latest = client
                    .storage_upload_chunk(
                        nanokvm_core::ChunkMetadata {
                            upload_id: upload_id.clone(),
                            file_name: metadata.file_name.clone(),
                            chunk_size: chunk.len() as u64,
                            chunk_index: chunk_index as u64,
                            total_chunks,
                        },
                        chunk.to_vec(),
                    )
                    .await
                    .map_err(|error| error.to_string())?;
                let _ = app.emit(
                    "upload://progress",
                    UploadProgress {
                        upload_id: upload_id.clone(),
                        chunk_index: chunk_index as u64,
                        total_chunks,
                        bytes_sent: ((chunk_index + 1) * CHUNK_SIZE).min(bytes.len()) as u64,
                        total_bytes,
                    },
                );
            }
            Ok(latest)
        }
        "edid" | "script" => {
            let result = if kind == "edid" {
                client.upload_edid(metadata, bytes).await
            } else {
                client.upload_script(metadata, bytes).await
            };
            result.map_err(|error| error.to_string())
        }
        _ => Err(format!("unsupported upload kind: {kind}")),
    }
}

#[tauri::command]
fn start_realtime(
    app: tauri::AppHandle,
    state: State<'_, AppState>,
    id: String,
    codec: nanokvm_core::VideoCodec,
) -> Result<(), String> {
    let id = device_id(&id)?;
    let client = client_for(&state, id)?;
    let control = realtime::start(app, id, client, codec, Arc::clone(&state.video_last_packet))?;
    let mut realtime = state
        .realtime
        .lock()
        .map_err(|_| "realtime lock poisoned".to_owned())?;
    if let Some(previous) = realtime.insert(id, control) {
        previous.stop();
    }
    Ok(())
}

#[tauri::command]
fn stop_realtime(state: State<'_, AppState>, id: String) -> Result<(), String> {
    let control = state
        .realtime
        .lock()
        .map_err(|_| "realtime lock poisoned".to_owned())?
        .remove(&device_id(&id)?)
        .ok_or_else(|| "realtime session is not active".to_owned())?;
    control.stop();
    Ok(())
}

#[tauri::command]
fn send_hid_input(state: State<'_, AppState>, id: String, input: HidInput) -> Result<(), String> {
    let id = device_id(&id)?;
    let sequence = state.hid_sequence.fetch_add(1, Ordering::Relaxed);
    let report = match input {
        HidInput::Keyboard { modifiers, keys } => InputTransportReport::keyboard(
            nanokvm_core::SOURCE_BROWSER_KEYBOARD,
            modifiers,
            &keys,
            sequence,
            timestamp_ms(),
        ),
        HidInput::AbsolutePointer {
            buttons,
            x,
            y,
            wheel,
        } => InputTransportReport::absolute_pointer(buttons, x, y, wheel, sequence, timestamp_ms()),
        HidInput::RelativePointer {
            buttons,
            dx,
            dy,
            wheel,
        } => {
            InputTransportReport::relative_pointer(buttons, dx, dy, wheel, sequence, timestamp_ms())
        }
        HidInput::Release => InputTransportReport::pointer_release(sequence, timestamp_ms()),
    }
    .map_err(|error| error.to_string())?;
    state
        .realtime
        .lock()
        .map_err(|_| "realtime lock poisoned".to_owned())?
        .get(&id)
        .ok_or_else(|| "realtime input is not connected".to_owned())?
        .send_hid(report)
}

#[tauri::command]
async fn match_local_edid(
    window: tauri::Window,
    state: State<'_, AppState>,
    id: String,
    refresh: Option<u32>,
    confirmed: bool,
) -> Result<String, String> {
    if !confirmed {
        return Err("local EDID matching requires explicit signal-power confirmation".into());
    }
    let client = client_for(&state, device_id(&id)?)?;
    let monitor = window
        .current_monitor()
        .map_err(|error| error.to_string())?
        .ok_or_else(|| "the application window is not on an active display".to_owned())?;
    let (width, height) = EdidBuilder::normalized(monitor.size().width, monitor.size().height);
    let refresh = refresh.unwrap_or(60);
    let builder = EdidBuilder {
        width,
        height,
        refresh,
        name: "NanoKVM-Windows".into(),
    };
    if width > 4095 || height > 4095 {
        return Err(format!("{width}×{height} exceeds the EDID 4095 px limit"));
    }
    if builder.timing().pixel_clock_mhz() > 300.0 {
        return Err(format!(
            "{width}×{height}@{refresh} exceeds the 300 MHz EDID limit"
        ));
    }
    let file_name = format!(
        "NanoKVM-Windows_Screen-{}x{}_HiDPI.bin",
        width.min(height),
        width.max(height)
    );
    let previous = client
        .edid()
        .await
        .ok()
        .and_then(|value| value.get("edid").and_then(Value::as_str).map(str::to_owned))
        .unwrap_or_default();
    client
        .upload_edid(
            UploadMetadata {
                file_name: file_name.clone(),
                content_type: Some("application/octet-stream".into()),
            },
            builder.build().to_vec(),
        )
        .await
        .map_err(|error| error.to_string())?;
    state.video_last_packet.store(0, Ordering::Release);
    client
        .set_edid(&file_name)
        .await
        .map_err(|error| error.to_string())?;
    for _ in 0..9 {
        tokio::time::sleep(std::time::Duration::from_secs(5)).await;
        if state.video_last_packet.load(Ordering::Acquire) > 0 {
            return Ok(format!(
                "EDID {file_name} matched {width}×{height}@{refresh}; signal restored"
            ));
        }
    }
    if !previous.is_empty() {
        state.video_last_packet.store(0, Ordering::Release);
        if let Err(error) = client.set_edid(&previous).await {
            return Err(format!(
                "no video returned and restoring the previous EDID failed: {error}"
            ));
        }
        for _ in 0..9 {
            tokio::time::sleep(std::time::Duration::from_secs(5)).await;
            if state.video_last_packet.load(Ordering::Acquire) > 0 {
                return Err(
                    "no signal with the matched EDID; the previous EDID was restored".into(),
                );
            }
        }
    }
    Err(format!(
        "no video returned after 45 seconds{}",
        if previous.is_empty() {
            "; no previous EDID was available"
        } else {
            "; the previous EDID was restored but also produced no signal"
        }
    ))
}

#[cfg_attr(mobile, tauri::mobile_entry_point)]
pub fn run() {
    tauri::Builder::default()
        .setup(|app| {
            let catalog_path = app
                .path()
                .app_data_dir()
                .map_err(|error| format!("failed to resolve app data directory: {error}"))?
                .join("devices.json");
            let devices =
                DeviceCatalog::load(&catalog_path).map_err(|error| std::io::Error::other(error))?;
            app.manage(AppState {
                catalog_path,
                devices: Mutex::new(devices),
                secrets: Box::new(storage::default_secret_store()),
                sessions: Mutex::new(HashMap::new()),
                login_challenges: Mutex::new(HashMap::new()),
                realtime: Mutex::new(HashMap::new()),
                hid_sequence: AtomicU32::new(0),
                video_last_packet: Arc::new(AtomicU64::new(0)),
            });
            Ok(())
        })
        .invoke_handler(tauri::generate_handler![
            app_features,
            validate_session_state,
            video_capabilities,
            list_devices,
            discover_devices,
            save_device,
            remove_device,
            connect_device,
            complete_two_factor,
            load_page_state,
            device_action,
            upload_file,
            start_realtime,
            stop_realtime,
            send_hid_input,
            match_local_edid
        ])
        .run(tauri::generate_context!())
        .expect("error while running NanoKVM");
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn exposes_parity_status_without_claiming_realtime_support() {
        let features = app_features();
        assert!(features.iter().any(|feature| feature.name == "devices"));
        assert!(
            !features
                .iter()
                .find(|feature| feature.name == "screen")
                .expect("screen feature")
                .available
        );
    }

    #[test]
    fn does_not_claim_unimplemented_video_decode() {
        let capabilities = video_capabilities();
        assert!(!capabilities.native_surface);
        #[cfg(not(windows))]
        {
            assert!(!capabilities.hardware_h264);
            assert!(!capabilities.hardware_h265);
        }
    }

    #[test]
    fn advertises_typed_login_but_not_video() {
        let features = app_features();
        assert!(
            features
                .iter()
                .find(|feature| feature.name == "authentication")
                .expect("authentication feature")
                .available
        );
        assert!(
            !features
                .iter()
                .find(|feature| feature.name == "screen")
                .expect("screen feature")
                .available
        );
    }

    #[test]
    fn protects_risky_commands_and_rejects_overflowing_values() {
        assert!(requires_confirmation("reboot"));
        assert!(requires_confirmation("wifi-connect"));
        assert!(!requires_confirmation("stream-fps"));
        assert!(field_u32(&json!({"value": u64::from(u32::MAX) + 1}), "value").is_err());
    }

    #[test]
    fn resolves_sensitive_action_names_without_timing_out() {
        assert_eq!(
            sensitive_action("mcp-enable", &json!({"enabled": true})),
            Some("mcp_enable")
        );
        assert_eq!(
            sensitive_action("mcp-enable", &json!({"enabled": false})),
            Some("mcp_disable")
        );
        assert_eq!(
            sensitive_action("signature-verification", &json!({})),
            Some("update_signature_verification")
        );
    }

    #[test]
    fn computes_media_chunk_progress_boundaries() {
        const CHUNK_SIZE: usize = 8 * 1024 * 1024;
        assert_eq!((CHUNK_SIZE - 1).div_ceil(CHUNK_SIZE), 1);
        assert_eq!((CHUNK_SIZE * 2 + 1).div_ceil(CHUNK_SIZE), 3);
    }
}
