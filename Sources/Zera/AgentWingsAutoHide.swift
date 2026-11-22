import Foundation

/// Settings › Integrations › Agents › "Wings while working", for every agent (Claude Code, Codex): the
/// wings show when a turn starts, then tuck away after a few seconds so they don't sit over your work.
/// They come back for a new turn, an approval, a finished turn, or when you open Agents.
/// Approvals are never hidden by this; they stay until answered or minimized.
enum AgentWingsAutoHide {
    /// Seconds the wings stay up while Claude works; 0 never shows them for work alone, -1 keeps them.
    static let choices: [Int] = [3, 5, 10, 30, 0, -1]
    static let titles = ["Hide after 3 seconds", "Hide after 5 seconds", "Hide after 10 seconds",
                         "Hide after 30 seconds", "Only when an agent needs you", "Keep showing"]
    static let defaultDelay = 3
    /// The stored name predates the Agents pane; kept so the choice carries over.
    static let key = "zera.claudeWings.hideAfter"

    static var delay: Int {
        get {
            guard let v = UserDefaults.standard.object(forKey: key) as? Int, choices.contains(v) else { return defaultDelay }
            return v
        }
        set { UserDefaults.standard.set(choices.contains(newValue) ? newValue : defaultDelay, forKey: key) }
    }

    /// Whether the wings for this running turn stay tucked away.
    /// - Parameters:
    ///   - runningKey: the turn the wings show as running ("session|prompt time"), nil for any other mode.
    ///   - hiddenTurn: the running turn that already had its seconds on screen.
    ///   - delay: the chosen setting.
    static func hides(runningKey: String?, hiddenTurn: String?, delay: Int) -> Bool {
        guard let key = runningKey, delay >= 0 else { return false }
        return delay == 0 || key == hiddenTurn
    }
}
