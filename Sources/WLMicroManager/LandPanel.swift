import Foundation
import WLKit

/// Lands the focused agent's stack onto the target, bottom branch first.
///
/// The land key is deliberately two presses: the first shows what would be
/// landed, the second runs it. Landing pushes to the target and is not easily
/// reversible, so a single stray key press must never do it. Any other pad
/// key while the confirmation is up cancels — reaching for a different key is
/// the closest thing a pad has to "no".
@MainActor
final class LandPanelController {

    static let shared = LandPanelController()

    /// Fires whenever the window appears or disappears, so the key light can
    /// follow it.
    var onVisibilityChange: ((Bool) -> Void)? {
        get { panel.onVisibilityChange }
        set { panel.onVisibilityChange = newValue }
    }

    enum Phase {
        case idle
        /// Window up, still working out what would be landed. The land key is
        /// ignored here: confirming a plan you have not seen is not consent.
        case loading
        case confirming
        case running
        case finished
    }

    private(set) var phase: Phase = .idle

    private let panel = FloatingPanel()
    private var directory: String?
    private var plan: [String] = []
    private var generation = 0

    /// How many lands one confirmation may run. Each land removes a branch, so
    /// a healthy loop finishes long before this; hitting it means `but` and
    /// this app disagree about what landing does, and stopping beats looping.
    private static let maxLands = 20

    init() {
        panel.onDismissRequested = { [weak self] in
            guard let self, self.phase != .running else { return }
            self.close()
        }
    }

    // MARK: - Key handling

    /// The land key: opens the confirmation, confirms it, or dismisses the
    /// finished report. Ignored while a land is running — there is nothing
    /// safe for a key press to mean mid-push.
    func handleLandKey() {
        switch phase {
        case .idle: openConfirmation()
        case .loading: break
        case .confirming: Task { await land() }
        case .running: break
        case .finished: close()
        }
    }

    /// Any other pad key. Returns true when the press cancelled the pending
    /// confirmation, in which case it must not also do its usual job — the
    /// press meant "no", not "focus agent 3".
    func handleOtherKey() -> Bool {
        switch phase {
        case .loading, .confirming:
            close()
            return true
        case .idle, .running, .finished:
            return false
        }
    }

    func close() {
        panel.close()
        phase = .idle
        directory = nil
        plan = []
        generation += 1   // orphans any in-flight load
    }

    // MARK: - Confirmation

    private func openConfirmation() {
        phase = .loading
        panel.present()
        panel.render(title: "…", subtitle: "", body: PanelHTML.note("Reading stack…"), footer: "")
        generation += 1
        let generation = self.generation
        Task { [weak self] in
            let prepared = await Self.prepare()
            guard let self, self.generation == generation, self.phase == .loading else { return }
            switch prepared {
            case .blocked(let title, let subtitle, let message):
                self.phase = .finished
                self.panel.render(
                    title: title,
                    subtitle: subtitle,
                    body: PanelHTML.note(message),
                    footer: "press the land key again to dismiss"
                )
            case .ready(let directory, let plan):
                self.directory = directory
                self.plan = plan
                self.phase = .confirming
                let listing = plan.enumerated()
                    .map { "  \($0.offset + 1). \($0.element)" }
                    .joined(separator: "\n")
                self.panel.render(
                    title: (directory as NSString).lastPathComponent,
                    subtitle: PanelHTML.abbreviate(directory),
                    body: "<pre>will land onto the target, bottom first:\n\n"
                        + AnsiHTML.escapeHTML(listing) + "</pre>",
                    footer: "press the land key again to land \(plan.count) "
                        + (plan.count == 1 ? "branch" : "branches")
                        + " — any other key cancels"
                )
            }
        }
    }

    private enum Preparation {
        case blocked(title: String, subtitle: String, message: String)
        case ready(directory: String, plan: [String])
    }

    private static func prepare() async -> Preparation {
        let agent: HerdrAgent?
        do {
            agent = try await HerdrClient.focusedAgent()
        } catch {
            return .blocked(title: "Herdr", subtitle: "", message: error.localizedDescription)
        }
        guard let agent else {
            return .blocked(
                title: "No focused agent",
                subtitle: "",
                message: "Nothing has focus in Herdr right now."
            )
        }
        guard let directory = agent.workingDirectory else {
            return .blocked(
                title: agent.shortName,
                subtitle: "",
                message: "Herdr did not report a working directory for this agent."
            )
        }

        let title = (directory as NSString).lastPathComponent
        let subtitle = PanelHTML.abbreviate(directory)
        do {
            let plan = try await GitButler.landPlan(in: directory)
            guard !plan.isEmpty else {
                return .blocked(
                    title: title,
                    subtitle: subtitle,
                    message: "Nothing to land — no applied branches in this workspace."
                )
            }
            return .ready(directory: directory, plan: plan)
        } catch {
            return .blocked(title: title, subtitle: subtitle, message: error.localizedDescription)
        }
    }

    // MARK: - Landing

    private func land() async {
        guard phase == .confirming, let directory else { return }
        phase = .running
        generation += 1
        let generation = self.generation
        panel.render(
            title: (directory as NSString).lastPathComponent,
            subtitle: PanelHTML.abbreviate(directory),
            body: "",
            footer: "landing…"
        )

        // The plan is refreshed after every land rather than iterated: each
        // land rebases what is left, and the confirmation's list is a promise
        // of intent, not of object identity.
        var landed = Set<String>()
        for _ in 0..<Self.maxLands {
            let plan: [String]
            do {
                plan = try await GitButler.landPlan(in: directory)
            } catch {
                panel.append(PanelHTML.note(error.localizedDescription))
                break
            }
            guard let branch = plan.first else { break }
            guard !landed.contains(branch) else {
                panel.append(PanelHTML.note(
                    "`\(branch)` is still in the workspace after landing it; stopping here."
                ))
                break
            }
            landed.insert(branch)

            panel.append(PanelHTML.command("but land --yes \(branch)"))
            do {
                let output = try await GitButler.land(branch, in: directory)
                panel.append(PanelHTML.output(output))
                if !output.succeeded { break }
            } catch {
                panel.append(PanelHTML.note(error.localizedDescription))
                break
            }
        }

        panel.append(PanelHTML.command("but status"))
        do {
            let status = try await GitButler.status(in: directory)
            panel.append(PanelHTML.output(status))
        } catch {
            panel.append(PanelHTML.note(error.localizedDescription))
        }

        guard self.generation == generation else { return }
        phase = .finished
        panel.setFooter("press the land key again to dismiss")
    }
}
