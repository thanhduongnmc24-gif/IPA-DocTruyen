import SwiftUI
import UIKit

/// UIView neo bên trong ScrollView để tự động phát hiện UIScrollView ngay khi gắn vào hệ thống phân cấp View
final class ScrollBridgeAnchorView: UIView {
    var onHierarchyReady: ((UIView) -> Void)?

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil {
            onHierarchyReady?(self)
        }
    }

    override func didMoveToSuperview() {
        super.didMoveToSuperview()
        if superview != nil {
            onHierarchyReady?(self)
        }
    }
}

/// Tìm UIScrollView bọc ngoài của SwiftUI ScrollView, theo dõi vị trí đọc hiện tại, tự động khôi phục vị trí đọc giữa chương và cuộn mượt ở 60fps.
struct AutoScrollBridge: UIViewRepresentable {
    let chapterId: String
    let restoreScrollRatio: Double
    let restoreScrollOffsetY: Double
    let restoreToken: Int
    let isScrolling: Bool
    let speedPointsPerSecond: Double
    let onUserDragPause: () -> Void
    let onReachedBottom: () -> Void
    var onScrollProgressChanged: ((Double, Double, Bool) -> Void)? = nil
    var onRegisterScrollRatioProvider: ((@escaping () -> Double) -> Void)? = nil

    func makeCoordinator() -> Coordinator {
        Coordinator(
            onUserDragPause: onUserDragPause,
            onReachedBottom: onReachedBottom,
            onScrollProgressChanged: onScrollProgressChanged,
            onRegisterScrollRatioProvider: onRegisterScrollRatioProvider
        )
    }

    func makeUIView(context: Context) -> ScrollBridgeAnchorView {
        let view = ScrollBridgeAnchorView(frame: .zero)
        view.isUserInteractionEnabled = false
        view.backgroundColor = .clear
        view.onHierarchyReady = { [weak coordinator = context.coordinator] anchor in
            coordinator?.attachToScrollViewIfNeeded(from: anchor)
        }
        return view
    }

    func updateUIView(_ uiView: ScrollBridgeAnchorView, context: Context) {
        context.coordinator.onUserDragPause = onUserDragPause
        context.coordinator.onReachedBottom = onReachedBottom
        context.coordinator.onScrollProgressChanged = onScrollProgressChanged
        context.coordinator.onRegisterScrollRatioProvider = onRegisterScrollRatioProvider
        context.coordinator.update(
            anchorView: uiView,
            chapterId: chapterId,
            restoreRatio: restoreScrollRatio,
            restoreOffsetY: restoreScrollOffsetY,
            restoreToken: restoreToken,
            isScrolling: isScrolling,
            speed: speedPointsPerSecond
        )
    }

    static func dismantleUIView(_ uiView: ScrollBridgeAnchorView, coordinator: Coordinator) {
        coordinator.stopDisplayLink()
        coordinator.cancelPendingRestoreTasks()
        coordinator.detachScrollObserver()
    }

    final class Coordinator: NSObject {
        var onUserDragPause: () -> Void
        var onReachedBottom: () -> Void
        var onScrollProgressChanged: ((Double, Double, Bool) -> Void)?
        var onRegisterScrollRatioProvider: ((@escaping () -> Double) -> Void)?

        private weak var targetScrollView: UIScrollView?
        private weak var lastAnchorView: UIView?
        private var contentOffsetObservation: NSKeyValueObservation?
        private var contentSizeObservation: NSKeyValueObservation?
        private var displayLink: CADisplayLink?
        private var lastTimestamp: CFTimeInterval = 0
        private var isActive: Bool = false
        private var speed: Double = 45
        private var didNotifyBottom: Bool = false

        // Trạng thái khôi phục vị trí cuộn
        private var lastAppliedRestoreToken: Int = -1
        private var lastRestoredChapterId: String = ""
        private var pendingTargetRatio: Double = 0.0
        private var pendingTargetOffsetY: Double = 0.0
        private var isRestoringPosition: Bool = false
        private var hasCompletedInitialRestoreForChapter: Bool = false
        private var restoreWorkItems: [DispatchWorkItem] = []

