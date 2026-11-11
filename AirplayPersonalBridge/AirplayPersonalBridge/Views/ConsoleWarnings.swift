//
//  ConsoleWarnings.swift
//  AirplayPersonalBridge
//

import SwiftUI

/// Un avertissement de la console, sur une ligne : d'où il vient, ce qu'il dit, et de quoi y remédier.
struct ConsoleWarning: Identifiable, Equatable {
    enum Tone: Equatable {
        case warning
        case critical
    }

    var id: String
    var tone: Tone
    /// En gras : le sujet (« Autorisation manquante », le nom d'une enceinte).
    var subject: String
    var text: String
    /// Le volet des Réglages Système qui y remédie, s'il y en a un.
    var settingsPane: SystemSettingsPane?

    static func == (lhs: ConsoleWarning, rhs: ConsoleWarning) -> Bool {
        lhs.id == rhs.id && lhs.tone == rhs.tone && lhs.subject == rhs.subject && lhs.text == rhs.text
            && (lhs.settingsPane == nil) == (rhs.settingsPane == nil)
    }

    /// Ce que la console doit signaler, du plus grave au moins grave : le démarrage, la capture, puis chaque
    /// enceinte en peine dans l'ordre des tuiles. Hors de la vue pour être testé.
    static func list(for state: BridgeState, speakers: [OutputState]) -> [ConsoleWarning] {
        var warnings: [ConsoleWarning] = []
        if let failure = state.startFailure {
            warnings.append(
                ConsoleWarning(
                    id: "demarrage", tone: .critical, subject: "Démarrage impossible", text: failure.message,
                    settingsPane: failure.settingsPane
                )
            )
        }
        if let alert = state.captureAlert {
            warnings.append(
                ConsoleWarning(
                    id: "capture", tone: alert.severity == .critical ? .critical : .warning,
                    subject: alert.title, text: alert.detail ?? "", settingsPane: alert.settingsPane
                )
            )
        }
        for output in speakers {
            guard
                let detail = ConsoleTileCaption.detail(
                    connection: output.connection, isEnabled: output.isEnabled, isHeldBack: output.consoleIsHeldBack
                )
            else { continue }
            warnings.append(
                ConsoleWarning(
                    id: "enceinte-\(output.id)", tone: detail.tone == .critical ? .critical : .warning,
                    subject: output.displayName, text: detail.text
                )
            )
        }
        return warnings
    }
}

/// Les avertissements, en petit sous la barre de lecture. Leur place est réservée, qu'il y en ait ou non :
/// un avertissement qui arrive ne déplace ni les tuiles ni la barre (demande de Baptiste du 2026-11-10).
/// Une ligne chacun, le texte entier au survol ; au-delà de la place, un décompte.
struct ConsoleWarnings: View {
    let warnings: [ConsoleWarning]

    /// Les lignes qui tiennent dans la place réservée.
    static let visibleLines = 3
    static let lineHeight: CGFloat = 18
    static let reservedHeight: CGFloat = CGFloat(visibleLines) * lineHeight + 4

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            let shown = warnings.count > Self.visibleLines ? Array(warnings.prefix(Self.visibleLines - 1)) : warnings
            ForEach(shown) { warning in
                line(warning)
            }
            if shown.count < warnings.count {
                Text("et \(warnings.count - shown.count) autres avertissements")
                    .font(.system(size: 11.5))
                    .foregroundStyle(Color.white.opacity(0.55))
                    .frame(height: Self.lineHeight)
                    .help(warnings.dropFirst(shown.count).map { "\($0.subject) : \($0.text)" }.joined(separator: "\n"))
            }
        }
        .padding(.horizontal, 18)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .frame(height: Self.reservedHeight, alignment: .top)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Avertissements")
    }

    private func line(_ warning: ConsoleWarning) -> some View {
        HStack(spacing: 6) {
            Image(systemName: warning.tone == .critical ? "exclamationmark.triangle.fill" : "exclamationmark.circle.fill")
                .foregroundStyle(warning.tone == .critical ? Color.red : Color.orange)
                .accessibilityHidden(true)
            Text(warning.subject)
                .fontWeight(.semibold)
                .foregroundStyle(Color.white.opacity(0.9))
                .layoutPriority(1)
            Text(warning.text)
                .foregroundStyle(Color.white.opacity(0.62))
                .truncationMode(.tail)
            if let pane = warning.settingsPane {
                Button("Réglages…") { pane.open() }
                    .buttonStyle(.plain)
                    .fontWeight(.medium)
                    .foregroundStyle(Color.white.opacity(0.9))
                    .underline()
                    .layoutPriority(1)
            }
        }
        .font(.system(size: 11.5))
        .lineLimit(1)
        .frame(height: Self.lineHeight)
        .help("\(warning.subject) : \(warning.text)")
        .accessibilityElement(children: .combine)
    }
}

/// Les avertissements d'une fenêtre basse : le plus grave sur une ligne, le décompte des autres, et tous
/// en entier au clic. Leur ligne est réservée comme celle de `ConsoleWarnings` : rien ne bouge à leur arrivée.
struct ConsoleCompactWarnings: View {
    let warnings: [ConsoleWarning]

    static let height: CGFloat = 22

    @State private var showsAll = false

    var body: some View {
        if let first = warnings.first {
            Button {
                showsAll.toggle()
            } label: {
                HStack(spacing: 6) {
                    Image(
                        systemName: first.tone == .critical
                            ? "exclamationmark.triangle.fill" : "exclamationmark.circle.fill"
                    )
                    .foregroundStyle(first.tone == .critical ? Color.red : Color.orange)
                    .accessibilityHidden(true)
                    Text(first.subject)
                        .fontWeight(.semibold)
                        .foregroundStyle(Color.white.opacity(0.9))
                        .layoutPriority(1)
                    Text(first.text)
                        .foregroundStyle(Color.white.opacity(0.62))
                        .truncationMode(.tail)
                    if warnings.count > 1 {
                        Text("+\(warnings.count - 1)")
                            .fontWeight(.semibold)
                            .foregroundStyle(Color.white.opacity(0.9))
                            .padding(.horizontal, 6)
                            .background(Color.white.opacity(0.14), in: Capsule())
                            .layoutPriority(1)
                    }
                }
                .font(.system(size: 11.5))
                .lineLimit(1)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(warnings.map { "\($0.subject) : \($0.text)" }.joined(separator: "\n"))
            .accessibilityLabel("Avertissements")
            .accessibilityValue(warnings.map { "\($0.subject) : \($0.text)" }.joined(separator: ". "))
            .accessibilityHint("Affiche les avertissements en entier.")
            .popover(isPresented: $showsAll, arrowEdge: .top) {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(warnings) { warning in
                        VStack(alignment: .leading, spacing: 3) {
                            Label {
                                Text(warning.subject).font(.headline)
                            } icon: {
                                Image(
                                    systemName: warning.tone == .critical
                                        ? "exclamationmark.triangle.fill" : "exclamationmark.circle.fill"
                                )
                                .foregroundStyle(warning.tone == .critical ? Color.red : Color.orange)
                            }
                            Text(warning.text)
                                .font(.callout)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                                .textSelection(.enabled)
                            if let pane = warning.settingsPane {
                                Button("Ouvrir les Réglages…") { pane.open() }
                                    .controlSize(.small)
                                    .padding(.top, 2)
                            }
                        }
                    }
                }
                .padding(16)
                .frame(width: 320, alignment: .leading)
            }
        }
    }
}
