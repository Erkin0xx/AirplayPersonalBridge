//
//  PanelPopup.swift
//  AirplayPersonalBridge
//

import SwiftUI

/// La fenêtre surgissante du panneau : une carte de verre posée sur son contenu, dans sa propre
/// fenêtre, qui sort de la rangée qui l'ouvre. **Le panneau ne change jamais de taille.**
///
/// Pourquoi pas un `.popover` : dans la fenêtre d'un `MenuBarExtra`, rien ne garantit qu'en présenter
/// un, ou cliquer dedans, ne referme pas le panneau lui-même. La sonde du 2026-11-10 n'a pas pu
/// trancher (écran verrouillé, aucune fenêtre ne s'affichait) ; une carte dessinée dans le panneau ne
/// court pas ce risque.
///
/// La carte se pose juste au-dessus de sa rangée, la pointe dessus. Si la place manque (panneau « vide »
/// ou « recherche »), elle recouvre la rangée et le pied ; s'il en manque encore, son contenu défile.
/// Elle se ferme d'un clic à côté, par Échap ou par son bouton.
extension View {
    /// Désigne la rangée d'où sort la carte.
    func panelPopupAnchor() -> some View {
        anchorPreference(key: PanelPopupAnchorKey.self, value: .bounds) { $0 }
    }

    /// Présente `content` dans une carte posée sur cette vue, ancrée à `panelPopupAnchor()`.
    func panelPopup<Content: View>(
        _ title: String, isPresented: Binding<Bool>, @ViewBuilder content: @escaping () -> Content
    ) -> some View {
        modifier(PanelPopupPresenter(title: title, isPresented: isPresented, popupContent: content))
    }
}

/// Où se trouve, dans le panneau, la rangée d'où sort la carte.
nonisolated struct PanelPopupAnchorKey: PreferenceKey {
    static var defaultValue: Anchor<CGRect>? { nil }

    static func reduce(value: inout Anchor<CGRect>?, nextValue: () -> Anchor<CGRect>?) {
        value = value ?? nextValue()
    }
}

private struct PanelPopupPresenter<PopupContent: View>: ViewModifier {
    let title: String
    @Binding var isPresented: Bool
    let popupContent: () -> PopupContent

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        content.overlayPreferenceValue(PanelPopupAnchorKey.self) { anchor in
            GeometryReader { proxy in
                // Sans rangée désignée, la carte se pose en bas du panneau.
                let rowTop = anchor.map { proxy[$0].minY } ?? proxy.size.height
                ZStack {
                    if isPresented {
                        scrim.transition(.opacity)
                        placement(rowTop: rowTop, in: proxy.size)
                            .transition(transition(from: rowTop, in: proxy.size))
                    }
                }
                .frame(width: proxy.size.width, height: proxy.size.height)
            }
        }
    }

    /// La carte sort de sa rangée, et y rentre.
    private func transition(from rowTop: CGFloat, in size: CGSize) -> AnyTransition {
        guard !reduceMotion, size.height > 0 else { return .opacity }
        let origin = UnitPoint(x: 0.5, y: min(max(rowTop / size.height, 0), 1))
        return .scale(scale: 0.86, anchor: origin).combined(with: .opacity)
    }

    /// Le voile qui dit que le reste attend, et qui ferme la carte d'un clic à côté.
    private var scrim: some View {
        Color.black.opacity(colorScheme == .dark ? 0.3 : 0.14)
            .clipShape(.rect(cornerRadius: PanelMetrics.panelRadius))
            .contentShape(Rectangle())
            .onTapGesture(perform: dismiss)
            .accessibilityHidden(true)
    }

    private func placement(rowTop: CGFloat, in size: CGSize) -> some View {
        let inset = PanelMetrics.popupInset
        return ViewThatFits(in: .vertical) {
            // La place suffit au-dessus de la rangée : la carte s'y pose, la pointe sur la rangée.
            VStack(spacing: 0) {
                Spacer(minLength: inset)
                card(pointsAtRow: true, scrolls: false)
                Color.clear.frame(height: max(size.height - rowTop, 0) + 1)
            }
            // Panneau trop court : la carte recouvre la rangée et le pied, et défile s'il le faut encore.
            card(pointsAtRow: false, scrolls: true)
                .padding(.vertical, inset)
                .frame(maxHeight: .infinity, alignment: .bottom)
        }
        .padding(.horizontal, inset)
    }

    private func card(pointsAtRow: Bool, scrolls: Bool) -> some View {
        PanelPopupCard(
            title: title, pointsDown: pointsAtRow, scrolls: scrolls, close: dismiss, content: popupContent
        )
    }

    private func dismiss() {
        withAnimation(PanelMotion.popup(reduceMotion: reduceMotion)) { isPresented = false }
    }
}

