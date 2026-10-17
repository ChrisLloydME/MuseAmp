//
//  TabBarController+Popup.swift
//  MuseAmp
//
//  Created by @Lakr233 on 2026/04/11.
//

import Combine
import ConfigurableKit
import Kingfisher
import LNPopupController
import MuseAmpDatabaseKit
import MuseAmpPlayerKit
import UIKit

extension TabBarController {
    /// While the shell is detached (a relaxed or Catalyst layout is
    /// installed) it neither builds nor updates its Now Playing, so only the
    /// active layout follows playback and lyrics.
    private var hostsNowPlayingPopup: Bool {
        parent != nil
    }

    func prepareNowPlayingPopupContentViewController() {
        guard let contentViewController = makeNowPlayingPopupContentViewController() else { return }
        contentViewController.loadViewIfNeeded()
        updateNowPlayingPopupItem(using: environment.playbackController.snapshot)
    }

    override func willMove(toParent parent: UIViewController?) {
        // Dismiss while the bar is still in the window: LNPopupController
        // defers a dismissal requested off-window until the view returns,
        // and keeps the content controller alive until then.
        if parent == nil, popupPresentationState != .barHidden {
            dismissPopupBar(animated: false)
        }
        super.willMove(toParent: parent)
    }

    override func didMove(toParent parent: UIViewController?) {
        super.didMove(toParent: parent)
        guard parent != nil else {
            // Only a detach cancels a pending reopen: UIKit can report the
            // same attach more than once.
            attachmentGeneration &+= 1
            nowPlayingPopupContentViewController = nil
            isNowPlayingPopupOpen = false
            restoresOpenNowPlaying = false
            return
        }
        prepareNowPlayingPopupContentViewController()
        guard restoresOpenNowPlaying else {
            syncPopupPresentation(with: environment.playbackController.snapshot)
            return
        }
        restoresOpenNowPlaying = false
        reopenNowPlayingAfterAttach()
    }

