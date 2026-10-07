import AppKit

// MARK: - GitHub PRs card
//
//  ┌──────────────────────────────────────────────────────────────┐
//  │ [tile] GitHub PRs              (Zera)  ╭bubble╮   [↻] [•••]  │  header
//  │        @login · checked 1 min ago                            │
//  │ [ Open 10 ][ Review 4 ][ CI 10 ][ Approvals 3 ]              │  segmented
//  │ [🔍 Search PRs…        ][Author⌄][Label⌄][Repo⌄][Sort⌄]      │  filters
//  │ ┌ PR row ───────────────────────────────────────────────┐    │
//  │ │ tile  repo #35          [✓ CI passing]  [Review] [•••] │    │  list (≤ 5 rows,
//  │ │       Title…             ◉◉◉   💬 2                    │    │  scrolls)
//  │ │       @author · 9 hours ago                           │    │
//  │ └───────────────────────────────────────────────────────┘    │
//  │ (Zera) ╭ 4 PRs have failing checks 😬 ╮ [↗ Open in Browser|⌄]│  insight
//  └──────────────────────────────────────────────────────────────┘
//
// All geometry lives in `L`; every frame below is derived from it, so nothing can overlap.

private enum L {
    static let width: CGFloat = 620
    static let pad: CGFloat = 20
    static let headerTop: CGFloat = 20
    /// Under the island header Zera hangs in.
    static let segY: CGFloat = 88
    static let segH: CGFloat = Metrics.segment
    static let filterH: CGFloat = 34
    static let rowH: CGFloat = RowTier.rich.height
    static let rowGap: CGFloat = Metrics.rowGap
    static let bannerH: CGFloat = 44
    static let insightH: CGFloat = 84
    static let gap: CGFloat = 12
    static let insightGap: CGFloat = 16
    static var filterY: CGFloat { segY + segH + gap }
    static var listY: CGFloat { filterY + filterH + gap }
}

/// What the status pill says for a PR, in priority order.
private func prStatus(_ p: GHPullRequest) -> (symbol: String, text: String, color: NSColor) {
    let c = Pal
    if p.approvalsWaiting > 0 { return ("hand.raised.fill", "Needs approval", c.warning) }
    switch p.ci {
    case .failed: return ("xmark.circle.fill", p.failing.count > 1 ? "\(p.failing.count) checks failing" : "CI failed", c.danger)
    default: break
    }
    if p.review == .changesRequested { return ("exclamationmark.triangle.fill", "Changes requested", c.warning) }
    if p.ci == .running { return ("clock.fill", "CI running", c.warning) }
    if p.review == .approved { return ("checkmark.seal.fill", "Approved", c.success) }
    if p.reviewRequested && !p.mine { return ("eye.fill", "Review requested", c.accent) }
    if p.ci == .passed { return ("checkmark.circle.fill", "CI passing", c.success) }
    if p.draft { return ("pencil.circle.fill", "Draft", c.muted) }
    return ("circle.dashed", "No checks", c.muted)
}

// MARK: - Row

/// One PR: repo tile · repo/#/title/author · status + reviewers + comments · Review · •••.
final class PullRequestRow: NSView {
    enum Primary { case review, approve }
    let pr: GHPullRequest
    var onOpen: (() -> Void)?
    var onPrimary: ((PRActionButton) -> Void)?
    var onMenu: ((NSView) -> Void)?
    var onHover: ((Bool) -> Void)?

    private let tile = PRRepoTile()
    private let repoLine = NSTextField(labelWithString: "")
    private let title = NSTextField(labelWithString: "")
    private let meta = NSTextField(labelWithString: "")
    private let chip = PRStatusChip()
    private let avatars = ReviewerAvatarGroup()
    private let comments = CommentCount()
    private var primary: PRActionButton!
    private var more: GHSquareButton!
    private let isNew: Bool
    private var hovered = false {
        didSet {
            guard hovered != oldValue else { return }
            needsDisplay = true
            avatars.ring = hovered ? Pal.surfaceHover : Pal.surfaceRow
            primary.emphasized = hovered
            onHover?(hovered)
        }
    }

    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    init(pr: GHPullRequest, primary kind: Primary, isNew: Bool) {
        self.pr = pr
        self.isNew = isNew
        super.init(frame: .zero)
        let p = Pal
        primary = PRActionButton(kind == .approve ? "Approve" : "Review", style: kind == .approve ? .success : .secondary, target: self, action: #selector(primaryTapped))
        more = GHSquareButton(symbol: "ellipsis", label: "More actions", target: self, action: #selector(moreTapped))
        tile.set(owner: pr.owner, mine: pr.mine)
        addSubview(tile)

        let repo = NSMutableAttributedString(string: pr.repo, attributes: [.font: NSFont.systemFont(ofSize: 12, weight: .medium), .foregroundColor: p.textSecondary])
        repo.append(NSAttributedString(string: "   #\(pr.number)", attributes: [.font: NSFont.systemFont(ofSize: 12, weight: .medium), .foregroundColor: p.textTertiary]))
        repoLine.attributedStringValue = repo
        repoLine.lineBreakMode = .byTruncatingTail
        addSubview(repoLine)

        title.stringValue = pr.title
        title.font = NSFont.systemFont(ofSize: 14.5, weight: isNew ? .bold : .semibold)
        title.textColor = p.text
        title.lineBreakMode = .byTruncatingTail
        title.toolTip = pr.title
        addSubview(title)

        meta.font = NSFont.systemFont(ofSize: 12)
        meta.textColor = p.textTertiary
        meta.lineBreakMode = .byTruncatingTail
        addSubview(meta)

        let st = prStatus(pr)
        chip.set(symbol: st.symbol, text: st.text, color: st.color)
        addSubview(chip)
        avatars.people = pr.reviewers.isEmpty ? [] : pr.reviewers
        avatars.ring = p.surfaceRow
        addSubview(avatars)
        comments.count = pr.comments
        addSubview(comments)
        addSubview(primary)
        addSubview(more)

        setAccessibilityRole(.button)
        setAccessibilityLabel("\(pr.repo) pull request \(pr.number): \(pr.title), \(st.text)")
        updateMeta(showStatus: false)
    }
    required init?(coder: NSCoder) { fatalError() }

    private func updateMeta(showStatus: Bool) {
        var s = "@\(pr.author.login)  ·  \(longAgo(pr.updated))"
        if pr.draft { s += "  ·  draft" }
        if showStatus { s += "  ·  \(prStatus(pr).text)" }
        meta.stringValue = s
    }

    @objc private func primaryTapped() { onPrimary?(primary) }
    @objc private func moreTapped() { onMenu?(more) }

    override func layout() {
        super.layout()
        let w = bounds.width, h = bounds.height
        let ts = RowTier.rich.tile
        tile.frame = NSRect(x: 14, y: (h - ts) / 2, width: ts, height: ts)
        var right = w - 12
        let mb = Metrics.headerButton
        more.frame = NSRect(x: right - mb, y: (h - mb) / 2, width: mb, height: mb)
        right -= mb + 8
        let pw = max(84, primary.fittedWidth)
        primary.frame = NSRect(x: right - pw, y: (h - Metrics.button) / 2, width: pw, height: Metrics.button)
        right -= pw + 14

        // Responsive status column: full (chip + avatars + comments) → chip only → folded into meta.
        let full = w >= 540, medium = w >= 460
        // Three lines (repo, title, meta) are 54 pt tall: centre them as a block on the row.
        let top = ((h - 54) / 2).rounded()
        let statusW: CGFloat = full ? 136 : (medium ? 120 : 0)
        chip.isHidden = statusW == 0
        let colX = right - statusW
        if statusW > 0 {
            let cw = min(statusW, chip.fittedWidth)
            chip.frame = NSRect(x: colX, y: full ? top : (h - 24) / 2, width: cw, height: 24)
            let commentsW = comments.count > 0 ? comments.fittedWidth : 0
            comments.isHidden = !full || commentsW == 0
            comments.frame = NSRect(x: right - commentsW, y: top + 31, width: commentsW, height: 22)
            let aw = avatars.fittedWidth
            avatars.isHidden = !full || aw == 0 || aw + commentsW + 8 > statusW
            avatars.frame = NSRect(x: colX, y: top + 30, width: aw, height: 24)
            right = colX - 14
        } else {
            comments.isHidden = true
            avatars.isHidden = true
        }
        updateMeta(showStatus: statusW == 0)

        let tx: CGFloat = tile.frame.maxX + 12, tw = max(40, right - tx)
        repoLine.frame = NSRect(x: tx, y: top, width: tw, height: 16)
        title.frame = NSRect(x: tx, y: top + 17, width: tw, height: 20)
        meta.frame = NSRect(x: tx, y: top + 38, width: tw, height: 16)
    }

    override func draw(_ dirtyRect: NSRect) {
        let p = Pal
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: Radius.l, yRadius: Radius.l)
        (hovered ? p.surfaceHover : p.surfaceRow).setFill(); path.fill()
        p.divider.setStroke(); path.lineWidth = 1; path.stroke()
        if isNew {
            p.accent.setFill()
            NSBezierPath(ovalIn: NSRect(x: 5, y: bounds.midY - 3, width: 6, height: 6)).fill()
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self, userInfo: nil))
    }
    override func mouseEntered(with event: NSEvent) { hovered = true }
    override func mouseExited(with event: NSEvent) { hovered = false }
    override func mouseDown(with event: NSEvent) { onOpen?() }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
}

