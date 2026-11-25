use serde::{Deserialize, Serialize};
use uuid::Uuid;

use crate::{CoreError, Result};

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Envelope<T> {
    pub code: i32,
    pub msg: String,
    pub data: Option<T>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Credentials {
    pub username: String,
    #[serde(skip_serializing)]
    pub password: String,
}

impl Credentials {
    pub fn new(username: impl Into<String>, password: impl Into<String>) -> Result<Self> {
        let username = username.into();
        let password = password.into();
        if username.trim().is_empty() {
            return Err(CoreError::EmptyUsername);
        }
        if password.is_empty() {
            return Err(CoreError::EmptyPassword);
        }
        Ok(Self { username, password })
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct LoginRequest {
    pub username: String,
    pub password: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub challenge: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct LoginResponse {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub token: Option<String>,
    #[serde(
        rename = "requires2FA",
        default,
        skip_serializing_if = "Option::is_none"
    )]
    pub requires2_f_a: Option<bool>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub challenge: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct SavedDevice {
    pub id: Uuid,
    pub name: String,
    pub address: String,
    pub username: String,
}

impl SavedDevice {
    pub fn new(
        id: Uuid,
        name: impl Into<String>,
        address: impl Into<String>,
        username: impl Into<String>,
    ) -> Result<Self> {
        let name = name.into();
        let address = address.into();
        let username = username.into();
        if name.trim().is_empty() {
            return Err(CoreError::EmptyDeviceName);
        }
        if address.trim().is_empty() {
            return Err(CoreError::EmptyAddress);
        }
        if username.trim().is_empty() {
            return Err(CoreError::EmptyUsername);
        }
        Ok(Self {
            id,
            name,
            address: address.trim_end_matches('/').to_owned(),
            username,
        })
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ConnectionProfile {
    pub device: SavedDevice,
    pub accept_self_signed_tls: bool,
    pub request_timeout_ms: u64,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct FeatureState {
    pub name: &'static str,
    pub available: bool,
    pub detail: &'static str,
}
