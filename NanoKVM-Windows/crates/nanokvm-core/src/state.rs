use serde::{Deserialize, Serialize};

use crate::{CoreError, Result, SavedDevice};

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ConnectionState {
    Disconnected,
    Connecting,
    Authenticating,
    RequiresTwoFactor,
    Connected,
    Error,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct SessionState {
    pub device: SavedDevice,
    pub connection: ConnectionState,
}

impl SessionState {
    pub fn disconnected(device: SavedDevice) -> Self {
        Self {
            device,
            connection: ConnectionState::Disconnected,
        }
    }

    pub fn transition(&mut self, next: ConnectionState) -> Result<()> {
        use ConnectionState::*;
        let valid = matches!(
            (self.connection, next),
            (Disconnected, Connecting)
                | (Connecting, Authenticating)
                | (Connecting, Connected)
                | (Authenticating, RequiresTwoFactor)
                | (Authenticating, Connected)
                | (Authenticating, Error)
                | (RequiresTwoFactor, Connected)
                | (RequiresTwoFactor, Error)
                | (Connected, Disconnected)
                | (Connected, Error)
                | (Error, Disconnected)
        );
        if !valid {
            return Err(CoreError::Unsupported(format!(
                "invalid state transition {:?} -> {next:?}",
                self.connection
            )));
        }
        self.connection = next;
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use uuid::Uuid;

    fn session() -> SessionState {
        let device = SavedDevice::new(Uuid::nil(), "Desk KVM", "https://kvm", "admin").unwrap();
        SessionState::disconnected(device)
    }

    #[test]
    fn permits_login_with_two_factor() {
        let mut session = session();
        session.transition(ConnectionState::Connecting).unwrap();
        session.transition(ConnectionState::Authenticating).unwrap();
        session
            .transition(ConnectionState::RequiresTwoFactor)
            .unwrap();
        session.transition(ConnectionState::Connected).unwrap();
        assert_eq!(session.connection, ConnectionState::Connected);
    }

    #[test]
    fn rejects_skipping_connection_steps() {
        let mut session = session();
        assert!(matches!(
            session.transition(ConnectionState::Connected),
            Err(CoreError::Unsupported(_))
        ));
    }
}
