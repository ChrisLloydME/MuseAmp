import SnapKit
import UIKit

enum NowPlayingRelaxedPanel: Equatable {
    case lyrics
    case queue
}

@MainActor
class NowPlayingRelaxedShellView: UIView {
    let leftContentView: UIView
    let lyricsPanelView: UIView
    let queuePanelView: UIView

    private(set) var currentRightPanel: NowPlayingRelaxedPanel = .lyrics

    private nonisolated enum Layout {
        /// Inset of the columns from the safe area's left and right edges
        /// and, on each side, from the line that splits them.
        static let columnInset: CGFloat = 16
    }

    private let contentSafeAreaView: UIView = {
        let view = UIView()
        view.backgroundColor = .clear
        view.isUserInteractionEnabled = true
        return view
    }()

    private let leftPanelView: UIView = {
        let view = UIView()
        view.backgroundColor = .clear
        view.clipsToBounds = true
        return view
    }()

    private let rightPanelView: UIView = {
        let view = UIView()
        view.backgroundColor = .clear
        view.clipsToBounds = false
        return view
    }()

    private let rightPanelContentContainer: UIView = {
        let view = UIView()
        view.backgroundColor = .clear
        view.clipsToBounds = false
        return view
    }()

    init(
        leftContentView: UIView,
        lyricsPanelView: UIView,
        queuePanelView: UIView,
    ) {
        self.leftContentView = leftContentView
        self.lyricsPanelView = lyricsPanelView
        self.queuePanelView = queuePanelView
        super.init(frame: UIScreen.main.bounds)
        backgroundColor = .clear
        setupViewHierarchy()
        setupLayout()
        installHingeObserver()
        switchRightPanel(to: .lyrics, animated: false)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError()
    }

    /// Region frames are in fixed screen orientation, so the split uses
    /// physical left and right; in right-to-left the artwork column moves
    /// to the right as it did with leading and trailing.
    private var isArtworkColumnOnRight: Bool {
        UIView.userInterfaceLayoutDirection(for: semanticContentAttribute) == .rightToLeft
    }

    private lazy var physicalLeftColumn: UIView = isArtworkColumnOnRight ? rightPanelView : leftPanelView
    private lazy var physicalRightColumn: UIView = isArtworkColumnOnRight ? leftPanelView : rightPanelView
    /// Pinned to this view's centre, not the content area's: a vertical
    /// status bar insets only one side, which would move the content
    /// area's centre off the fold.
    private lazy var leftColumnInnerEdge = physicalLeftColumn.rightAnchor.constraint(
        equalTo: centerXAnchor,
        constant: -Layout.columnInset,
    )
    private lazy var rightColumnInnerEdge = physicalRightColumn.leftAnchor.constraint(
        equalTo: centerXAnchor,
        constant: Layout.columnInset,
    )

    override func layoutSubviews() {
        let split = columnSplit()
        let leftConstant = split.leftColumnMaxX - bounds.midX
        let rightConstant = split.rightColumnMinX - bounds.midX
        if leftColumnInnerEdge.constant != leftConstant {
            leftColumnInnerEdge.constant = leftConstant
        }
        if rightColumnInnerEdge.constant != rightConstant {
            rightColumnInnerEdge.constant = rightConstant
        }
        super.layoutSubviews()
    }

    /// Where the left column ends and the right column starts, in this
    /// view's coordinates.
    private func columnSplit() -> (leftColumnMaxX: CGFloat, rightColumnMinX: CGFloat) {
        let gutter = Layout.columnInset
        if let fold = activeVerticalDivision() {
            return (fold.minX - gutter, fold.maxX + gutter)
        }
        return (bounds.midX - gutter, bounds.midX + gutter)
    }

