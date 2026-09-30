import AppKit

/// One window (or app) in the switcher. Pure layers + two labels, laid out
/// by hand: cheap to configure and reuse on every keystroke.
final class ItemCell: NSView {
    private(set) var itemID: UInt64 = 0
    private var style: SwitcherStyle = .previews
    private var thumbBox: CGSize = .zero
    private var thumbnail: CGImage?
    private var hasThumbnail: Bool { thumbnail != nil }
    private var dimmed = false
    private var badge: String?

    private let selectionLayer = CALayer()
    private let thumbShadow = CALayer()
    private let thumbLayer = CALayer()
    private let placeholderLayer = CALayer()
    private let iconLayer = CALayer()
    private let badgeLayer = CALayer()
    private let badgeText = CATextLayer()
    private let closeButton = CALayer()
    private let minimizeButton = CALayer()
    private let titleField = NSTextField(labelWithString: "")
    private let subtitleField = NSTextField(labelWithString: "")

    var isSelected = false { didSet { if isSelected != oldValue { updateColors() } } }
    var isHovered = false {
        didSet {
            guard isHovered != oldValue else { return }
            updateColors()
            updateButtons()
        }
    }

    override var isFlipped: Bool { true }
    override var wantsUpdateLayer: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layerContentsRedrawPolicy = .never
        guard let root = layer else { return }

        selectionLayer.cornerRadius = 14
        selectionLayer.cornerCurve = .continuous
        root.addSublayer(selectionLayer)

        placeholderLayer.cornerRadius = 10
        placeholderLayer.cornerCurve = .continuous
        root.addSublayer(placeholderLayer)

        thumbShadow.shadowOpacity = 0.28
        thumbShadow.shadowRadius = 5
        thumbShadow.shadowOffset = CGSize(width: 0, height: -2)
        thumbShadow.shadowColor = NSColor.black.cgColor
        root.addSublayer(thumbShadow)

        thumbLayer.cornerRadius = 8
        thumbLayer.cornerCurve = .continuous
        thumbLayer.masksToBounds = true
        thumbLayer.contentsGravity = .resize
        thumbLayer.borderWidth = 0.5
        thumbShadow.addSublayer(thumbLayer)

        iconLayer.contentsGravity = .resizeAspect
        iconLayer.shadowOpacity = 0.3
        iconLayer.shadowRadius = 3
        iconLayer.shadowOffset = CGSize(width: 0, height: -1)
        root.addSublayer(iconLayer)

        badgeLayer.cornerCurve = .continuous
        badgeLayer.shadowOpacity = 0.25
        badgeLayer.shadowRadius = 1.5
        badgeLayer.shadowOffset = CGSize(width: 0, height: -0.5)
        badgeLayer.isHidden = true
        badgeText.alignmentMode = .center
        badgeText.truncationMode = .end
        badgeLayer.addSublayer(badgeText)
        root.addSublayer(badgeLayer)

        for (button, symbol) in [(closeButton, "xmark"), (minimizeButton, "minus")] {
            button.cornerRadius = 10
            button.contentsGravity = .center
            button.isHidden = true
            button.contents = Self.symbol(symbol)
            root.addSublayer(button)
        }

        for field in [titleField, subtitleField] {
            field.lineBreakMode = .byTruncatingTail
            field.maximumNumberOfLines = 1
            field.cell?.truncatesLastVisibleLine = true
            field.allowsDefaultTighteningForTruncation = true
            addSubview(field)
        }

