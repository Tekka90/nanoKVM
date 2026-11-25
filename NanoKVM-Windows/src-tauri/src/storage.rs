use std::fs;
use std::path::{Path, PathBuf};

use nanokvm_core::SavedDevice;
use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub(crate) struct DeviceCatalog {
    version: u8,
    devices: Vec<SavedDevice>,
}

impl Default for DeviceCatalog {
    fn default() -> Self {
        Self {
            version: 1,
            devices: Vec::new(),
        }
    }
}

impl DeviceCatalog {
    pub(crate) fn load(path: &Path) -> Result<Self, String> {
        if !path.exists() {
            return Ok(Self {
                version: 1,
                devices: Vec::new(),
            });
        }
        let contents =
            fs::read(path).map_err(|error| format!("failed to read device catalog: {error}"))?;
        let catalog: DeviceCatalog = serde_json::from_slice(&contents)
            .map_err(|error| format!("invalid device catalog: {error}"))?;
        if catalog.version != 1 {
            return Err(format!(
                "unsupported device catalog version: {}",
                catalog.version
            ));
        }
        Ok(catalog)
    }

    pub(crate) fn upsert(&mut self, device: SavedDevice) -> Result<(), String> {
        if let Some(existing) = self.devices.iter_mut().find(|item| item.id == device.id) {
            *existing = device;
        } else {
            self.devices.push(device);
        }
        Ok(())
    }

    pub(crate) fn remove(&mut self, id: uuid::Uuid) -> bool {
        let before = self.devices.len();
        self.devices.retain(|device| device.id != id);
        self.devices.len() != before
    }

    pub(crate) fn devices(&self) -> &[SavedDevice] {
        &self.devices
    }

    pub(crate) fn save(&self, path: &Path) -> Result<(), String> {
        let parent = path
            .parent()
            .ok_or_else(|| "device catalog has no parent directory".to_owned())?;
        fs::create_dir_all(parent)
            .map_err(|error| format!("failed to create device directory: {error}"))?;

        let temporary = temporary_path(path);
        let bytes = serde_json::to_vec_pretty(self)
            .map_err(|error| format!("failed to encode device catalog: {error}"))?;
        fs::write(&temporary, bytes)
            .map_err(|error| format!("failed to write device catalog: {error}"))?;
        replace_file(&temporary, path)?;
        Ok(())
    }
}

#[cfg(not(windows))]
fn replace_file(from: &Path, to: &Path) -> Result<(), String> {
    fs::rename(from, to).map_err(|error| format!("failed to replace device catalog: {error}"))
}

#[cfg(windows)]
fn replace_file(from: &Path, to: &Path) -> Result<(), String> {
    use windows::Win32::Storage::FileSystem::{
        MOVEFILE_REPLACE_EXISTING, MOVEFILE_WRITE_THROUGH, MoveFileExW,
    };
    use windows::core::HSTRING;

    unsafe {
        MoveFileExW(
            &HSTRING::from(from.as_os_str()),
            &HSTRING::from(to.as_os_str()),
            MOVEFILE_REPLACE_EXISTING | MOVEFILE_WRITE_THROUGH,
        )
        .map_err(|error| format!("failed to replace device catalog: {error}"))
    }
}

fn temporary_path(path: &Path) -> PathBuf {
    let mut value = path.as_os_str().to_os_string();
    value.push(".tmp");
    PathBuf::from(value)
}

pub(crate) trait SecretStore: Send + Sync {
    fn set(&self, service: &str, account: &str, secret: &str) -> Result<(), String>;
    fn get(&self, service: &str, account: &str) -> Result<String, String>;
    fn delete(&self, service: &str, account: &str) -> Result<(), String>;
}

#[cfg(windows)]
mod platform {
    use super::SecretStore;
    use keyring::Entry;

    pub(crate) struct WindowsCredentialStore;

    impl SecretStore for WindowsCredentialStore {
        fn set(&self, service: &str, account: &str, secret: &str) -> Result<(), String> {
            Entry::new(service, account)
                .and_then(|entry| entry.set_password(secret))
                .map_err(|error| format!("failed to store Windows credential: {error}"))
        }

        fn get(&self, service: &str, account: &str) -> Result<String, String> {
            Entry::new(service, account)
                .and_then(|entry| entry.get_password())
                .map_err(|error| format!("failed to read Windows credential: {error}"))
        }

