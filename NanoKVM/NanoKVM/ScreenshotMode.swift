import Foundation

/// Launch with `-screenshots-host <host:port>` to run against a local mock KVM (scripts/screenshots/screenshots.sh).
/// The device is never saved, so a real device list and iCloud data stay untouched.
enum ScreenshotMode {
    static let deviceID = UUID(uuidString: "00000000-0000-0000-0000-0000000000A1")!
    static let password = "demo"

    static var host: String? {
        let v = UserDefaults.standard.string(forKey: "screenshots-host")
        return (v?.isEmpty == false) ? v : nil
    }

    static var device: SavedDevice? {
        host.map { SavedDevice(id: deviceID, name: "Lab KVM", host: $0, username: "admin") }
    }

    /// The demo device shows its power and auto-EDID switches on so the Display section looks configured.
    static func forcesFlag(_ name: String, _ id: UUID) -> Bool {
        host != nil && id == deviceID && (name == "externalPower" || name == "autoEDID")
    }

    static func password(for id: UUID) -> String? { id == deviceID && host != nil ? password : nil }
}
