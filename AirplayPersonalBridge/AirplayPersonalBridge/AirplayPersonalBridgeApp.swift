//
//  AirplayPersonalBridgeApp.swift
//  AirplayPersonalBridge
//
//  Created by baptiste on 07/08/2026.
//

import SwiftUI

@main
struct AirplayPersonalBridgeApp: App {
    init() {
        TerminationSignal.install()
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
