import Foundation
import SwiftUI
import Testing
@testable import NanoKVM
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// Renders each page inside a real window so its `.task` loaders run against the mock server.
@MainActor
func mount<V: View>(_ view: V, wait: Duration = .milliseconds(600)) async {
    #if os(macOS)
    let host = NSHostingView(rootView: view.frame(width: 700, height: 900))
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 900), styleMask: [.titled], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = host
    window.orderBack(nil)
    try? await Task.sleep(for: wait)
    window.close()
    #else
    let controller = UIHostingController(rootView: view)
    let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 700, height: 900))
    window.rootViewController = controller
    window.isHidden = false
    try? await Task.sleep(for: wait)
    window.isHidden = true
    #endif
}

@MainActor
struct ViewSmokeTests {
    let server = MockServer()

    func session(_ override: (MockServer) -> Void = { _ in }) async -> DeviceSession {
        server.lenient = true
        server.on("POST /auth/login", data: ["token": "tok"])
        server.on("GET /vm/info", data: ["ips": [["name": "wlan0", "addr": "10.0.0.2", "version": "IPv4", "type": "Wireless"]],
                                         "mdns": "m", "image": "i", "application": "a", "deviceKey": "k", "pn": "p", "arch": "x"])
        server.on("GET /network/wifi", data: ["supported": true, "apMode": false, "connected": true,
                                              "wifi": ["ssid": "Home", "bssid": "aa", "signal": -60, "frequency": 5180, "security": "SAE"]])
        server.on("GET /network/wifi/scan", data: ["wifiList": [["ssid": "Home", "signal": -60, "frequency": 5180, "security": "SAE"], ["ssid": "Open", "signal": -80, "frequency": 2437, "security": ""]]])
        server.on("GET /extensions/tailscale/status", data: ["state": "running", "name": "kvm", "ip": "100.1.1.1", "routingAvailable": true])
        server.on("GET /vm/hostname", data: ["hostname": "kvm"])
        server.on("GET /vm/ssh", data: ["enabled": true])
        server.on("GET /vm/mdns", data: ["enabled": true])
        server.on("GET /ai/config", data: ["mcpEnabled": true])
        server.on("POST /ai/mcp/key", data: ["mcpApiKey": "KEY"])
        server.on("GET /ai/services", data: ["memoryMiB": 246, "memoryTier": "low", "services": []])
        server.on("GET /vm/script", data: ["files": ["a.sh", "b.sh"]])
        server.on("GET /application/version", data: ["current": "1.0", "latest": "1.1"])
        server.on("GET /vm/timezone", data: ["timezone": "Europe/Paris"])
        server.on("GET /vm/time/status", data: ["isSynchronized": true, "lastSyncTime": "now"])
        server.on("GET /hid/mode", data: ["mode": "normal"])
        server.on("GET /vm/usb-id", data: ["enabled": true, "vid": "1234", "pid": "5678", "bcdDevice": "1", "serialnumber": "s", "manufacturer": "m", "product": "p"])
        server.on("GET /vm/usb-network", data: ["mode": "server", "ipv4": "10.1.1.1", "forwarding": true])
        server.on("GET /vm/device/virtual", data: ["isNetworkEnabled": true, "isDiskEnabled": false, "diskMinSizeMiB": 5120, "diskMaxSizeMiB": 49750, "audioMode": "mic"])
        server.on("GET /network/static-ip", data: ["enabled": true, "ip": "10.0.0.50"])
        server.on("GET /storage/download/image/enabled", data: ["enabled": true])
        server.on("GET /vm/finger-robot", data: ["enabled": true, "available": true])
        server.on("GET /apps", data: [["id": "x", "name": "App", "version": "1"]])
        server.on("GET /network/wol/mac", data: ["macs": ["AA:BB:CC:DD:EE:FF PC"]])
        server.on("GET /storage/image", data: ["files": ["a.iso"]])
        server.on("GET /storage/image/mounted", data: ["mounted": true, "file": "a.iso", "cdrom": true, "readOnly": true])
        server.on("GET /stream/encoder", data: ["rate_control": "cbr", "bitrate": 8000, "gop": 30, "fps": 30])
        server.on("GET /vm/edid", data: ["edid": "x.bin", "width": 1920, "height": 1080])
        server.on("GET /vm/edid/custom", data: ["edidList": ["x.bin", "y.bin"]])
        server.on("GET /hid/pointer-mode", data: ["mode": "absolute"])
        server.on("GET /vm/mouse-jiggler", data: ["enabled": true, "mode": "relative"])
        override(server)
        let device = SavedDevice(name: "T", host: server.host, username: "admin")
        let s = DeviceSession(device: device, makeClient: { MockServer.client(host: $0) }, passwordProvider: { _ in "pw" })
        await s.connect()
        return s
    }

    @Test func networkPage() async {
        let s = await session()
        await mount(NavigationStack { NetworkView(session: s) })
        #expect(!server.requests(to: "GET /network/wifi").isEmpty)
        s.disconnect()
    }

    @Test func servicesPage() async {
        let s = await session()
        await mount(NavigationStack { ServicesView(session: s) })
        #expect(!server.requests(to: "GET /ai/services").isEmpty)
        s.disconnect()
    }

    @Test func devicePage() async {
        let s = await session()
        await mount(NavigationStack { DevicePageView(session: s) })
        #expect(!server.requests(to: "GET /application/version").isEmpty)
        s.disconnect()
    }

    @Test func advancedPage() async {
        let s = await session()
        await mount(NavigationStack { AdvancedView(session: s) })
        #expect(!server.requests(to: "GET /vm/usb-id").isEmpty)
        s.disconnect()
    }

    @Test func mediaPage() async {
        let s = await session()
        await mount(NavigationStack { MediaView(session: s) })
        #expect(!server.requests(to: "GET /storage/image").isEmpty)
        s.disconnect()
    }

    @Test func wakePage() async {
        let s = await session()
        await mount(NavigationStack { WakeView(session: s) })
        #expect(!server.requests(to: "GET /network/wol/mac").isEmpty)
        s.disconnect()
    }

    @Test func settingsPage() async {
        let s = await session()
        await mount(NavigationStack { SettingsView(session: s) })
        #expect(!server.requests(to: "GET /stream/encoder").isEmpty)
        s.disconnect()
    }

    @Test func screenPage() async {
        let s = await session()
        await mount(ScreenView(session: s), wait: .milliseconds(300))
        s.disconnect()
    }
}
