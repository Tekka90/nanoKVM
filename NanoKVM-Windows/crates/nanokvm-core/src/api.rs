use std::sync::RwLock;
use std::time::Duration;

use reqwest::header::{COOKIE, HeaderValue, ORIGIN, REFERER, SET_COOKIE};
use reqwest::multipart;
use reqwest::{Method, Url};
use serde::de::DeserializeOwned;
use serde::{Deserialize, Serialize};
use serde_json::Value;

use crate::{CoreError, Credentials, Envelope, LoginRequest, LoginResponse, Result};

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ClientConfig {
    pub address: String,
    pub accept_self_signed_tls: bool,
    pub request_timeout: Duration,
}

impl ClientConfig {
    pub fn new(address: impl Into<String>) -> Self {
        Self {
            address: address.into(),
            accept_self_signed_tls: false,
            request_timeout: Duration::from_secs(15),
        }
    }

    pub fn with_self_signed_tls(mut self, accept: bool) -> Self {
        self.accept_self_signed_tls = accept;
        self
    }

    pub fn with_timeout(mut self, timeout: Duration) -> Self {
        self.request_timeout = timeout;
        self
    }
}

#[derive(Debug, Clone, Copy, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct EmptyRequest {}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum LoginResult {
    Authenticated,
    RequiresTwoFactor { challenge: String },
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum PointerMode {
    Absolute,
    Relative,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum StreamEncoder {
    H264,
    H265,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum RateControl {
    Cbr,
    Vbr,
    Cqp,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct EnableRequest {
    pub enable: bool,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct EnabledRequest {
    pub enabled: bool,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ModeRequest<T> {
    pub mode: T,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ValueRequest<T> {
    pub value: T,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct RateControlRequest {
    pub mode: RateControl,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct QualityRequest {
    pub quality: u32,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct GopRequest {
    pub gop: u32,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct FpsRequest {
    pub fps: u32,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct TailscaleActionRequest {
    pub action: String,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct TwoFactorVerifyRequest {
    pub challenge: String,
    pub code: String,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct SensitiveActionRequest {
    pub action: String,
    pub code: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub password: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct AccountRequest {
    pub username: String,
    pub password: String,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct PasswordRequest {
    #[serde(rename = "oldPassword")]
    pub old_password: String,
    #[serde(rename = "newPassword")]
    pub new_password: String,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct PasteRequest {
    pub content: String,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct NameRequest {
    pub name: String,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct HostnameRequest {
    pub hostname: String,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct WebTitleRequest {
    pub title: String,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct TimeRequest {
    pub timestamp: i64,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub timezone: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct TimezoneRequest {
    pub timezone: String,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct WifiConnectRequest {
    pub ssid: String,
    pub password: String,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct StaticIpRequest {
    pub enabled: bool,
    pub ip: String,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct WakeOnLanHost {
    pub mac: String,
    pub name: String,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct UsbIdRequest {
    pub enabled: bool,
    pub vid: String,
    pub pid: String,
    #[serde(rename = "bcdDevice")]
    pub bcd_device: String,
    pub serialnumber: String,
    pub manufacturer: String,
    pub product: String,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct UsbNetworkRequest {
    pub mode: String,
    pub ipv4: String,
    pub forwarding: bool,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct MountImageRequest {
    pub file: String,
    pub cdrom: bool,
    #[serde(rename = "readOnly")]
    pub read_only: bool,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct JigglerRequest {
    pub enabled: bool,
    pub mode: String,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ScriptRunRequest {
    pub name: String,
    #[serde(rename = "type")]
    pub run_type: String,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct UploadMetadata {
    pub file_name: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub content_type: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ChunkMetadata {
    pub upload_id: String,
    pub file_name: String,
    pub chunk_size: u64,
    pub chunk_index: u64,
    pub total_chunks: u64,
}

#[derive(Debug, Clone)]
pub struct NanoKvmClient {
    base_url: Url,
    origin: Url,
    http: reqwest::Client,
    token: std::sync::Arc<RwLock<Option<String>>>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct WebSocketEndpoint {
    pub url: String,
    pub origin: String,
    pub cookie: Option<String>,
}

impl NanoKvmClient {
    pub fn new(config: ClientConfig) -> Result<Self> {
        let mut raw = config.address.trim().to_owned();
        if !raw.contains("://") {
            raw.insert_str(0, "https://");
        }
        let mut origin = Url::parse(&raw).map_err(|e| CoreError::InvalidAddress(e.to_string()))?;
        if origin.scheme() != "http" && origin.scheme() != "https" {
            return Err(CoreError::InvalidAddress(
                "only http and https addresses are supported".into(),
            ));
        }
        origin.set_query(None);
        origin.set_fragment(None);
        let base_url = origin
            .join(if raw.ends_with('/') { "api/" } else { "/api/" })
            .map_err(|e| CoreError::InvalidAddress(e.to_string()))?;
        let http = reqwest::Client::builder()
            .danger_accept_invalid_certs(config.accept_self_signed_tls)
            .timeout(config.request_timeout)
            .build()
            .map_err(|e| CoreError::Http(e.to_string()))?;
        Ok(Self {
            base_url,
            origin,
            http,
            token: std::sync::Arc::new(RwLock::new(None)),
        })
    }

    pub fn base_url(&self) -> &Url {
        &self.base_url
    }

    pub fn set_token(&self, token: impl Into<String>) {
        *self.token.write().expect("token lock poisoned") = Some(token.into());
    }

    pub fn clear_token(&self) {
        *self.token.write().expect("token lock poisoned") = None;
    }

    pub fn is_authenticated(&self) -> bool {
        self.token
            .read()
            .expect("token lock poisoned")
            .as_ref()
            .is_some_and(|token| !token.is_empty())
    }

    pub fn websocket_endpoint(&self, path: &str) -> Result<WebSocketEndpoint> {
        let mut url = self
            .base_url
            .join(path.trim_start_matches('/'))
            .map_err(|e| CoreError::InvalidAddress(e.to_string()))?;
        match url.scheme() {
            "https" => {
                url.set_scheme("wss").map_err(|_| {
                    CoreError::InvalidAddress("failed to select secure WebSocket".into())
                })?;
            }
            "http" => {
                url.set_scheme("ws")
                    .map_err(|_| CoreError::InvalidAddress("failed to select WebSocket".into()))?;
            }
            scheme => {
                return Err(CoreError::InvalidAddress(format!(
                    "unsupported WebSocket scheme: {scheme}"
                )));
            }
        }
        Ok(WebSocketEndpoint {
            url: url.to_string(),
            origin: origin_value(&self.origin)?
                .to_str()
                .map_err(|error| CoreError::InvalidAddress(error.to_string()))?
                .to_owned(),
            cookie: self
                .token
                .read()
                .expect("token lock poisoned")
                .clone()
                .map(|token| format!("nano-kvm-token={token}")),
        })
    }

    pub async fn login(&self, credentials: &Credentials) -> Result<LoginResult> {
        let response: LoginResponse = self
            .send(
                Method::POST,
                "/auth/login",
                Some(&LoginRequest {
                    username: credentials.username.clone(),
                    password: credentials.password.clone(),
                    challenge: None,
                }),
            )
            .await?;
        if let Some(token) = response.token {
            self.set_token(token);
            return Ok(LoginResult::Authenticated);
        }
        if response.requires2_f_a == Some(true) {
            return match response.challenge {
                Some(challenge) if !challenge.is_empty() => {
                    Ok(LoginResult::RequiresTwoFactor { challenge })
                }
                _ => Err(CoreError::MissingToken),
            };
        }
        Err(CoreError::MissingToken)
    }

    pub async fn complete_two_factor_login(
        &self,
        request: &TwoFactorVerifyRequest,
    ) -> Result<LoginResult> {
        let response: LoginResponse = self
            .send(Method::POST, "/auth/login", Some(request))
            .await?;
        match response.token {
            Some(token) if !token.is_empty() => {
                self.set_token(token);
                Ok(LoginResult::Authenticated)
            }
            _ => Err(CoreError::MissingToken),
        }
    }

    pub async fn get<T: DeserializeOwned>(&self, path: &str) -> Result<T> {
        self.send::<T, ()>(Method::GET, path, None).await
    }

    pub async fn post<T: DeserializeOwned, B: Serialize>(&self, path: &str, body: &B) -> Result<T> {
        self.send(Method::POST, path, Some(body)).await
    }

    pub async fn post_empty<T: DeserializeOwned>(&self, path: &str) -> Result<T> {
        self.send(Method::POST, path, Some(&EmptyRequest {})).await
    }

    pub async fn delete<T: DeserializeOwned, B: Serialize>(
        &self,
        path: &str,
        body: &B,
    ) -> Result<T> {
        self.send(Method::DELETE, path, Some(body)).await
    }

    pub async fn command<B: Serialize>(
        &self,
        method: Method,
        path: &str,
        body: Option<&B>,
    ) -> Result<Value> {
        let mut request = self.request(method, path)?;
        if let Some(body) = body {
            request = request.json(body);
        }
        self.execute_command(request).await
    }

    async fn send<T: DeserializeOwned, B: Serialize>(
        &self,
        method: Method,
        path: &str,
        body: Option<&B>,
    ) -> Result<T> {
        let mut request = self.request(method, path)?;
        if let Some(body) = body {
            request = request.json(body);
        }
        self.execute(request).await
    }

    fn request(&self, method: Method, path: &str) -> Result<reqwest::RequestBuilder> {
        let url = self
            .base_url
            .join(path.trim_start_matches('/'))
            .map_err(|e| CoreError::InvalidAddress(e.to_string()))?;
        self.request_url(method, url)
    }

    fn request_url(&self, method: Method, url: Url) -> Result<reqwest::RequestBuilder> {
        let origin = origin_value(&self.origin)?;
        let referer = self.origin.to_string().trim_end_matches('/').to_owned() + "/";
        let mut request = self
            .http
            .request(method, url)
            .header(ORIGIN, origin)
            .header(REFERER, referer);
        if let Some(token) = self.token.read().expect("token lock poisoned").as_ref() {
            request = request.header(
                COOKIE,
                HeaderValue::from_str(&format!("nano-kvm-token={token}"))
                    .map_err(|e| CoreError::Http(e.to_string()))?,
            );
        }
        Ok(request)
    }

    async fn execute<T: DeserializeOwned>(&self, request: reqwest::RequestBuilder) -> Result<T> {
        let response = request
            .send()
            .await
            .map_err(|e| CoreError::Http(e.to_string()))?;
        self.capture_token(&response);
        let status = response.status();
        let bytes = response
            .bytes()
            .await
            .map_err(|e| CoreError::Http(e.to_string()))?;
        if !status.is_success() {
            return Err(CoreError::HttpStatus {
                status: status.as_u16(),
                body: String::from_utf8_lossy(&bytes).into_owned(),
            });
        }
        let envelope: Envelope<T> =
            serde_json::from_slice(&bytes).map_err(|e| CoreError::Decode(e.to_string()))?;
        if envelope.code != 0 {
            return Err(CoreError::Api {
                code: envelope.code,
                message: envelope.msg,
            });
        }
        envelope.data.ok_or(CoreError::MissingData)
    }

    async fn execute_command(&self, request: reqwest::RequestBuilder) -> Result<Value> {
        let response = request
            .send()
            .await
            .map_err(|e| CoreError::Http(e.to_string()))?;
        self.capture_token(&response);
        let status = response.status();
        let bytes = response
            .bytes()
            .await
            .map_err(|e| CoreError::Http(e.to_string()))?;
        if !status.is_success() {
            return Err(CoreError::HttpStatus {
                status: status.as_u16(),
                body: String::from_utf8_lossy(&bytes).into_owned(),
            });
        }
        let envelope: Envelope<Value> =
            serde_json::from_slice(&bytes).map_err(|e| CoreError::Decode(e.to_string()))?;
        if envelope.code != 0 {
            return Err(CoreError::Api {
                code: envelope.code,
                message: envelope.msg,
            });
        }
        Ok(envelope.data.unwrap_or(Value::Null))
    }

    fn capture_token(&self, response: &reqwest::Response) {
        for value in response.headers().get_all(SET_COOKIE) {
            let cookie = value.to_str().unwrap_or_default();
            if let Some(token) = cookie
                .split(';')
                .next()
                .and_then(|pair| pair.strip_prefix("nano-kvm-token="))
            {
                self.set_token(token);
            }
        }
    }

    pub async fn upload_multipart(
        &self,
        path: &str,
        field: &str,
        metadata: UploadMetadata,
        bytes: Vec<u8>,
    ) -> Result<Value> {
        let mut part = multipart::Part::bytes(bytes).file_name(metadata.file_name);
        if let Some(content_type) = metadata.content_type {
            part = part
                .mime_str(&content_type)
                .map_err(|e| CoreError::Encode(e.to_string()))?;
        }
        self.execute_command(
            self.request(Method::POST, path)?
                .multipart(multipart::Form::new().part(field.to_owned(), part)),
        )
        .await
    }

    pub async fn upload_chunk(
        &self,
        path: &str,
        metadata: ChunkMetadata,
        bytes: Vec<u8>,
    ) -> Result<Value> {
        let mut url = self
            .base_url
            .join(path.trim_start_matches('/'))
            .map_err(|e| CoreError::InvalidAddress(e.to_string()))?;
        {
            let mut query = url.query_pairs_mut();
            query.append_pair("uploadId", &metadata.upload_id);
            query.append_pair("filename", &metadata.file_name);
            query.append_pair("chunkSize", &metadata.chunk_size.to_string());
            query.append_pair("chunkIndex", &metadata.chunk_index.to_string());
            query.append_pair("totalChunks", &metadata.total_chunks.to_string());
        }
        let request = self.request_url(Method::POST, url)?;
        self.execute_command(
            request
                .header("content-type", "application/octet-stream")
                .body(bytes),
        )
        .await
    }

    pub async fn two_factor_status(&self) -> Result<Value> {
        self.get("/auth/2fa/status").await
    }

    pub async fn verify_sensitive_action(&self, request: &SensitiveActionRequest) -> Result<Value> {
        self.post("/auth/2fa/verify-sensitive-action", request)
            .await
    }

    pub async fn account(&self) -> Result<Value> {
        self.get("/auth/account").await
    }

    pub async fn update_password(&self, username: &str, password: &str) -> Result<Value> {
        self.command(
            Method::POST,
            "/auth/password",
            Some(&AccountRequest {
                username: username.to_owned(),
                password: password.to_owned(),
            }),
        )
        .await
    }

    pub async fn vm_info(&self) -> Result<Value> {
        self.get("/vm/info").await
    }
    pub async fn vm_hardware(&self) -> Result<Value> {
        self.get("/vm/hardware").await
    }
    pub async fn vm_hostname(&self) -> Result<Value> {
        self.get("/vm/hostname").await
    }
    pub async fn set_vm_hostname(&self, request: &HostnameRequest) -> Result<Value> {
        self.post("/vm/hostname", request).await
    }
    pub async fn vm_web_title(&self) -> Result<Value> {
        self.get("/vm/web-title").await
    }
    pub async fn set_vm_web_title(&self, request: &WebTitleRequest) -> Result<Value> {
        self.command(Method::POST, "/vm/web-title", Some(request))
            .await
    }
    pub async fn low_power(&self) -> Result<Value> {
        self.get("/vm/low-power").await
    }
    pub async fn set_low_power(&self, enable: bool) -> Result<Value> {
        self.command(
            Method::POST,
            "/vm/low-power",
            Some(&EnableRequest { enable }),
        )
        .await
    }
    pub async fn swap(&self) -> Result<Value> {
        self.get("/vm/swap").await
    }
    pub async fn set_swap(&self, enable: bool) -> Result<Value> {
        self.command(Method::POST, "/vm/swap", Some(&EnableRequest { enable }))
            .await
    }
    pub async fn vm_timezone(&self) -> Result<Value> {
        self.get("/vm/timezone").await
    }
    pub async fn set_timezone(&self, request: &TimezoneRequest) -> Result<Value> {
        self.command(Method::POST, "/vm/timezone", Some(request))
            .await
    }
    pub async fn sync_time(&self) -> Result<Value> {
        self.command::<EmptyRequest>(Method::POST, "/vm/time/sync", None)
            .await
    }
    pub async fn vm_status(&self) -> Result<Value> {
        self.get("/vm/time/status").await
    }
    pub async fn ssh(&self) -> Result<Value> {
        self.get("/vm/ssh").await
    }
    pub async fn set_ssh(&self, enable: bool) -> Result<Value> {
        self.command::<EmptyRequest>(
            Method::POST,
            if enable {
                "/vm/ssh/enable"
            } else {
                "/vm/ssh/disable"
            },
            None,
        )
        .await
    }
    pub async fn mdns(&self) -> Result<Value> {
        self.get("/vm/mdns").await
    }
    pub async fn set_mdns(&self, enable: bool) -> Result<Value> {
        self.command::<EmptyRequest>(
            Method::POST,
            if enable {
                "/vm/mdns/enable"
            } else {
                "/vm/mdns/disable"
            },
            None,
        )
        .await
    }
    pub async fn reboot(&self) -> Result<Value> {
        self.command::<EmptyRequest>(Method::POST, "/vm/system/reboot", None)
            .await
    }

    pub async fn hid_pointer_mode(&self) -> Result<Value> {
        self.get("/hid/pointer-mode").await
    }
    pub async fn set_hid_pointer_mode(&self, mode: PointerMode) -> Result<Value> {
        self.command(
            Method::POST,
            "/hid/pointer-mode",
            Some(&ModeRequest { mode }),
        )
        .await
    }
    pub async fn set_hid_mode(&self, request: &ModeRequest<PointerMode>) -> Result<Value> {
        self.command(Method::POST, "/hid/mode", Some(request)).await
    }
    pub async fn paste(&self, request: &PasteRequest) -> Result<Value> {
        self.command(Method::POST, "/hid/paste", Some(request))
            .await
    }
    pub async fn reset_hid(&self) -> Result<Value> {
        self.command::<EmptyRequest>(Method::POST, "/hid/reset", None)
            .await
    }
    pub async fn mouse_jiggler(&self) -> Result<Value> {
        self.get("/vm/mouse-jiggler").await
    }
    pub async fn set_mouse_jiggler(&self, request: &JigglerRequest) -> Result<Value> {
        self.command(Method::POST, "/vm/mouse-jiggler", Some(request))
            .await
    }

    pub async fn stream_encoder(&self) -> Result<Value> {
        self.get("/stream/encoder").await
    }
    pub async fn set_stream_rate_control(&self, value: RateControl) -> Result<Value> {
        self.command(
            Method::POST,
            "/stream/rate-control",
            Some(&RateControlRequest { mode: value }),
        )
        .await
    }
    pub async fn set_stream_quality(&self, value: u32) -> Result<Value> {
        self.command(
            Method::POST,
            "/stream/quality",
            Some(&QualityRequest { quality: value }),
        )
        .await
    }
    pub async fn set_stream_gop(&self, value: u32) -> Result<Value> {
        self.command(
            Method::POST,
            "/stream/gop",
            Some(&GopRequest { gop: value }),
        )
        .await
    }
    pub async fn set_stream_mode(&self, value: String) -> Result<Value> {
        self.command(
            Method::POST,
            "/stream/mode",
            Some(&ModeRequest { mode: value }),
        )
        .await
    }
    pub async fn set_stream_fps(&self, value: u32) -> Result<Value> {
        self.command(
            Method::POST,
            "/stream/fps",
            Some(&FpsRequest { fps: value }),
        )
        .await
    }

    pub async fn edid(&self) -> Result<Value> {
        self.get("/vm/edid").await
    }
    pub async fn custom_edid(&self) -> Result<Value> {
        self.get("/vm/edid/custom").await
    }
    pub async fn set_edid(&self, name: &str) -> Result<Value> {
        self.command(
            Method::POST,
            "/vm/edid",
            Some(&serde_json::json!({"edid": name})),
        )
        .await
    }
    pub async fn delete_edid(&self, name: &str) -> Result<Value> {
        self.command(
            Method::POST,
            "/vm/edid/delete",
            Some(&serde_json::json!({"edid": name})),
        )
        .await
    }
    pub async fn upload_edid(&self, metadata: UploadMetadata, bytes: Vec<u8>) -> Result<Value> {
        self.upload_multipart("/vm/edid/upload", "file", metadata, bytes)
            .await
    }
    pub async fn hdmi_capture(&self) -> Result<Value> {
        self.get("/vm/hdmi/capture").await
    }
    pub async fn set_hdmi_capture(&self, enabled: bool) -> Result<Value> {
        self.command(
            Method::POST,
            "/vm/hdmi/capture",
            Some(&EnabledRequest { enabled }),
        )
        .await
    }

    pub async fn storage_images(&self) -> Result<Value> {
        self.get("/storage/image").await
    }
    pub async fn storage_mounted(&self) -> Result<Value> {
        self.get("/storage/image/mounted").await
    }
    pub async fn storage_upload_chunk(
        &self,
        metadata: ChunkMetadata,
        bytes: Vec<u8>,
    ) -> Result<Value> {
        self.upload_chunk("/storage/image/upload", metadata, bytes)
            .await
    }
    pub async fn cancel_storage_upload(&self, upload_id: &str) -> Result<Value> {
        self.command(
            Method::POST,
            "/storage/image/upload/cancel",
            Some(&serde_json::json!({"uploadId": upload_id})),
        )
        .await
    }
    pub async fn mount_image(&self, request: &MountImageRequest) -> Result<Value> {
        self.command(Method::POST, "/storage/image/mount", Some(request))
            .await
    }
    pub async fn delete_image(&self, file: &str) -> Result<Value> {
        self.command(
            Method::POST,
            "/storage/image/delete",
            Some(&serde_json::json!({"file": file})),
        )
        .await
    }
    pub async fn image_download_enabled(&self) -> Result<Value> {
        self.get("/storage/download/image/enabled").await
    }
    pub async fn image_download_status(&self) -> Result<Value> {
        self.get("/storage/download/image/status").await
    }
    pub async fn start_image_download<B: Serialize>(&self, body: &B) -> Result<Value> {
        self.command(Method::POST, "/storage/download/image", Some(body))
            .await
    }
    pub async fn pause_image_download(&self) -> Result<Value> {
        self.command::<EmptyRequest>(Method::POST, "/storage/download/image/pause", None)
            .await
    }
    pub async fn resume_image_download(&self) -> Result<Value> {
        self.command::<EmptyRequest>(Method::POST, "/storage/download/image/resume", None)
            .await
    }
    pub async fn cancel_image_download(&self) -> Result<Value> {
        self.command::<EmptyRequest>(Method::POST, "/storage/download/image/cancel", None)
            .await
    }

    pub async fn wol_hosts(&self) -> Result<Value> {
        self.get("/network/wol/mac").await
    }
    pub async fn add_wol_host(&self, host: &WakeOnLanHost) -> Result<Value> {
        self.command(
            Method::POST,
            "/network/wol/mac/name",
            Some(&serde_json::json!({"mac": host.mac, "name": host.name})),
        )
        .await
    }
    pub async fn delete_wol_host(&self, host: &NameRequest) -> Result<Value> {
        self.command(Method::DELETE, "/network/wol/mac", Some(host))
            .await
    }
    pub async fn wake_host(&self, mac: &str) -> Result<Value> {
        self.command(
            Method::POST,
            "/network/wol",
            Some(&serde_json::json!({"mac": mac})),
        )
        .await
    }

    pub async fn wifi_status(&self) -> Result<Value> {
        self.get("/network/wifi").await
    }
    pub async fn scan_wifi(&self) -> Result<Value> {
        self.get("/network/wifi/scan").await
    }
    pub async fn connect_wifi(&self, request: &WifiConnectRequest) -> Result<Value> {
        self.command(Method::POST, "/network/wifi/connect", Some(request))
            .await
    }
    pub async fn disconnect_wifi(&self) -> Result<Value> {
        self.command::<EmptyRequest>(Method::POST, "/network/wifi/disconnect", None)
            .await
    }
    pub async fn set_static_ip(&self, request: &StaticIpRequest) -> Result<Value> {
        self.command(Method::POST, "/network/static-ip", Some(request))
            .await
    }
    pub async fn static_ip(&self) -> Result<Value> {
        self.get("/network/static-ip").await
    }
    pub async fn network_preset<B: Serialize>(&self, request: &B) -> Result<Value> {
        self.command(Method::POST, "/network/wifi/preset", Some(request))
            .await
    }
    pub async fn wifi_preset(&self) -> Result<Value> {
        self.get("/network/wifi/preset").await
    }
    pub async fn remove_network_preset(&self) -> Result<Value> {
        self.command::<EmptyRequest>(Method::POST, "/network/wifi/preset/remove", None)
            .await
    }

    pub async fn tailscale_status(&self) -> Result<Value> {
        self.get("/extensions/tailscale/status").await
    }
    pub async fn tailscale_action(&self, action: String) -> Result<Value> {
        self.command::<EmptyRequest>(
            Method::POST,
            &format!("/extensions/tailscale/{action}"),
            None,
        )
        .await
    }
    pub async fn set_tailscale_exit_node(&self, enabled: bool) -> Result<Value> {
        self.command(
            Method::POST,
            "/extensions/tailscale/exit-node",
            Some(&EnabledRequest { enabled }),
        )
        .await
    }
    pub async fn set_tailscale_subnet_route(&self, enabled: bool) -> Result<Value> {
        self.command(
            Method::POST,
            "/extensions/tailscale/subnet-route",
            Some(&EnabledRequest { enabled }),
        )
        .await
    }

    pub async fn usb_id(&self) -> Result<Value> {
        self.get("/vm/usb-id").await
    }
    pub async fn set_usb_id(&self, request: &UsbIdRequest) -> Result<Value> {
        self.command(Method::POST, "/vm/usb-id", Some(request))
            .await
    }
    pub async fn usb_network(&self) -> Result<Value> {
        self.get("/vm/usb-network").await
    }
    pub async fn set_usb_network(&self, request: &UsbNetworkRequest) -> Result<Value> {
        self.command(Method::POST, "/vm/usb-network", Some(request))
            .await
    }
    pub async fn usb_virtual_device(&self) -> Result<Value> {
        self.get("/vm/device/virtual").await
    }
    pub async fn set_usb_virtual_device<B: Serialize>(&self, body: &B) -> Result<Value> {
        self.command(Method::POST, "/vm/device/virtual", Some(body))
            .await
    }
    pub async fn refresh_usb(&self) -> Result<Value> {
        self.command(
            Method::POST,
            "/vm/device/virtual/refresh",
            Some(&serde_json::json!({"device": "disk"})),
        )
        .await
    }
    pub async fn set_usb_disk_disabled(&self) -> Result<Value> {
        self.command::<EmptyRequest>(Method::POST, "/vm/device/virtual/disk/disable", None)
            .await
    }
    pub async fn set_usb_reported_name<B: Serialize>(&self, path: &str, body: &B) -> Result<Value> {
        match path {
            "/vm/disk-inquiry-cdrom" | "/vm/disk-inquiry" | "/vm/uac2-function-name" => {
                self.command(Method::POST, path, Some(body)).await
            }
            _ => Err(CoreError::Unsupported(format!(
                "unsupported USB name endpoint: {path}"
            ))),
        }
    }
    pub async fn reported_name(&self, path: &str) -> Result<Value> {
        match path {
            "/vm/disk-inquiry-cdrom" | "/vm/disk-inquiry" | "/vm/uac2-function-name" => {
                self.get(path).await
            }
            _ => Err(CoreError::Unsupported(format!(
                "unsupported USB name endpoint: {path}"
            ))),
        }
    }

    pub async fn signature(&self) -> Result<Value> {
        self.get("/application/signature-verification").await
    }
    pub async fn set_signature_verification(&self, enabled: bool) -> Result<Value> {
        self.command(
            Method::POST,
            "/application/signature-verification",
            Some(&EnabledRequest { enabled }),
        )
        .await
    }
    pub async fn version(&self) -> Result<Value> {
        self.get("/application/version").await
    }
    pub async fn preview(&self) -> Result<Value> {
        self.get("/application/preview").await
    }
    pub async fn set_preview(&self, enable: bool) -> Result<Value> {
        self.command(
            Method::POST,
            "/application/preview",
            Some(&EnableRequest { enable }),
        )
        .await
    }
    pub async fn update(&self) -> Result<Value> {
        self.command::<EmptyRequest>(Method::POST, "/application/update", None)
            .await
    }
    pub async fn apps(&self) -> Result<Value> {
        self.get("/apps").await
    }

    pub async fn ai_config(&self) -> Result<Value> {
        self.get("/ai/config").await
    }
    pub async fn set_ai_config<B: Serialize>(&self, body: &B) -> Result<Value> {
        self.command(Method::POST, "/ai/config", Some(body)).await
    }
    pub async fn ai_services(&self) -> Result<Value> {
        self.get("/ai/services").await
    }
    pub async fn mcp_key(&self) -> Result<Value> {
        self.command::<EmptyRequest>(Method::POST, "/ai/mcp/key", None)
            .await
    }
    pub async fn regenerate_mcp_key(&self) -> Result<Value> {
        self.command::<EmptyRequest>(Method::POST, "/ai/mcp/key/regenerate", None)
            .await
    }
    pub async fn memory_fabric(&self) -> Result<Value> {
        self.get("/ai/memory-fabric").await
    }
    pub async fn timelapse(&self) -> Result<Value> {
        self.get("/ai/screen-timelapse/state").await
    }
    pub async fn set_memory_fabric<B: Serialize>(&self, body: &B) -> Result<Value> {
        self.command(Method::POST, "/ai/memory-fabric", Some(body))
            .await
    }
    pub async fn set_timelapse<B: Serialize>(&self, body: &B) -> Result<Value> {
        self.command(Method::POST, "/ai/screen-timelapse/state", Some(body))
            .await
    }

    pub async fn scripts(&self) -> Result<Value> {
        self.get("/vm/script").await
    }
    pub async fn run_script(&self, request: &ScriptRunRequest) -> Result<Value> {
        self.post("/vm/script/run", request).await
    }
    pub async fn upload_script(&self, metadata: UploadMetadata, bytes: Vec<u8>) -> Result<Value> {
        self.upload_multipart("/vm/script/upload", "file", metadata, bytes)
            .await
    }
    pub async fn delete_script(&self, request: &NameRequest) -> Result<Value> {
        self.command(Method::DELETE, "/vm/script", Some(request))
            .await
    }

    pub async fn finger_robot(&self) -> Result<Value> {
        self.get("/vm/finger-robot").await
    }
    pub async fn finger_robot_press(&self) -> Result<Value> {
        self.command(
            Method::POST,
            "/vm/finger-robot/press",
            Some(&EmptyRequest {}),
        )
        .await
    }
    pub async fn finger_robot_release(&self) -> Result<Value> {
        self.command(
            Method::POST,
            "/vm/finger-robot/release",
            Some(&EmptyRequest {}),
        )
        .await
    }
}

fn origin_value(url: &Url) -> Result<HeaderValue> {
    let host = url
        .host_str()
        .ok_or_else(|| CoreError::InvalidAddress("missing host".into()))?;
    let port = url
        .port()
        .map(|port| format!(":{port}"))
        .unwrap_or_default();
    HeaderValue::from_str(&format!("{}://{}{}", url.scheme(), host, port))
        .map_err(|e| CoreError::InvalidAddress(e.to_string()))
}
