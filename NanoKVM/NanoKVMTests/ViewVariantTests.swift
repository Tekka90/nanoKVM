import SwiftUI
import Testing
@testable import NanoKVM

/// Mounts pages against different device states so every conditional branch of their bodies is rendered.
@MainActor
struct ViewVariantTests {
    let base = ViewSmokeTests()

    @Test(arguments: ["running", "stopped", "notLogin", "notRunning", "notInstall", "weird"])
    func networkTailscaleStates(state: String) async {
        let s = await base.session { $0.on("GET /extensions/tailscale/status", data: ["state": state, "ip": "100.1.1.1", "account": "me", "advertiseExitNode": true, "advertiseSubnetRoute": false, "lanSubnet": "10.0.0.0/24"]) }
        await mount(NavigationStack { NetworkView(session: s) }, wait: .milliseconds(400))
        #expect(!base.server.requests(to: "GET /extensions/tailscale/status").isEmpty)
        s.disconnect()
    }

    @Test func networkWhenWifiOffline() async {
        let s = await base.session { $0.on("GET /network/wifi", data: ["supported": true, "apMode": true, "connected": false]) }
        await mount(NavigationStack { NetworkView(session: s) }, wait: .milliseconds(400))
        s.disconnect()
    }

    @Test func pagesSurviveFailingServer() async {
        let s = await base.session { server in
            server.lenient = false
            for key in ["GET /network/wifi", "GET /vm/hostname", "GET /ai/services", "GET /application/version", "GET /vm/usb-id",
                        "GET /storage/image", "GET /network/wol/mac", "GET /stream/encoder", "GET /vm/edid"] {
                server.on(key, data: [String: Any](), code: -1, msg: "boom")
            }
        }
        base.server.lenient = false
        await mount(NavigationStack { NetworkView(session: s) }, wait: .milliseconds(300))
        await mount(NavigationStack { ServicesView(session: s) }, wait: .milliseconds(300))
        await mount(NavigationStack { DevicePageView(session: s) }, wait: .milliseconds(300))
        await mount(NavigationStack { AdvancedView(session: s) }, wait: .milliseconds(300))
        await mount(NavigationStack { MediaView(session: s) }, wait: .milliseconds(300))
        await mount(NavigationStack { WakeView(session: s) }, wait: .milliseconds(300))
        await mount(NavigationStack { SettingsView(session: s) }, wait: .milliseconds(300))
        s.disconnect()
    }

    @Test func servicesWithMemoryPressure() async {
        let s = await base.session {
            $0.on("GET /ai/services", data: ["memoryMiB": 40, "memoryTier": "critical",
                                             "services": [["name": "mcp", "running": true], ["name": "fabric", "running": false]]])
            $0.on("GET /ai/config", data: ["mcpEnabled": false])
        }
        await mount(NavigationStack { ServicesView(session: s) }, wait: .milliseconds(400))
        s.disconnect()
    }

    @Test func mediaWithNothingMounted() async {
        let s = await base.session {
            $0.on("GET /storage/image", data: ["files": [String]()])
            $0.on("GET /storage/image/mounted", data: ["mounted": false, "file": "", "cdrom": false, "readOnly": false])
        }
        await mount(NavigationStack { MediaView(session: s) }, wait: .milliseconds(400))
        s.disconnect()
    }

    @Test func wakeWithNoSavedMacs() async {
        let s = await base.session { $0.on("GET /network/wol/mac", data: ["macs": [String]()]) }
        await mount(NavigationStack { WakeView(session: s) }, wait: .milliseconds(400))
        s.disconnect()
    }

    @Test func settingsWithAlternateEncoder() async {
        let s = await base.session {
            $0.on("GET /stream/encoder", data: ["rate_control": "vbr", "bitrate": 2000, "gop": 60, "fps": 0])
            $0.on("GET /hid/pointer-mode", data: ["mode": "relative"])
            $0.on("GET /vm/mouse-jiggler", data: ["enabled": false, "mode": "absolute"])
        }
        await mount(NavigationStack { SettingsView(session: s) }, wait: .milliseconds(400))
        s.disconnect()
    }

    @Test func advancedWithDisabledFeatures() async {
        let s = await base.session {
            $0.on("GET /vm/usb-id", data: ["enabled": false])
            $0.on("GET /vm/finger-robot", data: ["enabled": false, "available": false])
            $0.on("GET /hid/mode", data: ["mode": "hid-only"])
            $0.on("GET /vm/usb-network", data: ["mode": "off"])
        }
        await mount(NavigationStack { AdvancedView(session: s) }, wait: .milliseconds(400))
        s.disconnect()
    }

    @Test func deviceViewShowsFailureForUnreachableHost() async {
        let device = SavedDevice(name: "Offline", host: "unreachable-\(UUID().uuidString.prefix(6).lowercased()).invalid", username: "admin")
        await mount(DeviceView(device: device, deviceMenu: AnyView(EmptyView())), wait: .milliseconds(1500))
    }

    @Test func deviceFormAddAndEdit() async {
        await mount(DeviceForm(device: nil, prefill: nil) { _, _ in }, wait: .milliseconds(200))
        let existing = SavedDevice(name: "A", host: "a.local", username: "admin")
        await mount(DeviceForm(device: existing, prefill: nil) { _, _ in }, wait: .milliseconds(200))
        let found = DiscoveredDevice(name: "kvm")
        await mount(DeviceForm(device: nil, prefill: found) { _, _ in }, wait: .milliseconds(200))
    }
}
