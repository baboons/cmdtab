import AppKit

/// Geometry for one switcher session, computed when it opens.
struct SwitcherLayout {
    var style: SwitcherStyle
    var columns: Int
    var maxRows: Int
    var cellSize: CGSize
    var thumbSize: CGSize
    var spacing: CGFloat
    var inset: CGFloat
    var headerHeight: CGFloat
    var footerHeight: CGFloat
    var width: CGFloat

    var contentTop: CGFloat { inset + headerHeight }

    func rows(for count: Int) -> Int {
        max(1, min(maxRows, (max(count, 1) + columns - 1) / columns))
    }

    func height(for count: Int) -> CGFloat {
        let rows = CGFloat(rows(for: count))
        return contentTop + rows * cellSize.height + (rows - 1) * spacing + footerHeight + inset
    }

    static func make(style: SwitcherStyle, scale: CGFloat, itemCount: Int, screen: CGRect, hints: Bool) -> SwitcherLayout {
        let inset: CGFloat = 12
        let header: CGFloat = 52
        let footer: CGFloat = hints ? 32 : 8
        let maxWidth = screen.width * 0.92
        let maxHeight = screen.height * 0.84
        let count = max(itemCount, 1)

        switch style {
        case .previews:
            let spacing: CGFloat = 4
            var s = scale
            while true {
                let thumb = CGSize(width: (228 * s).rounded(), height: (142 * s).rounded())
                let cell = CGSize(width: thumb.width + 20, height: thumb.height + 20 + 38)
                let fit = max(1, min(count, 8, Int((maxWidth - 2 * inset + spacing) / (cell.width + spacing))))
                let rowsNeeded = (count + fit - 1) / fit
                // Balance the rows: 10 windows become 5 + 5, not 8 + 2.
                let columns = (count + rowsNeeded - 1) / rowsNeeded
                let rowsFit = max(1, Int((maxHeight - 2 * inset - header - footer + spacing) / (cell.height + spacing)))
                if rowsNeeded <= rowsFit || s <= 0.56 {
                    let gridWidth = CGFloat(columns) * cell.width + CGFloat(columns - 1) * spacing + 2 * inset
                    return SwitcherLayout(
                        style: style, columns: columns, maxRows: min(rowsFit, rowsNeeded), cellSize: cell, thumbSize: thumb,
                        spacing: spacing, inset: inset, headerHeight: header, footerHeight: footer,
                        width: max(gridWidth, 580)
                    )
                }
                s -= 0.06
            }
        case .list:
            let spacing: CGFloat = 2
            let cell = CGSize(width: (660 * min(scale, 1.15)).rounded(), height: 48)
            let rowsFit = max(1, Int((maxHeight - 2 * inset - header - footer + spacing) / (cell.height + spacing)))
            return SwitcherLayout(
                style: style, columns: 1, maxRows: min(rowsFit, 12, count), cellSize: cell, thumbSize: .zero,
                spacing: spacing, inset: inset, headerHeight: header, footerHeight: footer, width: cell.width + 2 * inset
            )
        }
    }
}

@MainActor
protocol SwitcherViewDelegate: AnyObject {
    func switcherView(didHover index: Int)
    func switcherView(didClick index: Int)
    func switcherView(didRequest action: WindowAction, at index: Int)
}

/// Header (search field, optional clock), result grid/list and hint footer.
final class SwitcherView: NSView {
    weak var delegate: SwitcherViewDelegate?

    private var layoutInfo = SwitcherLayout.make(style: .previews, scale: 1, itemCount: 1, screen: CGRect(x: 0, y: 0, width: 1440, height: 900), hints: true)
    private var results: [SearchResult] = []
    private var selected = 0
    private var topRow = 0
    private var cells: [UInt64: ItemCell] = [:]
    private var visibleCells: [Int: ItemCell] = [:]
    private var hoveredIndex: Int?
    private var mouseOrigin: NSPoint?

    private let searchIcon = NSImageView()
    private let queryField = NSTextField(labelWithString: "")
    private let countField = NSTextField(labelWithString: "")
    private let clockField = NSTextField(labelWithString: "")
    private var clockTimer: Timer?
    private let caret = CALayer()
    private let separator = CALayer()
    private let footerField = NSTextField(labelWithString: "")
    private let emptyField = NSTextField(labelWithString: "")

    override var isFlipped: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true

