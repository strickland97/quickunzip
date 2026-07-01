//
//  QuickUnzipApp.swift
//  QuickUnzip
//
//  App entry point, AppDelegate (NSServices right-click handler + Dock file
//  open), and the shared AppCoordinator that bridges external triggers
//  (Services menu, Dock drop, double-click) into the SwiftUI window.
//

import SwiftUI
import AppKit
import FinderSync

// MARK: - App coordinator

@MainActor
final class AppCoordinator: ObservableObject {
    static let shared = AppCoordinator()

    /// The archive currently loaded into the window.
    @Published var currentArchive: URL?
    @Published var entries: [ArchiveEntry] = []
    @Published var format: ArchiveFormat = .unknown
    @Published var anyEncrypted: Bool = false
    @Published var listError: String?
    /// True while the entry list is being read in the background.
    @Published var isLoading: Bool = false

    /// Navigation history. `backStack` holds archives visited before the
    /// current one (most-recent-last); `forwardStack` holds archives that were
    /// navigated back from (most-recent-last). Loading a fresh archive clears
    /// `forwardStack`, mirroring browser semantics.
    @Published private(set) var backStack: [URL] = []
    @Published private(set) var forwardStack: [URL] = []

    var canGoBack: Bool { !backStack.isEmpty }
    var canGoForward: Bool { !forwardStack.isEmpty }

    let viewModel = ExtractionViewModel()

    /// Loads an archive's entry list into the window.
    /// Listing runs in a detached task so the MainActor stays responsive on
    /// large archives. The UI observes `isLoading` to show a spinner.
    /// `pushHistory` controls whether the previous currentArchive is recorded
    /// in `backStack`. Internal back/forward navigation set it to false.
    func load(_ url: URL, pushHistory: Bool = true) {
        if pushHistory, let cur = currentArchive, cur != url {
            backStack.append(cur)
            forwardStack.removeAll()
        }
        currentArchive = url
        entries = []
        format = ArchiveFormat.from(pathExtension: url.pathExtension)
        anyEncrypted = false
        listError = nil
        isLoading = true
        // LibarchiveEngine is stateless and Sendable; capturing the shared
        // instance is safe off-MainActor.
        let engine = LibarchiveEngine.shared
        Task.detached(priority: .userInitiated) {
            // Sandbox: dropped URLs need a security scope to be readable.
            let needsScope = url.startAccessingSecurityScopedResource()
            defer { if needsScope { url.stopAccessingSecurityScopedResource() } }
            let result: (entries: [ArchiveEntry], encrypted: Bool, error: Error?)
            do {
                let (entries, anyEncrypted) = try engine.listEntries(at: url)
                result = (entries, anyEncrypted, nil)
            } catch {
                result = ([], false, error)
            }
            // AppCoordinator.shared is a singleton; referencing it directly
            // avoids capturing `self` across the detached task boundary (which
            // would trip Swift 6 strict-concurrency isolation checks).
            await MainActor.run {
                let coord = AppCoordinator.shared
                coord.isLoading = false
                if let err = result.error {
                    coord.listError = err.localizedDescription
                    coord.entries = []
                } else {
                    coord.entries = result.entries
                    coord.anyEncrypted = result.encrypted
                }
            }
        }
    }

    /// Navigate back in history. The current archive is pushed onto
    /// `forwardStack`; the last item of `backStack` becomes current.
    func goBack() {
        guard let prev = backStack.popLast() else { return }
        if let cur = currentArchive { forwardStack.append(cur) }
        load(prev, pushHistory: false)
    }

    /// Navigate forward in history. The current archive is pushed onto
    /// `backStack`; the last item of `forwardStack` becomes current.
    func goForward() {
        guard let next = forwardStack.popLast() else { return }
        if let cur = currentArchive { backStack.append(cur) }
        load(next, pushHistory: false)
    }

    /// Handles URLs coming from the Services menu or Dock/file-open.
    /// Under App Sandbox, `autostart` no longer triggers extraction directly
    /// because the archive's parent folder is not writable without user
    /// authorization. Instead, the archive is loaded into the window and the
    /// user picks a destination via the in-window buttons (which route through
    /// NSOpenPanel). The `autostart` flag is retained for call-site
    /// compatibility but currently has no behavioral effect.
    func handle(urls: [URL], autostart: Bool) {
        guard let first = urls.first(where: { $0.isArchive }) else { return }
        NSApp.activate(ignoringOtherApps: true)
        load(first)
    }
}

// MARK: - App

@main
struct QuickUnzipApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var coordinator = AppCoordinator.shared
    @StateObject private var extractionQueue = ExtractionQueue()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(coordinator)
                .environmentObject(coordinator.viewModel)
                .environmentObject(extractionQueue)
                .frame(minWidth: 640, minHeight: 460)
                .onOpenURL { url in
                    coordinator.handle(urls: [url], autostart: false)
                }
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 820, height: 560)
        .commands {
            // History navigation commands appear in the app menu's toolbar
            // group and bind Cmd+[ / Cmd+] shortcuts.
            CommandGroup(after: .toolbar) {
                Button("后退") { coordinator.goBack() }
                    .keyboardShortcut("[", modifiers: .command)
                    .disabled(!coordinator.canGoBack)
                Button("前进") { coordinator.goForward() }
                    .keyboardShortcut("]", modifiers: .command)
                    .disabled(!coordinator.canGoForward)
            }
        }
    }
}

// MARK: - App delegate (Services provider)

final class AppDelegate: NSObject, NSApplicationDelegate {

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Register self as the Services provider so the NSServices entries in
        // Info.plist route to the handler below.
        NSApp.servicesProvider = self
        // First-launch: surface the system "Enable Finder extension" sheet so
        // the user can turn on the QuickUnzipFinderSync contextual menu item.
        // We gate on a UserDefaults flag so we only nag once.
        if !UserDefaults.standard.bool(forKey: "QUDidPromptFinderSync") {
            UserDefaults.standard.set(true, forKey: "QUDidPromptFinderSync")
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                FIFinderSyncController.showExtensionManagementInterface()
            }
        }
    }

    /// NSServices handler: Finder right-click > Services > "QuickUnzip: 打开压缩包".
    /// Under App Sandbox we cannot write to the archive's parent folder from
    /// the service, so the handler loads the archive into the app window;
    /// the user then picks a destination via the in-window NSOpenPanel flow.
    @objc func extractHereService(_ pboard: NSPasteboard,
                                  userData: String,
                                  error: AutoreleasingUnsafeMutablePointer<NSString?>) {
        guard let urls = pboard.readObjects(forClasses: [NSURL.self],
                                            options: nil) as? [URL],
              !urls.isEmpty else {
            error.pointee = "QuickUnzip: 未收到文件" as NSString
            return
        }
        let archives = urls.filter { $0.isArchive }
        guard !archives.isEmpty else {
            error.pointee = "QuickUnzip: 不支持的压缩包格式" as NSString
            return
        }
        // Load each archive into the window. Concurrent extraction is not
        // triggered; the user picks a destination via the in-window buttons.
        Task { @MainActor in
            for url in archives {
                AppCoordinator.shared.handle(urls: [url], autostart: true)
            }
        }
    }
}
