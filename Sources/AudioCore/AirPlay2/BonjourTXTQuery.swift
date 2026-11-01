import Foundation
import dnssd

/// Lecture d'un enregistrement TXT Bonjour via l'API `dns_sd` historique.
///
/// ## Pourquoi ne pas se contenter de Network framework
///
/// `NWBrowser` sait rendre le TXT (`bonjourWithTXTRecord`), mais il l'**analyse** au
/// passage — et **écarte purement et simplement tout service dont l'enregistrement ne lui
/// convient pas**. Le service n'apparaît alors pas du tout dans les résultats : aucune
/// erreur, aucun avertissement, juste une liste vide.
///
/// C'est exactement ce que fait le mock `airplay2-receiver` : `dns-sd -B _airplay._tcp` le
/// voit, `NWBrowser` en mode `.bonjour` le voit, mais `NWBrowser` en mode
/// `.bonjourWithTXTRecord` renvoie **zéro résultat** — alors que le même code rend bien le
/// service RAOP de shairport-sync. Vérifié en isolant les deux descripteurs côte à côte.
///
/// La parade retenue : parcourir **sans** TXT, puis lire le TXT par cette requête DNS
/// dédiée. Elle rend l'enregistrement brut, sans jugement sur sa forme — comme `dns-sd`.
///
/// L'intérêt dépasse le mock : les bits de fonctionnalité (`features`) et la clé publique
/// (`pk`) du récepteur ne sont lisibles que là, et un récepteur matériel dont le TXT
/// déplairait à Network framework deviendrait autrement invisible sans explication.
///
/// ## Gestion mémoire
///
/// Invariant section 12 : le `DNSServiceRef` est créé ici et libéré dans tous les chemins de
/// sortie, y compris en cas d'échec ou de délai dépassé. Aucun pointeur C ne sort de ce type.
enum BonjourTXTQuery {