/// La carte elle-même : un titre, de quoi la fermer, et le contenu.
struct PanelPopupCard<Content: View>: View {
    let title: String
    /// La pointe vise la rangée d'où sort la carte ; sans objet quand la carte la recouvre.
    var pointsDown = true
    /// Le contenu défile s'il dépasse la hauteur qu'on lui laisse.
    var scrolls = false
    let close: () -> Void
    @ViewBuilder var content: () -> Content

    private var shape: PanelPopupShape {
        PanelPopupShape(
            cornerRadius: PanelMetrics.popupRadius, beakHeight: pointsDown ? PanelMetrics.popupBeak : 0
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            if scrolls {
                ViewThatFits(in: .vertical) {
                    content()
                    ScrollView { content() }
                }
            } else {
                content()
            }
        }
        .padding(PanelMetrics.margin)
        .padding(.bottom, pointsDown ? PanelMetrics.popupBeak : 0)
        // Un clic dans la carte, hors de ses contrôles, ne doit pas atteindre le voile qui la ferme.
        .contentShape(shape)
        .onTapGesture {}
        .modifier(PanelPopupSurface(shape: shape))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(title)
        .accessibilityAddTraits(.isModal)
    }

    private var header: some View {
        HStack(spacing: 6) {
            PanelSectionTitle(title: title)
            Spacer(minLength: 4)
            Button(action: close) {
                Image(systemName: "xmark")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.secondary)
                    .frame(width: 20, height: 20)
                    .background(PanelPalette.quietFill, in: Circle())
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            // Échap ferme la carte, où que soit le focus.
            .keyboardShortcut(.cancelAction)
            .help("Fermer")
            .accessibilityLabel("Fermer")
        }
    }
}

/// Le fond de la carte : le verre, doublé d'un voile de la couleur des fenêtres.
///
/// Le voile n'est pas de trop : la carte passe sur des noms d'enceintes et des curseurs, et le verre
/// seul les laisserait transparaître sous le texte des options. Hors écran, où le verre ne dessine
/// rien, un aplat de même forme le remplace (`panelSimulatesGlass`).
private struct PanelPopupSurface: ViewModifier {
    let shape: PanelPopupShape
    @Environment(\.panelSimulatesGlass) private var simulatesGlass
    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        Group {
            if simulatesGlass {
                content
                    .background(standIn, in: shape)
                    .overlay { shape.stroke(edge, lineWidth: 0.5) }
            } else {
                content
                    .background(Color(nsColor: .windowBackgroundColor).opacity(0.45), in: shape)
                    .glassEffect(.regular, in: shape)
            }
        }
        .shadow(color: .black.opacity(colorScheme == .dark ? 0.45 : 0.22), radius: 14, y: 5)
    }

    private var standIn: Color {
        colorScheme == .dark ? Color(white: 0.2) : Color(white: 0.985)
    }

    private var edge: Color {
        colorScheme == .dark ? Color.white.opacity(0.18) : Color.black.opacity(0.1)
    }
}

/// Un rectangle arrondi, avec au besoin une pointe au milieu de son bord inférieur, comme celle d'un
/// popover. La pointe est comprise dans le cadre : le contenu se décale d'autant.
struct PanelPopupShape: Shape {
    var cornerRadius: CGFloat
    /// 0 pour une carte sans pointe.
    var beakHeight: CGFloat

    func path(in rect: CGRect) -> Path {
        let body = CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: rect.height - beakHeight)
        let card = Path(roundedRect: body, cornerRadius: cornerRadius, style: .continuous)
        guard beakHeight > 0 else { return card }

        let halfWidth = beakHeight * 1.25
        let tip = CGPoint(x: rect.midX, y: rect.maxY)
        var beak = Path()
        // Un point au-dessus du bord : l'union ne laisse pas de couture entre la carte et la pointe.
        beak.move(to: CGPoint(x: tip.x - halfWidth, y: body.maxY - 1))
        beak.addLine(to: CGPoint(x: tip.x - halfWidth, y: body.maxY))
        beak.addArc(
            tangent1End: tip, tangent2End: CGPoint(x: tip.x + halfWidth, y: body.maxY), radius: 2.5
        )
        beak.addLine(to: CGPoint(x: tip.x + halfWidth, y: body.maxY))
        beak.addLine(to: CGPoint(x: tip.x + halfWidth, y: body.maxY - 1))
        beak.closeSubpath()
        return card.union(beak)
    }
}
