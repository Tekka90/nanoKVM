use thiserror::Error;

pub type Result<T> = std::result::Result<T, CoreError>;

#[derive(Debug, Error, Clone, PartialEq, Eq)]
pub enum CoreError {
    #[error("the device address is empty")]
    EmptyAddress,
    #[error("the device name is empty")]
    EmptyDeviceName,
    #[error("the username is empty")]
    EmptyUsername,
    #[error("the password is empty")]
    EmptyPassword,
    #[error("the HID report is too large: {0} bytes")]
    HidReportTooLarge(usize),
    #[error("the HID report is empty")]
    EmptyHidReport,
    #[error("the encoded video frame is empty")]
    EmptyVideoFrame,
    #[error("the video packet is shorter than its 9-byte header")]
    InvalidVideoPacket,
    #[error("the video packet contains no Annex-B NAL units")]
    MissingNalUnits,
    #[error("the session is not connected")]
    NotConnected,
    #[error("the requested operation is not available: {0}")]
    Unsupported(String),
    #[error("invalid device address: {0}")]
    InvalidAddress(String),
    #[error("HTTP request failed: {0}")]
    Http(String),
    #[error("HTTP response {status}: {body}")]
    HttpStatus { status: u16, body: String },
    #[error("NanoKVM API error {code}: {message}")]
    Api { code: i32, message: String },
    #[error("failed to encode request: {0}")]
    Encode(String),
    #[error("failed to decode response: {0}")]
    Decode(String),
    #[error("the API response did not contain data")]
    MissingData,
    #[error("the authentication response did not contain a token")]
    MissingToken,
}

#[cfg(test)]
mod tests {
    use super::CoreError;

    #[test]
    fn unsupported_errors_include_the_specific_reason() {
        let error = CoreError::Unsupported("native Direct3D presenter is not attached".into());
        assert_eq!(
            error.to_string(),
            "the requested operation is not available: native Direct3D presenter is not attached"
        );
    }
}
