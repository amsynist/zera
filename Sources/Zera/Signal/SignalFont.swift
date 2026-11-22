import AppKit
import CoreText

// MARK: - Signal type
//
// Every font in Zera comes from here (see `Typo` for the named roles). The Signal look sets the
// whole interface in one monospaced face, like Ghostty X: JetBrains Mono, bundled under its open
// licence (Resources/Fonts, see THIRD_PARTY_NOTICES.md). Settings › Appearance › Interface font
// can switch to SF Mono or back to the system font. The choice applies from the next launch,
// because screens build their labels once.
//
// Sizes stay the ones each screen asks for, but a monospaced face is wider than the system font,
// so `ui` sets it a little smaller (`scale`). Text then takes about the same width as before and
// the existing layouts keep fitting.

enum ZFont {
    enum Family: String, CaseIterable {
        case jetBrains = "jetbrains", sfMono = "sfmono", system = "system"
        var title: String {
            switch self {
            case .jetBrains: return "JetBrains Mono"
            case .sfMono: return "SF Mono"
            case .system: return "System"
            }
        }
    }

    private static let familyKey = "zera.font.family"
    /// Read once per launch: every `Typo` role is built from it.
    static let family: Family = Family(rawValue: UserDefaults.standard.string(forKey: familyKey) ?? "") ?? .jetBrains
    /// What Settings shows; takes effect on the next launch.
    static var chosenFamily: Family {
        get { Family(rawValue: UserDefaults.standard.string(forKey: familyKey) ?? "") ?? .jetBrains }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: familyKey) }
    }

    /// A monospaced glyph is 0.6 em wide, about 13 % wider than the system font's average.
    static let scale: CGFloat = 0.88

    /// Interface text (titles, labels, buttons) at the size a screen asks for.
    static func ui(ofSize size: CGFloat, weight: NSFont.Weight = .regular) -> NSFont {
        switch family {
        case .system: return NSFont.systemFont(ofSize: size, weight: weight)
        case .sfMono: return NSFont.monospacedSystemFont(ofSize: scaled(size), weight: weight)
        case .jetBrains: return bundled(scaled(size), weight) ?? NSFont.monospacedSystemFont(ofSize: scaled(size), weight: weight)
        }
    }

    /// Text that was already monospaced (commands, code, hex): same size, no scaling.
    static func mono(ofSize size: CGFloat, weight: NSFont.Weight = .regular) -> NSFont {
        switch family {
        case .system, .sfMono: return NSFont.monospacedSystemFont(ofSize: size, weight: weight)
        case .jetBrains: return bundled(size, weight) ?? NSFont.monospacedSystemFont(ofSize: size, weight: weight)
        }
    }

    /// Numbers that must not shift as they change (timers, vitals, counts).
    static func digits(ofSize size: CGFloat, weight: NSFont.Weight = .regular) -> NSFont {
        family == .system ? NSFont.monospacedDigitSystemFont(ofSize: size, weight: weight) : ui(ofSize: size, weight: weight)
    }

    private static func scaled(_ size: CGFloat) -> CGFloat { max(7, (size * scale * 2).rounded() / 2) }

    // MARK: Bundled face

    private static func bundled(_ size: CGFloat, _ weight: NSFont.Weight) -> NSFont? {
        guard registered else { return nil }
        let name: String
        switch weight.rawValue {
        case ..<0.2: name = "JetBrainsMonoNL-Regular"
        case ..<0.27: name = "JetBrainsMonoNL-Medium"
        case ..<0.36: name = "JetBrainsMonoNL-SemiBold"
        default: name = "JetBrainsMonoNL-Bold"
        }
        let key = "\(name)|\(size)" as NSString
        if let f = fontCache.object(forKey: key) { return f }
        guard let f = NSFont(name: name, size: size) else { return nil }
        fontCache.setObject(f, forKey: key)
        return f
    }

    /// Draw code asks for the same few faces every frame; look each one up once.
    private static let fontCache = NSCache<NSString, NSFont>()

    /// Registers the bundled fonts for this process only, once. False when they can't be found
    /// (a test run outside the app bundle), so callers fall back to SF Mono.
    static let registered: Bool = {
        guard let dir = locateFonts() else { return false }
        let files = ((try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension.lowercased() == "ttf" }
        var any = false
        for url in files {
            var error: Unmanaged<CFError>?
            if CTFontManagerRegisterFontsForURL(url as CFURL, .process, &error) { any = true }
            else if NSFont(name: url.deletingPathExtension().lastPathComponent, size: 12) != nil { any = true }  // already registered
        }
        return any && NSFont(name: "JetBrainsMonoNL-Regular", size: 12) != nil
    }()

    /// The app bundle's Resources/Fonts, or the repository's when running tests.
    private static func locateFonts() -> URL? {
        var candidates: [URL] = []
        if let r = Bundle.main.resourceURL { candidates.append(r.appendingPathComponent("Fonts")) }
        let exe = Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0])
        var u = exe.deletingLastPathComponent()
        for _ in 0..<5 {
            candidates.append(u.appendingPathComponent("Resources/Fonts"))
            u = u.deletingLastPathComponent()
        }
        candidates.append(URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("Resources/Fonts"))
        return candidates.first { FileManager.default.fileExists(atPath: $0.appendingPathComponent("JetBrainsMonoNL-Regular.ttf").path) }
    }
}