    /// Opens Now Playing without animation once the shell has been laid out
    /// at its new size: LNPopupController can drop an open requested before
    /// the container's first layout.
    private func reopenNowPlayingAfterAttach() {
        let generation = attachmentGeneration
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            // A second fold or unfold before this runs detaches the shell
            // (and may attach it again), so this request no longer applies.
            guard generation == attachmentGeneration, hostsNowPlayingPopup else {
                AppLog.info(self, "reopenNowPlayingAfterAttach skipped, shell moved")
                return
            }
            let snapshot = environment.playbackController.snapshot
            guard snapshot.currentTrack != nil else {
                AppLog.info(self, "reopenNowPlayingAfterAttach skipped, nothing playing")
                syncPopupPresentation(with: snapshot)
                return
            }
            view.layoutIfNeeded()
            // Nothing may keep the keyboard up over the restored Now Playing.
            view.window?.endEditing(true)
            AppLog.info(self, "reopenNowPlayingAfterAttach")
            ensureNowPlayingPopupPresented(openFullscreen: true, animated: false)
        }
    }

    func configurePopupBar() {
        popupBar.customBarViewController = nil
        popupBar.barStyle = .floating
        popupBar.progressViewStyle = .bottom
        popupBar.usesContentControllersAsDataSource = false
        popupBar.dataSource = self
        popupBar.delegate = self

        popupBar.addInteraction(UIContextMenuInteraction(delegate: self))
    }

    func bindPlaybackPopup() {
        environment.playbackController.$snapshot
            .removeDuplicates { lhs, rhs in
                lhs.currentTrack == rhs.currentTrack
                    && lhs.state == rhs.state
                    && lhs.upcoming == rhs.upcoming
            }
            .receive(on: DispatchQueue.main)
            .sink { [weak self] snapshot in
                self?.syncPopupPresentation(with: snapshot)
            }
            .store(in: &cancellables)

        environment.playbackController.$snapshot
            .removeDuplicates { lhs, rhs in
                lhs.currentTime == rhs.currentTime
                    && lhs.duration == rhs.duration
            }
            .receive(on: DispatchQueue.main)
            .sink { [weak self] snapshot in
                self?.updatePopupProgress(using: snapshot)
            }
            .store(in: &cancellables)

        environment.playbackController.playbackTimeSubject
            .receive(on: DispatchQueue.main)
            .sink { [weak self] currentTime, duration in
                guard let self else { return }
                let snapshot = environment.playbackController.latestSnapshot
                    .withTime(currentTime, duration: duration)
                updatePopupProgress(using: snapshot)
            }
            .store(in: &cancellables)

        ConfigurableKit.publisher(
            forKey: AppPreferences.cleanSongTitleKey, type: Bool.self,
        )
        .dropFirst()
        .receive(on: DispatchQueue.main)
        .sink { [weak self] _ in
            guard let self else { return }
            updateNowPlayingPopupItem(using: environment.playbackController.snapshot)
        }
        .store(in: &cancellables)
    }

    private func syncPopupPresentation(with snapshot: PlaybackSnapshot) {
        guard hostsNowPlayingPopup else { return }
        guard !isPagingCooldownActive else {
            updatePopupProgress(using: snapshot)
            return
        }

        updateNowPlayingPopupItem(using: snapshot)

        guard snapshot.currentTrack != nil else {
            if popupPresentationState == .barPresented {
                dismissPopupBar(animated: true)
            }
            return
        }

        ensureNowPlayingPopupPresented(openFullscreen: false, animated: true)
    }

    private var isPagingCooldownActive: Bool {
        popupPagingHandler.isCooldownActive
    }

    private func ensureNowPlayingPopupPresented(openFullscreen: Bool, animated: Bool) {
        guard let contentViewController = makeNowPlayingPopupContentViewController() else { return }
        updateNowPlayingPopupItem(using: environment.playbackController.snapshot)

        if popupPresentationState == .barHidden || popupContent !== contentViewController {
            presentPopupBar(with: contentViewController, openPopup: openFullscreen, animated: animated)
            return
        }

        guard openFullscreen, popupPresentationState != .open else {
            return
        }
        openPopup(animated: animated)
    }

    private func makeNowPlayingPopupContentViewController() -> NowPlayingCompactController? {
        if let nowPlayingPopupContentViewController {
            return nowPlayingPopupContentViewController
        }
        guard hostsNowPlayingPopup else { return nil }

        let controller = NowPlayingCompactController(environment: environment)
        controller.title = String(localized: "Now Playing")
        nowPlayingPopupContentViewController = controller
        return controller
    }

    func updateNowPlayingPopupItem(using snapshot: PlaybackSnapshot) {
        guard hostsNowPlayingPopup else { return }
        _ = makeNowPlayingPopupContentViewController()

        let popupItem: LNPopupItem
        if let existing = popupBar.popupItem {
            popupItem = existing
        } else {
            popupItem = LNPopupItem()
            popupBar.popupItem = popupItem
        }

        popupItem.barButtonItems = [popupPlayPauseItem, popupNextItem]

        if let currentTrack = snapshot.currentTrack {
            let sanitizedTitle = currentTrack.title.sanitizedTrackTitle
            if popupItem.title != sanitizedTitle {
                popupItem.title = sanitizedTitle
            }
            if popupItem.subtitle != currentTrack.artistName {
                popupItem.subtitle = currentTrack.artistName
            }
            updatePopupBarButtonState(using: snapshot)
            popupItem.progress = Float(progress(for: snapshot))
            popupItem.accessibilityProgressLabel = String(localized: "Playback Progress")
            popupItem.accessibilityProgressValue = "\(formattedPlaybackTime(snapshot.currentTime)) / \(formattedPlaybackTime(snapshot.duration))"
            popupItem.userInfo = [
                "trackID": currentTrack.id,
                "queueIndex": snapshot.playerIndex as Any,
            ]
            updatePopupArtwork(for: currentTrack.artworkURL, popupItem: popupItem)
        } else {
            popupItem.title = String(localized: "Nothing Playing")
            popupItem.subtitle = nil
            popupPlayPauseItem.image = UIImage(systemName: "play.fill")
            popupPlayPauseItem.isEnabled = false
            popupNextItem.isEnabled = false
            popupItem.progress = 0
            popupItem.accessibilityProgressValue = nil
            popupItem.userInfo = nil
            updatePopupArtwork(for: nil, popupItem: popupItem)
        }
    }

    private func updatePopupProgress(using snapshot: PlaybackSnapshot) {
        guard let popupItem = popupBar.popupItem,
              snapshot.currentTrack != nil
        else {
            return
        }

        popupItem.progress = Float(progress(for: snapshot))
        popupItem.accessibilityProgressValue = "\(formattedPlaybackTime(snapshot.currentTime)) / \(formattedPlaybackTime(snapshot.duration))"
    }

    private func progress(for snapshot: PlaybackSnapshot) -> Double {
        guard snapshot.duration > 0 else {
            return 0
        }

        return min(max(snapshot.currentTime / snapshot.duration, 0), 1)
    }

    private func updatePopupBarButtonState(using snapshot: PlaybackSnapshot) {
        popupPlayPauseItem.image = UIImage(systemName: snapshot.state == .playing ? "pause.fill" : "play.fill")
        popupPlayPauseItem.isEnabled = true
        popupNextItem.isEnabled = !snapshot.upcoming.isEmpty || snapshot.repeatMode != .off
    }

    private static let placeholderArtwork: UIImage = Bundle.appIcon

    private func updatePopupArtwork(for artworkURL: URL?, popupItem: LNPopupItem) {
        if artworkURL == popupArtworkURL,
           popupItem.image != nil || popupArtworkTask != nil
        {
            return
        }

        popupArtworkTask?.cancel()
        popupArtworkTask = nil
        popupArtworkURL = artworkURL

        guard let artworkURL else {
            popupItem.image = Self.placeholderArtwork
            return
        }

        if artworkURL.isFileURL {
            let image = UIImage(contentsOfFile: artworkURL.path)
            if image == nil {
                AppLog.warning(self, "updatePopupArtwork missing local artwork path=\(artworkURL.path)")
            }
            popupItem.image = image ?? Self.placeholderArtwork
            return
        }

        popupItem.image = Self.placeholderArtwork

        popupArtworkTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let image = await retrievePopupArtwork(from: artworkURL)
            popupArtworkTask = nil
            guard !Task.isCancelled,
                  popupArtworkURL == artworkURL,
                  environment.playbackController.snapshot.currentTrack?.artworkURL == artworkURL
            else {
                return
            }
            popupItem.image = image ?? Self.placeholderArtwork
        }
    }

    private func retrievePopupArtwork(from artworkURL: URL) async -> UIImage? {
        await withCheckedContinuation { continuation in
            KingfisherManager.shared.retrieveImage(with: artworkURL) { result in
                switch result {
                case let .success(value):
                    continuation.resume(returning: value.image)
                case let .failure(error):
                    AppLog.warning(self, "retrievePopupArtwork failed url=\(artworkURL.absoluteString) error=\(error.localizedDescription)")
                    continuation.resume(returning: nil)
                }
            }
        }
    }
}