        let config = NSImage.SymbolConfiguration(pointSize: 17, weight: .medium)
        searchIcon.image = NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: "Search")?.withSymbolConfiguration(config)
        searchIcon.contentTintColor = .secondaryLabelColor
        addSubview(searchIcon)

        queryField.font = .systemFont(ofSize: 20, weight: .regular)
        queryField.lineBreakMode = .byTruncatingHead
        queryField.maximumNumberOfLines = 1
        addSubview(queryField)

        countField.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        countField.textColor = .tertiaryLabelColor
        countField.alignment = .right
        addSubview(countField)

        clockField.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        clockField.textColor = .secondaryLabelColor
        clockField.alignment = .right
        clockField.isHidden = true
        addSubview(clockField)

        caret.cornerRadius = 1
        layer?.addSublayer(caret)
        layer?.addSublayer(separator)

        footerField.alignment = .center
        footerField.maximumNumberOfLines = 1
        footerField.lineBreakMode = .byTruncatingTail
        addSubview(footerField)

        emptyField.alignment = .center
        emptyField.font = .systemFont(ofSize: 14, weight: .regular)
        emptyField.textColor = .secondaryLabelColor
        emptyField.isHidden = true
        addSubview(emptyField)

        startCaretBlink()
    }

    required init?(coder: NSCoder) { fatalError() }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    // MARK: - Session

    func begin(layout: SwitcherLayout, mode: KeyboardTap.Mode, trigger: TriggerModifier, releaseSwitches: Bool, showClock: Bool) {
        layoutInfo = layout
        topRow = 0
        hoveredIndex = nil
        mouseOrigin = NSEvent.mouseLocation
        for cell in cells.values { cell.isHidden = true }
        visibleCells.removeAll()
        setHints(mode: mode, trigger: trigger, releaseSwitches: releaseSwitches)
        footerField.isHidden = layout.footerHeight < 20
        clockField.isHidden = !showClock
        if showClock { startClock() } else { stopClock() }
        updateTrackingAreas()
    }

    func end() {
        stopClock()
    }

    func update(query: String, results: [SearchResult], selected: Int, animated: Bool) {
        self.results = results
        self.selected = selected
        setQuery(query, count: results.count)
        emptyField.isHidden = !results.isEmpty
        if results.isEmpty {
            emptyField.stringValue = query.isEmpty ? "No windows" : "No windows match “\(query)”"
        }
        ensureSelectionVisible()
        layoutCells(animated: animated)
        needsLayout = true
    }

    func updateSelection(_ selected: Int) {
        self.selected = selected
        let oldTop = topRow
        ensureSelectionVisible()
        if oldTop != topRow {
            layoutCells(animated: false)
        } else {
            for (index, cell) in visibleCells { cell.isSelected = index == selected }
        }
    }

    func updateThumbnail(_ id: CGWindowID, _ image: CGImage) {
        cells[UInt64(id)]?.setThumbnail(image)
    }

    /// Drops cached cells for items that no longer exist.
    func prune(keeping ids: Set<UInt64>) {
        for (id, cell) in cells where !ids.contains(id) {
            cell.removeFromSuperview()
            cells.removeValue(forKey: id)
        }
    }

    // MARK: - Layout

    private var visibleRange: Range<Int> {
        let start = topRow * layoutInfo.columns
        let end = min(results.count, start + layoutInfo.maxRows * layoutInfo.columns)
        return start..<max(start, end)
    }

    private func ensureSelectionVisible() {
        guard !results.isEmpty else { topRow = 0; return }
        let row = selected / layoutInfo.columns
        let totalRows = (results.count + layoutInfo.columns - 1) / layoutInfo.columns
        if row < topRow { topRow = row }
        if row >= topRow + layoutInfo.maxRows { topRow = row - layoutInfo.maxRows + 1 }
        topRow = max(0, min(topRow, totalRows - layoutInfo.maxRows))
    }

    private func frameForCell(at index: Int) -> CGRect {
        let l = layoutInfo
        let row = index / l.columns - topRow
        let col = index % l.columns
        let rowStart = (index / l.columns) * l.columns
        let inRow = min(l.columns, results.count - rowStart)
        let rowWidth = CGFloat(inRow) * l.cellSize.width + CGFloat(inRow - 1) * l.spacing
        let x0 = ((bounds.width - rowWidth) / 2).rounded()
        return CGRect(
            x: x0 + CGFloat(col) * (l.cellSize.width + l.spacing),
            y: l.contentTop + CGFloat(row) * (l.cellSize.height + l.spacing),
            width: l.cellSize.width, height: l.cellSize.height
        )
    }

    private func layoutCells(animated: Bool) {
        let range = visibleRange
        var nextVisible: [Int: ItemCell] = [:]
        var moves: [(ItemCell, CGRect)] = []
        let scale = window?.backingScaleFactor ?? 2
        let maxPixels = CGSize(width: layoutInfo.thumbSize.width * scale, height: layoutInfo.thumbSize.height * scale)
        var needThumbs: [CGWindowID] = []

        for index in range {
            let result = results[index]
            let id = result.item.id
            let frame = frameForCell(at: index)
            let cell: ItemCell
            let wasVisible: Bool
            if let existing = cells[id] {
                cell = existing
                wasVisible = !existing.isHidden
            } else {
                cell = ItemCell(frame: frame)
                cells[id] = cell
                addSubview(cell, positioned: .below, relativeTo: nil)
                wasVisible = false
            }
            let thumb = ThumbnailService.shared.thumbnail(for: result.item.windowID)
            if thumb == nil, layoutInfo.style == .previews, !result.item.isWindowless { needThumbs.append(result.item.windowID) }
            cell.configure(result, layout: layoutInfo, thumbnail: thumb, icon: IconCache.icon(for: result.item))
            cell.isSelected = index == selected
            cell.isHovered = index == hoveredIndex
            cell.isHidden = false
            if animated && wasVisible && cell.frame != frame {
                moves.append((cell, frame))
            } else {
                cell.frame = frame
            }
            nextVisible[index] = cell
        }
        let shown = Set(nextVisible.values.map(ObjectIdentifier.init))
        for cell in visibleCells.values where !shown.contains(ObjectIdentifier(cell)) {
            cell.isHidden = true
        }
        visibleCells = nextVisible

        if !moves.isEmpty {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.16
                ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                ctx.allowsImplicitAnimation = true
                for (cell, frame) in moves { cell.animator().frame = frame }
            }
        }
        if !needThumbs.isEmpty {
            ThumbnailService.shared.refresh(needThumbs, maxPixels: maxPixels)
        }
    }

    override func layout() {
        super.layout()
        let l = layoutInfo
        let headerMidY = l.inset + l.headerHeight / 2 - 2
        searchIcon.frame = CGRect(x: l.inset + 12, y: headerMidY - 11, width: 22, height: 22)
        var headerRight = bounds.width - l.inset - 12
        if !clockField.isHidden {
            let clockWidth = ceil(clockField.intrinsicContentSize.width)
            clockField.frame = CGRect(x: headerRight - clockWidth, y: headerMidY - 8, width: clockWidth, height: 16)
            headerRight = clockField.frame.minX - 10
        }
        let countWidth: CGFloat = 110
        countField.frame = CGRect(x: headerRight - countWidth, y: headerMidY - 8, width: countWidth, height: 16)
        let queryX = searchIcon.frame.maxX + 10
        queryField.frame = CGRect(x: queryX, y: headerMidY - 13, width: countField.frame.minX - queryX - 12, height: 26)
        positionCaret()

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        separator.frame = CGRect(x: l.inset + 8, y: l.contentTop - 6, width: bounds.width - 2 * (l.inset + 8), height: 1)
        CATransaction.commit()

        footerField.frame = CGRect(x: l.inset, y: bounds.height - l.inset - 20, width: bounds.width - 2 * l.inset, height: 16)
        emptyField.frame = CGRect(x: l.inset, y: l.contentTop + l.cellSize.height / 2 - 10, width: bounds.width - 2 * l.inset, height: 20)
    }

    // MARK: - Header

    private var hasQuery = false

    private func setQuery(_ query: String, count: Int) {
        hasQuery = !query.isEmpty
        if query.isEmpty {
            queryField.stringValue = "Type to search windows"
            queryField.textColor = .tertiaryLabelColor
        } else {
            queryField.stringValue = query
            queryField.textColor = .labelColor
        }
        countField.stringValue = count == 1 ? "1 window" : "\(count) windows"
        positionCaret()
    }

    private func positionCaret() {
        let textWidth = hasQuery ? min(queryField.attributedStringValue.size().width, queryField.frame.width) : 0
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        caret.frame = CGRect(x: queryField.frame.minX + textWidth + 2.5, y: queryField.frame.minY + 2, width: 2, height: 22)
        CATransaction.commit()
    }

    /// Shows the time and keeps it current: the switcher can stay open, so
    /// the label is refreshed on every minute boundary until the session ends.
    private func startClock() {
        stopClock()
        updateClock()
        let nextMinute = Calendar.current.nextDate(after: Date(), matching: DateComponents(second: 0), matchingPolicy: .nextTime) ?? Date()
        let timer = Timer(fire: nextMinute, interval: 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateClock() }
        }
        RunLoop.main.add(timer, forMode: .common)
        clockTimer = timer
    }

    private func stopClock() {
        clockTimer?.invalidate()
        clockTimer = nil
    }

    private func updateClock() {
        // The system's own short time format, as in the menu bar: the region's
        // pattern plus the 12/24-hour setting from System Settings.
        clockField.stringValue = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .short)
        needsLayout = true
    }

    private func startCaretBlink() {
        let blink = CAKeyframeAnimation(keyPath: "opacity")
        blink.values = [1, 1, 0, 0, 1]
        blink.keyTimes = [0, 0.45, 0.5, 0.95, 1]
        blink.duration = 1.06
        blink.repeatCount = .infinity
        caret.add(blink, forKey: "blink")
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateColors()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateColors()
    }

    private func updateColors() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            caret.backgroundColor = NSColor.controlAccentColor.cgColor
            separator.backgroundColor = NSColor.separatorColor.cgColor
        }
    }

    func setHints(mode: KeyboardTap.Mode, trigger: TriggerModifier, releaseSwitches: Bool) {
        footerField.attributedStringValue = Self.hints(mode: mode, trigger: trigger, releaseSwitches: releaseSwitches)
    }

    private static func hints(mode: KeyboardTap.Mode, trigger: TriggerModifier, releaseSwitches: Bool) -> NSAttributedString {
        let actionPrefix = mode == .hold ? "⇧" : "⌘"
        var pairs: [(String, String)] = [(mode == .hold ? "⇥" : "↑↓", mode == .hold ? "next" : "select")]
        if mode == .hold && !releaseSwitches { pairs.append(("type", "to search")) }
        pairs += [
            (mode == .hold && releaseSwitches ? "release \(trigger.symbol)" : "↩", "switch"),
            ("\(actionPrefix)W", "close"),
            ("\(actionPrefix)M", "minimize"),
            ("\(actionPrefix)H", "hide"),
            ("\(actionPrefix)Q", "quit"),
            ("esc", "cancel"),
        ]
        let out = NSMutableAttributedString()
        let keyAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11, weight: .semibold), .foregroundColor: NSColor.secondaryLabelColor,
        ]
        let textAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11, weight: .regular), .foregroundColor: NSColor.tertiaryLabelColor,
        ]
        for (i, (key, label)) in pairs.enumerated() {
            if i > 0 { out.append(NSAttributedString(string: "     ", attributes: textAttrs)) }
            out.append(NSAttributedString(string: key, attributes: keyAttrs))
            out.append(NSAttributedString(string: " \(label)", attributes: textAttrs))
        }
        let p = NSMutableParagraphStyle()
        p.alignment = .center
        out.addAttribute(.paragraphStyle, value: p, range: NSRange(location: 0, length: out.length))
        return out
    }

    // MARK: - Mouse

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }

    private func index(at point: NSPoint) -> Int? {
        for (index, cell) in visibleCells where cell.frame.contains(point) { return index }
        return nil
    }

    override func mouseMoved(with event: NSEvent) {
        // Ignore the cursor until it actually moves, so a mouse resting where
        // the panel appears doesn't hijack keyboard selection.
        if let origin = mouseOrigin {
            let now = NSEvent.mouseLocation
            guard hypot(now.x - origin.x, now.y - origin.y) > 3 else { return }
            mouseOrigin = nil
        }
        setHovered(index(at: convert(event.locationInWindow, from: nil)))
        if let hoveredIndex { delegate?.switcherView(didHover: hoveredIndex) }
    }

    override func mouseExited(with event: NSEvent) {
        setHovered(nil)
    }

    private func setHovered(_ index: Int?) {
        guard index != hoveredIndex else { return }
        if let old = hoveredIndex { visibleCells[old]?.isHovered = false }
        hoveredIndex = index
        if let index { visibleCells[index]?.isHovered = true }
    }

    override func mouseUp(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard let index = index(at: point), let cell = visibleCells[index] else { return }
        switch cell.hitPart(at: convert(point, to: cell)) {
        case .item: delegate?.switcherView(didClick: index)
        case .close: delegate?.switcherView(didRequest: .close, at: index)
        case .minimize: delegate?.switcherView(didRequest: .minimize, at: index)
        }
    }
}

/// App icons by pid, cached for the process lifetime of each app.
enum IconCache {
    private static var icons: [pid_t: NSImage] = [:]
    private static var overrides: [UInt64: NSImage] = [:]

    static func setOverride(_ icon: NSImage, for id: UInt64) {
        overrides[id] = icon
    }

    static func icon(for item: WindowItem) -> NSImage? {
        if let icon = overrides[item.id] { return icon }
        if let icon = icons[item.pid] { return icon }
        let icon = NSRunningApplication(processIdentifier: item.pid)?.icon
        icons[item.pid] = icon
        return icon
    }

    static func evict(pid: pid_t) {
        icons.removeValue(forKey: pid)
    }
}
