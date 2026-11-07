import Foundation
#if os(iOS)
import UIKit
#endif

/// Says which install of the app currently owns the connection to a KVM. Synced via iCloud so that
/// only one instance (e.g. Mac or iPhone) talks to a KVM at a time and they don't fight over it.
enum ConnectionLease {
    struct Lease: Equatable {
        let owner: String
        let name: String
        let at: Date
    }

    private static let installKey = "installID"
    private static let store = NSUbiquitousKeyValueStore.default

    static var installID: String {
        if let id = UserDefaults.standard.string(forKey: installKey) { return id }
        let id = UUID().uuidString
        UserDefaults.standard.set(id, forKey: installKey)
        return id
    }

    static var thisDeviceName: String {
        #if os(iOS)
        UIDevice.current.name
        #else
        Host.current().localizedName ?? "Mac"
        #endif
    }

    private static func key(_ id: UUID) -> String { "lease.\(id.uuidString)" }

    private static func lease(from d: [String: Any]?) -> Lease? {
        guard let d, let owner = d["owner"] as? String else { return nil }
        return Lease(owner: owner, name: d["name"] as? String ?? "another device",
                     at: Date(timeIntervalSince1970: d["at"] as? Double ?? 0))
    }

    /// The newest of the iCloud value and the local copy (the local one covers a missing or slow iCloud).
    static func current(for id: UUID) -> Lease? {
        let remote = lease(from: store.dictionary(forKey: key(id)))
        let local = lease(from: UserDefaults.standard.dictionary(forKey: key(id)))
        guard let remote else { return local }
        guard let local else { return remote }
        return remote.at >= local.at ? remote : local
    }

    /// Takes the connection for this install; whoever held it before will see it and stop.
    static func claim(_ id: UUID, install: String = installID, name: String = thisDeviceName, now: Date = Date()) {
        let value: [String: Any] = ["owner": install, "name": name, "at": now.timeIntervalSince1970]
        UserDefaults.standard.set(value, forKey: key(id))
        store.set(value, forKey: key(id))
        store.synchronize()
    }

    /// Name of the other device that owns the KVM, or nil when this install owns it or nobody does.
    static func otherOwner(of id: UUID, install: String = installID) -> String? {
        guard let lease = current(for: id), lease.owner != install else { return nil }
        return lease.name
    }

    static func release(_ id: UUID, install: String = installID) {
        guard current(for: id)?.owner == install else { return }
        UserDefaults.standard.removeObject(forKey: key(id))
        store.removeObject(forKey: key(id))
        store.synchronize()
    }
}