        init(
            onUserDragPause: @escaping () -> Void,
            onReachedBottom: @escaping () -> Void,
            onScrollProgressChanged: ((Double, Double, Bool) -> Void)?,
            onRegisterScrollRatioProvider: ((@escaping () -> Double) -> Void)?
        ) {
            self.onUserDragPause = onUserDragPause
            self.onReachedBottom = onReachedBottom
            self.onScrollProgressChanged = onScrollProgressChanged
            self.onRegisterScrollRatioProvider = onRegisterScrollRatioProvider
            super.init()
        }

        func update(
            anchorView: UIView,
            chapterId: String,
            restoreRatio: Double,
            restoreOffsetY: Double,
            restoreToken: Int,
            isScrolling: Bool,
            speed: Double
        ) {
            self.speed = speed
            self.isActive = isScrolling
            self.lastAnchorView = anchorView

            attachToScrollViewIfNeeded(from: anchorView)

            if restoreToken != lastAppliedRestoreToken || chapterId != lastRestoredChapterId {
                lastAppliedRestoreToken = restoreToken
                lastRestoredChapterId = chapterId
                scheduleScrollRestoration(ratio: restoreRatio, offsetY: restoreOffsetY)
            }

            if isScrolling {
                didNotifyBottom = false
                startDisplayLinkIfNeeded()
            } else {
                stopDisplayLink()
            }
        }

        func cancelPendingRestoreTasks() {
            for item in restoreWorkItems {
                item.cancel()
            }
            restoreWorkItems.removeAll()
            isRestoringPosition = false
        }

        private func scheduleScrollRestoration(ratio: Double, offsetY: Double) {
            cancelPendingRestoreTasks()
            pendingTargetRatio = min(1.0, max(0.0, ratio))
            pendingTargetOffsetY = max(0.0, offsetY)

            guard pendingTargetRatio > 0.005 || pendingTargetOffsetY > 24.0 else {
                hasCompletedInitialRestoreForChapter = true
                isRestoringPosition = true
                if let sv = targetScrollView {
                    let topY = -sv.adjustedContentInset.top
                    sv.setContentOffset(CGPoint(x: 0, y: topY), animated: false)
                }
                let doneItem = DispatchWorkItem { [weak self] in
                    self?.isRestoringPosition = false
                }
                restoreWorkItems.append(doneItem)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.06, execute: doneItem)
                return
            }

            hasCompletedInitialRestoreForChapter = false
            isRestoringPosition = true

            // Thử khôi phục ở nhiều mốc layout (0s -> 0.55s) cho đến khi SwiftUI Text dựng xong toàn bộ chiều cao chương
            let delays: [Double] = [0.01, 0.05, 0.12, 0.22, 0.35, 0.55]
            for (idx, delay) in delays.enumerated() {
                let isLastPass = (idx == delays.count - 1)
                let item = DispatchWorkItem { [weak self] in
                    guard let self else { return }
                    self.applyPendingScrollRestoreIfPossible(isFinalPass: isLastPass)
                }
                restoreWorkItems.append(item)
                DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
            }
        }

