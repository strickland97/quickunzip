//
//  FinderSync.swift
//  QuickUnzipFinderSync
//
//  Finder Sync extension: adds a top-level "用 QuickUnzip 打开" item to the
//  Finder contextual menu for any selection that contains an archive. Clicking
//  the item hands the archive URLs to the main QuickUnzip app via NSWorkspace.
//

import Cocoa
import FinderSync
import UniformTypeIdentifiers

class FinderSync: FIFinderSync {

    /// Extensions we surface the menu item for. Anything else is ignored so
    /// the menu stays out of the way on non-archive selections.
    private static let archiveExtensions: Set<String> = [
        "zip", "rar", "7z", "tar", "tgz", "tbz2", "tbz", "txz", "tlz",
        "gz", "bz2", "xz", "lz", "zst", "cab", "iso", "lha", "lzh"
    ]

    override init() {
        super.init()
        // Observe the root directory so the extension is active in every
        // Finder window. The contextual menu is filtered per-selection in
        // `menu(for:)` so the item only appears when an archive is selected.
        FIFinderSyncController.default().directoryURLs = [URL(fileURLWithPath: "/")]
    }

    // MARK: - Contextual menu

    override func menu(for menuKind: FIMenuKind) -> NSMenu? {
        // Only show for right-click on selected items, not on empty space.
        guard menuKind == .contextualMenuForItems else { return nil }
        let menu = NSMenu(title: "")
        let item = NSMenuItem(title: "用 QuickUnzip 打开",
                              action: #selector(openInQuickUnzip(_:)),
                              keyEquivalent: "")
        // Use a small archive-type icon so the item is visually distinct.
        let icon = NSWorkspace.shared.icon(for: UTType.archive)
        icon.size = NSSize(width: 16, height: 16)
        item.image = icon
        menu.addItem(item)
        return menu
    }

    @objc func openInQuickUnzip(_ sender: NSMenuItem) {
        // selectedItemURLs() returns the Finder-selected file URLs at click time.
        guard let selected = FIFinderSyncController.default().selectedItemURLs(),
              !selected.isEmpty else { return }
        // Keep only archive-looking files so non-archive selections are a no-op.
        let archives = selected.filter {
            Self.archiveExtensions.contains($0.pathExtension.lowercased())
        }
        guard !archives.isEmpty else { return }
        // Launch the main QuickUnzip app with the archive URLs. NSWorkspace
        // resolves the app by bundle identifier, so this works regardless
        // of where QuickUnzip.app is installed.
        guard let appURL = NSWorkspace.shared.urlForApplication(
            withBundleIdentifier: "com.quickunzip.app") else { return }
        let config = NSWorkspace.OpenConfiguration()
        NSWorkspace.shared.open(archives, withApplicationAt: appURL, configuration: config)
    }
}