        // Nothing inside needs implicit animations except position changes of the cell itself.
        for l in [selectionLayer, thumbShadow, thumbLayer, placeholderLayer, iconLayer, closeButton, minimizeButton, badgeLayer, badgeText] {
            l.actions = ["contents": NSNull(), "bounds": NSNull(), "position": NSNull(), "backgroundColor": NSNull(),
                         "borderColor": NSNull(), "hidden": NSNull(), "opacity": NSNull()]
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    // MARK: - Configuration

    func configure(_ result: SearchResult, layout: SwitcherLayout, thumbnail: CGImage?, icon: NSImage?) {
        let item = result.item
        itemID = item.id
        style = layout.style
        thumbBox = layout.thumbSize
        dimmed = item.isMinimized || item.isAppHidden

        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        for l in [iconLayer, closeButton, minimizeButton, badgeText] { l.contentsScale = scale }
        badge = Settings.shared.showBadges ? item.badge : nil
        if let icon {
            iconLayer.contents = icon.layerContents(forContentsScale: scale)
        }

        let titleFont: NSFont
        let subtitleFont: NSFont
        switch style {
        case .previews:
            titleFont = .systemFont(ofSize: 12.5, weight: .medium)
            subtitleFont = .systemFont(ofSize: 11, weight: .regular)
            titleField.alignment = .center
            subtitleField.alignment = .center
            self.thumbnail = item.isWindowless ? nil : thumbnail
            thumbLayer.contents = self.thumbnail
        case .list:
            titleFont = .systemFont(ofSize: 14, weight: .medium)
            subtitleFont = .systemFont(ofSize: 11.5, weight: .regular)
            titleField.alignment = .left
            subtitleField.alignment = .left
            self.thumbnail = nil
            thumbLayer.contents = nil
        }

        let usesAppName = item.isWindowless || item.searchTitle.isEmpty
        titleField.attributedStringValue = Self.highlighted(
            usesAppName ? item.appName : item.searchTitle,
            ranges: usesAppName ? result.appRanges : result.titleRanges,
            font: titleFont, color: .labelColor, alignment: titleField.alignment,
            prefix: usesAppName ? nil : item.profile.map { ($0, item.profilePrefixLength) }
        )
        var subtitle = Self.highlighted(item.appName, ranges: result.appRanges, font: subtitleFont,
                                        color: .secondaryLabelColor, alignment: subtitleField.alignment)
        if item.isWindowless {
            subtitle = NSAttributedString(string: "No open windows", attributes: [
                .font: subtitleFont, .foregroundColor: NSColor.tertiaryLabelColor, .paragraphStyle: Self.paragraph(subtitleField.alignment),
            ])
        } else if let state = Self.stateLabel(item) {
            let m = NSMutableAttributedString(attributedString: subtitle)
            m.append(NSAttributedString(string: "  ·  \(state)", attributes: [
                .font: subtitleFont, .foregroundColor: NSColor.tertiaryLabelColor, .paragraphStyle: Self.paragraph(subtitleField.alignment),
            ]))
            subtitle = m
        }
        subtitleField.attributedStringValue = subtitle

        layoutContents()
        updateColors()
        updateButtons()
    }

    func setThumbnail(_ image: CGImage) {
        guard style == .previews, itemID >> 32 == 0, thumbnail !== image else { return }
        thumbnail = image
        thumbLayer.contents = image
        layoutContents()
        updateColors()
    }

    private static func stateLabel(_ item: WindowItem) -> String? {
        if item.isMinimized { return "Minimized" }
        if item.isAppHidden { return "Hidden" }
        if item.isFullscreen { return "Full Screen" }
        return nil
    }

    // MARK: - Layout

    override func layout() {
        super.layout()
        layoutContents()
    }

    override func setFrameSize(_ newSize: NSSize) {
        let changed = newSize != frame.size
        super.setFrameSize(newSize)
        if changed { layoutContents() }
    }

    private var thumbRect: CGRect {
        let box = CGRect(x: 10, y: 10, width: thumbBox.width, height: thumbBox.height)
        guard let image = thumbnail else { return box }
        let w = CGFloat(image.width), h = CGFloat(image.height)
        let s = min(box.width / w, box.height / h)
        let size = CGSize(width: (w * s).rounded(), height: (h * s).rounded())
        return CGRect(x: box.midX - size.width / 2, y: box.maxY - size.height, width: size.width, height: size.height)
    }

    private func layoutContents() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }

