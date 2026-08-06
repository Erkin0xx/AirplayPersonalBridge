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
/// sortie, y compris en cas d'échec ou de délai dépassé.
enum BonjourTXTQuery {

    /// Interroge le TXT de `fullName` et renvoie ses paires clé/valeur, clés en minuscules.
    ///
    /// - Parameter fullName: nom pleinement qualifié du service, par exemple
    ///   `ApTV-HomePod-Mock._airplay._tcp.local.`
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
            { _, _, _, errorCode, _, _, _, rdlen, rdata, _, context in
                guard errorCode == kDNSServiceErr_NoError,
                    let context,
                    let rdata
                else { return }
                let collector = Unmanaged<Collector>.fromOpaque(context).takeUnretainedValue()
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

        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline, !collector.hasResult {
            var readSet = fd_set()
            fdZero(&readSet)
            fdSet(socket, &readSet)

            var remaining = timeval(
                tv_sec: Int(max(0, deadline.timeIntervalSinceNow)),
                tv_usec: 0
            )
            // Un TXT arrive typiquement en quelques millisecondes ; la boucle sert surtout
            // à ne pas bloquer indéfiniment si le service disparaît entre-temps.
            guard select(socket + 1, &readSet, nil, nil, &remaining) > 0 else { break }
            guard DNSServiceProcessResult(serviceRef) == kDNSServiceErr_NoError else { break }
        }

        return collector.txt
    }

    /// Accumule le résultat du callback C. `final class` : le callback reçoit un pointeur
    /// opaque, il lui faut une référence stable.
    private final class Collector {
        private(set) var txt: [String: String] = [:]
        private(set) var hasResult = false

        /// Décode le format TXT du DNS : une suite de chaînes préfixées de leur longueur
        /// sur un octet, chacune de la forme `clé=valeur`.
        func absorb(_ record: Data) {
            var parsed: [String: String] = [:]
            var index = record.startIndex

            while index < record.endIndex {
                let length = Int(record[index])
                let valueStart = index + 1
                guard length > 0, valueStart + length <= record.endIndex else { break }

                let entry = record[valueStart..<(valueStart + length)]
                if let text = String(data: Data(entry), encoding: .utf8) {
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

            txt = parsed
            hasResult = true
        }
    }

    // `FD_ZERO` et `FD_SET` sont des macros C, invisibles depuis Swift : il faut manipuler
    // le champ de bits à la main. Confiné ici, comme tout accès bas niveau.
    private static func fdZero(_ set: inout fd_set) {
        withUnsafeMutableBytes(of: &set) { $0.initializeMemory(as: UInt8.self, repeating: 0) }
    }

    private static func fdSet(_ descriptor: Int32, _ set: inout fd_set) {
        let bitsPerMask = Int32(MemoryLayout<Int32>.size * 8)
        let index = Int(descriptor / bitsPerMask)
        let bit = Int32(1) << (descriptor % bitsPerMask)
        withUnsafeMutableBytes(of: &set.fds_bits) { raw in
            let masks = raw.bindMemory(to: Int32.self)
            guard index < masks.count else { return }
            masks[index] |= bit
        }
    }
}