// MARK: - Detail

/// "@login ✓" — reviewer with their latest verdict.
private final class ReviewerChip: NSView {
    let person: GHPullRequest.Person
    let verdict: GHPullRequest.Review
    override var isFlipped: Bool { true }
    private static let font = NSFont.systemFont(ofSize: 12, weight: .medium)

    init(_ p: GHPullRequest.Person, verdict v: GHPullRequest.Review) {
        person = p; verdict = v
        super.init(frame: .zero)
        NotificationCenter.default.addObserver(self, selector: #selector(redraw), name: AvatarCache.loaded, object: nil)
    }
    required init?(coder: NSCoder) { fatalError() }
    deinit { NotificationCenter.default.removeObserver(self) }
    @objc private func redraw() { needsDisplay = true }

    var fittedWidth: CGFloat {
        let textW: CGFloat = ceil(("@\(person.login)" as NSString).size(withAttributes: [.font: Self.font]).width)
        let badgeW: CGFloat = verdict == .none ? 0 : 18
        return textW + 4 + 20 + 6 + badgeW + 10
    }

    override func draw(_ dirtyRect: NSRect) {
        let p = Pal
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: bounds.height / 2, yRadius: bounds.height / 2)
        p.surfaceElevated.setFill(); path.fill()
        p.border.setStroke(); path.lineWidth = 1; path.stroke()
        AvatarCache.draw(person, in: NSRect(x: 3, y: (bounds.height - 20) / 2, width: 20, height: 20), ring: nil)
        let attrs: [NSAttributedString.Key: Any] = [.font: Self.font, .foregroundColor: p.text]
        let s = ("@\(person.login)" as NSString)
        let sz = s.size(withAttributes: attrs)
        s.draw(at: NSPoint(x: 29, y: (bounds.height - sz.height) / 2), withAttributes: attrs)
        let sym: String, col: NSColor
        switch verdict {
        case .approved: sym = "checkmark.circle.fill"; col = p.success
        case .changesRequested: sym = "exclamationmark.circle.fill"; col = p.warning
        case .none: return
        }
        if let img = NSImage(systemSymbolName: sym, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 12, weight: .bold))?.withSymbolConfiguration(.init(paletteColors: [col])) {
            let isz = img.size
            img.draw(in: NSRect(x: 29 + sz.width + 5, y: (bounds.height - isz.height) / 2, width: isz.width, height: isz.height),
                     from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        }
    }
}

/// The PR opened inside the card: same language as the rows, more room.
final class PRDetailView: NSView {
    var onBack: (() -> Void)?
    var onReview: (() -> Void)?
    var onSummarize: (() -> Void)?
    var onOpen: (() -> Void)?
    var onApprove: ((PRActionButton) -> Void)?

    let pr: GHPullRequest
    private var back: PRActionButton!
    private let panel = NSView()
    private let tile = PRRepoTile()
    private let repoLine = NSTextField(labelWithString: "")
    private let title = NSTextField(wrappingLabelWithString: "")
    private let meta = NSTextField(labelWithString: "")
    private var chips: [NSView] = []
    private let reviewersCaption = NSTextField(labelWithString: "REVIEWERS")
    private var reviewerChips: [ReviewerChip] = []
    private let checksCaption = NSTextField(labelWithString: "FAILING CHECKS")
    private var checkLines: [NSTextField] = []
    private var actions: [PRActionButton] = []
    private static let titleFont = NSFont.systemFont(ofSize: 16, weight: .semibold)

    override var isFlipped: Bool { true }

