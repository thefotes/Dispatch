import AppKit
import WebKit
import WLKit

/// A floating, non-activating HTML window: the shared chrome behind the pad's
/// panel keys. The window deliberately never becomes key: you are looking at
/// it *from* the terminal you were already typing in, and stealing focus to
/// show a status view would mean two keystrokes to get back to where you were.
@MainActor
final class FloatingPanel: NSObject {

    /// Fires whenever the window appears or disappears, so a key light can
    /// follow it.
    var onVisibilityChange: ((Bool) -> Void)?
    /// The close glyph or the window chrome was clicked. The owner decides
    /// whether dismissal is allowed right now, so this asks rather than closes.
    var onDismissRequested: (() -> Void)?

    /// Owners whose content is a short list rather than command output can ask
    /// for something narrower; the stack graph needs the full width, a model
    /// list would just be mostly margin. Set before the first `present`.
    var preferredWidth: CGFloat = FloatingPanel.width

    private var panel: NSPanel?
    private var webView: WKWebView?
    private var messageBridge: MessageBridge?
    private var shellLoaded = false
    private var queued: [String] = []

    private static let width: CGFloat = 1160
    private static let initialHeight: CGFloat = 240
    private static let minimumHeight: CGFloat = 140

    var isVisible: Bool { panel?.isVisible == true }

    func present() {
        let panel = panel ?? makePanel()
        self.panel = panel
        centre(panel, height: panel.frame.height)
        panel.orderFrontRegardless()
        onVisibilityChange?(true)
    }

    func close() {
        guard let panel, panel.isVisible else { return }
        panel.orderOut(nil)
        onVisibilityChange?(false)
    }

    // MARK: - Content

    /// Replaces the whole document.
    func render(title: String, subtitle: String, body: String, footer: String) {
        let payload = ["title": title, "subtitle": subtitle, "body": body, "footer": footer]
        evaluate("window.render(\(json(payload)))")
    }

    /// Adds HTML to the end of the body and keeps it scrolled into view.
    func append(_ html: String) {
        evaluate("window.append(\(json(["html": html])))")
    }

    func setFooter(_ text: String) {
        evaluate("window.setFooter(\(json(["text": text])))")
    }

    private func json(_ object: [String: String]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: object),
              let encoded = String(data: data, encoding: .utf8)
        else { return "{}" }
        return encoded
    }

    /// Scripts sent before the shell finishes loading are replayed in order
    /// once it has, so callers never have to care about load timing.
    private func evaluate(_ script: String) {
        guard shellLoaded, let webView else {
            queued.append(script)
            return
        }
        webView.evaluateJavaScript(script)
    }

    // MARK: - Window

    private func makePanel() -> NSPanel {
        let contentRect = NSRect(x: 0, y: 0, width: preferredWidth, height: Self.initialHeight)
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

        let width = min(preferredWidth, visible.width - 80)
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

    private func shellDidLoad() {
        shellLoaded = true
        guard let webView else { return }
        for script in queued { webView.evaluateJavaScript(script) }
        queued.removeAll()
    }

    private func contentHeightChanged(_ height: CGFloat) {
        guard let panel, panel.isVisible else { return }
        centre(panel, height: height)
    }

    /// A message handler is retained by the content controller, so it holds the
    /// panel weakly to keep the webview from retaining itself through it.
    private final class MessageBridge: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
        private weak var owner: FloatingPanel?

        init(owner: FloatingPanel) {
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
                    owner?.onDismissRequested?()
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

// MARK: - Shared fragments

/// HTML the panel owners build their bodies from.
enum PanelHTML {

    static func note(_ text: String) -> String {
        "<p class=\"note\">\(AnsiHTML.escapeHTML(text))</p>"
    }

    /// A `$ but ...` line introducing a command's output.
    static func command(_ text: String) -> String {
        "<div class=\"cmd\">$ \(AnsiHTML.escapeHTML(text))</div>"
    }

    /// A command's combined output, colour intact. Success keeps `pre`'s
    /// columns — a stack graph only reads if they hold. A failure is one long
    /// sentence, and clipping it behind a scrollbar hides the half that says
    /// what to do about it, so it wraps instead.
    static func output(_ output: GitButler.StatusOutput) -> String {
        let rendered = AnsiHTML.render(output.text)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !rendered.isEmpty else { return note("(no output)") }
        return "<pre\(output.succeeded ? "" : " class=\"wrap\"")>\(rendered)</pre>"
    }

    static func abbreviate(_ path: String) -> String {
        let home = NSHomeDirectory()
        guard path == home || path.hasPrefix(home + "/") else { return path }
        return "~" + path.dropFirst(home.count)
    }
}

// MARK: - Document

extension FloatingPanel {
    /// Loaded once; `render` and `append` mutate the contents in place
    /// afterwards, which avoids the white flash of reloading a document per
    /// key press.
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
      /* A full-height column: the window is sized to the content, but when it
         is taller than the screen allows, the output scrolls inside a window
         that still ends in its footer. */
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
      .cmd { margin: 14px 0 4px; font-weight: 700; color: #1a1f28; }
      .cmd:first-child { margin-top: 0; }
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
      <footer></footer>
      <script>
        const send = (payload) => window.webkit.messageHandlers.panel.postMessage(payload);

        window.render = ({ title, subtitle, body, footer }) => {
          document.getElementById('title').textContent = title;
          document.getElementById('subtitle').textContent = subtitle;
          document.getElementById('body').innerHTML = body;
          document.querySelector('footer').textContent = footer;
          requestAnimationFrame(measure);
        };

        window.append = ({ html }) => {
          const main = document.getElementById('body');
          const holder = document.createElement('div');
          holder.innerHTML = html;
          while (holder.firstChild) main.appendChild(holder.firstChild);
          requestAnimationFrame(() => {
            measure();
            main.scrollTop = main.scrollHeight;
          });
        };

        window.setFooter = ({ text }) => {
          document.querySelector('footer').textContent = text;
        };

        // The window sizes itself to the content rather than guessing: these
        // are a handful of lines most of the time, and a fixed frame would be
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
