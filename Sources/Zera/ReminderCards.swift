import AppKit

/// The compact notification Zera shows when something is due:
///
///   (Z)  [💧] Drink water                         1 of 2  ✕
///        Every 2 hours · 9:00 AM – 9:00 PM · next 1:00 PM
///        [ Snooze ▾ ]  [ ✓ Mark as done ]
///
/// Snooze offers 15 min · 30 min · 1 hour · 2 hours · Tomorrow. Meetings get Join (when there
/// is a call link) or Got it; break nudges get Taking it.
final class ReminderAlertCard: CardBase, CardContent {
    var cardWidth: CGFloat { 440 }
    var say: ((String, ZeraMood) -> Void)?
    var onDrained: (() -> Void)?
    /// Tapping the title: open the reminder in Reminders & Calendar.
    var onView: ((ReminderAlert) -> Void)?

    private let figure = NSImageView()
    private let tile = AgendaTile()
    private let headline = rlabel(NSFont.systemFont(ofSize: 15, weight: .bold), Pal.text)
    private let detail = rlabel(NSFont.systemFont(ofSize: 12.5), Pal.textSecondary, lines: 2)
    private let counter = rlabel(NSFont.systemFont(ofSize: 11.5, weight: .semibold), Pal.textTertiary)
    private var dismissButton: GHSquareButton!
    private var snooze: PRActionButton!
    private var primary: PRActionButton!
    private var current: ReminderAlert?

    private static let figureW: CGFloat = 84

    init() {
        super.init(width: 440, title: "")
        titleLabel.isHidden = true
        figure.imageScaling = .scaleProportionallyUpOrDown
        figure.imageAlignment = .alignBottom
        addSubview(figure)
        addSubview(tile)
        headline.toolTip = "Open in Reminders & Calendar"
        addSubview(headline)
        addSubview(detail)
        counter.alignment = .right
        addSubview(counter)
        dismissButton = GHSquareButton(symbol: "xmark", label: "Dismiss", target: self, action: #selector(dismissTapped))
        addSubview(dismissButton)
        snooze = PRActionButton("Snooze", style: .secondary, symbol: "moon.zzz.fill", target: self, action: #selector(snoozeTapped))
        primary = PRActionButton("Mark as done", style: .primary, symbol: "checkmark", target: self, action: #selector(primaryTapped))
        addSubview(snooze)
        addSubview(primary)
        NotificationCenter.default.addObserver(self, selector: #selector(reload), name: ReminderService.changed, object: nil)
        reload()
    }

    required init?(coder: NSCoder) { fatalError() }
    deinit { NotificationCenter.default.removeObserver(self) }

    var desiredHeight: CGFloat { 18 + 22 + 4 + detailHeight + 14 + 36 + 18 }

    private var detailHeight: CGFloat {
        let w = bounds.width - textX - 18
        let r = (detail.stringValue as NSString).boundingRect(with: NSSize(width: max(60, w), height: 60),
                                                               options: [.usesLineFragmentOrigin, .usesFontLeading],
                                                               attributes: [.font: detail.font!])
        return min(36, max(17, ceil(r.height)))
    }
    private var textX: CGFloat { Self.figureW + 12 + 34 + 12 }

    @objc func reload() {
        let svc = ReminderService.shared
        current = svc.pendingAlerts.first
        guard let a = current else { onDrained?(); return }

        // Look and pose for what it is.
        let look: AgendaLook
        let pose: String
        if a.kind == .breakTime {
            look = .source(.custom); pose = "cozy"
        } else if a.hydration {
            look = .hydration; pose = "boba"
        } else if let eid = a.eventID {
            look = .source(svc.event(eid)?.source ?? .custom)
            pose = a.kind == .calendarNow ? "card_notify" : "card_bell"
        } else {
            look = .reminder
            pose = a.kind == .snoozed ? "card_bell" : "pointing"
        }
        tile.look = look
        figure.image = SpriteLibrary.shared.sprite(pose)?.image ?? SpriteLibrary.shared.sprite("card_bell")?.image

        headline.stringValue = a.hydration && a.kind != .snoozed ? a.headline + " 💧" : a.headline
        detail.stringValue = a.detail
        counter.stringValue = svc.pendingAlerts.count > 1 ? "1 of \(svc.pendingAlerts.count)" : ""
        setAccessibilityLabel("\(a.headline). \(a.detail)")

        if a.kind == .breakTime {
            primary.setTitleText("Taking it ☕")
            snooze.setTitleText("Later")
        } else if a.isEvent {
            primary.setTitleText(a.joinURL != nil ? "Join call" : "Got it")
            snooze.setTitleText("Snooze")
        } else {
            primary.setTitleText("Mark as done")
            snooze.setTitleText("Snooze")
        }
        needsLayout = true
        layoutSubtreeIfNeeded()
        onHeightChange?()
    }

    @objc private func snoozeTapped() {
        guard let a = current else { return }
        ZeraDropdown.shared.show(snoozeItems { [weak self] until, label in
            ReminderService.shared.snooze(a, until: until)
            self?.say?(a.kind == .breakTime ? "okay, a bit later ☕" : "okay — I'll remind you in \(label) 😴", .sleepy)
        }, below: snooze, width: 210)
    }

    @objc private func primaryTapped() {
        guard let a = current else { return }
        let svc = ReminderService.shared
        if a.kind == .breakTime {
            svc.dismiss(a)
            say?("enjoy it! ☕", .cozy)
        } else if a.isEvent {
            if let u = a.joinURL { NSWorkspace.shared.open(u) }
            svc.dismiss(a)
            say?(a.joinURL != nil ? "joining… have a good one 👋" : "got it 👍", .happy)
        } else {
            svc.complete(a)
            say?(a.hydration ? "nice — stay hydrated 💧" : "done! ✨", a.hydration ? .love : .happy)
        }
    }

    @objc private func dismissTapped() {
        guard let a = current else { return }
        ReminderService.shared.dismiss(a)
    }

    override func mouseUp(with event: NSEvent) {
        let pt = convert(event.locationInWindow, from: nil)
        if let a = current, NSPointInRect(pt, headline.frame.union(tile.frame)) { onView?(a) }
    }

    override func layout() {
        super.layout()
        let w = bounds.width, h = bounds.height
        let fw = Self.figureW
        figure.frame = NSRect(x: 8, y: h - fw - 4, width: fw, height: fw)
        let x0 = fw + 12
        tile.frame = NSRect(x: x0, y: 18, width: 34, height: 34)
        dismissButton.frame = NSRect(x: w - 14 - 26, y: 14, width: 26, height: 26)
        let cw: CGFloat = counter.stringValue.isEmpty ? 0 : 54
        counter.frame = NSRect(x: dismissButton.frame.minX - 6 - cw, y: 20, width: cw, height: 15)
        let tx = textX
        headline.frame = NSRect(x: tx, y: 16, width: max(60, counter.frame.minX - 8 - tx), height: 22)
        detail.frame = NSRect(x: tx, y: 40, width: w - tx - 18, height: detailHeight)
        let by = h - 18 - 36
        let pw = max(130, primary.fittedWidth)
        primary.frame = NSRect(x: w - 18 - pw, y: by, width: pw, height: 36)
        let sw = max(104, snooze.fittedWidth + 14)
        snooze.frame = NSRect(x: primary.frame.minX - 10 - sw, y: by, width: sw, height: 36)
    }
}
