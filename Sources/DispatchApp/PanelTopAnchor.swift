import AppKit
import SwiftUI

/// Keeps the menu-bar panel fitted to its content, with its top edge under
/// the menu bar. A `MenuBarExtra` window grows with its content but does not
/// shrink while open: shorter content sits at the bottom of the old window,
/// leaving an empty gap under the menu bar.
enum PanelTopAnchor {
    /// The window frame whose content area is `contentHeight` tall, keeping
    /// the window's width, horizontal position, and non-content height, with
    /// its top edge at `top`.
    static func frame(
        fitting contentHeight: CGFloat,
        window: CGRect,
        currentContentHeight: CGFloat,
        keepingTopAt top: CGFloat
    ) -> CGRect {
        let height = window.height - currentContentHeight + contentHeight
        return CGRect(x: window.minX, y: top - height, width: window.width, height: height)
    }
}

/// Place behind the panel's content, so that this view's height is the
/// content's height, to keep the panel's window fitted and anchored.
struct PanelTopAnchorView: NSViewRepresentable {
    func makeNSView(context: Context) -> AnchoringView { AnchoringView() }
    func updateNSView(_ nsView: AnchoringView, context: Context) {}

    final class AnchoringView: NSView {
        /// The top edge where the system placed the panel when it opened.
        private var anchoredTop: CGFloat?
        private var observer: NSObjectProtocol?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            observer.map(NotificationCenter.default.removeObserver)
            observer = nil
            anchoredTop = nil
            guard let window else { return }
            // The system positions the panel under the menu bar each time it
            // opens, just before it becomes key.
            observer = NotificationCenter.default.addObserver(
                forName: NSWindow.didBecomeKeyNotification, object: window, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.anchoredTop = self?.window?.frame.maxY }
            }
        }

        override func setFrameSize(_ newSize: NSSize) {
            super.setFrameSize(newSize)
            // Resizing the window from inside layout would re-enter it.
            DispatchQueue.main.async { [weak self] in self?.fitWindow() }
        }

        private func fitWindow() {
            guard let window, let anchoredTop, let contentView = window.contentView else { return }
            let fitted = PanelTopAnchor.frame(
                fitting: frame.height,
                window: window.frame,
                currentContentHeight: contentView.frame.height,
                keepingTopAt: anchoredTop
            )
            guard fitted != window.frame else { return }
            window.setFrame(fitted, display: true)
        }
    }
}
