import Kingfisher
import LRUCache
import SnapKit
import UIKit

@MainActor
class MuseAmpImageView: UIView {
    let imageView = UIImageView()
    private let placeholderView = UIImageView()
    private let blurView: UIVisualEffectView = {
        let view = UIVisualEffectView(effect: UIBlurEffect(style: .regular))
        view.alpha = 0
        return view
    }()

    var currentURL: URL?
    var loadID: UInt = 0
    private var isShimmerActive = false
    private static let shimmerAnimationKey = "amImageView.shimmer"

    let previewCoordinator = PreviewCoordinator()

    var allowsPreviewOnTap = false {
        didSet {
            tapGestureRecognizer.isEnabled = allowsPreviewOnTap
            imageView.isUserInteractionEnabled = allowsPreviewOnTap
        }
    }

    var onImageLoaded: (URL, UIImage) -> Void = { _, _ in } {
        didSet {
            guard let currentURL, let image = imageView.image else { return }
            onImageLoaded(currentURL, image)
        }
    }

    private var placeholderSymbol = "music.note"
    private let tapGestureRecognizer = UITapGestureRecognizer()

    override init(frame: CGRect) {
        super.init(frame: frame)
        setup()
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        updatePlaceholderSize()
    }

    func configure(placeholder: String, cornerRadius: CGFloat) {
        placeholderSymbol = placeholder
        layer.cornerRadius = cornerRadius
        imageView.layer.cornerRadius = cornerRadius
        updatePlaceholderSize()
        if imageView.image == nil, currentURL == nil {
            showPlaceholderState()
        }
    }

    func setImage(_ image: UIImage) {
        invalidateCurrentLoad()
        currentURL = nil
        imageView.image = image
        showImageState()
    }

    func reset() {
        invalidateCurrentLoad()
        currentURL = nil
        imageView.image = nil
        handleTransientStateReset()
        showPlaceholderState()
    }

    func showImageState() {
        stopLoadingShimmer()
        removeNonGeometryAnimations(from: imageView.layer)
        removeNonGeometryAnimations(from: blurView.layer)
        removeNonGeometryAnimations(from: placeholderView.layer)
        imageView.alpha = 1
        blurView.alpha = 0
        placeholderView.alpha = 0
    }

    func showPlaceholderState() {
        stopLoadingShimmer()
        imageView.alpha = 0
        blurView.alpha = 0
        placeholderView.alpha = 1
    }

    func invalidateCurrentLoad() {
        loadID &+= 1
        imageView.kf.cancelDownloadTask()
    }

    func startLoadingShimmer() {
        guard !isShimmerActive else { return }
        isShimmerActive = true
        let animation = CABasicAnimation(keyPath: "backgroundColor")
        animation.fromValue = PlatformInterfacePalette.secondaryFill.cgColor
        animation.toValue = PlatformInterfacePalette.tertiaryFill.cgColor
        animation.duration = 0.8
        animation.autoreverses = true
        animation.repeatCount = .infinity
        animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        layer.add(animation, forKey: Self.shimmerAnimationKey)
    }

    func stopLoadingShimmer() {
        guard isShimmerActive else { return }
        isShimmerActive = false
        layer.removeAnimation(forKey: Self.shimmerAnimationKey)
    }

    @objc func handleTap() {
        presentPreview()
    }

    func handleLoadedImageApplied(_ image: UIImage, sourceURL url: URL) {
        previewCoordinator.pendingImage = image
        previewCoordinator.pendingSourceURL = url
        previewCoordinator.previewItemURL = Self.previewFileCache.value(forKey: url)
    }

    func handleTransientStateReset() {
        previewCoordinator.clear()
    }

    func logWarning(_ message: String) {
        AppLog.warning(self, message)
    }

    func logError(_ message: String) {
        AppLog.error(self, message)
    }

    private func setup() {
        backgroundColor = PlatformInterfacePalette.secondaryFill
        clipsToBounds = true

        imageView.contentMode = .scaleAspectFill
        imageView.clipsToBounds = true
        imageView.alpha = 0

        placeholderView.contentMode = .center
        placeholderView.tintColor = PlatformInterfacePalette.tertiaryText

        addSubview(imageView)
        addSubview(blurView)
        addSubview(placeholderView)

        imageView.snp.makeConstraints { make in
            make.edges.equalToSuperview()
        }
        blurView.snp.makeConstraints { make in
            make.edges.equalToSuperview()
        }
        placeholderView.snp.makeConstraints { make in
            make.center.equalToSuperview()
            make.width.lessThanOrEqualTo(64)
            make.height.lessThanOrEqualTo(64)
            make.top.greaterThanOrEqualToSuperview().offset(InterfaceStyle.Spacing.xSmall)
            make.leading.greaterThanOrEqualToSuperview().offset(InterfaceStyle.Spacing.xSmall)
            make.bottom.lessThanOrEqualToSuperview().offset(-InterfaceStyle.Spacing.xSmall)
            make.trailing.lessThanOrEqualToSuperview().offset(-InterfaceStyle.Spacing.xSmall)
        }

        tapGestureRecognizer.addTarget(self, action: #selector(handleTap))
        tapGestureRecognizer.isEnabled = false
        imageView.isUserInteractionEnabled = false
        imageView.addGestureRecognizer(tapGestureRecognizer)
    }

    /// Cancels in-flight fades but keeps frame animations: removing those
    /// mid layout animation snaps the image to its final frame while this
    /// view's rounded backing still animates, so the two drift apart.
    private func removeNonGeometryAnimations(from layer: CALayer) {
        for key in layer.animationKeys() ?? [] {
            let isGeometry = key.hasPrefix("position")
                || key.hasPrefix("bounds")
                || key.hasPrefix("transform")
                || key.hasPrefix("anchorPoint")
            if !isGeometry {
                layer.removeAnimation(forKey: key)
            }
        }
    }

    private func updatePlaceholderSize() {
        let containerSize = bounds.size.width
        guard containerSize > 0 else { return }
        let symbolSize = min(max(containerSize - 16, 12), 64)
        let configuration = UIImage.SymbolConfiguration(pointSize: symbolSize * 0.45, weight: .light)
        placeholderView.image = UIImage(systemName: placeholderSymbol, withConfiguration: configuration)
    }
}
