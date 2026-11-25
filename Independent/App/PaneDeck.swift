import UIKit

private final class SplitHandle: UIView {
    var adjust: ((CGFloat) -> Void)?
    var begin: (() -> Void)?
    var end: (() -> Void)?
    var axis: NSLayoutConstraint.Axis = .horizontal
    private let grip = UIView()

    init() {
        super.init(frame: .zero)
        isAccessibilityElement = true
        accessibilityTraits = .adjustable
        accessibilityLabel = "Resize split"
        accessibilityIdentifier = "t3rm.divider"
        accessibilityHint = "Drag to resize adjacent panes"
        grip.isUserInteractionEnabled = false
        grip.layer.cornerRadius = 1.5
        addSubview(grip)
        addGestureRecognizer(UIPanGestureRecognizer(target: self, action: #selector(drag(_:))))
    }
    required init?(coder: NSCoder) { fatalError() }
    func apply(_ chrome: TerminalChrome) {
        backgroundColor = chrome.surface
        grip.backgroundColor = chrome.secondary
    }
    override func layoutSubviews() {
        super.layoutSubviews()
        let size = axis == .horizontal ? CGSize(width: 3, height: min(28,bounds.height)) : CGSize(width: min(28,bounds.width), height: 3)
        grip.frame = CGRect(x: (bounds.width-size.width)/2, y: (bounds.height-size.height)/2, width: size.width, height: size.height)
    }
    @objc private func drag(_ pan: UIPanGestureRecognizer) {
        if pan.state == .began { begin?() }
        let translation = pan.translation(in: superview)
        adjust?(axis == .horizontal ? translation.x : translation.y)
        pan.setTranslation(.zero, in: superview)
        if pan.state == .ended || pan.state == .cancelled { end?() }
    }
    override func accessibilityIncrement() { adjust?(24) }
    override func accessibilityDecrement() { adjust?(-24) }
}

final class PaneDeck: UIView {
    private(set) var paneViews: [TerminalPane] = []
    private var handles: [SplitHandle] = []
    private var weights: [CGFloat] = []
    var changed: (([CGFloat]) -> Void)?
    var axis: NSLayoutConstraint.Axis = .vertical { didSet { if oldValue != axis { setNeedsLayout() } } }
    private let handleSize: CGFloat = 12
    private var chrome = TerminalChrome.current

    func apply(_ appearance: TerminalChrome) {
        chrome = appearance
        backgroundColor = appearance.stroke
        for handle in handles { handle.apply(appearance) }
    }

    func display(_ panes: [TerminalPane], weights: [CGFloat]) {
        for pane in paneViews where !panes.contains(where: { $0 === pane }) { pane.removeFromSuperview() }
        for handle in handles { handle.removeFromSuperview() }
        handles = []
        paneViews = panes
        self.weights = weights.count == panes.count ? weights : Array(repeating: 1, count: panes.count)
        for pane in panes where pane.superview !== self { addSubview(pane) }
        for index in 0..<max(0, panes.count - 1) {
            let handle = SplitHandle()
            handle.apply(chrome)
            handle.begin = { [weak self] in self?.setResizing(true) }
            handle.end = { [weak self] in self?.setResizing(false) }
            handle.adjust = { [weak self] delta in self?.move(index: index, by: delta) }
            handles.append(handle)
            addSubview(handle)
        }
        setNeedsLayout()
    }

    private func setResizing(_ resizing: Bool) {
        for pane in paneViews { pane.resizing = resizing }
    }
    private func move(index: Int, by delta: CGFloat) {
        guard index + 1 < paneViews.count, abs(delta) > 0 else { return }
        layoutIfNeeded()
        let sizes = paneViews.map { axis == .horizontal ? $0.bounds.width : $0.bounds.height }
        let pair = sizes[index] + sizes[index+1]
        let minimum = min(axis == .horizontal ? 60 : 36, pair/2)
        let a = max(minimum, min(pair-minimum, sizes[index]+delta))
        guard pair > 0, a != sizes[index] else { return }
        weights = sizes
        weights[index] = a
        weights[index+1] = pair-a
        changed?(weights)
        setNeedsLayout()
        layoutIfNeeded()
    }
    override func layoutSubviews() {
        super.layoutSubviews()
        guard !paneViews.isEmpty else { return }
        let length = axis == .horizontal ? bounds.width : bounds.height
        let divider = min(handleSize, length / CGFloat(paneViews.count * 2))
        let available = max(0,length - CGFloat(handles.count)*divider)
        let total = weights.reduce(0,+)
        guard total > 0 else { return }
        var position: CGFloat = 0
        var weight: CGFloat = 0
        func rect(_ origin: CGFloat, _ extent: CGFloat) -> CGRect {
            axis == .horizontal ? CGRect(x: origin, y: 0, width: extent, height: bounds.height) :
                CGRect(x: 0, y: origin, width: bounds.width, height: extent)
        }
        for (index, pane) in paneViews.enumerated() {
            weight += weights[index]
            let edge = (available * weight / total).rounded() + CGFloat(index)*divider
            pane.frame = rect(position, max(0,edge-position))
            position = edge
            if index < handles.count {
                handles[index].axis = axis
                handles[index].frame = rect(position, divider)
                handles[index].accessibilityValue = "\(Int(100 * weights[index] / total)) percent"
                position += divider
            }
        }
    }
}

// A scene may own several tabs, each with several panes. All scenes draw from
// the same history budget even when UIKit disconnects a background window.
final class HistoryBudget {
    static let shared = HistoryBudget()
    private let panes = NSHashTable<TerminalPane>.weakObjects()
    private var bytes = 24 * 1024 * 1024
    func add(_ pane: TerminalPane) { panes.add(pane); rebalance() }
    func remove(_ pane: TerminalPane) { panes.remove(pane); rebalance() }
    func underPressure() {
        bytes = min(bytes, 12 * 1024 * 1024)
        for pane in panes.allObjects { pane.releaseCache() }
        rebalance()
    }
    private func rebalance() {
        let all = panes.allObjects
        let share = bytes / max(1,all.count)
        for pane in all { pane.model.trim(bytes: share) }
    }
}
