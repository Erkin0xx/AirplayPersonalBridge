import Foundation

/// Dit si un processus audio est une application de l'utilisateur.
///
/// Sert à lever l'ambiguïté d'un silence strict (``ProcessTapCapture/isAudioExpected()``). Pour Core
/// Audio, « jouer » veut dire garder un flux de sortie ouvert : des démons système
/// (`com.apple.CoreSpeech`, relevé le 2026-11-09) et des outils de développement (les `python` des
/// mocks, le 2026-11-02) en gardent un, muet. Les compter faisait accuser l'autorisation alors que
/// rien ne jouait. Injecté (CDC section 13) : les tests décrivent des processus sans en lancer.
public protocol AudioProcessClassifying: Sendable {
    /// Hors temps réel : la réponse peut lire le disque.
    func isUserApplication(_ process: AudioProcessInfo) -> Bool
}

/// Classement d'après l'emplacement de l'exécutable, sans AppKit : le cœur ignore l'interface.
///
/// Une application de l'utilisateur est un exécutable logé dans une application `.app` qui s'affiche
/// dans le Dock, ni `LSUIElement` ni `LSBackgroundOnly` : le sens d'`activationPolicy == .regular`.
/// Trois règles, tirées des chemins relevés sur cette machine le 2026-11-09 :
///
/// - **le premier paquet du chemin décide, pas le dernier.** Un navigateur joue depuis un auxiliaire,
///   agent invisible logé dans l'application (`Dia.app/…/ArcCore.framework/Helpers/Browser Helper
///   (Aperitif).app`) : c'est Dia qui compte. À l'inverse, l'interpréteur Python est un `Python.app`
///   d'apparence ordinaire, logé dans `Python.framework` : un cadriciel n'est pas une application ;
/// - un démon (`CoreSpeech.framework/corespeechd`, `/usr/libexec/…`) ou un outil en ligne de commande
///   (`afplay`, `shairport-sync`) n'est logé dans aucune application, et ne compte pas ;
/// - **WebKit fait exception** : Safari joue depuis `com.apple.WebKit.GPU`, service XPC du cadriciel
///   lancé par `launchd`, dont ni le chemin ni le parent ne mènent à Safari. Il ne tourne que pour une
///   application qui affiche du web : il compte comme elle.
///
/// `NSRunningApplication(processIdentifier:)` ne ferait pas mieux : un auxiliaire de navigateur n'y
/// figure pas (voir `CaptureSource.owningApplication`, côté app), et remonter les parents rattacherait
/// à Terminal un `python` lancé depuis un terminal.
public struct BundleLocationClassifier: AudioProcessClassifying {
    public init() {}

    public func isUserApplication(_ process: AudioProcessInfo) -> Bool {
        if process.bundleID.hasPrefix(Self.webKitServicePrefix) { return true }
        guard let path = process.executablePath,
            let application = Self.outermostApplication(containing: path)
        else { return false }
        return Self.showsInDock(application)
    }

    /// Les services XPC de WebKit : `com.apple.WebKit.GPU`, `.WebContent`, `.Networking`.
    static let webKitServicePrefix = "com.apple.WebKit."

    /// Extensions de paquet. Une version (`Versions/157.0.8103.38`, `python@3.14/3.14.6`) porte aussi
    /// un point : seule une extension connue fait un paquet.
    private static let bundleExtensions: Set<String> = [
        "app", "framework", "xpc", "appex", "bundle", "plugin",
    ]

    /// L'application `.app` la plus extérieure qui loge l'exécutable, `nil` si le premier paquet du
    /// chemin n'en est pas une, ou s'il n'y a aucun paquet.
    static func outermostApplication(containing executablePath: String) -> URL? {
        // Le dernier élément est l'exécutable lui-même, pas un dossier qui le loge.
        let folders = executablePath.split(separator: "/").dropLast()
        var prefix = ""
        for folder in folders {
            prefix += "/" + folder
            let pathExtension = (String(folder) as NSString).pathExtension.lowercased()
            guard bundleExtensions.contains(pathExtension) else { continue }
            return pathExtension == "app" ? URL(fileURLWithPath: prefix, isDirectory: true) : nil
        }
        return nil
    }

    /// Ni `LSUIElement` (agent de la barre des menus, auxiliaire) ni `LSBackgroundOnly`. Une
    /// application à l'Info.plist illisible compte : son emplacement suffit à en faire une.
    static func showsInDock(_ application: URL) -> Bool {
        let plist = application.appendingPathComponent("Contents/Info.plist")
        guard let data = try? Data(contentsOf: plist),
            let info = try? PropertyListSerialization.propertyList(from: data, format: nil)
                as? [String: Any]
        else { return true }
        return !isSet(info["LSUIElement"]) && !isSet(info["LSBackgroundOnly"])
    }

    /// Ces clés s'écrivent en booléen, en nombre ou en texte (`"1"`) selon les applications.
    private static func isSet(_ value: Any?) -> Bool {
        switch value {
        case let flag as Bool: flag
        case let number as NSNumber: number.boolValue
        case let text as String: ["1", "yes", "true"].contains(text.lowercased())
        default: false
        }
    }
}