// MARK: - Popup Bar Paging (LNPopupBarDataSource & LNPopupBarDelegate)

extension TabBarController: LNPopupBarDataSource {
    func popupBar(_: LNPopupBar, popupItemBefore popupItem: LNPopupItem) -> LNPopupItem? {
        popupPagingHandler.popupItemBefore(popupItem)
    }

    func popupBar(_: LNPopupBar, popupItemAfter popupItem: LNPopupItem) -> LNPopupItem? {
        popupPagingHandler.popupItemAfter(popupItem)
    }
}

extension TabBarController: LNPopupBarDelegate {
    func popupBar(_: LNPopupBar, didDisplay newPopupItem: LNPopupItem, previous previousPopupItem: LNPopupItem?) {
        popupPagingHandler.didDisplay(newPopupItem, previous: previousPopupItem)
    }
}

// MARK: - Popup Presentation Delegate

extension TabBarController: LNPopupPresentationDelegate {
    func popupPresentationController(
        _: UIViewController,
        willOpenPopupWithContentController _: UIViewController,
        animated _: Bool,
    ) {
        isNowPlayingPopupOpen = true
        nowPlayingPopupContentViewController?.prepareForPopupOpen()
        setNeedsStatusBarAppearanceUpdate()
    }

    func popupPresentationController(
        _: UIViewController,
        willClosePopupWithContentController _: UIViewController,
        animated _: Bool,
    ) {
        isNowPlayingPopupOpen = false
        setNeedsStatusBarAppearanceUpdate()
    }

    func popupPresentationController(
        _: UIViewController,
        didClosePopupWithContentController _: UIViewController,
        animated _: Bool,
    ) {
        isNowPlayingPopupOpen = false
        setNeedsStatusBarAppearanceUpdate()

        guard environment.playbackController.snapshot.currentTrack == nil else {
            return
        }
        dismissPopupBar(animated: true)
    }
}

// MARK: - Popup Bar Context Menu

extension TabBarController: UIContextMenuInteractionDelegate {
    func contextMenuInteraction(
        _: UIContextMenuInteraction,
        configurationForMenuAtLocation _: CGPoint,
    ) -> UIContextMenuConfiguration? {
        guard let track = environment.playbackController.snapshot.currentTrack else {
            return nil
        }

        return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { [weak self] _ in
            self?.buildPopupContextMenu(for: track)
        }
    }

    private func buildPopupContextMenu(for track: PlaybackTrack) -> UIMenu? {
        let entry = track.playlistEntry
        let snapshot = environment.playbackController.snapshot
        var repairAction: UIAction?
        if let localTrack = environment.libraryDatabase.trackOrNil(byID: track.id),
           localTrack.trackID.isCatalogID || localTrack.albumID.isCatalogID
        {
            repairAction = TrackArtworkRepairPresenter.makeMenuAction { [weak self] _ in
                guard let self else { return }
                TrackArtworkRepairPresenter.present(
                    on: self,
                    track: localTrack,
                    repairService: environment.trackArtworkRepairService,
                )
            }
        }

        return popupSongContextMenuProvider.menu(
            title: track.title.sanitizedTrackTitle,
            for: entry,
            context: .library,
            configuration: .init(
                availablePlaylists: { [weak self] in
                    self?.environment.playlistStore.playlists ?? []
                },
                showInAlbum: { [weak self] in
                    guard let self,
                          let nav = selectedViewController as? UINavigationController
                    else { return }
                    let helper = AlbumNavigationHelper(
                        environment: environment,
                        viewController: nav.topViewController,
                    )
                    helper.pushAlbumDetail(songID: track.id, albumID: track.albumID, albumName: track.albumName ?? "", artistName: track.artistName)
                },
                primaryActions: popupPlaybackMenuProvider.songPrimaryActions(
                    trackProvider: { [weak self] in
                        self?.environment.playbackController.snapshot.currentTrack
                    },
                    queueProvider: { [weak self] in
                        self?.environment.playbackController.snapshot.queue ?? []
                    },
                    sourceProvider: { snapshot.source ?? .library },
                ),
                secondaryActions: repairAction.map { [$0] } ?? [],
            ),
        )
    }
}
