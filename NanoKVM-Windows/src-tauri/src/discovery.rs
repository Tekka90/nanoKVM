use std::collections::BTreeMap;
use std::time::Duration;

use mdns_sd::{ServiceDaemon, ServiceEvent};
use serde::Serialize;

const DISCOVERY_TIMEOUT: Duration = Duration::from_secs(3);

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct DiscoveredDevice {
    pub name: String,
    pub address: String,
}

pub(crate) fn discover() -> Result<Vec<DiscoveredDevice>, String> {
    let daemon = ServiceDaemon::new()
        .map_err(|error| format!("could not start network discovery: {error}"))?;
    let mut devices = BTreeMap::new();
    for service in ["_http._tcp.local.", "_https._tcp.local."] {
        let receiver = daemon
            .browse(service)
            .map_err(|error| format!("could not browse {service}: {error}"))?;
        let deadline = std::time::Instant::now() + DISCOVERY_TIMEOUT;
        while std::time::Instant::now() < deadline {
            let remaining = deadline.saturating_duration_since(std::time::Instant::now());
            let event = match receiver.recv_timeout(remaining) {
                Ok(event) => event,
                Err(error) => match error {
                    flume::RecvTimeoutError::Timeout => break,
                    flume::RecvTimeoutError::Disconnected => break,
                },
            };
            if let ServiceEvent::ServiceResolved(resolved) = event
                && is_nanokvm(
                    &resolved.fullname,
                    &resolved.host,
                    resolved
                        .get_properties()
                        .iter()
                        .any(|property| property.key().to_lowercase().contains("nanokvm")),
                )
            {
                let Some(address) = resolved.get_addresses_v4().into_iter().next() else {
                    continue;
                };
                let scheme = if service.starts_with("_https") {
                    "https"
                } else {
                    "http"
                };
                let item = DiscoveredDevice {
                    name: resolved
                        .fullname
                        .split('.')
                        .next()
                        .unwrap_or("NanoKVM")
                        .to_owned(),
                    address: format!("{scheme}://{address}:{}", resolved.port),
                };
                devices.insert(item.address.clone(), item);
            }
        }
        let _ = daemon.stop_browse(service);
    }
    Ok(devices.into_values().collect())
}

fn is_nanokvm(fullname: &str, hostname: &str, has_property: bool) -> bool {
    has_property
        || fullname.to_ascii_lowercase().contains("kvm")
        || hostname.to_ascii_lowercase().contains("kvm")
}

#[cfg(test)]
mod tests {
    use super::is_nanokvm;

    #[test]
    fn only_reports_plausible_nanokvm_services() {
        assert!(is_nanokvm(
            "Desk NanoKVM._http._tcp.local.",
            "desk.local.",
            false
        ));
        assert!(!is_nanokvm(
            "Printer._http._tcp.local.",
            "printer.local.",
            false
        ));
        assert!(is_nanokvm(
            "Unknown._http._tcp.local.",
            "device.local.",
            true
        ));
    }
}
