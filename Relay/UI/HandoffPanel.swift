import AppKit
import SwiftUI

/// Shows the handoff offer in a small panel under the menu bar icon.
/// The panel never takes focus, so the video keeps playing undisturbed,
/// and it also appears over full-screen apps.
final class HandoffPanelController {
    private let suggester: HandoffSuggester
    private let anchor: () -> NSRect?
    private var panel: NSPanel?
    private var shownID: UUID?

    private static let size = NSSize(width: 372, height: 150)

    init(suggester: HandoffSuggester, anchor: @escaping () -> NSRect?) {
        self.suggester = suggester
        self.anchor = anchor
        observeChanges { [weak self] in
            self?.update()
        }
    }

    private func update() {
        let suggestion = suggester.current
        guard suggestion?.id != shownID else { return }
        shownID = suggestion?.id
        if let suggestion {
            Task { self.present(suggestion) }
        } else {
            Task { self.hide() }
        }
    }

    private func present(_ suggestion: HandoffSuggester.Suggestion) {
        let panel = self.panel ?? makePanel()
        self.panel = panel
        let root = HandoffCard(
            suggestion: suggestion,
            accept: { [weak self] in self?.suggester.accept() },
            decline: { [weak self] in self?.suggester.decline() }
        )
        let hosting = NSHostingView(rootView: root)
        hosting.sizingOptions = []
        panel.contentView = hosting
        panel.setFrame(frame(), display: true)
        panel.orderFrontRegardless()
    }

    private func hide() {
        guard let panel else { return }
        // Let the card play its exit transition, then take the window away.
        (panel.contentView as? NSHostingView<HandoffCard>)?.rootView.isLeaving = true
        Task {
            try? await Task.sleep(for: .milliseconds(220))
            if self.shownID == nil { panel.orderOut(nil) }
        }
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: Self.size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.isReleasedWhenClosed = false
        return panel
    }

    /// Right under the menu bar icon, kept on screen.
    private func frame() -> NSRect {
        let size = Self.size
        let screen = NSScreen.screens.first { $0.frame.contains(anchor()?.origin ?? .zero) } ?? NSScreen.main ?? NSScreen.screens[0]
        let visible = screen.visibleFrame
        var origin: NSPoint
        if let anchor = anchor() {
            origin = NSPoint(x: anchor.midX - size.width / 2, y: anchor.minY - size.height - 2)
        } else {
            origin = NSPoint(x: visible.maxX - size.width - 8, y: visible.maxY - size.height - 4)
        }
        origin.x = min(max(origin.x, visible.minX + 8), visible.maxX - size.width - 8)
        return NSRect(origin: origin, size: size)
    }
}

/// boardui card: icon of the app that plays, one question, two buttons.
struct HandoffCard: View {
    let suggestion: HandoffSuggester.Suggestion
    let accept: () -> Void
    let decline: () -> Void
    var isLeaving = false

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var appeared = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                icon
                VStack(alignment: .leading, spacing: 3) {
                    Text("Écouter sur ce Mac ?")
                        .font(.rHeadline)
                        .foregroundStyle(Color(.textPrimary))
                    Text(message)
                        .font(.rBody2)
                        .foregroundStyle(Color(.textSecondary))
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            HStack(spacing: 8) {
                Spacer()
                Button("Pas maintenant", action: decline)
                    .buttonStyle(.r(.secondary, .small))
                Button("Passer l’enceinte ici", action: accept)
                    .buttonStyle(.r(.primary, .small))
            }
        }
        .padding(16)
        .frame(width: 340)
        .background(RoundedRectangle(cornerRadius: Radius.card, style: .continuous).fill(Color(.backgroundPrimary)))
        .overlay(RoundedRectangle(cornerRadius: Radius.card, style: .continuous).strokeBorder(Color(.borderButton), lineWidth: 1))
        .shadow(color: .black.opacity(0.06), radius: 6, x: 0, y: 0)
        .shadow(color: .black.opacity(0.14), radius: 24, x: 0, y: 8)
        .opacity(visible ? 1 : 0)
        .offset(y: visible || reduceMotion ? 0 : -8)
        .scaleEffect(visible || reduceMotion ? 1 : 0.97, anchor: .top)
        .animation(reduceMotion ? .easeInOut(duration: 0.15) : Motion.panel, value: visible)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .padding(.top, 6)
        .onAppear { appeared = true }
    }

    private var visible: Bool { appeared && !isLeaving }

    private var message: String {
        let source = suggestion.appName ?? "Du son"
        let verb = suggestion.appName == nil ? "est en cours de lecture" : "joue du son"
        return "\(source) \(verb) ici. « \(suggestion.speakerName) » est sur \(suggestion.holderName)."
    }

    @ViewBuilder private var icon: some View {
        if let appIcon = suggestion.appIcon {
            Image(nsImage: appIcon)
                .resizable()
                .interpolation(.high)
                .frame(width: 40, height: 40)
        } else {
            SymbolTile(symbol: "play.fill", size: 40, tint: Color(.accent500), background: Color(.selectionBackground))
        }
    }
}
