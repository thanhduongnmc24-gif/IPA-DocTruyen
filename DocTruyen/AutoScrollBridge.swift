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

/// Tìm UIScrollView bọc ngoài của SwiftUI ScrollView, theo dõi vị trí đọc hiện tại và cuộn mượt ở 60fps.
struct AutoScrollBridge: UIViewRepresentable {
    let isScrolling: Bool
    let speedPointsPerSecond: Double
    let onUserDragPause: () -> Void
    let onReachedBottom: () -> Void
    var onScrollProgressChanged: ((Double, Bool) -> Void)? = nil
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
            isScrolling: isScrolling,
            speed: speedPointsPerSecond
        )
    }

    static func dismantleUIView(_ uiView: ScrollBridgeAnchorView, coordinator: Coordinator) {
        coordinator.stopDisplayLink()
        coordinator.detachScrollObserver()
    }

    final class Coordinator: NSObject {
        var onUserDragPause: () -> Void
        var onReachedBottom: () -> Void
        var onScrollProgressChanged: ((Double, Bool) -> Void)?
        var onRegisterScrollRatioProvider: ((@escaping () -> Double) -> Void)?

        private weak var targetScrollView: UIScrollView?
        private weak var lastAnchorView: UIView?
        private var contentOffsetObservation: NSKeyValueObservation?
        private var displayLink: CADisplayLink?
        private var lastTimestamp: CFTimeInterval = 0
        private var isActive: Bool = false
        private var speed: Double = 45
        private var didNotifyBottom: Bool = false

        init(
            onUserDragPause: @escaping () -> Void,
            onReachedBottom: @escaping () -> Void,
            onScrollProgressChanged: ((Double, Bool) -> Void)?,
            onRegisterScrollRatioProvider: ((@escaping () -> Double) -> Void)?
        ) {
            self.onUserDragPause = onUserDragPause
            self.onReachedBottom = onReachedBottom
            self.onScrollProgressChanged = onScrollProgressChanged
            self.onRegisterScrollRatioProvider = onRegisterScrollRatioProvider
            super.init()
        }

        func update(anchorView: UIView, isScrolling: Bool, speed: Double) {
            self.speed = speed
            self.isActive = isScrolling
            self.lastAnchorView = anchorView

            attachToScrollViewIfNeeded(from: anchorView)

            if isScrolling {
                didNotifyBottom = false
                startDisplayLinkIfNeeded()
            } else {
                stopDisplayLink()
            }
        }

        func attachToScrollViewIfNeeded(from anchorView: UIView) {
            self.lastAnchorView = anchorView
            onRegisterScrollRatioProvider? { [weak self] in
                guard let self else { return 0.0 }
                if self.targetScrollView == nil, let anchor = self.lastAnchorView {
                    self.bindScrollView(self.findEnclosingScrollView(from: anchor))
                }
                guard let sv = self.targetScrollView else { return 0.0 }
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
            contentOffsetObservation = sv.observe(\.contentOffset, options: [.new]) { [weak self] scrollView, _ in
                guard let self else { return }
                let ratio = Self.computeStoryReadingRatio(for: scrollView)
                let userInteracting = scrollView.isDragging || scrollView.isTracking
                DispatchQueue.main.async { [weak self] in
                    self?.onScrollProgressChanged?(ratio, userInteracting)
                }
            }
        }

        func detachScrollObserver() {
            contentOffsetObservation?.invalidate()
            contentOffsetObservation = nil
        }

        /// Tính tỷ lệ vị trí đoạn văn bản đang hiển thị ở mép đọc phía trên màn hình (0.0 -> 1.0)
        static func computeStoryReadingRatio(for sv: UIScrollView) -> Double {
            let offsetY = sv.contentOffset.y + sv.adjustedContentInset.top
            // Nếu đang ở đầu chương (chưa cuộn quá phần tiêu đề chương) -> tính là đọc từ đầu (0.0)
            if offsetY <= 24 {
                return 0.0
            }

            let titleHeaderHeight: CGFloat = 38
            let bottomNavFooterHeight: CGFloat = 96
            let storyBodyHeight = max(1, sv.contentSize.height - titleHeaderHeight - bottomNavFooterHeight)

            // Vị trí dòng chữ người dùng đang nhìn ở phần trên màn hình
            let readingFocusOffset = max(0, offsetY - titleHeaderHeight + 18)
            let ratio = Double(readingFocusOffset / storyBodyHeight)
            return min(1.0, max(0.0, ratio))
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

            // Nếu người dùng tự chạm tay kéo màn hình -> tạm dừng cuộn tự động
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