        selectionLayer.frame = bounds
        switch style {
        case .previews:
            let box = CGRect(x: 10, y: 10, width: thumbBox.width, height: thumbBox.height)
            if hasThumbnail {
                let rect = thumbRect
                thumbShadow.isHidden = false
                placeholderLayer.isHidden = true
                thumbShadow.frame = rect
                thumbLayer.frame = thumbShadow.bounds
                thumbShadow.shadowPath = CGPath(roundedRect: thumbShadow.bounds, cornerWidth: 8, cornerHeight: 8, transform: nil)
                let iconSize = (min(box.width, box.height) * 0.26).rounded()
                iconLayer.frame = CGRect(x: rect.minX + 6, y: rect.maxY - iconSize - 6, width: iconSize, height: iconSize)
            } else {
                thumbShadow.isHidden = true
                placeholderLayer.isHidden = false
                placeholderLayer.frame = box
                let iconSize = (min(box.width, box.height) * 0.56).rounded()
                iconLayer.frame = CGRect(x: box.midX - iconSize / 2, y: box.midY - iconSize / 2, width: iconSize, height: iconSize)
            }
            let textY = box.maxY + 7
            titleField.frame = CGRect(x: 8, y: textY, width: bounds.width - 16, height: 17)
            subtitleField.frame = CGRect(x: 8, y: textY + 17, width: bounds.width - 16, height: 15)
            let anchor = hasThumbnail ? thumbRect : box
            closeButton.frame = CGRect(x: anchor.minX - 6, y: anchor.minY - 6, width: 20, height: 20)
            minimizeButton.frame = CGRect(x: anchor.minX + 18, y: anchor.minY - 6, width: 20, height: 20)

        case .list:
            thumbShadow.isHidden = true
            placeholderLayer.isHidden = true
            let iconSize: CGFloat = 32
            iconLayer.frame = CGRect(x: 10, y: (bounds.height - iconSize) / 2, width: iconSize, height: iconSize)
            let textX: CGFloat = 52
            let textWidth = bounds.width - textX - 40
            titleField.frame = CGRect(x: textX, y: 6, width: textWidth, height: 18)
            subtitleField.frame = CGRect(x: textX, y: 25, width: textWidth, height: 16)
            closeButton.frame = CGRect(x: bounds.width - 32, y: (bounds.height - 20) / 2, width: 20, height: 20)
            minimizeButton.frame = .zero
        }
        layoutBadge()
    }

    /// A Dock-style red capsule on the icon's top-right corner.
    private func layoutBadge() {
        guard let badge else {
            badgeLayer.isHidden = true
            return
        }
        let icon = iconLayer.frame
        let height = min(max(icon.width * 0.42, 15), 20).rounded()
        let font = NSFont.systemFont(ofSize: (height * 0.64).rounded(), weight: .semibold)
        let text = NSAttributedString(string: badge, attributes: [.font: font, .foregroundColor: NSColor.white])
        let width = min(max(height, ceil(text.size().width) + height * 0.6), icon.width * 1.4)
        badgeLayer.isHidden = false
        badgeLayer.frame = CGRect(x: icon.maxX - width * 0.5 - icon.width * 0.12, y: icon.minY - height * 0.5 + icon.height * 0.12,
                                  width: width, height: height)
        badgeLayer.cornerRadius = height / 2
        badgeLayer.shadowPath = CGPath(roundedRect: badgeLayer.bounds, cornerWidth: height / 2, cornerHeight: height / 2, transform: nil)
        let lineHeight = ceil(font.ascender - font.descender)
        badgeText.string = text
        badgeText.frame = CGRect(x: 1, y: (height - lineHeight) / 2, width: width - 2, height: lineHeight)
    }

    // MARK: - Appearance

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateColors()
    }

    override func updateLayer() {
        updateColors()
    }

    private func updateColors() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            let accent = NSColor.controlAccentColor
            if isSelected {
                selectionLayer.backgroundColor = accent.withAlphaComponent(0.22).cgColor
                selectionLayer.borderColor = accent.withAlphaComponent(0.55).cgColor
                selectionLayer.borderWidth = 1.5
            } else if isHovered {
                selectionLayer.backgroundColor = NSColor.labelColor.withAlphaComponent(0.06).cgColor
                selectionLayer.borderWidth = 0
            } else {
                selectionLayer.backgroundColor = nil
                selectionLayer.borderWidth = 0
            }
            placeholderLayer.backgroundColor = NSColor.labelColor.withAlphaComponent(0.05).cgColor
            badgeLayer.backgroundColor = NSColor.systemRed.cgColor
            thumbLayer.borderColor = NSColor.labelColor.withAlphaComponent(0.12).cgColor
            let buttonColor = NSColor.windowBackgroundColor.withAlphaComponent(0.92).cgColor
            closeButton.backgroundColor = buttonColor
            minimizeButton.backgroundColor = buttonColor
            closeButton.borderColor = NSColor.labelColor.withAlphaComponent(0.15).cgColor
            minimizeButton.borderColor = closeButton.borderColor
            closeButton.borderWidth = 0.5
            minimizeButton.borderWidth = 0.5
        }
        thumbShadow.opacity = dimmed ? 0.5 : 1
        iconLayer.opacity = dimmed && !hasThumbnail ? 0.6 : 1
    }

    private func updateButtons() {
        let show = isHovered && itemID >> 32 == 0 // windowless apps can't be closed/minimized
        closeButton.isHidden = !show
        minimizeButton.isHidden = !show || style == .list
    }

    // MARK: - Hit testing

    enum Hit { case item, close, minimize }

    func hitPart(at point: NSPoint) -> Hit {
        if !closeButton.isHidden, closeButton.frame.insetBy(dx: -3, dy: -3).contains(point) { return .close }
        if !minimizeButton.isHidden, minimizeButton.frame.insetBy(dx: -3, dy: -3).contains(point) { return .minimize }
        return .item
    }

    // MARK: - Helpers

    private static func paragraph(_ alignment: NSTextAlignment) -> NSParagraphStyle {
        let p = NSMutableParagraphStyle()
        p.alignment = alignment
        p.lineBreakMode = .byTruncatingTail
        return p
    }

    /// `prefix`: a browser profile name and the UTF-16 length of the
    /// "Profile  ·  " prefix, drawn in the profile's color.
    static func highlighted(_ string: String, ranges: [NSRange], font: NSFont, color: NSColor,
                            alignment: NSTextAlignment, prefix: (name: String, length: Int)? = nil) -> NSAttributedString {
        let result = NSMutableAttributedString(string: string, attributes: [
            .font: font, .foregroundColor: color, .paragraphStyle: paragraph(alignment),
        ])
        let length = (string as NSString).length
        if let prefix, prefix.length <= length {
            let nameLength = min((prefix.name as NSString).length, prefix.length)
            result.addAttributes([.foregroundColor: profileColor(prefix.name),
                                  .font: NSFont.systemFont(ofSize: font.pointSize, weight: .semibold)],
                                 range: NSRange(location: 0, length: nameLength))
            result.addAttribute(.foregroundColor, value: NSColor.tertiaryLabelColor,
                                range: NSRange(location: nameLength, length: prefix.length - nameLength))
        }
        guard !ranges.isEmpty else { return result }
        let bold = NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask)
        for range in ranges where range.location + range.length <= length {
            result.addAttributes([.foregroundColor: NSColor.controlAccentColor, .font: bold], range: range)
        }
        return result
    }

    /// A stable color per profile name (FNV-1a hash; `hashValue` is randomized per launch).
    static func profileColor(_ name: String) -> NSColor {
        let palette: [NSColor] = [.systemBlue, .systemPurple, .systemPink, .systemOrange, .systemGreen, .systemTeal, .systemIndigo, .systemRed]
        var hash: UInt32 = 2_166_136_261
        for byte in name.utf8 { hash = (hash ^ UInt32(byte)) &* 16_777_619 }
        return palette[Int(hash % UInt32(palette.count))]
    }

    private static func symbol(_ name: String) -> NSImage? {
        let config = NSImage.SymbolConfiguration(pointSize: 9, weight: .bold)
            .applying(.init(hierarchicalColor: .secondaryLabelColor))
        return NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(config)
    }
}
