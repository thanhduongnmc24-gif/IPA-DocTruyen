import SwiftUI
import UIKit

/// Tìm UIScrollView bọc ngoài của SwiftUI ScrollView và cuộn mượt ở 60fps theo tốc độ (pt/giây).
struct AutoScrollBridge: UIViewRepresentable {
    let isScrolling: Bool
    let speedPointsPerSecond: Double
    let onUserDragPause: () -> Void
    let onReachedBottom: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(
            onUserDragPause: onUserDragPause,
            onReachedBottom: onReachedBottom
        )
    }

    func makeUIView(context: Context) -> UIView {
        let view = UIView(frame: .zero)
        view.isUserInteractionEnabled = false
        view.backgroundColor = .clear
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        context.coordinator.onUserDragPause = onUserDragPause
        context.coordinator.onReachedBottom = onReachedBottom
        context.coordinator.update(
            anchorView: uiView,
            isScrolling: isScrolling,
            speed: speedPointsPerSecond
        )
    }

    static func dismantleUIView(_ uiView: UIView, coordinator: Coordinator) {
        coordinator.stopDisplayLink()
    }

    final class Coordinator: NSObject {
        var onUserDragPause: () -> Void
        var onReachedBottom: () -> Void

        private weak var targetScrollView: UIScrollView?
        private var displayLink: CADisplayLink?
        private var lastTimestamp: CFTimeInterval = 0
        private var isActive: Bool = false
        private var speed: Double = 45
        private var didNotifyBottom: Bool = false

        init(onUserDragPause: @escaping () -> Void, onReachedBottom: @escaping () -> Void) {
            self.onUserDragPause = onUserDragPause
            self.onReachedBottom = onReachedBottom
        }

        func update(anchorView: UIView, isScrolling: Bool, speed: Double) {
            self.speed = speed
            self.isActive = isScrolling

            if targetScrollView == nil {
                DispatchQueue.main.async { [weak self, weak anchorView] in
                    guard let self, let anchorView else { return }
                    self.targetScrollView = self.findEnclosingScrollView(from: anchorView)
                }
            }

            if isScrolling {
                didNotifyBottom = false
                startDisplayLinkIfNeeded()
            } else {
                stopDisplayLink()
            }
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