    /// The fold of a partly opened iPhone Duo when it runs down this view.
    /// Ignored unless it lies in the middle third, so neither column can
    /// collapse.
    private func activeVerticalDivision() -> CGRect? {
        #if MUSEAMP_HAS_RESERVED_REGIONS && !targetEnvironment(macCatalyst)
            // Regions describe the window's display; a view being removed
            // from it (folding closed) has none to ask about.
            if #available(iOS 27.1, *), window != nil {
                let content = bounds
                let middleThird = content.insetBy(dx: content.width / 3, dy: 0)
                for region in reservedRegions(kind: .division) {
                    let regionFrame: CGRect = region.frame
                    // Compared by edges: a fold reported as a zero-width
                    // line is an empty rect, which `intersects` rejects.
                    guard region.isActive,
                          regionFrame.height >= regionFrame.width,
                          regionFrame.maxY > content.minY,
                          regionFrame.minY < content.maxY,
                          regionFrame.midX > middleThird.minX,
                          regionFrame.midX < middleThird.maxX
                    else { continue }
                    return regionFrame
                }
            }
        #endif
        return nil
    }

    private func installHingeObserver() {
        #if MUSEAMP_HAS_RESERVED_REGIONS && !targetEnvironment(macCatalyst)
            if #available(iOS 27.1, *) {
                // Half open and flat open have the same bounds, so a fold
                // change alone would not lay the columns out again.
                //
                // The handler's isolation is not documented, and it also
                // runs when this view leaves the window (folding closed
                // tears the split layout down mid-update). So it asserts
                // nothing about its thread and only schedules a layout on
                // the main actor, which the view skips once it is off screen.
                let interaction = UIHingeInteraction { @Sendable [weak self] _, _ in
                    Task { @MainActor [weak self] in
                        guard let self, window != nil else { return }
                        setNeedsLayout()
                    }
                }
                addInteraction(interaction)
            }
        #endif
    }

    func switchRightPanel(to panel: NowPlayingRelaxedPanel, animated: Bool) {
        guard panel != currentRightPanel else {
            return
        }
        currentRightPanel = panel

        let incomingView: UIView
        let outgoingView: UIView

        switch panel {
        case .lyrics:
            incomingView = lyricsPanelView
            outgoingView = queuePanelView
        case .queue:
            incomingView = queuePanelView
            outgoingView = lyricsPanelView
        }

        guard animated else {
            outgoingView.alpha = 0
            outgoingView.transform = CGAffineTransform(scaleX: 0.96, y: 0.96)
            incomingView.alpha = 1
            incomingView.transform = .identity
            return
        }

        incomingView.alpha = 0
        incomingView.transform = CGAffineTransform(scaleX: 1.04, y: 1.04)

        Interface.springAnimate(
            duration: 0.35,
            dampingRatio: 0.92,
            initialVelocity: 0.8,
        ) {
            outgoingView.alpha = 0
            outgoingView.transform = CGAffineTransform(scaleX: 0.96, y: 0.96)
            incomingView.alpha = 1
            incomingView.transform = .identity
        }
    }

    private func setupViewHierarchy() {
        addSubview(contentSafeAreaView)
        contentSafeAreaView.addSubview(leftPanelView)
        contentSafeAreaView.addSubview(rightPanelView)

        leftPanelView.addSubview(leftContentView)
        rightPanelView.addSubview(rightPanelContentContainer)
        rightPanelContentContainer.addSubview(lyricsPanelView)
        rightPanelContentContainer.addSubview(queuePanelView)
    }

    private func setupLayout() {
        contentSafeAreaView.snp.makeConstraints { make in
            make.top.bottom.equalToSuperview()
            // A vertical status bar on the iPhone Duo sits inside the left
            // or right safe area; only the background reaches under it.
            make.left.right.equalTo(safeAreaLayoutGuide).inset(Layout.columnInset)
        }

        physicalLeftColumn.snp.makeConstraints { make in
            make.left.top.bottom.equalToSuperview()
        }

        physicalRightColumn.snp.makeConstraints { make in
            make.right.top.bottom.equalToSuperview()
        }

        NSLayoutConstraint.activate([leftColumnInnerEdge, rightColumnInnerEdge])

        leftContentView.snp.makeConstraints { make in
            make.edges.equalToSuperview()
        }

        rightPanelContentContainer.snp.makeConstraints { make in
            make.edges.equalToSuperview()
        }

        lyricsPanelView.snp.makeConstraints { make in
            make.edges.equalToSuperview()
        }

        queuePanelView.snp.makeConstraints { make in
            make.edges.equalToSuperview()
        }

        queuePanelView.alpha = 0
        queuePanelView.transform = CGAffineTransform(scaleX: 0.96, y: 0.96)
    }
}
