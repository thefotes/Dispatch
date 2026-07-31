import AppKit
import WebKit
import WLKit

/// The GitButler stack, floating in the middle of the screen.
///
/// Pressing the stack key opens it for whichever agent has focus in Herdr;
/// pressing it again puts it away. The window deliberately never becomes key:
/// you are looking at it *from* the terminal you were already typing in, and
/// stealing focus to show a read-only view would mean two keystrokes to get
/// back to where you were.
@MainActor
final class StackPanelController: NSObject {

    static let shared = StackPanelController()

    /// Fires whenever the window appears or disappears, so the key light can
    /// follow it.
    var onVisibilityChange: ((Bool) -> Void)?

    private var panel: NSPanel?
    private var webView: WKWebView?
    private var messageBridge: MessageBridge?
    private var shellLoaded = false
    private var pendingRender: Payload?
    private var loadGeneration = 0

    private static let width: CGFloat = 1160
    private static let initialHeight: CGFloat = 240
    private static let minimumHeight: CGFloat = 140

    var isVisible: Bool { panel?.isVisible == true }

    // MARK: - Toggle

    func toggle() {
        if isVisible {
            close()
        } else {
            open()
        }
    }

    func open() {
        present()
        // The window goes up straight away with a placeholder rather than
        // after `but status` returns: a key press that does nothing for a beat
        // reads as a key press that did not register.
        render(Payload(title: "…", subtitle: "", body: "<p class=\"note\">Reading stack…</p>"))
        loadGeneration += 1
        let generation = loadGeneration
        Task { [weak self] in
            let payload = await Self.buildPayload()
            guard let self, self.loadGeneration == generation, self.isVisible else { return }
            self.render(payload)
        }
    }

    func close() {
        guard let panel, panel.isVisible else { return }
        panel.orderOut(nil)
        onVisibilityChange?(false)
    }

    // MARK: - Content

    private struct Payload {
        var title: String
        var subtitle: String
        /// HTML, already escaped and styled.
        var body: String
    }

    private static func buildPayload() async -> Payload {
        let agent: HerdrAgent?
        do {
            agent = try await HerdrClient.focusedAgent()
        } catch {
            return Payload(
                title: "Herdr",
                subtitle: "",
                body: note(error.localizedDescription)
            )
        }

        guard let agent else {
            return Payload(
                title: "No focused agent",
                subtitle: "",
                body: note("Nothing has focus in Herdr right now.")
            )
        }
        guard let directory = agent.workingDirectory else {
            return Payload(
                title: agent.shortName,
                subtitle: "",
                body: note("Herdr did not report a working directory for this agent.")
            )
        }

        do {
            let output = try await GitButler.status(in: directory)
            let rendered = AnsiHTML.render(output.text)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            // A stack must not wrap — the graph only reads if the columns hold.
            // A failure is one long sentence, and clipping it behind a
            // scrollbar hides the half that says what to do about it.
            let body = rendered.isEmpty
                ? note("`but status` said nothing.")
                : "<pre\(output.succeeded ? "" : " class=\"wrap\"")>\(rendered)</pre>"
            return Payload(
                title: (directory as NSString).lastPathComponent,
                subtitle: abbreviate(directory),
                body: body
            )
        } catch {
            return Payload(
                title: (directory as NSString).lastPathComponent,
                subtitle: abbreviate(directory),
                body: note(error.localizedDescription)
            )
        }
    }

    private static func note(_ text: String) -> String {
        "<p class=\"note\">\(AnsiHTML.escapeHTML(text))</p>"
    }

    private static func abbreviate(_ path: String) -> String {
        let home = NSHomeDirectory()
        guard path == home || path.hasPrefix(home + "/") else { return path }
        return "~" + path.dropFirst(home.count)
    }

    private func render(_ payload: Payload) {
        guard shellLoaded, let webView else {
            pendingRender = payload
            return
        }
        pendingRender = nil
        let json = [
            "title": payload.title,
            "subtitle": payload.subtitle,
            "body": payload.body,
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: json),
              let encoded = String(data: data, encoding: .utf8)
        else { return }
        webView.evaluateJavaScript("window.render(\(encoded))")
    }

    // MARK: - Window

    private func present() {
        let panel = panel ?? makePanel()
        self.panel = panel
        centre(panel, height: panel.frame.height)
        panel.orderFrontRegardless()
        onVisibilityChange?(true)
    }

    private func makePanel() -> NSPanel {
        let contentRect = NSRect(x: 0, y: 0, width: Self.width, height: Self.initialHeight)
        let panel = NSPanel(
            contentRect: contentRect,
            styleMask: [.titled, .fullSizeContentView, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.titlebarAppearsTransparent = true
        panel.titleVisibility = .hidden
        for button: NSWindow.ButtonType in [.closeButton, .miniaturizeButton, .zoomButton] {
            panel.standardWindowButton(button)?.isHidden = true
        }
        panel.isMovableByWindowBackground = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true

        let configuration = WKWebViewConfiguration()
        let bridge = MessageBridge(owner: self)
        configuration.userContentController.add(bridge, name: "panel")

        let webView = WKWebView(frame: contentRect, configuration: configuration)
        webView.navigationDelegate = bridge
        webView.underPageBackgroundColor = NSColor.white
        webView.autoresizingMask = [.width, .height]
        self.webView = webView
        self.messageBridge = bridge

        // Rounded on its own layer: the window is transparent so the web
        // content would otherwise paint square corners into the shadow.
        let container = NSView(frame: contentRect)
        container.wantsLayer = true
        container.layer?.cornerRadius = 12
        container.layer?.masksToBounds = true
        container.layer?.backgroundColor = NSColor.white.cgColor
        container.addSubview(webView)
        panel.contentView = container

        shellLoaded = false
        webView.loadHTMLString(Self.shell, baseURL: nil)
        return panel
    }

    private func centre(_ panel: NSPanel, height: CGFloat) {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) }
            ?? NSScreen.main
            ?? NSScreen.screens.first
        guard let visible = screen?.visibleFrame else { return }

        let width = min(Self.width, visible.width - 80)
        let clamped = min(max(height, Self.minimumHeight), visible.height * 0.8)
        panel.setFrame(
            NSRect(
                x: visible.midX - width / 2,
                y: visible.midY - clamped / 2,
                width: width,
                height: clamped
            ),
            display: true
        )
    }

    // MARK: - Web callbacks

    fileprivate func shellDidLoad() {
        shellLoaded = true
        if let pending = pendingRender { render(pending) }
    }

    fileprivate func contentHeightChanged(_ height: CGFloat) {
        guard let panel, panel.isVisible else { return }
        centre(panel, height: height)
    }

    /// A message handler is retained by the content controller, so it holds the
    /// controller weakly to keep the webview from retaining itself through it.
    private final class MessageBridge: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
        private weak var owner: StackPanelController?

        init(owner: StackPanelController) {
            self.owner = owner
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            Task { @MainActor [weak owner] in owner?.shellDidLoad() }
        }

        func userContentController(
            _ controller: WKUserContentController,
            didReceive message: WKScriptMessage
        ) {
            guard let body = message.body as? [String: Any],
                  let type = body["type"] as? String
            else { return }
            Task { @MainActor [weak owner] in
                switch type {
                case "close":
                    owner?.close()
                case "height":
                    if let value = body["value"] as? Double {
                        owner?.contentHeightChanged(CGFloat(value))
                    }
                default:
                    break
                }
            }
        }
    }
}

