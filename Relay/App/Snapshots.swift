#if DEBUG
import AppKit
import OSLog
import SwiftUI

/// Debug aid: `Relay --snapshots` renders every window in light and dark
/// into the app's temporary directory, then quits.
enum Snapshots {
    static var requested: Bool { CommandLine.arguments.contains("--snapshots") }

    static func render(app: AppDelegate) {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("snapshots")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        var pages: [(String, NSSize, AnyView)] = OnboardingView.Step.allCases.map { step in
            ("onboarding-\(step.rawValue)", NSSize(width: 640, height: 600), AnyView(OnboardingView(initialStep: step)))
        }
        for page in WindowManager.SettingsPage.allCases {
            pages.append(("settings-\(page.rawValue)", NSSize(width: 820, height: 580), AnyView(SettingsPageSnapshot(page: page))))
        }
        pages.append(("help", NSSize(width: 700, height: 660), AnyView(HelpView())))
        let offer = HandoffSuggester.Suggestion(
            appName: "Safari",
            appIcon: NSWorkspace.shared.icon(forFile: "/Applications/Safari.app"),
            speakerName: "Eris 4.5BT",
            holderName: "MacBook Pro"
        )
        pages.append(("handoff", NSSize(width: 372, height: 150), AnyView(
            HandoffCard(suggestion: offer, accept: {}, decline: {})
                .frame(width: 372, height: 150)
                .background(Color(.backgroundFull))
        )))

        for (name, size, view) in pages {
            for dark in [false, true] {
                let root = view
                    .environment(app.coordinator)
                    .environment(app.store)
                    .environment(app.permissions)
                    .environment(app.speaker)
                    .environment(app.peers)
                    .environment(app.windows)
                    .environment(\.appActions, AppActions())
                let hosting = NSHostingView(rootView: WindowManager.layout(root))
                hosting.sizingOptions = []
                // Same window as the app (title bar and safe area included).
                let window = WindowManager.makeWindow(size: size)
                window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                window.contentView = hosting
                WindowManager.resize(window, to: size)
                hosting.layoutSubtreeIfNeeded()
                RunLoop.main.run(until: Date().addingTimeInterval(0.4))
                guard let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else { continue }
                hosting.cacheDisplay(in: hosting.bounds, to: rep)
                let url = directory.appendingPathComponent("\(name)-\(dark ? "dark" : "light").png")
                try? rep.representation(using: .png, properties: [:])?.write(to: url)
            }
        }
        Log.app.info("Snapshots written to \(directory.path, privacy: .public)")
        NSApp.terminate(nil)
    }
}

private struct SettingsPageSnapshot: View {
    let page: WindowManager.SettingsPage
    @Environment(WindowManager.self) private var windows

    var body: some View {
        SettingsView().onAppear { windows.settingsPage = page }
    }
}
#endif
