//
//  NanoKVMApp.swift
//  NanoKVM
//
//  Created by Stephane Jupille on 21/10/2026.
//

import SwiftUI

@main
struct NanoKVMApp: App {
    var body: some Scene {
        WindowGroup {
            RootView()
                #if os(macOS)
                .frame(minWidth: 760, minHeight: 520)
                #endif
        }
        #if os(macOS)
        .defaultSize(width: 1100, height: 760)
        #endif
    }
}