        private func applyPendingScrollRestoreIfPossible(isFinalPass: Bool) {
            if targetScrollView == nil, let anchor = lastAnchorView {
                bindScrollView(findEnclosingScrollView(from: anchor))
            }
            guard let sv = targetScrollView else {
                if isFinalPass {
                    isRestoringPosition = false
                }
                return
            }

            // Nếu người dùng đã chủ động chạm tay kéo màn hình thì dừng can thiệp ngay lập tức
            if sv.isDragging || sv.isTracking {
                cancelPendingRestoreTasks()
                hasCompletedInitialRestoreForChapter = true
                return
            }

            let contentH = sv.contentSize.height
            let boundsH = max(1, sv.bounds.height)
            let maxOffsetY = max(0, contentH - boundsH + sv.adjustedContentInset.bottom)

            // Nếu SwiftUI chưa kịp tính xong chiều cao văn bản của chương, chờ nhịp kế tiếp
            guard contentH > boundsH + 30 && maxOffsetY > 10 else {
                if isFinalPass {
                    isRestoringPosition = false
                    hasCompletedInitialRestoreForChapter = true
                }
                return
            }

            let ratioBasedY = Self.computeTargetOffsetY(forRatio: pendingTargetRatio, in: sv)
            let targetY: CGFloat

            if pendingTargetOffsetY > 24.0 && CGFloat(pendingTargetOffsetY) <= maxOffsetY + 60 {
                // Nếu có tọa độ offsetY đã lưu và tương thích với chiều cao chương hiện tại thì ưu tiên khôi phục chính xác từng dòng
                let savedY = min(maxOffsetY, max(0, CGFloat(pendingTargetOffsetY)))
                if pendingTargetRatio > 0.005 {
                    let diffRatio = abs(Double(savedY - ratioBasedY) / Double(max(1, contentH)))
                    targetY = (diffRatio <= 0.12) ? savedY : ratioBasedY
                } else {
                    targetY = savedY
                }
            } else {
                targetY = ratioBasedY
            }

            let clampedY = min(maxOffsetY, max(-sv.adjustedContentInset.top, targetY))
            if abs(sv.contentOffset.y - clampedY) > 1.5 {
                sv.setContentOffset(CGPoint(x: sv.contentOffset.x, y: clampedY), animated: false)
            }

            hasCompletedInitialRestoreForChapter = true
            if isFinalPass {
                isRestoringPosition = false
            }
        }

        func attachToScrollViewIfNeeded(from anchorView: UIView) {
            self.lastAnchorView = anchorView
            onRegisterScrollRatioProvider? { [weak self] in
                guard let self else { return 0.0 }
                if self.targetScrollView == nil, let anchor = self.lastAnchorView {
                    self.bindScrollView(self.findEnclosingScrollView(from: anchor))
                }
                guard let sv = self.targetScrollView else { return self.pendingTargetRatio }
                return Self.computeStoryReadingRatio(for: sv)
            }

            if let existing = targetScrollView, existing.window != nil {
                return
            }

            if let found = findEnclosingScrollView(from: anchorView) {
                bindScrollView(found)
            } else {
                DispatchQueue.main.async { [weak self, weak anchorView] in
                    guard let self, let anchorView else { return }
                    if let found = self.findEnclosingScrollView(from: anchorView) {
                        self.bindScrollView(found)
                    }
                }
            }
        }

        private func bindScrollView(_ sv: UIScrollView?) {
            guard let sv else { return }
            if targetScrollView === sv && contentOffsetObservation != nil {
                return
            }
            targetScrollView = sv
            contentOffsetObservation?.invalidate()
            contentSizeObservation?.invalidate()

            contentSizeObservation = sv.observe(\.contentSize, options: [.new]) { [weak self] _, _ in
                guard let self, self.isRestoringPosition else { return }
                DispatchQueue.main.async { [weak self] in
                    self?.applyPendingScrollRestoreIfPossible(isFinalPass: false)
                }
            }

            contentOffsetObservation = sv.observe(\.contentOffset, options: [.new]) { [weak self] scrollView, _ in
                guard let self else { return }
                let userInteracting = scrollView.isDragging || scrollView.isTracking || scrollView.isDecelerating
                if self.isRestoringPosition && !userInteracting {
                    return
                }
                if userInteracting && self.isRestoringPosition {
                    self.cancelPendingRestoreTasks()
                    self.hasCompletedInitialRestoreForChapter = true
                }

                let ratio = Self.computeStoryReadingRatio(for: scrollView)
                let rawOffsetY = Double(max(0, scrollView.contentOffset.y + scrollView.adjustedContentInset.top))
                let activeScroll = userInteracting || self.isActive
                DispatchQueue.main.async { [weak self] in
                    self?.onScrollProgressChanged?(ratio, rawOffsetY, activeScroll)
                }
            }

            if isRestoringPosition {
                applyPendingScrollRestoreIfPossible(isFinalPass: false)
            }
        }

