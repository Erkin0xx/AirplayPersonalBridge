//
//  RotaryKnob.swift
//  AirplayPersonalBridge
//

import SwiftUI

/// Le bouton rotatif de volume master (CDC section 9).
///
/// Le geste est **vertical**, pas circulaire, alors que le rendu est un cadran : suivre
/// l'angle du curseur oblige à viser le centre et rend le réglage fin impossible dès que
/// le pointeur s'en approche. Tous les boutons rotatifs logiciels sérieux font ce choix ;
/// le cadran ne sert qu'à lire la valeur.
struct RotaryKnob: View {
    @Binding var value: Double
    let range: ClosedRange<Double>
    var diameter: CGFloat = 88
    /// Valeur rétablie au double-clic.
    var resetValue: Double?

    /// Course du geste, en points, pour parcourir toute la plage.
    private let travel: CGFloat = 180
    /// Arc utile du cadran : une ouverture en bas marque sans ambiguïté les deux extrêmes.
    private let sweep: Double = 280

    @State private var valueAtGestureStart: Double?

    /// Origine de l'arc, comptée depuis 3 heures dans le sens horaire — c'est ainsi que
    /// `Circle` construit son tracé, et c'est la seule référence angulaire du fichier.
    /// Tout ce qui tourne ici part de cette valeur ; en dériver une seconde par un
    /// `rotationEffect` sur le conteneur ferait tourner le repère deux fois.
    private var startAngle: Double { 90 + (360 - sweep) / 2 }

    private var fraction: Double {
        let span = range.upperBound - range.lowerBound
        guard span > 0 else { return 0 }
        return min(max((value - range.lowerBound) / span, 0), 1)
    }

    var body: some View {
        ZStack {
            Circle()
                .trim(from: 0, to: sweep / 360)
                .stroke(.quaternary, style: .init(lineWidth: 7, lineCap: .round))
                .rotationEffect(.degrees(startAngle))

            Circle()
                .trim(from: 0, to: sweep / 360 * fraction)
                .stroke(.tint, style: .init(lineWidth: 7, lineCap: .round))
                .rotationEffect(.degrees(startAngle))

            Circle()
                .fill(.quinary)
                .padding(12)

            // Le repère pointe vers le haut au repos : il faut donc les 90° qui l'amènent
            // sur l'origine de l'arc, puis la fraction parcourue.
            Capsule()
                .fill(.primary)
                .frame(width: 3, height: diameter * 0.20)
                .offset(y: -diameter * 0.24)
                .rotationEffect(.degrees(startAngle + 90 + sweep * fraction))
        }
        .frame(width: diameter, height: diameter)
        .contentShape(Circle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { drag in
                    let start = valueAtGestureStart ?? value
                    valueAtGestureStart = start
                    let span = range.upperBound - range.lowerBound
                    // Vers le haut = plus fort, d'où le signe : l'axe des ordonnées
                    // descend à l'écran.
                    let delta = Double(-drag.translation.height / travel) * span
                    value = min(max(start + delta, range.lowerBound), range.upperBound)
                }
                .onEnded { _ in valueAtGestureStart = nil }
        )
        .onTapGesture(count: 2) {
            if let resetValue { value = min(max(resetValue, range.lowerBound), range.upperBound) }
        }
        .accessibilityElement()
        .accessibilityLabel("Volume master")
        .accessibilityValue(String(format: "%.0f décibels", value))
        .accessibilityAdjustableAction { direction in
            let step = (range.upperBound - range.lowerBound) / 40
            switch direction {
            case .increment: value = min(value + step, range.upperBound)
            case .decrement: value = max(value - step, range.lowerBound)
            @unknown default: break
            }
        }
    }
}

#Preview {
    @Previewable @State var value: Double = -12
    VStack(spacing: 16) {
        RotaryKnob(value: $value, range: -60...0, resetValue: -12)
        Text(String(format: "%.0f dB", value)).monospacedDigit()
        // Les extrêmes doivent tomber pile sur les deux bouts de l'arc : c'est là que le
        // décalage angulaire se voyait.
        HStack {
            Button("Min") { value = -60 }
            Button("Max") { value = 0 }
        }
    }
    .padding(40)
}
