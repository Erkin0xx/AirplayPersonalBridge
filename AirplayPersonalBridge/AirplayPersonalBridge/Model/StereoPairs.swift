//
//  StereoPairs.swift
//  AirplayPersonalBridge
//

import Foundation

/// Les paires stéréo de HomePod : deux sorties, deux sessions, mais un seul geste et une seule ouverture.
///
/// ## Le défaut corrigé
///
/// « Salon » et « Salon (2) » forment une paire stéréo : même `tsid` dans leur TXT `_airplay._tcp`. Un
/// membre adressé seul ne joue que **son** canal, et la vraie stéréo exige une session vers chacun (ADR
/// 009). Or **deux sessions ouvertes à des moments différents s'expulsent en boucle** (coupures toutes
/// les ~10 s, entendu le 2026-11-02), quand deux sessions ouvertes ensemble tiennent une heure sans perte.
/// Le démarrage d'une diffusion les ouvrait bien ensemble ; cocher un membre pendant que l'autre jouait,
/// ou le décocher puis le recocher, reproduisait l'ouverture décalée.
///
/// ## La règle
///
/// - **Un geste vaut pour toute la paire** (`BridgeState.setEnabled(_:for:)`) : cocher ou décocher un
///   membre coche ou décoche les autres. Chacun garde sa rangée, son volume et son silence (ADR 012) :
///   c'est un sender par membre, et rien ne change sur le fil.
/// - **Une paire entre en session d'un seul tenant** (`sessionPlan(for:)`) : ses membres cochés sont
///   confiés au moteur dans le même tour de la boucle, jamais l'un sans l'autre. Si l'un diffuse déjà
///   quand un autre arrive (réglages qui n'en cochaient qu'un, membre revenu sur le réseau après coup),
///   celui qui diffuse sort, et toute la paire rentre ensemble au tour suivant. Seuls ses membres sont
///   relancés : ni les autres sorties ni la capture ne bougent.
///
/// ## Ce qui reste isolé, volontairement
///
/// **Une reconnexion après une panne ne relance jamais l'autre membre.** C'est l'invariant du CDC
/// section 12 : une panne sur une sortie n'interrompt jamais l'autre, et le sender concerné se reconnecte
/// seul. Une reconnexion se passe dans le moteur, la sortie restant en session : elle n'est donc jamais
/// une arrivée, et ce plan ne la voit pas. Le 2026-11-02, les expulsions mutuelles nées d'une ouverture
/// décalée se sont d'ailleurs résorbées sans relance de l'app. Ne pas « corriger » cet écart : relancer
/// la paire à chaque reconnexion couperait le membre sain à chaque hoquet de l'autre.
///
/// De même, un membre coché qui ne répond pas est attendu par le moteur comme tout récepteur absent
/// (`waitingForReceiver`) : il est déjà en session, et le moteur l'ouvre seul dès qu'il répond. Seul un
/// membre que la liste n'avait plus (décoché puis disparu du réseau) revient par la découverte : il
/// arrive alors coché avec sa paire (`BridgeState.apply`), et c'est une arrivée.
enum StereoPairs {
    /// Ce que le plan doit savoir d'une sortie.
    struct SessionMember: Equatable {
        let id: String
        /// Le `tsid` de sa paire, s'il est connu (`OutputState.stereoPairKey`).
        let pairKey: String?
        let isEnabled: Bool
        /// Confiée au moteur.
        let isActive: Bool
        /// Une tâche du moteur la concerne encore : ajout, retrait (`TEARDOWN`) ou réglages.
        let isBusy: Bool
    }

    /// Ce que la boucle fait des paires ce tour-ci. Une sortie absente des deux ensembles suit la règle
    /// ordinaire : cochée et hors session, elle entre ; décochée et en session, elle sort.
    struct SessionPlan: Equatable {
        /// Cochées et hors session, mais retenues : un membre de leur paire diffuse encore ou n'est pas
        /// libre. Elles entreront toutes au même tour.
        var held: Set<String> = []
        /// En session, à retirer pour que toute la paire rentre ensemble.
        var leaving: Set<String> = []
    }

    /// Le plan d'un tour, pour les seules paires dont un membre coché attend d'entrer en session.
    ///
    /// Une paire dont tous les membres cochés sont déjà en session n'a rien à faire ici, même si l'un
    /// d'eux est en reconnexion ou en attente du réseau : voir « Ce qui reste isolé ».
    static func sessionPlan(for members: [SessionMember]) -> SessionPlan {
        var groups: [String: [SessionMember]] = [:]
        for member in members where member.isEnabled {
            guard let key = member.pairKey else { continue }
            groups[key, default: []].append(member)
        }

        var plan = SessionPlan()
        for group in groups.values where group.count > 1 {
            let joining = group.filter { !$0.isActive }
            guard !joining.isEmpty else { continue }
            let streaming = group.filter(\.isActive)
            if !streaming.isEmpty {
                plan.leaving.formUnion(streaming.map(\.id))
                plan.held.formUnion(joining.map(\.id))
            } else if group.contains(where: \.isBusy) {
                // Un `TEARDOWN` encore en cours : celle qui est libre partirait seule.
                plan.held.formUnion(joining.map(\.id))
            }
        }
        return plan
    }
}

extension StereoPairs {
    /// Les partenaires nommés pour une phrase : « Salon (2) », « A et B », « A, B et C ». `nil` sans
    /// partenaire.
    static func names(_ partners: [String]) -> String? {
        guard let last = partners.last else { return nil }
        let head = partners.dropLast()
        return head.isEmpty ? last : "\(head.joined(separator: ", ")) et \(last)"
    }
}

extension OutputState {
    /// La clé de sa paire stéréo : le `tsid` annoncé, s'il est connu et non vide. `nil` pour toute
    /// sortie RAOP, qui n'en annonce pas.
    var stereoPairKey: String? {
        guard let tightSyncIdentifier, !tightSyncIdentifier.isEmpty else { return nil }
        return tightSyncIdentifier
    }
}