// MARK: - Document

extension StackPanelController {
    /// Loaded once; `render` swaps the contents in place afterwards, which
    /// avoids the white flash of reloading a document per key press.
    static let shell = """
    <!doctype html>
    <html>
    <head>
    <meta charset="utf-8">
    <style>
      :root { color-scheme: light; }
      * { box-sizing: border-box; }
      html, body {
        margin: 0;
        background: #ffffff;
        color: #3a4150;
        font: 20px/1.55 "JetBrains Mono", "JetBrainsMono Nerd Font",
              ui-monospace, "SF Mono", Menlo, monospace;
        overflow: hidden;
      }
      /* A full-height column: the window is sized to the stack, but when the
         stack is taller than the screen allows, the output scrolls inside a
         window that still ends in its footer. */
      body { height: 100vh; display: flex; flex-direction: column; }
      header {
        flex: none;
        display: flex; align-items: baseline; gap: 10px;
        padding: 12px 18px 10px;
        border-bottom: 1px solid #e4e7ec;
      }
      #title { font-size: 20px; font-weight: 600; color: #1a1f28; }
      #subtitle { font-size: 16px; color: #8a919e; overflow: hidden;
                  text-overflow: ellipsis; white-space: nowrap; }
      #close {
        margin-left: auto; flex: none; cursor: default;
        color: #8a919e; font-size: 22px; line-height: 1; padding: 2px 4px;
      }
      #close:hover { color: #1a1f28; }
      main { flex: 1 1 auto; min-height: 0; padding: 12px 18px; overflow-y: auto; }
      pre { margin: 0; white-space: pre; overflow-x: auto; }
      pre.wrap { white-space: pre-wrap; overflow-x: hidden; word-break: break-word; }
      .note { margin: 2px 0; color: #6f7684; white-space: pre-wrap; }
      .b { font-weight: 700; }
      .d { opacity: 0.55; }
      .i { font-style: italic; }
      .u { text-decoration: underline; }
      footer {
        flex: none;
        padding: 9px 18px 11px;
        border-top: 1px solid #e4e7ec;
        font-size: 16px; color: #9aa1ac;
      }
      ::-webkit-scrollbar { width: 9px; height: 9px; }
      ::-webkit-scrollbar-thumb { background: #d4d8df; border-radius: 5px; }
    </style>
    </head>
    <body>
      <header>
        <span id="title"></span>
        <span id="subtitle"></span>
        <span id="close">&times;</span>
      </header>
      <main id="body"></main>
      <footer>press the stack key again to dismiss</footer>
      <script>
        const send = (payload) => window.webkit.messageHandlers.panel.postMessage(payload);

        window.render = ({ title, subtitle, body }) => {
          document.getElementById('title').textContent = title;
          document.getElementById('subtitle').textContent = subtitle;
          document.getElementById('body').innerHTML = body;
          requestAnimationFrame(measure);
        };

        // The window sizes itself to the stack rather than guessing: these are
        // a handful of lines most of the time, and a fixed frame would be
        // mostly empty. Report what the content *wants*, and let the window
        // clamp it — `main` scrolls if the clamp bites.
        const measure = () => {
          const chrome = document.querySelector('header').offsetHeight
            + document.querySelector('footer').offsetHeight;
          const content = document.getElementById('body').scrollHeight;
          send({ type: 'height', value: Math.ceil(chrome + content) });
        };

        document.getElementById('close').addEventListener('click', () => send({ type: 'close' }));
        // Clicking the chrome dismisses; clicking the output itself does not,
        // so the text stays selectable.
        document.addEventListener('click', (event) => {
          if (!event.target.closest('#body') && !event.target.closest('header')) {
            send({ type: 'close' });
          }
        });
        window.addEventListener('resize', measure);
      </script>
    </body>
    </html>
    """
}
