mod api;
mod edid;
mod error;
mod hid;
mod model;
mod state;
mod video;

pub use api::{
    AccountRequest, ChunkMetadata, ClientConfig, EmptyRequest, EnableRequest, EnabledRequest,
    FpsRequest, GopRequest, HostnameRequest, JigglerRequest, LoginResult, ModeRequest,
    MountImageRequest, NameRequest, NanoKvmClient, PasswordRequest, PasteRequest, PointerMode,
    QualityRequest, RateControl, RateControlRequest, ScriptRunRequest, SensitiveActionRequest,
    StaticIpRequest, StreamEncoder, TailscaleActionRequest, TimeRequest, TimezoneRequest,
    TwoFactorVerifyRequest, UploadMetadata, UsbIdRequest, UsbNetworkRequest, ValueRequest,
    WakeOnLanHost, WebSocketEndpoint, WebTitleRequest, WifiConnectRequest,
};
pub use edid::EdidBuilder;
pub use error::{CoreError, Result};
pub use hid::{
    HidReport, InputTransportReport, KeyCode, KeyEvent, MouseButton, MouseEvent, ReportKind,
    SOURCE_BROWSER_KEYBOARD, SOURCE_BROWSER_POINTER, SOURCE_VIRTUAL_KEYBOARD,
};
pub use model::{
    ConnectionProfile, Credentials, Envelope, FeatureState, LoginRequest, LoginResponse,
    SavedDevice,
};
pub use state::{ConnectionState, SessionState};
pub use video::{
    EncodedFrame, FrameKind, NalRole, VideoCodec, VideoPacket, classify_nal, split_annex_b,
};
