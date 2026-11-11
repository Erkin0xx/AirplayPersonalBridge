import CoreGraphics
import Foundation
import Testing

@testable import BridgeApp

/// Ce que la vue « Console » calcule hors de ses vues : la course de ses curseurs verticaux, sa mise en
/// page, et ce que dit une tuile.
@Suite("Vue Console — curseurs, mise en page et tuiles")
struct ConsoleViewTests {
    private let trim = BridgeSettings.Limits.trimDB
    private let master = BridgeSettings.Limits.masterDB
    private let step = PanelToneStep.step

    // MARK: - Curseur vertical

    private func value(
        atY y: CGFloat, height: CGFloat = 300, floor: CGFloat = 26, in range: ClosedRange<Double>? = nil,
        step: Double? = PanelToneStep.step
    ) -> Double? {
        ConsoleFaderScale.value(atY: y, trackHeight: height, floor: floor, in: range ?? trim, step: step)
    }

    @Test("Le haut du rail vaut le maximum, le bas le minimum, et rien n'en sort")
    func faderClampsAtBothEnds() {
        #expect(value(atY: 0) == trim.upperBound)
        #expect(value(atY: 300) == trim.lowerBound)
        // La main sort du rail pendant un glissement : la valeur reste aux bornes.
        #expect(value(atY: -500) == trim.upperBound)
        #expect(value(atY: 5_000) == trim.lowerBound)
        // Dans le socle, sous la course : toujours le minimum.
        #expect(value(atY: 290) == trim.lowerBound)
        #expect(value(atY: 274) == trim.lowerBound)
    }

    @Test("Le milieu de la course d'une enceinte vaut 0 dB")
    func faderMiddleIsUnity() {
        // 300 points de rail, 26 de socle : la course fait 274 points, son milieu est à 137 du haut.
        #expect(value(atY: 137) == 0)
    }

    @Test("Le volume d'une enceinte va par demi-décibel")
    func faderRoundsToHalfDecibels() {
        var y: CGFloat = -10
        while y <= 310 {
            let result = value(atY: y)
            #expect(result != nil)
            if let result {
                #expect((result * 2).rounded() == result * 2, "\(result) dB à y = \(y)")
                #expect(trim.contains(result))
            }
            y += 0.37
        }
        // Un point quelconque de la course ne tombe pas de lui-même sur un demi-décibel.
        #expect(value(atY: 100, step: nil) != value(atY: 100))
    }

