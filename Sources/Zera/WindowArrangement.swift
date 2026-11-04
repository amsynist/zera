import AppKit
import Carbon.HIToolbox

/// All geometry is in Accessibility's global, top-left coordinates, in points.
struct ArrangeDisplay: Equatable {
    var id: String
    var name: String
    var frame: CGRect
    var visible: CGRect
    var main: Bool
    /// `visible` already excludes the menu bar and Dock in global AX points. Never
    /// subtract guessed title-bar, notch or backing-pixel dimensions a second time.
    var area: CGRect { frame.intersection(visible).insetBy(dx: 8, dy: 8) }
    static func current() -> [Self] {
        let top = NSScreen.screens.first?.frame.maxY ?? 0
        return NSScreen.screens.enumerated().map { index, screen in
            func flip(_ r: CGRect) -> CGRect { CGRect(x: r.minX, y: top - r.maxY, width: r.width, height: r.height) }
            return .init(id: String((screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? UInt32(index)),
                         name: screen.localizedName, frame: flip(screen.frame), visible: flip(screen.visibleFrame), main: index == 0)
        }
    }
}

struct ArrangeWindow: Equatable {
    var id: String, app: String, bundle: String, title: String
    var pid: pid_t
    var frame: CGRect
    var workspace: Int
    var minimized: Bool
    var floating = false
    var minimum = CGSize(width: 240, height: 160)
}

/// Reuse adjusted frames only for the same ordered tiles and usable display area.
struct ArrangeManualLayout {
    var area: CGRect
    var ids: [String]
    func frames(for windows: [ArrangeWindow], in area: CGRect) -> [String: CGRect]? {
        guard ArrangeGeometry.near(self.area, area), ids == windows.map(\.id),
              ArrangeGeometry.fits(windows.map(\.frame), windows: windows, in: area) else { return nil }
        return Dictionary(uniqueKeysWithValues: windows.map { ($0.id, $0.frame) })
    }
}

enum ArrangeLayout: String, Codable, CaseIterable {
    case columns, rows, grid, twoAbove, twoBelow, mainLeft, mainRight, mainTop
    var title: String {
        switch self {
        case .columns: return "Columns"
        case .rows: return "Rows"
        case .grid: return "Grid"
        case .twoAbove: return "Two above"
        case .twoBelow: return "Two below"
        case .mainLeft: return "Main left"
        case .mainRight: return "Main right"
        case .mainTop: return "Main above"
        }
    }
    static func choices(count: Int) -> [Self] {
        count == 1 ? [.columns] : count == 3 ? [.columns, .rows, .twoAbove, .twoBelow, .mainLeft, .mainTop] : [.columns, .rows, .grid, .mainLeft, .mainRight, .mainTop]
    }
    func frames(count: Int, in area: CGRect, gap: CGFloat = 8, ratio: CGFloat = 0.6) -> [CGRect] {
        guard (1...64).contains(count), area.width > 0, area.height > 0, area.width.isFinite, area.height.isFinite else { return [] }
        if count == 1 { return [area] }
        let gap = max(0, min(gap, min(area.width, area.height) / CGFloat(count * 2)))
        func split(_ rect: CGRect, _ n: Int, horizontal: Bool) -> [CGRect] {
            let length = (horizontal ? rect.width : rect.height) - CGFloat(n - 1) * gap
            guard length > 0 else { return [] }
            return (0..<n).map { i in
                let start = (length * CGFloat(i) / CGFloat(n)).rounded(.down) + CGFloat(i) * gap
                let end = (length * CGFloat(i + 1) / CGFloat(n)).rounded(.down) + CGFloat(i) * gap
                return horizontal ? CGRect(x: rect.minX + start, y: rect.minY, width: end - start, height: rect.height)
                    : CGRect(x: rect.minX, y: rect.minY + start, width: rect.width, height: end - start)
            }
        }
        switch self {
        case .columns: return split(area, count, horizontal: true)
        case .rows: return split(area, count, horizontal: false)
        case .twoAbove, .twoBelow:
            guard count == 3 else { return ArrangeLayout.grid.frames(count: count, in: area, gap: gap) }
            let rows = split(area, 2, horizontal: false)
            return self == .twoAbove ? split(rows[0], 2, horizontal: true) + [rows[1]] : [rows[0]] + split(rows[1], 2, horizontal: true)
        case .mainTop:
            let height = ((area.height - gap) * min(0.8, max(0.2, ratio))).rounded(.down)
            let master = CGRect(x: area.minX, y: area.minY, width: area.width, height: height)
            let stack = CGRect(x: area.minX, y: master.maxY + gap, width: area.width, height: area.height - height - gap)
            return [master] + split(stack, count - 1, horizontal: true)
        case .mainLeft, .mainRight:
            let width = ((area.width - gap) * min(0.8, max(0.2, ratio))).rounded(.down)
            let master = CGRect(x: self == .mainLeft ? area.minX : area.maxX - width, y: area.minY, width: width, height: area.height)
            let stack = CGRect(x: self == .mainLeft ? master.maxX + gap : area.minX, y: area.minY, width: area.width - width - gap, height: area.height)
            return [master] + split(stack, count - 1, horizontal: false)
        case .grid:
            let rowCount = max(1, Int(ceil(sqrt(Double(count) / Double(max(0.5, area.width / area.height))))))
            let bands = split(area, min(count, rowCount), horizontal: false)
            var result: [CGRect] = [], left = count
            for (i, band) in bands.enumerated() {
                let n = Int(ceil(Double(left) / Double(bands.count - i)))
                result += split(band, n, horizontal: true); left -= n
            }
            return result
        }
    }
}

enum ArrangeGeometry {
    static func fits(_ frames: [CGRect], windows: [ArrangeWindow], in area: CGRect) -> Bool {
        guard frames.count == windows.count, !frames.isEmpty else { return false }
        for (i, r) in frames.enumerated() {
            guard r.width.isFinite, r.height.isFinite, r.width >= windows[i].minimum.width, r.height >= windows[i].minimum.height,
                  area.insetBy(dx: -1, dy: -1).contains(r) else { return false }
            if frames[..<i].contains(where: { $0.intersection(r).width > 1 && $0.intersection(r).height > 1 }) { return false }
        }
        return true
    }
    static func near(_ a: CGRect, _ b: CGRect, tolerance: CGFloat = 3) -> Bool {
        abs(a.minX - b.minX) <= tolerance && abs(a.minY - b.minY) <= tolerance && abs(a.width - b.width) <= tolerance && abs(a.height - b.height) <= tolerance
    }
    static func resolvedFocus(observed: String?, previous: String?, windows: [ArrangeWindow], active: Set<Int>) -> String? {
        let visible = windows.filter { active.contains($0.workspace) && !$0.minimized }
        return [observed, previous].compactMap { $0 }.first { id in visible.contains { $0.id == id } } ?? visible.first?.id
    }
    static func appLaunchTarget(_ rule: ArrangeAppRule, windows: [ArrangeWindow], focused: String?, workspace: Int, active: Set<Int>) -> (window: ArrangeWindow?, workspace: Int?) {
        let candidates = windows.filter { $0.bundle == rule.bundle }
        let existing = candidates.first { $0.id == focused }
            ?? candidates.first { $0.workspace == workspace && !$0.minimized }
            ?? candidates.first { active.contains($0.workspace) && !$0.minimized }
            ?? candidates.first
        return (existing, existing?.workspace ?? rule.workspace)
    }
    static func neighbor(_ id: String, windows: [ArrangeWindow], dx: CGFloat, dy: CGFloat) -> String? {
        guard let origin = windows.first(where: { $0.id == id }), windows.count > 1 else { return nil }
        let rest = windows.filter { $0.id != id }
        func along(_ w: ArrangeWindow) -> CGFloat { (w.frame.midX - origin.frame.midX) * dx + (w.frame.midY - origin.frame.midY) * dy }
        func across(_ w: ArrangeWindow) -> CGFloat { abs((w.frame.midX - origin.frame.midX) * dy - (w.frame.midY - origin.frame.midY) * dx) }
        if let next = rest.filter({ along($0) > 1 }).min(by: { along($0) + across($0) * 2 < along($1) + across($1) * 2 }) { return next.id }
        return rest.min { along($0) + across($0) * 2 < along($1) + across($1) * 2 }?.id
    }
    /// Move a connected internal divider, keeping every outer edge and gap fixed.
    static func resizedDivider(_ id: String, windows: [ArrangeWindow], in area: CGRect, horizontal: Bool, delta: CGFloat, gap: CGFloat = 8) -> [String: CGRect]? {
        guard (2...64).contains(windows.count), delta.isFinite, delta != 0, let source = windows.first(where: { $0.id == id }),
              fits(windows.map(\.frame), windows: windows, in: area) else { return nil }
        func low(_ r: CGRect) -> CGFloat { horizontal ? r.minX : r.minY }
        func high(_ r: CGRect) -> CGFloat { horizontal ? r.maxX : r.maxY }
        func length(_ r: CGRect) -> CGFloat { horizontal ? r.width : r.height }
        func overlap(_ a: CGRect, _ b: CGRect) -> Bool {
            horizontal ? min(a.maxY, b.maxY) - max(a.minY, b.minY) > 1 : min(a.maxX, b.maxX) - max(a.minX, b.minX) > 1
        }
        let peers = windows.filter { $0.id != id && overlap($0.frame, source.frame) }
        let hasBefore = peers.contains { abs(high($0.frame) + gap - low(source.frame)) <= 2 }
        let hasAfter = peers.contains { abs(low($0.frame) - gap - high(source.frame)) <= 2 }
        guard hasBefore || hasAfter else { return nil }
        // Neighbour order stays stable as widths change; a centre-coordinate test
        // could flip edges after one press and make the reverse arrow grow again.
        let beforeCount = peers.filter { high($0.frame) <= low(source.frame) + 2 }.count
        let afterCount = peers.filter { low($0.frame) >= high(source.frame) - 2 }.count
        let moveHigh = hasAfter && (!hasBefore || beforeCount <= afterCount)
        let divider = moveHigh ? high(source.frame) : low(source.frame) - gap
        var before: Set<String> = moveHigh ? [id] : [], after: Set<String> = moveHigh ? [] : [id]
        var changed = true
        while changed {
            changed = false
            for w in windows {
                if !before.contains(w.id), abs(high(w.frame) - divider) <= 2,
                   windows.contains(where: { after.contains($0.id) && overlap(w.frame, $0.frame) }) {
                    before.insert(w.id); changed = true
                }
                if !after.contains(w.id), abs(low(w.frame) - divider - gap) <= 2,
                   windows.contains(where: { before.contains($0.id) && overlap(w.frame, $0.frame) }) {
                    after.insert(w.id); changed = true
                }
            }
        }
        guard !before.isEmpty, !after.isEmpty else { return nil }
        var minimum = -length(area), maximum = length(area)
        for w in windows {
            let minSize = horizontal ? w.minimum.width : w.minimum.height
            if before.contains(w.id) { minimum = max(minimum, minSize - length(w.frame)) }
            if after.contains(w.id) { maximum = min(maximum, length(w.frame) - minSize) }
        }
        let movement = min(maximum, max(minimum, delta)).rounded(.towardZero)
        guard abs(movement) >= 1 else { return nil }
        let resized = windows.map { w -> CGRect in
            var r = w.frame
            if before.contains(w.id) {
                if horizontal { r.size.width += movement } else { r.size.height += movement }
            }
            if after.contains(w.id) {
                if horizontal { r.origin.x += movement; r.size.width -= movement }
                else { r.origin.y += movement; r.size.height -= movement }
            }
            return r
        }
        guard fits(resized, windows: windows, in: area) else { return nil }
        return Dictionary(uniqueKeysWithValues: zip(windows.map(\.id), resized))
    }
    static func distribution(count: Int, capacity: Int) -> [Int] {
        guard count > 0 else { return [] }
        let groups = Int(ceil(Double(count) / Double(max(1, capacity))))
        return (0..<groups).map { count / groups + ($0 < count % groups ? 1 : 0) }
    }
}

struct ArrangeAppRule: Codable, Equatable {
    var name: String, bundle: String, path: String
    var workspace: Int?
    var shortcut: HotKeyShortcut?
}

struct ArrangeSettings: Codable {
    var enabled = false
    var automatic = true
    var capacity = 4
    var scope: String?
    var includedApps: Set<String>?
    var visualTransitions: Bool?
    var rules = Self.suppliedRules
    var shortcuts: [String: HotKeyShortcut] = [:]
    var disabled: Set<String> = []
    static let key = "zera.windowArrangement.v1"
    static func load() -> Self { UserDefaults.standard.data(forKey: key).flatMap { try? JSONDecoder().decode(Self.self, from: $0) } ?? .init() }
    func save() { if let data = try? JSONEncoder().encode(self) { UserDefaults.standard.set(data, forKey: Self.key) } }
    static var suppliedRules: [ArrangeAppRule] {
        let cmd = UInt32(cmdKey), ctrl = UInt32(controlKey)
        return [
            .init(name: "Rio", bundle: "com.raphaelamorim.rio", path: "/Applications/rio.app", workspace: 2, shortcut: .init(keyCode: 13, modifiers: cmd, key: "W")),
            .init(name: "Arc", bundle: "company.thebrowser.Browser", path: "/Applications/Arc.app", workspace: 3, shortcut: .init(keyCode: 11, modifiers: cmd, key: "B")),
            .init(name: "Teams", bundle: "com.microsoft.teams2", path: "/Applications/Microsoft Teams.app", workspace: 1, shortcut: .init(keyCode: 46, modifiers: cmd, key: "M")),
            .init(name: "VS Code", bundle: "com.microsoft.VSCode", path: "/Applications/Visual Studio Code.app", workspace: nil, shortcut: .init(keyCode: 13, modifiers: ctrl, key: "W")),
            .init(name: "GitHub Desktop", bundle: "com.github.GitHubClient", path: "/Applications/GitHub Desktop.app", workspace: nil, shortcut: .init(keyCode: 5, modifiers: cmd, key: "G")),
            .init(name: "TablePlus", bundle: "com.tinyapp.TablePlus", path: "/Applications/TablePlus.app", workspace: nil, shortcut: .init(keyCode: 2, modifiers: cmd, key: "D")),
            .init(name: "Logseq", bundle: "com.electron.logseq", path: "/Applications/Logseq.app", workspace: 4, shortcut: .init(keyCode: 37, modifiers: cmd, key: "L")),
            .init(name: "Slack", bundle: "com.tinyspeck.slackmacgap", path: "/Applications/Slack.app", workspace: nil, shortcut: .init(keyCode: 46, modifiers: ctrl, key: "M")),
            .init(name: "Xcode", bundle: "com.apple.dt.Xcode", path: "/Applications/Xcode.app", workspace: 5, shortcut: .init(keyCode: 7, modifiers: ctrl, key: "X"))
        ]
    }
    static var bindings: [(String, String, HotKeyShortcut)] {
        let opt = UInt32(optionKey), shift = UInt32(shiftKey), cmd = UInt32(cmdKey)
        var result: [(String, String, HotKeyShortcut)] = []
        let codes: [UInt32] = [18,19,20,21,23,22,26,28,25]
        for i in 1...9 {
            result.append(("workspace.\(i)", "Workspace \(i)", .init(keyCode: codes[i-1], modifiers: cmd, key: String(i))))
            result.append(("send.\(i)", "Move window to \(i)", .init(keyCode: codes[i-1], modifiers: cmd | shift, key: String(i))))
        }
        for (name, code, key) in [("left", UInt32(123), "←"), ("right",124,"→"), ("down",125,"↓"), ("up",126,"↑")] {
            result.append(("focus.\(name)", "Focus \(name)", .init(keyCode: code, modifiers: opt, key: key)))
        }
        for (name, code, key) in [("left", UInt32(123), "←"), ("right",124,"→"), ("down",125,"↓"), ("up",126,"↑")] {
            result.append(("resize.\(name)", "Resize toward \(name)", .init(keyCode: code, modifiers: opt | shift, key: key)))
        }
        for (name, code, key) in [("left", UInt32(4), "H"), ("down",38,"J"), ("up",40,"K"), ("right",37,"L")] {
            result.append(("move.\(name)", "Swap \(name)", .init(keyCode: code, modifiers: opt | shift, key: key)))
        }
        for (id, title, code, mods, key) in [
            ("fill", "Fill / restore window", UInt32(3), opt, "F"),
            ("rows", "Rows", 1, opt, "S"), ("columns", "Columns", 13, opt, "W"),
            ("layout", "Cycle layout", 14, opt, "E"), ("float", "Float / tile window", 49, opt | shift, "Space"),
            ("back", "Previous workspace", 48, opt, "⇥"), ("monitor", "Move workspace to next display", 48, opt | shift, "⇥"),
            ("resize", "Resize mode", 15, opt, "R"), ("rotate", "Rotate window order", 15, opt | shift, "R")
        ] { result.append((id, title, .init(keyCode: code, modifiers: mods, key: key))) }
        return result
    }
}

/// One shared ease-out for every tile, with exact endpoints and no overshoot.
enum ArrangeMotion {
    static let duration: TimeInterval = 0.24
    static func frame(from: CGRect, to: CGRect, progress: CGFloat) -> CGRect {
        let t = min(1, max(0, progress)), eased = 1 - pow(1 - t, 3)
        func mix(_ a: CGFloat, _ b: CGFloat) -> CGFloat { a + (b - a) * eased }
        return CGRect(x: mix(from.minX, to.minX), y: mix(from.minY, to.minY),
                      width: mix(from.width, to.width), height: mix(from.height, to.height))
    }
}

/// Public AX cannot fully hide another app's individual window. Leave at most a
/// two-point edge, outside every display's working area, with its size unchanged.
enum ArrangeParking {
    static func accepts(_ frame: CGRect, displays: [CGRect]) -> Bool {
        frame.minX.isFinite && frame.minY.isFinite && frame.width.isFinite && frame.height.isFinite && frame.width > 0 && frame.height > 0 && !displays.isEmpty && displays.allSatisfy { screen in
            let visible = frame.intersection(screen)
            return visible.isNull || visible.width <= 2 || visible.height <= 2
        }
    }
    static func candidates(size: CGSize, displays: [CGRect]) -> [CGRect] {
        displays.flatMap { screen in
            [CGRect(x: screen.maxX - 1, y: screen.maxY - 32, width: size.width, height: size.height),
             CGRect(x: screen.minX - size.width + 1, y: screen.maxY - 32, width: size.width, height: size.height)]
        }.filter { accepts($0, displays: displays) }
    }
}

/// All-or-restore writes. The Bool is logical workspace visibility; the native
/// implementation parks windows rather than invoking Dock minimization.
enum ArrangeTransaction {
    static func apply(windows: [ArrangeWindow], active: Set<Int>, frames: [String: CGRect],
                      read: (String) -> (CGRect, Bool)?, setFrame: (String, CGRect) -> CGRect?,
                      setMinimized: (String, Bool) -> Bool,
                      animate: (([String: CGRect]) -> String?)? = nil,
                      isCurrent: () -> Bool = { true }) -> String? {
        let changedDesktop = "Desktop or access changed. Refresh before arranging again."
        var before: [(String, CGRect, Bool)] = []
        for window in windows {
            guard isCurrent() else { return changedDesktop }
            guard let (frame, minimized) = read(window.id) else { return "A window closed. Refresh and try again." }
            before.append((window.id, frame, minimized))
        }
        var failure: String?
        for window in windows {
            guard isCurrent() else { return changedDesktop }
            let hide = !active.contains(window.workspace)
            guard let (_, minimized) = read(window.id) else { failure = "A window closed during the arrangement."; break }
            if hide != minimized, !setMinimized(window.id, hide) { failure = "\(window.app) refused to switch workspace."; break }
        }
        if failure == nil, let animate {
            guard isCurrent() else { return changedDesktop }
            let visible = Set(windows.filter { active.contains($0.workspace) }.map(\.id))
            failure = animate(frames.filter { visible.contains($0.key) })
        }
        if failure == nil {
            for window in windows where active.contains(window.workspace) {
                guard isCurrent() else { return changedDesktop }
                guard let target = frames[window.id] else { continue }
                guard let actual = setFrame(window.id, target), ArrangeGeometry.near(actual, target) else {
                    failure = "\(window.app) needs a larger tile or refused resizing. Try fewer windows or distribute them."; break
                }
            }
        }
        if failure == nil {
            for window in windows where active.contains(window.workspace) {
                guard isCurrent() else { return changedDesktop }
                guard let target = frames[window.id] else { continue }
                guard let (actual, _) = read(window.id), ArrangeGeometry.near(actual, target) else {
                    failure = "\(window.app) changed size while arranging."; break
                }
            }
        }
        guard let failure else { return nil }
        var restored = true
        for (id, frame, minimized) in before {
            // Restoring coordinates on a different native desktop would itself be an
            // unsolicited move. The recovery journal retains parked-window ownership.
            guard isCurrent() else { return changedDesktop }
            if !setMinimized(id, false) { restored = false }
            if let actual = setFrame(id, frame) { if !ArrangeGeometry.near(actual, frame) { restored = false } }
            else { restored = false }
            if minimized, !setMinimized(id, true) { restored = false }
        }
        return failure + (restored ? " Previous positions restored." : " Some windows could not be restored; check their app.")
    }
}

/// A command must stop writing as soon as a native Space or display changes, including
/// while its serial AX queue is blocked inside another application's messaging timeout.
final class ArrangeOperationEpoch: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    func invalidate() { lock.lock(); value += 1; lock.unlock() }
    func ticket() -> Int { lock.lock(); defer { lock.unlock() }; return value }
    func matches(_ ticket: Int) -> Bool { lock.lock(); defer { lock.unlock() }; return value == ticket }
}

/// One deferred user action, never an unbounded backlog of window mutations.
struct ArrangePendingShortcut {
    private var latest: (() -> Void)?
    mutating func replace(_ action: @escaping () -> Void) { latest = action }
    mutating func take(ready: Bool) -> (() -> Void)? {
        guard ready else { return nil }; let action = latest; latest = nil; return action
    }
    mutating func cancel() { latest = nil }
}
