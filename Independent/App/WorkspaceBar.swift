import UIKit

/// A scrolling session strip and a fixed set of reachable workspace actions.
final class WorkspaceBar: UIView {
    private let strip = UIScrollView()
    private let tabs = UIStackView()
    private let actions = UIStackView()
    private let row = UIStackView()
    private let rule = UIView()
    private let newTab = UIButton(type: .system)
    private let split = UIButton(type: .system)
    private let search = UIButton(type: .system)
    private let settings = UIButton(type: .system)
    private let more = UIButton(type: .system)
    private var chrome = TerminalChrome.current
    private var previousWidth: CGFloat = 0
    private var titles: [String] = []
    private var active = -1
    private var revealActive = false

    var selectTab: ((Int) -> Void)?
    var makeMenu: ((Bool) -> UIMenu)? {
        didSet { more.menu = makeMenu?(split.isHidden) }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        row.alignment = .fill
        row.spacing = 4
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        strip.showsHorizontalScrollIndicator = false
        strip.scrollsToTop = false
        strip.contentInsetAdjustmentBehavior = .never
        tabs.alignment = .fill
        tabs.spacing = 2
        tabs.translatesAutoresizingMaskIntoConstraints = false
        strip.addSubview(tabs)
        row.addArrangedSubview(strip)
        row.addArrangedSubview(actions)
        actions.alignment = .center
        actions.setContentHuggingPriority(.required, for: .horizontal)
        actions.setContentCompressionResistancePriority(.required, for: .horizontal)

        for (button, symbol, name, id) in [
            (newTab, "plus", "New tab", "newTab"), (split, "rectangle.split.2x1", "Split pane", "split"),
            (search, "magnifyingglass", "Search terminal", "search"), (settings, "gearshape", "Settings", "settings"),
            (more, "ellipsis", "Terminal actions", "actions")
        ] {
            let icon = UIImage.SymbolConfiguration(pointSize: button === more ? 19 : 17, weight: .semibold)
            button.setImage(UIImage(systemName: symbol, withConfiguration: icon), for: .normal)
            button.accessibilityLabel = name
            button.accessibilityIdentifier = "t3rm." + id
            button.isPointerInteractionEnabled = true
            button.layer.cornerCurve = .continuous
            actions.addArrangedSubview(button)
            let width = button.widthAnchor.constraint(equalToConstant: 44)
            width.priority = .init(999) // A hidden stack item collapses to zero width.
            width.isActive = true
            button.heightAnchor.constraint(equalToConstant: 44).isActive = true
        }
        more.showsMenuAsPrimaryAction = true
        rule.isUserInteractionEnabled = false
        addSubview(rule)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            row.topAnchor.constraint(equalTo: topAnchor), row.bottomAnchor.constraint(equalTo: bottomAnchor),
            tabs.leadingAnchor.constraint(equalTo: strip.contentLayoutGuide.leadingAnchor),
            tabs.trailingAnchor.constraint(equalTo: strip.contentLayoutGuide.trailingAnchor),
            tabs.topAnchor.constraint(equalTo: strip.contentLayoutGuide.topAnchor),
            tabs.bottomAnchor.constraint(equalTo: strip.contentLayoutGuide.bottomAnchor),
            tabs.heightAnchor.constraint(equalTo: strip.frameLayoutGuide.heightAnchor)
        ])
        apply(chrome)
    }
    required init?(coder: NSCoder) { fatalError() }

    func connect(to target: AnyObject, add: Selector, splitPane: Selector, find: Selector, preferences: Selector) {
        for (button, action) in [(newTab, add), (split, splitPane), (search, find), (settings, preferences)] {
            button.addTarget(target, action: action, for: .touchUpInside)
        }
    }

    func apply(_ appearance: TerminalChrome) {
        chrome = appearance
        backgroundColor = chrome.surface
        rule.backgroundColor = chrome.stroke
        for button in [split, search, settings, more] { button.tintColor = chrome.secondary }
        var config = UIButton.Configuration.plain()
        config.image = UIImage(systemName: "plus", withConfiguration: UIImage.SymbolConfiguration(pointSize: 17, weight: .semibold))
        config.baseForegroundColor = chrome.accent
        config.background.backgroundColor = chrome.accentFill
        config.background.cornerRadius = 9
        config.background.backgroundInsets = NSDirectionalEdgeInsets(top: 7, leading: 7, bottom: 7, trailing: 7)
        newTab.configuration = config
        for (index, view) in tabs.arrangedSubviews.enumerated() {
            if let button = view as? UIButton { styleTab(button, index: index) }
        }
    }

    func show(titles next: [String], selected: Int) {
        let previous = titles
        let previousActive = active
        titles = next
        active = selected
        while tabs.arrangedSubviews.count > next.count {
            tabs.arrangedSubviews.last?.removeFromSuperview()
        }
        for index in next.indices {
            let button: UIButton
            if index < tabs.arrangedSubviews.count, let existing = tabs.arrangedSubviews[index] as? UIButton {
                button = existing
            } else {
                button = UIButton(type: .system)
                button.isPointerInteractionEnabled = true
                button.tag = index
                button.accessibilityIdentifier = "t3rm.tab.\(index + 1)"
                button.accessibilityHint = "Switch to this terminal tab"
                button.addTarget(self, action: #selector(choose(_:)), for: .touchUpInside)
                button.widthAnchor.constraint(lessThanOrEqualToConstant: 160).isActive = true
                button.widthAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true
                tabs.addArrangedSubview(button)
            }
            if index >= previous.count || previous[index] != next[index] || index == previousActive || index == active {
                styleTab(button, index: index)
            }
        }
        if previousActive != active || previous.count != next.count || previous.indices.contains(active) && previous[active] != next[active] {
            revealActive = true
            setNeedsLayout()
        }
    }

    private func styleTab(_ button: UIButton, index: Int) {
        let selected = index == active
        var config = UIButton.Configuration.plain()
        config.title = titles[index]
        config.titleLineBreakMode = .byTruncatingTail
        config.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { incoming in
            var attrs = incoming
            let base = UIFont.monospacedSystemFont(ofSize: 14, weight: selected ? .semibold : .regular)
            attrs.font = UIFontMetrics(forTextStyle: .subheadline).scaledFont(for: base, maximumPointSize: 19)
            return attrs
        }
        config.image = selected ? Self.sessionMark : nil
        config.imagePadding = 7
        config.imageColorTransformer = UIConfigurationColorTransformer { [chrome] _ in chrome.accent }
        config.baseForegroundColor = selected ? chrome.text : chrome.secondary
        config.contentInsets = NSDirectionalEdgeInsets(top: 0, leading: 11, bottom: 0, trailing: 11)
        config.background.backgroundColor = selected ? chrome.raised : .clear
        config.background.cornerRadius = 9
        config.background.backgroundInsets = NSDirectionalEdgeInsets(top: 7, leading: 0, bottom: 7, trailing: 0)
        button.configuration = config
        button.accessibilityLabel = titles[index]
        button.accessibilityTraits = selected ? [.button, .selected] : .button
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        if traitCollection.preferredContentSizeCategory != previousTraitCollection?.preferredContentSizeCategory {
            apply(chrome)
            revealActive = true
            setNeedsLayout()
        }
    }

    @objc private func choose(_ button: UIButton) { selectTab?(button.tag) }

    override func layoutSubviews() {
        let compact = bounds.width < 560
        if split.isHidden != compact {
            split.isHidden = compact
            settings.isHidden = compact
            more.menu = makeMenu?(compact)
        }
        super.layoutSubviews()
        let pixel = 1 / (window?.screen.scale ?? UIScreen.main.scale)
        rule.frame = CGRect(x: 0, y: bounds.height - pixel, width: bounds.width, height: pixel)
        guard revealActive || previousWidth != bounds.width else { return }
        previousWidth = bounds.width
        revealActive = false
        if tabs.arrangedSubviews.indices.contains(active) {
            row.layoutIfNeeded()
            let tab = tabs.arrangedSubviews[active]
            strip.scrollRectToVisible(tab.convert(tab.bounds, to: strip), animated: false)
        }
    }

    // The bent 3 and cursor from the app icon, redrawn for the small tab label.
    private static let sessionMark = UIGraphicsImageRenderer(size: CGSize(width: 18, height: 18)).image { context in
        let pen = context.cgContext
        pen.setStrokeColor(UIColor.black.cgColor)
        pen.setLineWidth(1.9)
        pen.setLineCap(.round)
        pen.setLineJoin(.round)
        pen.move(to: CGPoint(x: 2, y: 3.5))
        pen.addLine(to: CGPoint(x: 11.5, y: 3.5))
        pen.addLine(to: CGPoint(x: 7.2, y: 8.8))
        pen.addLine(to: CGPoint(x: 11, y: 8.8))
        pen.addLine(to: CGPoint(x: 6.5, y: 14.5))
        pen.strokePath()
        pen.move(to: CGPoint(x: 11.5, y: 14.5))
        pen.addLine(to: CGPoint(x: 16, y: 14.5))
        pen.strokePath()
    }.withRenderingMode(.alwaysTemplate)
}