    @Test("Monter la main ne baisse jamais la valeur, et la course entière est parcourue")
    func faderIsMonotonic() {
        for step in [PanelToneStep.step, nil] as [Double?] {
            var previous = -Double.infinity
            var seen: Set<Double> = []
            var y: CGFloat = 320
            while y >= -20 {
                let result = value(atY: y, step: step) ?? .nan
                #expect(result >= previous, "y = \(y)")
                previous = result
                seen.insert(result)
                y -= 0.25
            }
            #expect(seen.contains(trim.lowerBound))
            #expect(seen.contains(trim.upperBound))
            // Par demi-décibel, de −12 à +12 : 49 valeurs, toutes atteintes.
            if step != nil { #expect(seen.count == 49) }
        }
    }

    @Test("Le volume général reste continu, linéaire en dB")
    func masterFaderIsContinuous() {
        // 400 points de rail, 58 de socle : 342 de course pour 60 dB.
        let quarter = value(atY: 342 * 0.75, height: 400, floor: 58, in: master, step: nil)
        #expect(abs((quarter ?? .nan) - -45) < 1e-9)
        let level = value(atY: 342 * 0.4, height: 400, floor: 58, in: master, step: nil)
        #expect(abs((level ?? .nan) - BridgeState.defaultMasterVolumeDB) < 1e-9)
    }

    @Test("Le remplissage et la main se répondent : poser la main sur son bord rend la même valeur")
    func fillHeightRoundTrip() {
        let height: CGFloat = 280
        let floor: CGFloat = 26
        var decibels = trim.lowerBound
        while decibels <= trim.upperBound {
            let fill = ConsoleFaderScale.fillHeight(for: decibels, in: trim, trackHeight: height, floor: floor)
            #expect(fill >= floor && fill <= height)
            #expect(value(atY: height - fill, height: height, floor: floor) == decibels)
            decibels += step
        }
        // Au minimum il reste le socle ; au maximum le rail est plein.
        #expect(ConsoleFaderScale.fillHeight(for: trim.lowerBound, in: trim, trackHeight: height, floor: floor) == floor)
        #expect(ConsoleFaderScale.fillHeight(for: trim.upperBound, in: trim, trackHeight: height, floor: floor) == height)
        // Une valeur hors bornes (un fichier de réglages d'une autre version) ne déborde pas du rail.
        #expect(ConsoleFaderScale.fillHeight(for: 40, in: trim, trackHeight: height, floor: floor) == height)
        #expect(ConsoleFaderScale.fillHeight(for: -40, in: trim, trackHeight: height, floor: floor) == floor)
        #expect(ConsoleFaderScale.fraction(of: .nan, in: trim) == 0)
    }

    @Test("Un rail sans course ne désigne aucune valeur : le réglage ne bouge pas")
    func degenerateTrack() {
        #expect(value(atY: 10, height: 26) == nil)
        #expect(value(atY: 10, height: 0) == nil)
        #expect(value(atY: .nan) == nil)
        // Et son remplissage ne dépasse pas le rail.
        #expect(ConsoleFaderScale.fillHeight(for: 0, in: trim, trackHeight: 10, floor: 26) == 10)
    }

    @Test("Les flèches avancent d'un pas et s'arrêtent aux bornes")
    func keyboardSteps() {
        #expect(ConsoleFaderScale.stepped(0, by: step, in: trim, step: step) == 0.5)
        #expect(ConsoleFaderScale.stepped(0, by: -step, in: trim, step: step) == -0.5)
        #expect(ConsoleFaderScale.stepped(12, by: step, in: trim, step: step) == 12)
        #expect(ConsoleFaderScale.stepped(-12, by: -step, in: trim, step: step) == -12)
        // Une valeur héritée hors du pas y revient au premier geste.
        #expect(ConsoleFaderScale.stepped(1.3, by: step, in: trim, step: step) == 2)
        // Le général : 1,5 dB par flèche, sans pas imposé.
        #expect(ConsoleFaderScale.stepped(-24, by: 1.5, in: master, step: nil) == -22.5)
        #expect(ConsoleFaderScale.stepped(-0.5, by: 1.5, in: master, step: nil) == 0)
        #expect(ConsoleFaderScale.stepped(-59.5, by: -1.5, in: master, step: nil) == -60)
    }

    @Test("Saisir le curseur du général rétablit un son coupé, même sans changer de niveau")
    func masterFaderUnmutes() {
        let state = BridgeState.preview(.streaming)
        state.isMuted = true
        let binding = TransportBar.master(of: state)
        binding.wrappedValue = state.masterVolumeDB
        #expect(!state.isMuted)
        #expect(state.masterVolumeDB == BridgeState.defaultMasterVolumeDB)
        binding.wrappedValue = -30
        #expect(state.masterVolumeDB == -30)
        #expect(binding.wrappedValue == -30)
    }

    // MARK: - Mise en page

    private let minimum = CGSize(width: 960, height: 568)

    @Test("L'installation de Baptiste tient dans la plus petite fenêtre, sans défiler")
    func fourSpeakersFitTheMinimumWindow() {
        let layout = ConsoleLayout.make(size: minimum, speakerCount: 4)
        #expect(!layout.scrolls)
        #expect(layout.rowWidth <= minimum.width - 2 * ConsoleMetrics.margin)
        // La barre de lecture prend la largeur de la rangée, sans descendre sous la sienne.
        #expect(layout.columnWidth == max(layout.rowWidth, ConsoleLayout.minimumColumnWidth))
    }

    @Test("Chaque enceinte ajoute une tuile et son intervalle ; la rangée défile quand elle déborde")
    func rowGrowsAndScrolls() {
        var count = 1
        while count <= 8 {
            let width = ConsoleLayout.rowWidth(speakerCount: count)
            if count > 1 {
                #expect(
                    width - ConsoleLayout.rowWidth(speakerCount: count - 1)
                        == ConsoleMetrics.speakerWidth + ConsoleMetrics.tileSpacing
                )
            }
            let layout = ConsoleLayout.make(size: minimum, speakerCount: count)
            #expect(layout.scrolls == (width > minimum.width - 2 * ConsoleMetrics.margin))
            // L'en-tête ne déborde jamais de la fenêtre, que la rangée défile ou non.
            #expect(layout.columnWidth <= minimum.width - 2 * ConsoleMetrics.margin)
            count += 1
        }
        #expect(ConsoleLayout.make(size: minimum, speakerCount: 6).scrolls)
        #expect(!ConsoleLayout.make(size: CGSize(width: 1400, height: 848), speakerCount: 6).scrolls)
    }