    /// Nom pleinement qualifié d'un service, au format qu'attend `dns_sd`.
    ///
    /// Par `DNSServiceConstructFullName` et non par concaténation : un point ou une barre
    /// oblique inverse dans le nom d'instance doivent être échappés. « St. Louis » concaténé donnerait
    /// un enregistrement introuvable, un TXT vide sans erreur, et donc un appareil aux capacités
    /// inconnues.
    ///
    /// - Parameters:
    ///   - type: `_airplay._tcp`, avec ou sans point final.
    ///   - domain: `local.`, avec ou sans point final.
    static func fullName(instance: String, type: String, domain: String) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(kDNSServiceMaxDomainName))
        let status = DNSServiceConstructFullName(&buffer, instance, type, domain)
        guard status == kDNSServiceErr_NoError else { return nil }
        return String(cString: buffer)
    }

    /// Version asynchrone de ``lookup(fullName:timeout:)``.
    ///
    /// L'attente sur le socket bloque son fil : elle n'a rien à faire sur le pool coopératif de
    /// Swift Concurrency, où quelques services muets suffiraient à immobiliser tous les acteurs
    /// du processus — dont les senders.
    static func lookup(fullName: String, timeout: TimeInterval = 3) async -> [String: String] {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let result: [String: String] = lookup(fullName: fullName, timeout: timeout)
                continuation.resume(returning: result)
            }
        }
    }

    /// Interroge le TXT de `fullName` et renvoie ses paires clé/valeur, clés en minuscules.
    ///
    /// Bloque le fil appelant jusqu'à la réponse ou l'échéance.
    ///
    /// - Parameter fullName: nom pleinement qualifié du service, par exemple
    ///   `ApTV-HomePod-Mock._airplay._tcp.local.`, voir ``fullName(instance:type:domain:)``.
    /// - Returns: le TXT, ou un dictionnaire vide si la requête n'aboutit pas dans le délai.
    ///   Un TXT absent n'est pas une erreur : c'est à l'appelant de juger des clés manquantes.
    static func lookup(fullName: String, timeout: TimeInterval = 3) -> [String: String] {
        let collector = Collector()

        var serviceRef: DNSServiceRef?
        let status = DNSServiceQueryRecord(
            &serviceRef,
            kDNSServiceFlagsTimeout,
            0,  // toutes les interfaces
            fullName,
            UInt16(kDNSServiceType_TXT),
            UInt16(kDNSServiceClass_IN),
            { _, flags, _, errorCode, _, _, _, rdlen, rdata, _, context in
                guard let context else { return }
                let collector = Unmanaged<Collector>.fromOpaque(context).takeUnretainedValue()
                guard errorCode == kDNSServiceErr_NoError else {
                    collector.markFailed()
                    return
                }
                // Sans ce drapeau, le callback annonce la disparition de l'enregistrement.
                guard flags & kDNSServiceFlagsAdd != 0, let rdata else { return }
                collector.absorb(Data(bytes: rdata, count: Int(rdlen)))
            },
            Unmanaged.passUnretained(collector).toOpaque()
        )

        guard status == kDNSServiceErr_NoError, let serviceRef else {
            return [:]
        }
        // Libération garantie quel que soit le chemin de sortie.
        defer { DNSServiceRefDeallocate(serviceRef) }

        let socket = DNSServiceRefSockFD(serviceRef)
        guard socket >= 0 else { return [:] }

        // `poll` plutôt que `select` : l'échéance y est exprimée en millisecondes, là où le
        // `timeval` tronqué à la seconde rendait la main aussitôt sous la seconde restante, et il
        // n'a pas la limite de `FD_SETSIZE` — un processus aux nombreux sockets ouverts perdait
        // sinon sa réponse sans erreur.
        var descriptor = pollfd(fd: socket, events: Int16(POLLIN), revents: 0)
        let deadline = Date().addingTimeInterval(timeout)
        while !collector.hasResult, !collector.hasFailed {
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0 else { break }
            let ready = poll(&descriptor, 1, Int32((remaining * 1_000).rounded(.up)))
            if ready < 0, errno == EINTR { continue }
            guard ready > 0 else { break }
            guard DNSServiceProcessResult(serviceRef) == kDNSServiceErr_NoError else { break }
        }

        return collector.txt
    }

    /// Décode le format TXT du DNS : une suite de chaînes préfixées de leur longueur sur un octet,
    /// chacune de la forme `clé=valeur`.
    ///
    /// Une longueur qui dépasse l'enregistrement arrête la lecture sans la faire échouer : ce qui
    /// précède reste exploitable. Une chaîne vide est ignorée, conformément à la RFC 6763.
    static func parse(record: Data) -> [String: String] {
        var parsed: [String: String] = [:]
        var index = record.startIndex

        while index < record.endIndex {
            let length = Int(record[index])
            let valueStart = index + 1
            guard valueStart + length <= record.endIndex else { break }

            let entry = record[valueStart..<(valueStart + length)]
            if let text = String(data: Data(entry), encoding: .utf8), !text.isEmpty {
                if let separator = text.firstIndex(of: "=") {
                    let key = String(text[text.startIndex..<separator]).lowercased()
                    parsed[key] = String(text[text.index(after: separator)...])
                } else {
                    // Clé sans valeur : le format l'autorise.
                    parsed[text.lowercased()] = ""
                }
            }
            index = valueStart + length
        }
        return parsed
    }

    /// Accumule le résultat du callback C. `final class` : le callback reçoit un pointeur
    /// opaque, il lui faut une référence stable.
    private final class Collector {
        private(set) var txt: [String: String] = [:]
        private(set) var hasResult = false
        private(set) var hasFailed = false

        func absorb(_ record: Data) {
            txt = BonjourTXTQuery.parse(record: record)
            hasResult = true
        }

        /// `dns_sd` a signalé une erreur (dont son propre délai) : inutile d'attendre davantage.
        func markFailed() {
            hasFailed = true
        }
    }
}
