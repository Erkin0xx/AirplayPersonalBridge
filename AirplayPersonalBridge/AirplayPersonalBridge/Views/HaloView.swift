//
//  HaloView.swift
//  AirplayPersonalBridge
//

import SwiftUI

/// La vue « Halo » de la fenêtre. Provisoire : son contenu arrive.
struct HaloView: View {
    @Bindable var state: BridgeState

    var body: some View {
        Text(state.status.title)
            .font(.title.weight(.bold))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