    @Test("Une ou deux enceintes : la barre de lecture garde la place de son titre et de sa commande")
    func narrowRowKeepsAWideHeader() {
        let layout = ConsoleLayout.make(size: CGSize(width: 1200, height: 700), speakerCount: 1)
        #expect(layout.rowWidth < ConsoleLayout.minimumColumnWidth)
        #expect(layout.columnWidth == ConsoleLayout.minimumColumnWidth)
    }

    @Test("Sans enceinte, une tuile d'attente tient leur place")
    func emptyRow() {
        let empty = ConsoleLayout.rowWidth(speakerCount: 0)
        #expect(empty == ConsoleMetrics.placeholderWidth)
        #expect(!ConsoleLayout.make(size: minimum, speakerCount: 0).scrolls)
        // Un compte absurde ne retire rien à la rangée.
        #expect(ConsoleLayout.rowWidth(speakerCount: -3) == empty)
    }

    @Test("Les tuiles grandissent avec la fenêtre, jusqu'à un plafond")
    func tileHeightIsBounded() {
        let small = ConsoleLayout.make(size: minimum, speakerCount: 4).maxTileHeight
        let large = ConsoleLayout.make(size: CGSize(width: 1400, height: 848), speakerCount: 4).maxTileHeight
        let huge = ConsoleLayout.make(size: CGSize(width: 3000, height: 2000), speakerCount: 4).maxTileHeight
        #expect(small >= ConsoleLayout.minimumTileHeight)
        #expect(small < large)
        #expect(large <= ConsoleLayout.tileHeightCeiling)
        #expect(huge == ConsoleLayout.tileHeightCeiling)
        // Une fenêtre basse laisse descendre les tuiles sous l'ancien plancher, jusqu'à la tuile simplifiée.
        #expect(ConsoleLayout.make(size: .zero, speakerCount: 4).maxTileHeight == ConsoleLayout.smallestTileHeight)
        #expect(ConsoleLayout.smallestTileHeight < ConsoleLayout.minimumTileHeight)
    }

    // MARK: - Tuiles

    @Test("Le témoin ne bouge que pour une enceinte cochée qui reçoit un son audible")
    func liveIndicator() {
        func kind(
            _ connection: OutputConnectionState, enabled: Bool = true, muted: Bool = false, audible: Bool = true
        ) -> ConsoleTileIndicator {
            ConsoleTileIndicator.kind(
                connection: connection, isEnabled: enabled, isMuted: muted, isAudible: audible
            )
        }
        #expect(kind(.streaming) == .live)
        #expect(kind(.streaming, muted: true) == .none)
        #expect(kind(.streaming, audible: false) == .none)
        #expect(kind(.streaming, enabled: false) == .none)
        #expect(kind(.idle) == .none)
        #expect(kind(.connecting) == .busy)
        #expect(kind(.reconnecting(message: nil)) == .busy)
        #expect(kind(.waiting(attempt: 2, message: "absente", nextAttemptAt: nil)) == .busy)
        #expect(kind(.failed("refus")) == .failed)
        // Décochée, une session qui s'attarde ne fait tourner aucun témoin.
        #expect(kind(.connecting, enabled: false) == .none)
        #expect(kind(.failed("refus"), enabled: false) == .none)
    }

