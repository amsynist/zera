import AppKit

/// The compact notification Zera shows when something is due:
///
///   (Z)  [💧] Drink water                         1 of 2  ✕
///        Every 2 hours · 9:00 AM – 9:00 PM · next 1:00 PM
///        [ Snooze ▾ ]  [ ✓ Mark as done ]
///
/// Snooze offers 15 min · 30 min · 1 hour · 2 hours · Tomorrow. Meetings get Join (when there
/// is a call link) or Got it; break nudges get Taking it.
final class ReminderAlertCard: CardBase, CardContent, TimedNotificationBanner {
    var cardWidth: CGFloat {
        // Wide enough that a meeting's title isn't cut off left of Zera (540 left it ~144 pt).
        max(620, ceil((max(84, primary.fittedWidth) + snooze.fittedWidth + Metrics.rowButton + 16 + Metrics.sidePad + Isle.zeraGap / 2) * 2))
    }
    let countdownLine = BannerCountdownLine()
    var say: ((String, ZeraMood) -> Void)?
    var onDrained: (() -> Void)?
    var onAlertChange: (() -> Void)?
    /// Tapping the banner (anywhere but its buttons): open the reminder's details.
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
        super.init(width: 540, title: "")
        titleLabel.isHidden = true
        figure.imageScaling = .scaleProportionallyUpOrDown
        figure.imageAlignment = .alignBottom
        addSubview(figure)
        addSubview(tile)
        addSubview(headline)
        addSubview(detail)
        counter.alignment = .right
        addSubview(counter)
        dismissButton = GHSquareButton(symbol: "xmark", label: "Dismiss", target: self, action: #selector(dismissTapped))
        addSubview(dismissButton)
        snooze = PRActionButton("Snooze", style: .secondary, symbol: "moon.zzz.fill", target: self, action: #selector(snoozeTapped))
        primary = PRActionButton("Done", style: .success, symbol: "checkmark", target: self, action: #selector(primaryTapped))
        addSubview(snooze)
        addSubview(primary)
        toolTip = "Open the details"
        addSubview(countdownLine)
        NotificationCenter.default.addObserver(self, selector: #selector(reload), name: ReminderService.changed, object: nil)
        reload()
    }

    required init?(coder: NSCoder) { fatalError() }
    deinit { NotificationCenter.default.removeObserver(self) }

    /// A banner: the header row Zera hangs in, plus a little air.
    var desiredHeight: CGFloat { headerBottom + 6 }

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
        let previousID = current?.id
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
        headline.toolTip = headline.stringValue
        detail.toolTip = a.detail
        counter.stringValue = svc.pendingAlerts.count > 1 ? "1 of \(svc.pendingAlerts.count)" : ""
        setAccessibilityLabel("\(a.headline). \(a.detail)")

        if a.kind == .breakTime {
            primary.setTitleText("Taking it ☕")
            snooze.setTitleText("Later")
        } else if a.isEvent {
            primary.setTitleText(a.joinURL != nil ? "Join call" : "Got it")
            primary.style = a.joinURL != nil ? .primary : .success
            snooze.setTitleText("Snooze")
        } else {
            primary.setTitleText("Done")
            snooze.setTitleText("Snooze")
        }
        needsLayout = true
        layoutSubtreeIfNeeded()
        onHeightChange?()
        if previousID != a.id { onAlertChange?() }
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

    /// The banner body opens the details; only ✕ dismisses.
    override func mouseUp(with event: NSEvent) {
        if let a = current { onView?(a) }
    }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let hit = super.hitTest(point) else { return nil }
        return hit is NSButton ? hit : self
    }

    override func layout() {
        super.layout()
        // Banner: tile · headline / detail left of Zera; Snooze and Done on the right.
        let w = bounds.width
        figure.isHidden = true
        dismissButton.isHidden = false
        counter.isHidden = true
        let x = Metrics.sidePad
        tile.frame = NSRect(x: x, y: 26, width: 36, height: 36)
        let tx = x + 36 + 12, half = w / 2 - Isle.zeraGap / 2 - 8
        headline.font = Typo.rowTitleStrong
        detail.font = Typo.meta
        detail.maximumNumberOfLines = 1
        headline.lineBreakMode = .byTruncatingTail
        detail.lineBreakMode = .byTruncatingTail
        headline.frame = NSRect(x: tx, y: 25, width: max(60, half - tx), height: 18)
        detail.frame = NSRect(x: tx, y: 45, width: max(60, half - tx), height: 16)
        let pw = max(84, primary.fittedWidth), bh = Metrics.button
        // ✕ ends the button row, centred on it, at the same margin as everything else.
        let db = Metrics.rowButton
        dismissButton.frame = NSRect(x: w - x - db, y: 28 + (bh - db) / 2, width: db, height: db)
        primary.frame = NSRect(x: dismissButton.frame.minX - 8 - pw, y: 28, width: pw, height: bh)
        let sw = snooze.fittedWidth
        snooze.frame = NSRect(x: primary.frame.minX - 8 - sw, y: 28, width: sw, height: bh)
        countdownLine.frame = NSRect(x: 18, y: bounds.height - 8, width: max(0, w - 36), height: 2)
    }
}
