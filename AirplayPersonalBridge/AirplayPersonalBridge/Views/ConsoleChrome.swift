//
//  ConsoleChrome.swift
//  AirplayPersonalBridge
//

import SwiftUI

/// Ce qui entoure les tuiles de la console : le lieu d'écoute, les messages des enceintes, et l'attente.

// MARK: - Lieu d'écoute

/// Le lieu d'écoute, en commande segmentée : il recale les enceintes pour ce lieu, sans couper le son. Il
/// n'apparaît qu'à partir de deux lieux : avec un seul, il n'y a rien à choisir.
struct ConsoleListeningPlaces: View {
    @Bindable var state: BridgeState

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Namespace private var selection

    /// Au-delà, les segments ne tiennent plus à côté du titre : un menu les remplace.
    private static let segmentLimit = 3

    var body: some View {
        let listeners = state.roomLayout.listeners
        if listeners.count >= 2, let active = state.roomLayout.listener {
            // La première forme qui tient dans la largeur offerte : les segments, puis un menu au nom du
            // lieu en vigueur, puis une icône seule. Le choix reste entier dans les trois.
            ViewThatFits(in: .horizontal) {
                if listeners.count <= Self.segmentLimit {
                    segments(listeners, active: active)
                } else {
                    menu(listeners, active: active)
                }
                pill(listeners, active: active, showsName: true)
                pill(listeners, active: active, showsName: false)
            }
            .help("Lieu d'écoute : recale les enceintes pour ce lieu, sans couper le son")
        }
    }

    private static func name(of listener: RoomObject) -> String {
        listener.name.isEmpty ? listener.kind.label : listener.name
    }

    private func segments(_ listeners: [RoomObject], active: RoomObject) -> some View {
        HStack(spacing: 2) {
            ForEach(listeners) { listener in
                let isSelected = listener.id == active.id
                Button {
                    state.selectListeningPlace(id: listener.id)
                } label: {
                    Text(Self.name(of: listener))
                        .font(.system(size: 13, weight: isSelected ? .semibold : .medium))
                        .foregroundStyle(isSelected ? Color.black.opacity(0.86) : Color.white.opacity(0.86))
                        .lineLimit(1)
                        .padding(.horizontal, 14)
                        .frame(height: 30)
                        .background {
                            if isSelected {
                                Capsule()
                                    .fill(Color.white)
                                    .matchedGeometryEffect(id: "lieu", in: selection)
                            }
                        }
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(isSelected ? .isSelected : [])
            }
        }
        .padding(3)
        .floatingGlass(in: Capsule())
        .animation(PanelMotion.standard(reduceMotion: reduceMotion), value: active.id)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Lieu d'écoute")
    }

    private func choices(_ listeners: [RoomObject], active: RoomObject) -> some View {
        Picker(
            "Lieu d'écoute",
            selection: Binding(get: { active.id }, set: { state.selectListeningPlace(id: $0) })
        ) {
            ForEach(listeners) { listener in
                Text(Self.name(of: listener)).tag(listener.id)
            }
        }
        .pickerStyle(.inline)
    }

    /// Replié, à la facture de la pastille de source : l'oreille, le nom du lieu en vigueur s'il tient, et
    /// le menu des lieux.
    private func pill(_ listeners: [RoomObject], active: RoomObject, showsName: Bool) -> some View {
        Menu {
            choices(listeners, active: active)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "ear")
                    .font(.body.weight(.medium))
                    .accessibilityHidden(true)
                if showsName {
                    Text(Self.name(of: active))
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)
                    Image(systemName: "chevron.down")
                        .font(.caption2.weight(.bold))
                        .accessibilityHidden(true)
                }
            }
            .foregroundStyle(.white)
            .padding(.horizontal, showsName ? 14 : 0)
            .frame(minWidth: WindowChromeMetrics.controlHeight)
            .frame(height: WindowChromeMetrics.controlHeight)
            .floatingGlass(in: Capsule(), interactive: true)
            .contentShape(Capsule())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .accessibilityLabel("Lieu d'écoute")
        .accessibilityValue(Self.name(of: active))
    }

    private func menu(_ listeners: [RoomObject], active: RoomObject) -> some View {
        Menu {
            choices(listeners, active: active)
        } label: {
            Label(Self.name(of: active), systemImage: "ear")
                .labelStyle(.titleAndIcon)
        }
        .glassButtonStyle()
        .controlSize(.large)
        .fixedSize()
        .accessibilityLabel("Lieu d'écoute")
    }
}

// MARK: - Attente

/// La tuile qui tient la place des enceintes tant qu'il n'y en a aucune : la recherche en cours, ou ce
/// qu'il faut vérifier.
struct ConsoleEmptyTile: View {
    @Bindable var state: BridgeState

    var body: some View {
        VStack(spacing: 8) {
            if state.isBrowsing || !state.hasCompletedDiscovery {
                ProgressView().controlSize(.regular).padding(.bottom, 4)
                Text("Recherche des enceintes…")
                    .font(.system(size: 17, weight: .semibold))
                Text("Elles apparaîtront ici dès qu'elles répondront.")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            } else {
                Image(systemName: "hifispeaker.2")
                    .font(.system(size: 30, weight: .light))
                    .foregroundStyle(.secondary)
                    .padding(.bottom, 4)
                    .accessibilityHidden(true)
                Text("Aucune enceinte")
                    .font(.system(size: 17, weight: .semibold))
                Text(state.discoveryNotice ?? "Lance une recherche sur le réseau local.")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    Button("Rechercher") { Task { await state.refreshOutputs() } }
                        .glassButtonStyle()
                    if state.discoveryNotice != nil {
                        Button("Réseau local…") { SystemSettingsPane.localNetwork.open() }
                            .glassButtonStyle()
                            .help("Ouvrir les réglages « Réseau local »")
                    }
                }
                .padding(.top, 8)
            }
        }
        .multilineTextAlignment(.center)
        .padding(.horizontal, 28)
        .frame(width: ConsoleMetrics.placeholderWidth)
        .frame(maxHeight: .infinity)
        .modifier(ConsoleTileSurface(isHeldBack: true))
    }
}