    @Test("La légende d'une tuile dit l'état en un mot, et sa gravité")
    func tileCaption() {
        func caption(
            _ connection: OutputConnectionState, enabled: Bool = true, muted: Bool = false,
            statusLine: (text: String, tone: OutputStatusTone)? = nil
        ) -> (text: String, tone: OutputStatusTone) {
            ConsoleTileCaption.make(
                connection: connection, isEnabled: enabled, isMuted: muted, proto: "AirPlay 2",
                statusLine: statusLine
            )
        }
        #expect(caption(.streaming) == ("Diffusion", .muted))
        #expect(caption(.streaming, muted: true) == ("Coupée", .muted))
        #expect(caption(.idle) == ("Prête", .muted))
        #expect(caption(.connecting) == ("Connexion…", .muted))
        #expect(caption(.reconnecting(message: "coupure")) == ("Reconnexion…", .warning))
        #expect(caption(.waiting(attempt: 1, message: "absente", nextAttemptAt: nil)) == ("En attente", .warning))
        #expect(caption(.failed("refus")) == ("Échec", .critical))
        #expect(caption(.idle, enabled: false) == ("AirPlay 2", .muted))
        // Cochée et au repos, une enceinte que le réseau ne voit pas ne se dit pas « Prête ».
        #expect(caption(.idle, statusLine: ("Hors ligne", .warning)) == ("Hors ligne", .warning))
        // Le message du moteur ne tient pas dans une tuile : la légende reste un mot.
        #expect(caption(.failed("refus"), statusLine: ("refus", .critical)) == ("Échec", .critical))
        // Décochée, elle ne dit que ce qu'elle est, quoi qu'annonce le réseau.
        #expect(caption(.idle, enabled: false, statusLine: ("Hors ligne", .warning)) == ("AirPlay 2", .muted))
    }