        func detachScrollObserver() {
            contentOffsetObservation?.invalidate()
            contentOffsetObservation = nil
            contentSizeObservation?.invalidate()
            contentSizeObservation = nil
        }

        /// Tính tỷ lệ vị trí đoạn văn bản đang hiển thị ở mép đọc phía trên màn hình (0.0 -> 1.0)
        static func computeStoryReadingRatio(for sv: UIScrollView) -> Double {
            let offsetY = sv.contentOffset.y + sv.adjustedContentInset.top
            if offsetY <= 24 {
                return 0.0
            }

            let titleHeaderHeight: CGFloat = 38
            let bottomNavFooterHeight: CGFloat = 96
            let storyBodyHeight = max(1, sv.contentSize.height - titleHeaderHeight - bottomNavFooterHeight)

            let readingFocusOffset = max(0, offsetY - titleHeaderHeight + 18)
            let ratio = Double(readingFocusOffset / storyBodyHeight)
            return min(1.0, max(0.0, ratio))
        }

        /// Nghịch đảo của computeStoryReadingRatio: Tính tọa độ contentOffset.y từ tỷ lệ đọc (0.0 -> 1.0)
        static func computeTargetOffsetY(forRatio ratio: Double, in sv: UIScrollView) -> CGFloat {
            let clamped = min(1.0, max(0.0, ratio))
            if clamped <= 0.005 {
                return -sv.adjustedContentInset.top
            }
            let titleHeaderHeight: CGFloat = 38
            let bottomNavFooterHeight: CGFloat = 96
            let storyBodyHeight = max(1, sv.contentSize.height - titleHeaderHeight - bottomNavFooterHeight)
            let readingFocusOffset = CGFloat(clamped) * storyBodyHeight
            let offsetY = max(0, readingFocusOffset + titleHeaderHeight - 18)
            let maxOffsetY = max(0, sv.contentSize.height - sv.bounds.height + sv.adjustedContentInset.bottom)
            return min(maxOffsetY, offsetY - sv.adjustedContentInset.top)
        }

        private func findEnclosingScrollView(from view: UIView) -> UIScrollView? {
            var current: UIView? = view.superview
            while let node = current {
                if let sv = node as? UIScrollView {
                    return sv
                }
                current = node.superview
            }
            return nil
        }

        private func startDisplayLinkIfNeeded() {
            guard displayLink == nil else { return }
            lastTimestamp = 0
            let link = CADisplayLink(target: self, selector: #selector(handleTick(_:)))
            link.add(to: .main, forMode: .common)
            displayLink = link
        }

        func stopDisplayLink() {
            displayLink?.invalidate()
            displayLink = nil
            lastTimestamp = 0
        }

        @objc private func handleTick(_ link: CADisplayLink) {
            guard isActive else {
                stopDisplayLink()
                return
            }

            guard let sv = targetScrollView else { return }

            if sv.isDragging || sv.isTracking {
                stopDisplayLink()
                DispatchQueue.main.async { [weak self] in
                    self?.onUserDragPause()
                }
                return
            }

            if lastTimestamp == 0 {
                lastTimestamp = link.timestamp
                return
            }

            let dt = min(link.timestamp - lastTimestamp, 0.05)
            lastTimestamp = link.timestamp

            let maxOffsetY = max(0, sv.contentSize.height - sv.bounds.height + sv.adjustedContentInset.bottom)
            guard maxOffsetY > 4 else { return }

            let nextY = sv.contentOffset.y + CGFloat(speed * dt)
            if nextY >= maxOffsetY {
                sv.setContentOffset(CGPoint(x: sv.contentOffset.x, y: maxOffsetY), animated: false)
                if !didNotifyBottom {
                    didNotifyBottom = true
                    stopDisplayLink()
                    DispatchQueue.main.async { [weak self] in
                        self?.onReachedBottom()
                    }
                }
            } else {
                sv.setContentOffset(CGPoint(x: sv.contentOffset.x, y: nextY), animated: false)
            }
        }
    }
}
