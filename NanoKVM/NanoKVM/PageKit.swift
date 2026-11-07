import SwiftUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// Shared busy/error handling for the management pages.
@MainActor @Observable
final class PageState {
    var error: String?
    var notice: String?
    var busy = false

    func run(_ work: () async throws -> Void) async {
        busy = true
        defer { busy = false }
        do { try await work(); error = nil } catch { self.error = error.localizedDescription }
    }
}

func copyToClipboard(_ text: String) {
    #if os(macOS)
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(text, forType: .string)
    #else
    UIPasteboard.general.string = text
    #endif
}

extension View {
    func pageAlerts(_ page: PageState) -> some View {
        self
            .alert("Error", isPresented: Binding(get: { page.error != nil }, set: { if !$0 { page.error = nil } })) {
                Button("OK") {}
            } message: { Text(page.error ?? "") }
            .alert("Done", isPresented: Binding(get: { page.notice != nil }, set: { if !$0 { page.notice = nil } })) {
                Button("OK") {}
            } message: { Text(page.notice ?? "") }
            .overlay { if page.busy { ProgressView().padding(20).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12)) } }
    }
}

extension Dictionary where Key == String, Value == Any {
    func str(_ k: String) -> String { (self[k] as? String) ?? "" }
    func bool(_ k: String) -> Bool { (self[k] as? Bool) ?? false }
    func int(_ k: String) -> Int { (self[k] as? Int) ?? 0 }
}
