//
//  ConsoleView.swift
//  AirplayPersonalBridge
//

import SwiftUI

/// La vue « Console » de la fenêtre. Provisoire : son contenu arrive.
struct ConsoleView: View {
    @Bindable var state: BridgeState

    var body: some View {
        Text(state.status.title)
            .font(.title.weight(.bold))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