        fn delete(&self, service: &str, account: &str) -> Result<(), String> {
            Entry::new(service, account)
                .and_then(|entry| entry.delete_credential())
                .map_err(|error| format!("failed to delete Windows credential: {error}"))
        }
    }

    pub(crate) fn default_secret_store() -> impl SecretStore {
        WindowsCredentialStore
    }
}

#[cfg(not(windows))]
mod platform {
    use std::collections::HashMap;
    use std::sync::Mutex;

    use super::SecretStore;

    #[derive(Default)]
    pub(crate) struct EphemeralSecretStore(Mutex<HashMap<(String, String), String>>);

    impl SecretStore for EphemeralSecretStore {
        fn set(&self, service: &str, account: &str, secret: &str) -> Result<(), String> {
            self.0
                .lock()
                .map_err(|_| "ephemeral credential store lock poisoned".to_owned())?
                .insert((service.to_owned(), account.to_owned()), secret.to_owned());
            Ok(())
        }

        fn get(&self, service: &str, account: &str) -> Result<String, String> {
            self.0
                .lock()
                .map_err(|_| "ephemeral credential store lock poisoned".to_owned())?
                .get(&(service.to_owned(), account.to_owned()))
                .cloned()
                .ok_or_else(|| "credential is not stored".to_owned())
        }

        fn delete(&self, service: &str, account: &str) -> Result<(), String> {
            self.0
                .lock()
                .map_err(|_| "ephemeral credential store lock poisoned".to_owned())?
                .remove(&(service.to_owned(), account.to_owned()))
                .map(|_| ())
                .ok_or_else(|| "credential is not stored".to_owned())
        }
    }

    pub(crate) fn default_secret_store() -> impl SecretStore {
        EphemeralSecretStore::default()
    }
}

pub(crate) use platform::default_secret_store;

#[cfg(test)]
mod tests {
    use std::time::{SystemTime, UNIX_EPOCH};

    use super::*;
    use uuid::Uuid;

    fn unique_path() -> PathBuf {
        let suffix = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap()
            .as_nanos();
        std::env::temp_dir().join(format!("nanokvm-windows-{suffix}.json"))
    }

    #[test]
    fn round_trips_non_secret_device_metadata() {
        let path = unique_path();
        let mut catalog = DeviceCatalog::default();
        let device = SavedDevice::new(Uuid::new_v4(), "Desk KVM", "https://kvm.local/", "admin")
            .expect("valid device");
        catalog.upsert(device.clone()).unwrap();
        catalog.save(&path).unwrap();

        let loaded = DeviceCatalog::load(&path).unwrap();
        assert_eq!(loaded.devices(), &[device]);
        let contents = fs::read_to_string(&path).unwrap();
        assert!(!contents.contains("password"));
        fs::remove_file(path).unwrap();
    }

    #[test]
    fn removes_exact_device_id() {
        let id = Uuid::new_v4();
        let mut catalog = DeviceCatalog::default();
        catalog
            .upsert(SavedDevice::new(id, "KVM", "https://kvm", "admin").unwrap())
            .unwrap();
        assert!(catalog.remove(id));
        assert!(!catalog.remove(id));
    }

    #[test]
    fn secret_store_does_not_touch_catalog() {
        let store = default_secret_store();
        store.set("nanokvm-test", "account", "secret").unwrap();
        assert_eq!(store.get("nanokvm-test", "account").unwrap(), "secret");
        store.delete("nanokvm-test", "account").unwrap();
        assert!(store.get("nanokvm-test", "account").is_err());
    }

    #[test]
    fn atomically_replaces_an_existing_catalog() {
        let path = unique_path();
        let id = Uuid::new_v4();
        let mut catalog = DeviceCatalog::default();
        catalog
            .upsert(SavedDevice::new(id, "First", "https://first", "admin").unwrap())
            .unwrap();
        catalog.save(&path).unwrap();
        catalog
            .upsert(SavedDevice::new(id, "Second", "https://second", "operator").unwrap())
            .unwrap();
        catalog.save(&path).unwrap();

        let loaded = DeviceCatalog::load(&path).unwrap();
        assert_eq!(loaded.devices()[0].name, "Second");
        fs::remove_file(path).unwrap();
    }
}