    init(pr: GHPullRequest) {
        self.pr = pr
        super.init(frame: .zero)
        let p = Pal
        back = PRActionButton("All PRs", style: .secondary, symbol: "chevron.left", target: self, action: #selector(backTapped))
        addSubview(back)
        panel.wantsLayer = true
        panel.layer?.cornerRadius = Radius.l + 2
        panel.layer?.cornerCurve = .continuous
        panel.layer?.backgroundColor = p.surfaceRow.cgColor
        panel.layer?.borderWidth = 1
        panel.layer?.borderColor = p.border.cgColor
        addSubview(panel)

        tile.set(owner: pr.owner, mine: pr.mine)
        panel.addSubview(tile)
        repoLine.stringValue = "\(pr.fullRepo)  ·  #\(pr.number)  ·  opened \(longAgo(pr.created))"
        repoLine.font = NSFont.systemFont(ofSize: 12, weight: .medium)
        repoLine.textColor = p.textSecondary
        repoLine.lineBreakMode = .byTruncatingTail
        panel.addSubview(repoLine)
        title.stringValue = pr.title
        title.font = Self.titleFont
        title.textColor = p.text
        title.maximumNumberOfLines = 3
        title.isSelectable = true
        panel.addSubview(title)
        var m = "@\(pr.author.login)"
        if let b = pr.branch { m += " wants to merge \(b) into \(pr.base ?? "main")" }
        meta.stringValue = m
        meta.font = NSFont.systemFont(ofSize: 12.5)
        meta.textColor = p.textSecondary
        meta.lineBreakMode = .byTruncatingMiddle
        panel.addSubview(meta)

        // Chips: status, CI, size, draft, labels, comments.
        func chip(_ s: String, _ t: String, _ c: NSColor) {
            let v = PRStatusChip(); v.set(symbol: s, text: t, color: c); chips.append(v); panel.addSubview(v)
        }
        let st = prStatus(pr)
        chip(st.symbol, st.text, st.color)
        switch pr.ci {
        case .passed where st.text != "CI passing": chip("checkmark.circle.fill", "CI passing", p.success)
        case .running where st.text != "CI running": chip("clock.fill", "CI running", p.warning)
        case .failed where !st.text.contains("fail"): chip("xmark.circle.fill", "CI failed", p.danger)
        default: break
        }
        if pr.review == .approved, st.text != "Approved" { chip("checkmark.seal.fill", "Approved", p.success) }
        if let a = pr.additions, let d = pr.deletions {
            chip("plusminus", "+\(a) −\(d) · \(pr.changedFiles ?? 0) files", p.info)
        }
        if pr.draft, st.text != "Draft" { chip("pencil.circle.fill", "Draft", p.muted) }
        for l in pr.labels.prefix(3) { chip("tag.fill", l, p.muted) }
        if pr.comments > 0 { let c = CommentCount(); c.count = pr.comments; chips.append(c); panel.addSubview(c) }

        reviewersCaption.font = NSFont.systemFont(ofSize: 10.5, weight: .bold)
        reviewersCaption.textColor = p.textTertiary
        panel.addSubview(reviewersCaption)
        for r in pr.reviewers.prefix(6) {
            let v: GHPullRequest.Review = pr.approvedBy.contains(r.login) ? .approved : (pr.changesBy.contains(r.login) ? .changesRequested : .none)
            let c = ReviewerChip(r, verdict: v)
            reviewerChips.append(c); panel.addSubview(c)
        }
        reviewersCaption.isHidden = reviewerChips.isEmpty

        checksCaption.font = reviewersCaption.font
        checksCaption.textColor = p.textTertiary
        panel.addSubview(checksCaption)
        for c in pr.failing.prefix(3) {
            let l = NSTextField(labelWithString: "")
            let s = NSMutableAttributedString(string: "✕  ", attributes: [.font: NSFont.systemFont(ofSize: 12, weight: .bold), .foregroundColor: p.danger])
            s.append(NSAttributedString(string: c.name, attributes: [.font: NSFont.systemFont(ofSize: 12.5, weight: .semibold), .foregroundColor: p.text]))
            if !c.title.isEmpty { s.append(NSAttributedString(string: "  —  \(c.title)", attributes: [.font: NSFont.systemFont(ofSize: 12.5), .foregroundColor: p.textSecondary])) }
            l.attributedStringValue = s
            l.lineBreakMode = .byTruncatingTail
            checkLines.append(l); panel.addSubview(l)
        }
        checksCaption.isHidden = checkLines.isEmpty

        if pr.approvalsWaiting > 0 {
            actions.append(PRActionButton("Approve runs", style: .success, symbol: "hand.thumbsup.fill", target: self, action: #selector(approveTapped(_:))))
        }
        actions.append(PRActionButton("Review", style: .secondary, symbol: "eye", target: self, action: #selector(reviewTapped)))
        actions.append(PRActionButton("Summarize", style: .secondary, symbol: "sparkles", target: self, action: #selector(summarizeTapped)))
        actions.append(PRActionButton("Open in GitHub", style: .secondary, symbol: "arrow.up.right.square", target: self, action: #selector(openTapped)))
        actions.forEach { panel.addSubview($0) }
    }
    required init?(coder: NSCoder) { fatalError() }

    @objc private func backTapped() { onBack?() }
    @objc private func reviewTapped() { onReview?() }
    @objc private func summarizeTapped() { onSummarize?() }
    @objc private func openTapped() { onOpen?() }
    @objc private func approveTapped(_ sender: PRActionButton) { onApprove?(sender) }

    /// Lays everything out for `width` and returns the height it needs.
    @discardableResult
    func place(width: CGFloat) -> CGFloat {
        let bw = back.fittedWidth
        back.frame = NSRect(x: 0, y: 0, width: bw, height: 30)
        let pw = width, inset: CGFloat = 16
        let tx: CGFloat = inset + 44 + 12
        tile.frame = NSRect(x: inset, y: inset, width: 44, height: 44)
        repoLine.frame = NSRect(x: tx, y: inset, width: pw - tx - inset, height: 16)
        let tw = pw - tx - inset
        let titleBounds = (pr.title as NSString).boundingRect(with: NSSize(width: tw, height: 200), options: [.usesLineFragmentOrigin, .usesFontLeading],
                                                              attributes: [.font: Self.titleFont])
        let titleH: CGFloat = ceil(titleBounds.height) + 2
        let th: CGFloat = min(3 * 21, titleH)
        title.frame = NSRect(x: tx, y: inset + 20, width: tw, height: th)
        var y = max(inset + 44, title.frame.maxY) + 4
        meta.frame = NSRect(x: tx, y: y, width: tw, height: 17)
        y += 17 + 14

        // Chips flow, wrapping at the panel edge.
        var x = inset
        for c in chips {
            let cw = (c as? PRStatusChip).map { min(pw - inset * 2, $0.fittedWidth) } ?? ((c as? CommentCount)?.fittedWidth ?? 40)
            if x + cw > pw - inset, x > inset { x = inset; y += 24 + 8 }
            c.frame = NSRect(x: x, y: y, width: cw, height: c is CommentCount ? 22 : 24)
            x += cw + 8
        }
        if !chips.isEmpty { y += 24 + 16 }

        if !reviewerChips.isEmpty {
            reviewersCaption.frame = NSRect(x: inset, y: y, width: 200, height: 14)
            y += 14 + 8
            x = inset
            for c in reviewerChips {
                let cw = min(pw - inset * 2, c.fittedWidth)
                if x + cw > pw - inset, x > inset { x = inset; y += 26 + 6 }
                c.frame = NSRect(x: x, y: y, width: cw, height: 26)
                x += cw + 6
            }
            y += 26 + 16
        }

        if !checkLines.isEmpty {
            checksCaption.frame = NSRect(x: inset, y: y, width: 200, height: 14)
            y += 14 + 6
            for l in checkLines {
                l.frame = NSRect(x: inset, y: y, width: pw - inset * 2, height: 18)
                y += 22
            }
            y += 10
        }

        // Actions, left to right; the last one drops its label to an icon-width if space runs out.
        x = inset
        for b in actions {
            let w = min(b.fittedWidth, pw - inset - x)
            b.frame = NSRect(x: x, y: y, width: max(34, w), height: 34)
            x += w + 8
        }
        y += 34 + inset
        panel.frame = NSRect(x: 0, y: 30 + 10, width: pw, height: y)
        return 30 + 10 + y
    }

    override func layout() {
        super.layout()
        place(width: bounds.width)
    }
}

// MARK: - Insight

/// Zera's take on the board, bottom of the card: headline, a smaller line, and the browser action.
final class PRInsightCard: NSView {
    let split = GHSplitButton(title: "Open in Browser", symbol: "arrow.up.right.square")
    private let bubble = FlippedView()
    private let headline = NSTextField(labelWithString: "")
    private let detail = NSTextField(labelWithString: "")
    override var isFlipped: Bool { true }
    /// Room on the left for Zera, who stands just outside this view.
    static let zeraRoom: CGFloat = 96

    override init(frame: NSRect) {
        super.init(frame: frame)
        let p = Pal
        bubble.wantsLayer = true
        bubble.layer?.cornerRadius = Radius.l
        bubble.layer?.cornerCurve = .continuous
        bubble.layer?.backgroundColor = p.field.withAlphaComponent(p.isDark ? 0.7 : 1).cgColor
        bubble.layer?.borderWidth = 1
        bubble.layer?.borderColor = p.border.cgColor
        addSubview(bubble)
        headline.font = NSFont.systemFont(ofSize: 14.5, weight: .semibold)
        headline.textColor = p.text
        headline.lineBreakMode = .byTruncatingTail
        bubble.addSubview(headline)
        detail.font = NSFont.systemFont(ofSize: 12)
        detail.textColor = p.textSecondary
        detail.lineBreakMode = .byTruncatingTail
        bubble.addSubview(detail)
        addSubview(split)
    }
    required init?(coder: NSCoder) { fatalError() }

    func set(headline h: String, detail d: String) {
        headline.stringValue = h
        detail.stringValue = d
        headline.toolTip = h
        detail.toolTip = d
        setAccessibilityLabel("\(h). \(d)")
    }

    override func layout() {
        super.layout()
        let w = bounds.width, h = bounds.height
        let sw = max(172, split.fittedWidth)
        split.frame = NSRect(x: w - 16 - sw, y: (h - 40) / 2, width: sw, height: 40)
        let bx = Self.zeraRoom
        bubble.frame = NSRect(x: bx, y: 13, width: max(80, split.frame.minX - 12 - bx), height: h - 26)
        headline.frame = NSRect(x: 14, y: 10, width: bubble.frame.width - 28, height: 19)
        detail.frame = NSRect(x: 14, y: 31, width: bubble.frame.width - 28, height: 16)
    }

    override func draw(_ dirtyRect: NSRect) {
        let p = Pal
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: Radius.l + 2, yRadius: Radius.l + 2)
        NSGradient(starting: p.surfaceElevated, ending: p.surfaceRow)?.draw(in: path, angle: -90)
        p.accentBorder.withAlphaComponent(0.35).setStroke(); path.lineWidth = 1; path.stroke()
    }
}

// MARK: - Pieces used only by the card

/// The header's square GitHub tile.
private final class GHHeaderTile: NSView {
    override var isFlipped: Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        let p = Pal
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 13, yRadius: 13)
        (p.isDark ? p.surfaceStrong : p.tileGitHub).setFill(); path.fill()
        NSColor.white.withAlphaComponent(0.14).setStroke(); path.lineWidth = 1; path.stroke()
        let side = bounds.width * 0.54
        let r = NSRect(x: (bounds.width - side) / 2, y: (bounds.height - side) / 2, width: side, height: side)
        if let m = PRRepoTile.mark {
            let tinted = NSImage(size: r.size, flipped: false) { rr in m.draw(in: rr); NSColor.white.set(); rr.fill(using: .sourceAtop); return true }
            tinted.draw(in: r, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        } else if let img = NSImage(systemSymbolName: "arrow.triangle.pull", accessibilityDescription: "GitHub")?
            .withSymbolConfiguration(.init(pointSize: 20, weight: .semibold))?.withSymbolConfiguration(.init(paletteColors: [.white])) {
            let s = img.size
            img.draw(in: NSRect(x: (bounds.width - s.width) / 2, y: (bounds.height - s.height) / 2, width: s.width, height: s.height),
                     from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        }
    }
}

/// Slim warning strip above the list when GitHub fails but older data is still shown.
private final class GHBanner: NSView {
    let message = NSTextField(labelWithString: "")
    private let icon = NSImageView()
    var button: PRActionButton? {
        didSet { oldValue?.removeFromSuperview(); if let b = button { addSubview(b) }; needsLayout = true }
    }
    override var isFlipped: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        let p = Pal
        wantsLayer = true
        layer?.cornerRadius = Radius.m + 2
        layer?.cornerCurve = .continuous
        layer?.backgroundColor = p.danger.withAlphaComponent(0.12).cgColor
        layer?.borderWidth = 1
        layer?.borderColor = p.danger.withAlphaComponent(0.3).cgColor
        icon.image = NSImage(systemSymbolName: "exclamationmark.triangle.fill", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 13, weight: .semibold))
        icon.contentTintColor = p.danger
        addSubview(icon)
        message.font = NSFont.systemFont(ofSize: 13, weight: .medium)
        message.textColor = p.text
        message.lineBreakMode = .byTruncatingTail
        addSubview(message)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        let h = bounds.height
        icon.frame = NSRect(x: 14, y: (h - 16) / 2, width: 16, height: 16)
        var right = bounds.width - 6
        if let b = button {
            let bw = max(84, b.fittedWidth)
            b.frame = NSRect(x: right - bw, y: (h - 32) / 2, width: bw, height: 32)
            right -= bw + 10
        }
        message.frame = NSRect(x: 40, y: (h - 17) / 2, width: max(40, right - 40), height: 17)
    }
}

// MARK: - The card

final class GitHubCard: CardBase, CardContent, NSTextFieldDelegate {
    var cardWidth: CGFloat { L.width }
    var onOpenSettings: (() -> Void)?
    var onOpenURL: ((URL) -> Void)?
    var say: ((String, ZeraMood) -> Void)?
    /// Hand Zera a brief to read and a question about it (Summarize).
    var onSummarize: ((URL, String) -> Void)?

    private enum Mode { case disconnected, loading, failed, empty, list, detail }
    private enum Sort: String, CaseIterable {
        case updated = "Recently updated", newest = "Newest", oldest = "Oldest", comments = "Most comments"
        var short: String? {
            switch self { case .updated: return nil; case .newest: return "Newest"; case .oldest: return "Oldest"; case .comments: return "Comments" }
        }
    }

    // Filters survive the card being rebuilt (theme change) and reopened.
    private static var tab = 0
    private static var query = ""
    private static var author: String?
    private static var label: String?
    private static var repo: String?
    private static var sort: Sort = .updated

    private let headerTile = GHHeaderTile()
    private let zeraHead = NSImageView()
    private let bubble = ZeraGitHubBubble()
    private var refreshButton: GHSquareButton!
    private var moreButton: GHSquareButton!
    private let segmented = GitHubSegmentedControl(items: [
        .init(symbol: "arrow.triangle.branch", title: "Open", count: 0, tint: nil),
        .init(symbol: "bubble.left", title: "Review", count: 0, tint: nil),
        .init(symbol: "checkmark.circle", title: "CI", count: 0, tint: nil),
        .init(symbol: "person.2", title: "Approvals", count: 0, tint: nil)
    ])
    private let search = SearchBox(placeholder: "Search PRs, repositories, or authors…")
    private let authorButton = GitHubFilterButton("Author")
    private let labelButton = GitHubFilterButton("Label")
    private let repoButton = GitHubFilterButton("Repo")
    private let sortButton = GitHubFilterButton("Sort")
    private let banner = GHBanner()
    private let scroll = NSScrollView()
    private let list = FlippedView()
    private var rows: [PullRequestRow] = []
    private let state = GHStateView()
    private var detailView: PRDetailView?
    /// The PR whose page was showing after the last reload, so only a change animates.
    private var shownDetailID: String?
    private var detailID: String?
    private let insight = PRInsightCard()
    private let insightZera = NSImageView()
    private var mode: Mode = .loading
    private var headerLine = ""

    init() {
        super.init(width: L.width, title: "Pull requests")
        let p = Pal
        refreshButton = GHSquareButton(symbol: "arrow.clockwise", label: "Check now", target: self, action: #selector(refreshTapped))
        moreButton = GHSquareButton(symbol: "ellipsis", label: "More", target: self, action: #selector(moreTapped))

        addSubview(headerTile)
        subtitleLabel.font = NSFont.systemFont(ofSize: 12)
        subtitleLabel.textColor = p.textSecondary
        subtitleLabel.isHidden = false
        addSubview(refreshButton)
        addSubview(moreButton)

        segmented.selected = Self.tab
        segmented.onSelect = { [weak self] i in
            Self.tab = i
            self?.detailID = nil
            self?.reload()
        }
        addSubview(segmented)
        // Zera sits on the bar, so she goes above it.
        zeraHead.imageScaling = .scaleProportionallyUpOrDown
        zeraHead.imageAlignment = .alignBottom
        zeraHead.setAccessibilityLabel("Zera")
        addSubview(zeraHead)
        addSubview(bubble)

        search.field.font = NSFont.systemFont(ofSize: 13)
        (search.field.cell as? NSTextFieldCell)?.placeholderAttributedString = NSAttributedString(
            string: "Search PRs, repositories, or authors…", attributes: [.foregroundColor: p.textTertiary, .font: NSFont.systemFont(ofSize: 13)])
        search.field.stringValue = Self.query
        search.field.delegate = self
        search.layer?.backgroundColor = p.surfaceRow.cgColor
        search.layer?.borderColor = p.border.cgColor
        addSubview(search)
        for b in [authorButton, labelButton, repoButton, sortButton] {
            b.onClick = { [weak self] v in self?.showFilterMenu(for: v) }
            addSubview(b)
        }

        addSubview(banner)
        scroll.hasVerticalScroller = false
        scroll.hasHorizontalScroller = false
        scroll.borderType = .noBorder
        scroll.drawsBackground = false
        scroll.contentView.drawsBackground = false
        scroll.verticalScrollElasticity = .allowed
        scroll.documentView = list
        addSubview(scroll)
        addSubview(state)

        insight.split.onMain = { [weak self] in self?.openBrowserTapped() }
        insight.split.onMenu = { [weak self] v in self?.showInsightMenu(from: v) }
        addSubview(insight)
        insightZera.imageScaling = .scaleProportionallyUpOrDown
        insightZera.imageAlignment = .alignBottom
        addSubview(insightZera)

        NotificationCenter.default.addObserver(self, selector: #selector(reload), name: GitHubService.changed, object: nil)
        reload()
    }

    required init?(coder: NSCoder) { fatalError() }
    deinit { NotificationCenter.default.removeObserver(self) }

    // MARK: Data

    private var gh: GitHubService { GitHubService.shared }

    /// Every tab is a filter over the same set — the PRs opened in the last 24 hours — so no
    /// tab needs its own request:
    ///  Open: all of them · Review: not approved yet · CI: those with check runs ·
    ///  Approvals: the ones you approved.
    private func pulls(forTab t: Int) -> [GHPullRequest] {
        let all = gh.pulls
        let me = gh.login ?? ""
        switch t {
        case 1: return all.filter { $0.approvedBy.isEmpty && !gh.isMarkedReviewed($0) }
        case 2: return all.filter { $0.ci != .none }
        case 3: return all.filter { !me.isEmpty && $0.approvedBy.contains(me) }
        default: return all
        }
    }

    private var filtersActive: Bool { !Self.query.isEmpty || Self.author != nil || Self.label != nil || Self.repo != nil }

    /// Tab → search → author / label / repo → sort. CI puts failures first.
    private var visible: [GHPullRequest] {
        var out = pulls(forTab: Self.tab)
        let q = Self.query.trimmingCharacters(in: .whitespaces).lowercased()
        if !q.isEmpty {
            let num = q.hasPrefix("#") ? String(q.dropFirst()) : q
            out = out.filter { (pr: GHPullRequest) -> Bool in
                if pr.title.lowercased().contains(q) { return true }
                if pr.fullRepo.lowercased().contains(q) { return true }
                if pr.author.login.lowercased().contains(q) { return true }
                if String(pr.number) == num { return true }
                return pr.labels.contains(where: { $0.lowercased().contains(q) })
            }
        }
        if let a = Self.author { out = out.filter { $0.author.login == a } }
        if let l = Self.label { out = out.filter { $0.labels.contains(l) } }
        if let r = Self.repo { out = out.filter { $0.fullRepo == r } }
        switch Self.sort {
        case .updated: out.sort { $0.updated > $1.updated }
        case .newest: out.sort { $0.created > $1.created }
        case .oldest: out.sort { $0.created < $1.created }
        case .comments: out.sort { $0.comments > $1.comments }
        }
        if Self.tab == 2 {
            let rank: (GHPullRequest) -> Int = { $0.ci == .failed ? 0 : ($0.ci == .running ? 1 : 2) }
            out = out.enumerated().sorted { (rank($0.element), $0.offset) < (rank($1.element), $1.offset) }.map { $0.element }
        }
        return out
    }

    // MARK: Reload

    @objc func reload() {
        let p = Pal
        rows.forEach { $0.removeFromSuperview() }
        rows = []

        // Header.
        refreshButton.spinning = gh.isRefreshing
        refreshButton.isHidden = !gh.isConnected
        moreButton.isHidden = !gh.isConnected
        if gh.isConnected {
            var sub = "@\(gh.login ?? "")"
            if gh.isRefreshing { sub += " · checking…" } else if let t = gh.lastChecked { sub += " · checked \(relativeTime(t))" }
            subtitleLabel.stringValue = sub
        } else {
            subtitleLabel.stringValue = "Not connected"
        }

        // Tabs.
        let counts = (0..<4).map { pulls(forTab: $0).count }
        let failing = gh.pulls.filter { $0.ci == .failed }.count
        segmented.items = [
            .init(symbol: "arrow.triangle.branch", title: "Open", count: counts[0], tint: nil),
            .init(symbol: "bubble.left", title: "Review", count: counts[1], tint: nil),
            .init(symbol: failing > 0 ? "xmark.circle" : "checkmark.circle", title: "CI", count: counts[2], tint: failing > 0 ? p.danger : p.success),
            .init(symbol: "person.2", title: "Approvals", count: counts[3], tint: counts[3] > 0 ? p.success : nil)
        ]
        segmented.selected = Self.tab

        // Filters.
        authorButton.value = Self.author.map { $0 == gh.login ? "@me" : "@\($0)" }
        labelButton.value = Self.label
        repoButton.value = Self.repo.map { $0.split(separator: "/").last.map(String.init) ?? $0 }
        sortButton.value = Self.sort.short

        // Mode.
        let shown = visible
        if detailID != nil, gh.pulls.first(where: { $0.id == detailID }) == nil { detailID = nil }
        if !gh.isConnected { mode = .disconnected }
        else if let id = detailID, gh.pulls.contains(where: { $0.id == id }) { mode = .detail }
        else if gh.pulls.isEmpty && gh.lastError != nil && !gh.isRefreshing { mode = .failed }
        else if gh.pulls.isEmpty && (gh.isRefreshing || gh.lastChecked == nil) { mode = .loading }
        else if shown.isEmpty { mode = .empty }
        else { mode = .list }

        let connected = mode != .disconnected
        segmented.isHidden = !connected
        insight.isHidden = true
        insightZera.isHidden = true
        let showFilters = connected && mode != .detail
        ([search, authorButton, labelButton, repoButton, sortButton] as [NSView]).forEach { $0.isHidden = !showFilters }

        // Banner: GitHub failed but we still have last poll's PRs.
        let bannerOn = connected && mode != .failed && gh.lastError != nil && !gh.pulls.isEmpty
        banner.isHidden = !bannerOn
        if bannerOn {
            banner.message.stringValue = gh.authExpired ? "GitHub connection needs attention." : "Couldn't reach GitHub — showing the last check."
            banner.toolTip = gh.lastError
            banner.button = PRActionButton(gh.authExpired ? "Reconnect" : "Retry", style: .secondary, target: self,
                                           action: gh.authExpired ? #selector(connectTapped) : #selector(refreshTapped))
        }

        // Detail.
        detailView?.removeFromSuperview(); detailView = nil
        if mode == .detail, let id = detailID, let pr = gh.pulls.first(where: { $0.id == id }) {
            let d = PRDetailView(pr: pr)
            d.onBack = { [weak self] in self?.detailID = nil; self?.reload() }
            d.onReview = { [weak self] in self?.review(pr) }
            d.onSummarize = { [weak self] in self?.summarize(pr) }
            d.onOpen = { [weak self] in self?.onOpenURL?(pr.url) }
            d.onApprove = { [weak self] b in self?.approve(pr, button: b) }
            addSubview(d)
            detailView = d
            // A PR you just opened comes in like a page (data refreshes don't replay it).
            if shownDetailID != id { Motion.page(d, forward: true) }
        }
        if detailView == nil, shownDetailID != nil { Motion.page(list, forward: false) }
        shownDetailID = detailView == nil ? nil : detailID

        // Rows.
        let unseen = gh.unseenPRIDs
        if mode == .list {
            for pr in shown {
                let r = PullRequestRow(pr: pr, primary: .review, isNew: unseen.contains(pr.id))
                r.onOpen = { [weak self] in self?.openDetail(pr) }
                r.onPrimary = { [weak self] b in
                    guard let self = self else { return }
                    self.review(pr)
                }
                r.onMenu = { [weak self] v in self?.showRowMenu(for: pr, from: v) }
                r.onHover = { [weak self] on in self?.hoverChanged(pr, on) }
                list.addSubview(r)
                rows.append(r)
            }
        }
        scroll.isHidden = mode != .list

        configureState()
        configureZera(failing: failing)

        needsLayout = true
        layoutSubtreeIfNeeded()
        onHeightChange?()
    }

    private func configureState() {
        state.isHidden = !(mode == .disconnected || mode == .loading || mode == .failed || mode == .empty)
        switch mode {
        case .disconnected:
            state.set(pose: "card_greet", title: "Connect GitHub",
                      subtitle: "See your PRs, checks and approvals right here — I look every 2 minutes.",
                      button: PRActionButton("Connect GitHub", style: .primary, symbol: "link", target: self, action: #selector(connectTapped)))
        case .loading:
            state.set(pose: "card_read_q", title: "Checking your PRs…", subtitle: "This takes a few seconds the first time.", loading: true)
        case .failed:
            if gh.authExpired {
                state.set(pose: "worried", title: "GitHub connection needs attention.",
                          subtitle: "Your token was refused — paste a new one to reconnect.",
                          button: PRActionButton("Reconnect", style: .primary, target: self, action: #selector(connectTapped)))
            } else {
                state.set(pose: "worried", title: "Couldn't reach GitHub.",
                          subtitle: "Check your connection — I'll keep trying every 2 minutes.",
                          button: PRActionButton("Retry", style: .primary, symbol: "arrow.clockwise", target: self, action: #selector(refreshTapped)))
            }
            state.toolTip = gh.lastError
        case .empty:
            if filtersActive {
                state.set(pose: "card_read_q", title: "Nothing matches", subtitle: "Try a different search or clear the filters.",
                          button: PRActionButton("Clear filters", style: .secondary, target: self, action: #selector(clearFilters)))
            } else if gh.pulls.isEmpty {
                state.set(pose: "card_thumbs_wink", title: "You're all clear ✨", subtitle: "No PRs were opened in your repos in the last 24 hours.")
            } else {
                switch Self.tab {
                case 1: state.set(pose: "card_thumbs_wink", title: "Everything's approved ✨", subtitle: "Every PR opened in the last 24 hours has an approval.")
                case 2: state.set(pose: "card_sleepy_sit", title: "No checks to show", subtitle: "None of today's PRs have run any checks yet.")
                default: state.set(pose: "card_read_q", title: "Nothing approved yet", subtitle: "PRs from the last 24 hours that you approve show up here.")
                }
            }
        default: break
        }
    }

    /// Her pose and line in the header, and her take in the insight card.
    private func configureZera(failing: Int) {
        let n = gh.pulls.count
        let reviews = pulls(forTab: 1).count
        let approvals = gh.pulls.filter { $0.approvalsWaiting > 0 }.count
        let fresh = gh.unseenPRIDs.count
        let pose: String
        switch mode {
        case .disconnected: pose = "card_greet"; headerLine = "Let's hook up GitHub 🔌"
        case .loading: pose = "card_read_q"; headerLine = "Checking your PRs… 🔍"
        case .failed: pose = "worried"; headerLine = gh.authExpired ? "I need a new token 🔑" : "GitHub isn't answering 😕"
        default:
            pose = "card_laptop_side"
            headerLine = n == 0 ? "No new PRs today ✨" : "\(n) PR\(n == 1 ? "" : "s") opened in 24h — want a look? 👀"
        }
        zeraHead.image = SpriteLibrary.shared.sprite(pose)?.image ?? SpriteLibrary.shared.sprite("idle")?.image
        bubble.text = headerLine

        let headline: String, sub: String, ipose: String
        if failing > 0 {
            headline = "\(failing) PR\(failing == 1 ? " has" : "s have") failing checks 😬"
            sub = "Want me to summarize the issues or check the logs?"
            ipose = "card_point_sparkle"
        } else if approvals > 0 {
            headline = "\(approvals) PR\(approvals == 1 ? " has" : "s have") runs waiting for you 🙋"
            sub = "Open the PR and tap Approve runs — no browser needed."
            ipose = "card_bell"
        } else if reviews > 0 {
            let oldest = pulls(forTab: 1).map { $0.created }.min()
            headline = "\(reviews) PR\(reviews == 1 ? " isn't" : "s aren't") approved yet 👀"
            sub = oldest.map { "The oldest has been waiting since \(longAgo($0)). Want a summary first?" } ?? "Want a summary first?"
            ipose = "card_point_sparkle"
        } else if fresh > 0 {
            headline = "News on your PRs 💬"
            sub = "\(fresh) PR\(fresh == 1 ? " has" : "s have") new reviews, comments or checks."
            ipose = "card_notify"
        } else if mode == .failed {
            headline = "I'll keep trying 💪"
            sub = "GitHub will be back — I check every 2 minutes."
            ipose = "worried"
        } else {
            headline = "Nothing waiting on you ✨"
            sub = "I'll ping you the moment something changes."
            ipose = "card_cheer"
        }
        insight.set(headline: headline, detail: sub)
        insightZera.image = SpriteLibrary.shared.sprite(ipose)?.image ?? SpriteLibrary.shared.sprite("idle")?.image
    }

    /// She glances at the PR under the pointer.
    private func hoverChanged(_ pr: GHPullRequest, _ on: Bool) {
        guard on else { bubble.text = headerLine; needsLayout = true; return }
        switch true {
        case pr.approvalsWaiting > 0: bubble.text = "This one needs your OK 🙋"
        case pr.ci == .failed: bubble.text = "CI's red on this one 😬"
        case pr.review == .changesRequested: bubble.text = "Changes were requested ✍️"
        case pr.review == .approved: bubble.text = "Approved — ship it? ✅"
        case pr.reviewRequested && !pr.mine: bubble.text = "Waiting on your review 👀"
        default: bubble.text = "#\(pr.number) · \(longAgo(pr.updated))"
        }
        needsLayout = true
    }

    // MARK: Sizing

    /// How many rows fit on this screen under the notch (2…5).
    /// Rows the island shows before the list scrolls.
    private var rowsFit: Int { max(2, Int((Isle.maxContentHeight - L.listY - L.pad) / (L.rowH + L.rowGap))) }

    private var listHeight: CGFloat {
        switch mode {
        case .list: return CGFloat(min(rows.count, rowsFit)) * (L.rowH + L.rowGap) - L.rowGap
        default: return GHStateView.height
        }
    }

    private var detailHeight: CGFloat { detailView?.place(width: L.width - L.pad * 2) ?? 0 }

    var desiredHeight: CGFloat {
        if mode == .disconnected { return L.segY + GHStateView.height + L.pad }
        var y: CGFloat
        if mode == .detail {
            y = L.filterY + detailHeight
        } else {
            y = L.listY
            if !banner.isHidden { y += L.bannerH + L.rowGap }
            y += listHeight
        }
        return y + L.pad
    }

    // MARK: Layout

    override func layout() {
        super.layout()
        let w = bounds.width, x = L.pad, iw = w - L.pad * 2

        // Island header: title and summary left of Zera (she hangs in the middle); refresh and
        // more on the right. Her own pictures and the insight box stay hidden in the island.
        [headerTile, zeraHead, bubble, insight, insightZera].forEach { $0.isHidden = true }
        layoutHeader()
        moreButton.frame = NSRect(x: w - x - 34, y: 27, width: 34, height: 34)
        refreshButton.frame = NSRect(x: moreButton.frame.minX - 8 - 34, y: 27, width: 34, height: 34)

        if mode == .disconnected {
            state.frame = NSRect(x: x, y: L.segY, width: iw, height: GHStateView.height)
            return
        }

        segmented.frame = NSRect(x: x, y: L.segY, width: iw, height: L.segH)

        // Filters: buttons at their fitted widths on the right, search takes the rest; on a
        // narrow card the label and repo filters step aside before the search gets cramped.
        var buttons = [authorButton, labelButton, repoButton, sortButton]
        func searchWidth() -> CGFloat { iw - buttons.reduce(0) { $0 + $1.fittedWidth + 8 } }
        while searchWidth() < 170, buttons.count > 2 { buttons.remove(at: 1) }
        for b in [authorButton, labelButton, repoButton, sortButton] where !buttons.contains(where: { $0 === b }) { b.isHidden = true }
        var bx = x + iw
        for b in buttons.reversed() {
            let bw = b.fittedWidth
            bx -= bw
            b.frame = NSRect(x: bx, y: L.filterY, width: bw, height: L.filterH)
            bx -= 8
        }
        search.frame = NSRect(x: x, y: L.filterY, width: max(120, bx - x), height: L.filterH)

        // Body.
        var y = L.listY
        if mode == .detail, let d = detailView {
            let dh = d.place(width: iw)
            d.frame = NSRect(x: x, y: L.filterY, width: iw, height: dh)
            y = L.filterY + dh
        } else {
            if !banner.isHidden {
                banner.frame = NSRect(x: x, y: y, width: iw, height: L.bannerH)
                y += L.bannerH + L.rowGap
            }
            let lh = listHeight
            scroll.frame = NSRect(x: x, y: y, width: iw, height: lh)
            state.frame = NSRect(x: x, y: y, width: iw, height: lh)
            var ry: CGFloat = 0
            for r in rows {
                r.frame = NSRect(x: 0, y: ry, width: iw, height: L.rowH)
                ry += L.rowH + L.rowGap
            }
            list.frame = NSRect(x: 0, y: 0, width: iw, height: max(ry - L.rowGap, lh))
            y += lh
        }

    }

    // MARK: Actions

    private func openDetail(_ pr: GHPullRequest) {
        detailID = pr.id
        gh.markSeen(pr)
        reload()
    }

    private func review(_ pr: GHPullRequest) {
        gh.markSeen(pr)
        onOpenURL?(pr.filesURL)
    }

    private func summarize(_ pr: GHPullRequest) {
        say?("pulling #\(pr.number) together… 📥", .thinking)
        Task { @MainActor [weak self] in
            do {
                let url = try await GitHubService.shared.brief(for: pr)
                self?.onSummarize?(url, "Summarize this pull request for a reviewer: what it changes, anything risky, and — if CI is failing — the likely cause.")
            } catch {
                self?.say?("couldn't fetch that PR 😕", .worried)
            }
        }
    }

    private func approve(_ pr: GHPullRequest, button: PRActionButton) {
        button.isEnabled = false
        Task { @MainActor [weak self] in
            do {
                try await GitHubService.shared.approveRuns(for: pr)
                self?.say?("approved! ✅", .approved)
            } catch {
                button.isEnabled = true
                self?.say?("GitHub said no — check the run in your browser", .worried)
            }
        }
    }

    @objc private func refreshTapped() { Task { @MainActor in await GitHubService.shared.refresh() } }
    @objc private func connectTapped() { onOpenSettings?() }
    @objc private func clearFilters() {
        Self.query = ""; Self.author = nil; Self.label = nil; Self.repo = nil
        search.field.stringValue = ""
        reload()
    }

    private func browserURL(_ path: String) -> URL { URL(string: "https://github.com/\(path)")! }

    @objc private func openBrowserTapped() {
        let login = gh.login ?? ""
        switch Self.tab {
        case 1: onOpenURL?(browserURL("pulls?q=is%3Aopen+is%3Apr+-review%3Aapproved+involves%3A\(login)"))
        case 2: onOpenURL?(browserURL("pulls"))
        case 3: onOpenURL?(browserURL("pulls?q=is%3Apr+reviewed-by%3A\(login)"))
        default: onOpenURL?(browserURL("pulls?q=is%3Aopen+is%3Apr+involves%3A\(login)"))
        }
    }

    @objc private func moreTapped() {
        NSMenu.make([
            ClosureMenuItem("Check now", symbol: "arrow.clockwise") { [weak self] in self?.refreshTapped() },
            ClosureMenuItem("Mark all as read", symbol: "envelope.open", enabled: !gh.unseen.isEmpty) { GitHubService.shared.markAllSeen() },
            .separator(),
            ClosureMenuItem("Open GitHub notifications", symbol: "bell") { [weak self] in self?.onOpenURL?(URL(string: "https://github.com/notifications")!) },
            ClosureMenuItem("GitHub settings…", symbol: "gearshape") { [weak self] in self?.onOpenSettings?() }
        ]).pop(below: moreButton)
    }

    private func showRowMenu(for pr: GHPullRequest, from v: NSView) {
        let reviewed = gh.isMarkedReviewed(pr)
        NSMenu.make([
            ClosureMenuItem("View PR", symbol: "doc.text.magnifyingglass") { [weak self] in self?.openDetail(pr) },
            ClosureMenuItem("Summarize with Zera", symbol: "sparkles") { [weak self] in self?.summarize(pr) },
            ClosureMenuItem("Open in GitHub", symbol: "arrow.up.right.square") { [weak self] in self?.onOpenURL?(pr.url) },
            ClosureMenuItem("Copy link", symbol: "link") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(pr.url.absoluteString, forType: .string)
            },
            .separator(),
            ClosureMenuItem(reviewed ? "Mark as not reviewed" : "Mark reviewed", symbol: "checkmark.circle", enabled: pr.reviewRequested) {
                GitHubService.shared.setReviewed(pr, !reviewed)
            }
        ]).pop(below: v)
    }

    private func showInsightMenu(from v: NSView) {
        let failing = gh.pulls.contains { $0.ci == .failed }
        let login = gh.login ?? ""
        NSMenu.make([
            ClosureMenuItem("Summarize failing checks", symbol: "sparkles", enabled: failing) { [weak self] in
                guard let self = self else { return }
                if let url = try? GitHubService.shared.failingChecksBrief() {
                    self.onSummarize?(url, "These checks are failing on my open PRs. For each PR, explain what's failing and the most likely fix.")
                }
            },
            .separator(),
            ClosureMenuItem("Open review requests", symbol: "eye") { [weak self] in self?.onOpenURL?(self?.browserURL("pulls/review-requested") ?? URL(string: "https://github.com")!) },
            ClosureMenuItem("Open my PRs", symbol: "person") { [weak self] in self?.onOpenURL?(self?.browserURL("pulls") ?? URL(string: "https://github.com")!) },
            ClosureMenuItem("Open everything involving me", symbol: "arrow.triangle.branch") { [weak self] in
                self?.onOpenURL?(URL(string: "https://github.com/pulls?q=is%3Aopen+is%3Apr+involves%3A\(login)")!)
            }
        ]).pop(below: v)
    }

    private func showFilterMenu(for b: GitHubFilterButton) {
        let all = pulls(forTab: Self.tab)
        var items: [NSMenuItem] = []
        if b === authorButton {
            items.append(ClosureMenuItem("Anyone", checked: Self.author == nil) { [weak self] in Self.author = nil; self?.reload() })
            if let me = gh.login {
                items.append(ClosureMenuItem("Me (@\(me))", checked: Self.author == me) { [weak self] in Self.author = me; self?.reload() })
            }
            let others = Array(Set(all.map { $0.author.login })).filter { $0 != gh.login }.sorted()
            if !others.isEmpty { items.append(.separator()) }
            for a in others.prefix(15) {
                items.append(ClosureMenuItem("@\(a)", checked: Self.author == a) { [weak self] in Self.author = a; self?.reload() })
            }
        } else if b === labelButton {
            items.append(ClosureMenuItem("Any label", checked: Self.label == nil) { [weak self] in Self.label = nil; self?.reload() })
            let labels = Array(Set(all.flatMap { $0.labels })).sorted()
            if labels.isEmpty { items.append(ClosureMenuItem("No labels on these PRs", enabled: false) {}) }
            else { items.append(.separator()) }
            for l in labels.prefix(20) {
                items.append(ClosureMenuItem(l, checked: Self.label == l) { [weak self] in Self.label = l; self?.reload() })
            }
        } else if b === repoButton {
            items.append(ClosureMenuItem("Any repository", checked: Self.repo == nil) { [weak self] in Self.repo = nil; self?.reload() })
            let repos = Array(Set(all.map { $0.fullRepo })).sorted()
            if !repos.isEmpty { items.append(.separator()) }
            for r in repos.prefix(20) {
                items.append(ClosureMenuItem(r, checked: Self.repo == r) { [weak self] in Self.repo = r; self?.reload() })
            }
        } else {
            for s in Sort.allCases {
                items.append(ClosureMenuItem(s.rawValue, checked: Self.sort == s) { [weak self] in Self.sort = s; self?.reload() })
            }
        }
        NSMenu.make(items).pop(below: b)
    }

    // MARK: Search

    func controlTextDidChange(_ obj: Notification) {
        Self.query = search.field.stringValue
        reload()
    }
}