    @Test("Sous la console, seuls les messages du moteur que la légende ne dit pas")
    func speakerMessages() {
        func detail(
            _ connection: OutputConnectionState, enabled: Bool = true, heldBack: Bool = false
        ) -> (text: String, tone: OutputStatusTone)? {
            ConsoleTileCaption.detail(connection: connection, isEnabled: enabled, isHeldBack: heldBack)
        }
        #expect(detail(.failed("refus du SETUP")) ?? ("", .muted) == ("refus du SETUP", .critical))
        #expect(
            detail(.waiting(attempt: 3, message: "injoignable", nextAttemptAt: nil)) ?? ("", .muted)
                == ("injoignable", .warning)
        )
        #expect(detail(.reconnecting(message: "session perdue")) ?? ("", .muted) == ("session perdue", .warning))
        // Rien de plus à dire que la légende.
        #expect(detail(.reconnecting(message: nil)) == nil)
        #expect(detail(.streaming) == nil)
        #expect(detail(.connecting) == nil)
        #expect(detail(.idle) == nil)
        // Décochée, ou déjà expliquée dans sa tuile en retrait : pas de doublon.
        #expect(detail(.failed("refus"), enabled: false) == nil)
        #expect(detail(.failed("refus"), heldBack: true) == nil)
    }

    @Test("Les scènes d'essai : une alerte donne deux messages, l'Apple TV reste en retrait")
    func scenes() {
        let trouble = BridgeState.preview(.trouble)
        let messages = trouble.outputs.compactMap { output in
            ConsoleTileCaption.detail(
                connection: output.connection, isEnabled: output.isEnabled, isHeldBack: output.consoleIsHeldBack
            ).map { _ in output.displayName }
        }
        #expect(messages == ["Geneva", "Salon (2)"])
        #expect(trouble.outputs.filter(\.consoleIsHeldBack).map(\.displayName) == ["Apple TV Salon"])
        // Une enceinte signalée qui diffuse malgré tout n'est plus en retrait.
        let appleTV = trouble.outputs.first { $0.displayName == "Apple TV Salon" }
        appleTV?.connection = .streaming
        #expect(appleTV?.consoleIsHeldBack == false)
    }

    @Test("Chaque raison de retrait a son symbole")
    func heldBackSymbols() {
        #expect(ConsoleHeldBack.symbol(for: .pairingRequired) == "lock")
        #expect(ConsoleHeldBack.symbol(for: .passwordRequired) == "lock")
        #expect(ConsoleHeldBack.symbol(for: .unsupportedEncryption) == "exclamationmark.triangle")
        #expect(ConsoleHeldBack.symbol(for: .unsupportedFormat) == "exclamationmark.triangle")
        #expect(ConsoleHeldBack.symbol(for: nil) == "exclamationmark.triangle")
    }

    @Test("Les barres du témoin restent dans leur cadre, et bougent")
    func liveBars() {
        var seen: [Set<Int>] = Array(repeating: [], count: ConsoleLiveBars.barCount)
        var samples = 0
        var uneven = 0
        var time = 0.0
        while time < 20 {
            let levels = ConsoleLiveBars.levels(at: time)
            #expect(levels.count == ConsoleLiveBars.barCount)
            for (index, level) in levels.enumerated() {
                #expect(level >= ConsoleLiveBars.minimumLevel - 1e-9 && level <= 1 + 1e-9)
                seen[index].insert(Int(level * 10))
            }
            samples += 1
            if (levels.max() ?? 0) - (levels.min() ?? 0) > 0.15 { uneven += 1 }
            time += 0.05
        }
        // Chaque barre parcourt presque toute sa hauteur.
        for values in seen { #expect(values.count >= 6) }
        // Les trois ne montent pas ensemble : ce serait un clignotement, pas un témoin.
        #expect(uneven * 10 >= samples * 8)
        #expect(ConsoleLiveBars.restLevels.count == ConsoleLiveBars.barCount)
    }
}

/// Les avertissements de la console, en petit sous la barre de lecture.
@Suite("Console — avertissements")
struct ConsoleWarningsTests {
    @Test("Le démarrage, puis la capture, puis les enceintes en peine, dans l'ordre des tuiles")
    func order() {
        let state = BridgeState.preview(.trouble)
        let speakers = PanelSpeakerOrder.sorted(state.outputs)
        let warnings = ConsoleWarning.list(for: state, speakers: speakers)
        let subjects = warnings.map(\.subject)
        if let alert = state.captureAlert {
            #expect(subjects.first == alert.title)
            #expect(warnings.first?.settingsPane != nil || alert.settingsPane == nil)
        }
        // Une enceinte en échec ou en attente a sa ligne ; une enceinte qui diffuse n'en a pas.
        for output in speakers {
            let expected = ConsoleTileCaption.detail(
                connection: output.connection, isEnabled: output.isEnabled, isHeldBack: output.consoleIsHeldBack
            )
            #expect(subjects.contains(output.displayName) == (expected != nil))
        }
        #expect(Set(warnings.map(\.id)).count == warnings.count)
    }

    @Test("Rien à signaler : aucune ligne, mais la place reste réservée")
    func nothingToSay() {
        let state = BridgeState.preview(.streaming)
        #expect(ConsoleWarning.list(for: state, speakers: PanelSpeakerOrder.sorted(state.outputs)).isEmpty)
        #expect(ConsoleWarnings.reservedHeight >= CGFloat(ConsoleWarnings.visibleLines) * ConsoleWarnings.lineHeight)
    }
}
