//
//  ExtractionService.swift
//  QuickUnzip
//
//  High-level orchestration: smart destination naming (avoid clobbering an
//  existing folder), Keychain-backed password recall, and an ObservableObject
//  view-model that drives the UI with progress.
//

import Foundation
import AppKit
import Security
import os

enum ExtractionService {

    /// Decides the destination directory for "extract here" semantics:
    ///  - If a single top-level entry is a directory equal to the archive stem,
    ///    extract directly into the archive's parent folder (no extra wrapper).
    ///  - Otherwise extract into `<parent>/<stem>/`, appending a suffix if a
    ///    folder of that name already exists.
    static func resolveDestination(for archiveURL: URL,
                                   entries: [ArchiveEntry]) -> URL {
        let parent = archiveURL.deletingLastPathComponent()
        let stem = archiveURL.archiveStem

        // Single top-level directory matching the stem -> extract in place.
        let topLevel = Set(entries.compactMap { entry -> String? in
            let parts = entry.path.split(separator: "/")
            return parts.first.map(String.init)
        })
        if topLevel.count == 1,
           let only = topLevel.first,
           only == stem,
           entries.contains(where: { $0.path == only || $0.path == only + "/" }) {
            return parent
        }

        // Otherwise create a dedicated folder, avoiding name collisions.
        var candidate = parent.appendingPathComponent(stem, isDirectory: true)
        var suffix = 1
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = parent.appendingPathComponent("\(stem) \(suffix)", isDirectory: true)
            suffix += 1
        }
        return candidate
    }

    // MARK: - Keychain password storage

    private static let serviceTag = "com.quickunzip.app"

    static func savePassword(_ password: String, for archiveURL: URL) {
        let account = archiveURL.lastPathComponent
        let data = Data(password.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceTag,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(query as CFDictionary)
        var add = query
        add[kSecValueData as String] = data
        SecItemAdd(add as CFDictionary, nil)
    }

    static func loadPassword(for archiveURL: URL) -> String? {
        let account = archiveURL.lastPathComponent
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceTag,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func deletePassword(for archiveURL: URL) {
        let account = archiveURL.lastPathComponent
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceTag,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(query as CFDictionary)
    }
}

// MARK: - View model

@MainActor
final class ExtractionViewModel: ObservableObject {

    @Published var isProcessing = false
    @Published var progress: Double = 0
    @Published var currentPath: String = ""
    @Published var lastResult: Result<URL, Error>?
    @Published var needsPassword: Bool = false
    @Published var pendingPasswordURL: URL?
    @Published var showError = false
    /// True when the user tapped "取消" mid-extraction. Resets on each new run.
    @Published var wasCancelled = false

    private let engine: ArchiveEngine
    /// Lock-protected cancel flag, readable from the background extraction task
    /// without crossing actor isolation. OSAllocatedUnfairLock is Sendable when
    /// its state is Sendable (Bool is), so capturing the lock in a detached
    /// Task is safe under Swift 6 strict concurrency.
    private let cancelFlag = OSAllocatedUnfairLock(initialState: false)

    init(engine: ArchiveEngine = LibarchiveEngine.shared) {
        self.engine = engine
    }

    /// Lists entries for the UI.
    func listEntries(at url: URL) -> (entries: [ArchiveEntry], encrypted: Bool, error: Error?) {
        // Under App Sandbox, dropped file URLs need security-scoped access
        // to be readable. startAccessing... returns false when no scope is
        // needed (non-sandboxed or already accessible), so calling it is
        // always safe.
        let needsScope = url.startAccessingSecurityScopedResource()
        defer { if needsScope { url.stopAccessingSecurityScopedResource() } }
        do {
            let (entries, anyEncrypted) = try engine.listEntries(at: url)
            return (entries, anyEncrypted, nil)
        } catch {
            return ([], false, error)
        }
    }

    /// Requests cancellation of the current extraction. The engine checks the
    /// flag between entries and aborts; partial files already written remain
    /// in the destination folder.
    func cancelExtraction() {
        cancelFlag.withLock { $0 = true }
    }

    /// Extracts an archive to a chosen destination, prompting for a password if needed.
    /// On success the destination is revealed in Finder automatically.
    func extract(archiveURL: URL,
                 to destination: URL,
                 password: String? = nil) async {
        isProcessing = true
        progress = 0
        currentPath = ""
        lastResult = nil
        showError = false
        wasCancelled = false
        cancelFlag.withLock { $0 = false }
        defer { isProcessing = false }

        let pw = password ?? ExtractionService.loadPassword(for: archiveURL)
        do {
            try await runExtraction(archiveURL: archiveURL,
                                    destination: destination,
                                    password: pw)
            lastResult = .success(destination)
            // Reveal the extracted folder in Finder so the user sees the result
            // without an extra click. Using activateFileViewerSelecting keeps
            // Finder in the background while highlighting the destination.
            NSWorkspace.shared.activateFileViewerSelecting([destination])
        } catch ArchiveError.encryptedNeedsPassword {
            needsPassword = true
            pendingPasswordURL = archiveURL
        } catch ArchiveError.cancelled {
            wasCancelled = true
            lastResult = .failure(ArchiveError.cancelled)
        } catch {
            lastResult = .failure(error)
            showError = true
        }
    }

    /// Re-runs extraction with a user-supplied password, optionally saving it.
    func extractWithPassword(_ password: String, saveToKeychain: Bool) async {
        guard let url = pendingPasswordURL else { return }
        if saveToKeychain {
            ExtractionService.savePassword(password, for: url)
        }
        needsPassword = false
        // Re-resolve destination from a fresh listing.
        let (entries, _, _) = listEntries(at: url)
        let dest = ExtractionService.resolveDestination(for: url, entries: entries)
        await extract(archiveURL: url, to: dest, password: password)
    }

    private func runExtraction(archiveURL: URL,
                               destination: URL,
                               password: String?) async throws {
        // Capture engine and the cancel lock on the MainActor before entering
        // the detached task. Both are Sendable (stateless engine; lock with
        // Bool state), so capturing them as locals avoids accessing
        // MainActor-isolated properties from the non-isolated closure.
        let engine = self.engine
        let cancelFlag = self.cancelFlag
        // Under App Sandbox both the archive (read) and the destination
        // (write) need security-scoped access. The archive URL comes from a
        // drop or Services invocation; the destination comes from NSOpenPanel.
        // startAccessing... is idempotent and returns false when no scope is
        // required, so wrapping unconditionally is safe. We keep both scopes
        // alive across the detached extraction and release them on return.
        let archiveScope = archiveURL.startAccessingSecurityScopedResource()
        let destScope = destination.startAccessingSecurityScopedResource()
        defer {
            if archiveScope { archiveURL.stopAccessingSecurityScopedResource() }
            if destScope { destination.stopAccessingSecurityScopedResource() }
        }
        try await Task.detached(priority: .userInitiated) { [weak self] in
            try engine.extractAll(at: archiveURL,
                                  to: destination,
                                  password: password,
                                  progress: { fraction, path in
                // Check cancellation flag (thread-safe via the lock).
                let cancelled = cancelFlag.withLock { $0 }
                if !cancelled {
                    Task { @MainActor in
                        self?.progress = fraction
                        self?.currentPath = path
                    }
                }
                return !cancelled
            })
        }.value
    }
}

// MARK: - Extraction queue

/// One item in the extraction queue. State transitions:
/// pending → extracting → succeeded / failed / cancelled.
struct QueueItem: Identifiable, Hashable {
    let id = UUID()
    let archiveURL: URL
    let destination: URL
    var state: State = .pending
    var progress: Double = 0
    var error: String?

    enum State: String { case pending, extracting, succeeded, failed, cancelled }
}

/// Sequential extraction queue for batches of archives. Archives are processed
/// one at a time so a single password prompt or NSOpenPanel only blocks the
/// current item; subsequent items remain editable in the queue.
@MainActor
final class ExtractionQueue: ObservableObject {
    @Published private(set) var items: [QueueItem] = []
    @Published var isRunning: Bool = false

    private let engine: ArchiveEngine
    private var currentTask: Task<Void, Never>?

    init(engine: ArchiveEngine = LibarchiveEngine.shared) {
        self.engine = engine
    }

    /// Enqueues one or more archives for extraction.
    /// When `destination` is nil, each archive extracts into a sibling folder
    /// named after its stem (requires per-archive write authorization under
    /// the sandbox — typically only used when the caller already holds scope).
    /// When `destination` is provided (the batch-drop case), each archive
    /// extracts into `<destination>/<archiveStem>/` so multiple archives do
    /// not collide inside the same target folder.
    func enqueue(archives: [URL], destination: URL? = nil) {
        for url in archives where url.isArchive {
            let dest: URL
            if let baseDest = destination {
                dest = baseDest.appendingPathComponent(url.archiveStem,
                                                       isDirectory: true)
            } else {
                dest = url.deletingLastPathComponent()
                    .appendingPathComponent(url.archiveStem, isDirectory: true)
            }
            items.append(QueueItem(archiveURL: url, destination: dest))
        }
        if !isRunning { runNext() }
    }

    /// Removes completed/failed/cancelled items from the queue.
    func clearFinished() {
        items.removeAll { $0.state == .succeeded || $0.state == .failed || $0.state == .cancelled }
    }

    /// Cancels the currently-extracting item and any pending items.
    func cancelAll() {
        currentTask?.cancel()
        for i in items.indices {
            if items[i].state == .pending || items[i].state == .extracting {
                items[i].state = .cancelled
            }
        }
        isRunning = false
    }

    private func runNext() {
        guard let idx = items.firstIndex(where: { $0.state == .pending }) else {
            isRunning = false
            return
        }
        isRunning = true
        items[idx].state = .extracting
        let item = items[idx]
        let engine = self.engine
        let cancelFlag = OSAllocatedUnfairLock(initialState: false)
        currentTask = Task { [weak self] in
            let archiveScope = item.archiveURL.startAccessingSecurityScopedResource()
            let destScope = item.destination.startAccessingSecurityScopedResource()
            defer {
                if archiveScope { item.archiveURL.stopAccessingSecurityScopedResource() }
                if destScope { item.destination.stopAccessingSecurityScopedResource() }
            }
            // Ensure destination exists.
            try? FileManager.default.createDirectory(at: item.destination,
                                                     withIntermediateDirectories: true)
            let password = ExtractionService.loadPassword(for: item.archiveURL)
            do {
                try await Task.detached(priority: .userInitiated) {
                    try engine.extractAll(at: item.archiveURL,
                                          to: item.destination,
                                          password: password,
                                          progress: { fraction, _ in
                        let cancelled = cancelFlag.withLock { $0 }
                        if Task.isCancelled || cancelled { return false }
                        Task { @MainActor in
                            self?.updateItem(id: item.id, progress: fraction)
                        }
                        return true
                    })
                }.value
                await MainActor.run {
                    self?.updateItem(id: item.id, state: .succeeded, progress: 1)
                }
            } catch {
                await MainActor.run {
                    self?.updateItem(id: item.id, state: .failed,
                                     error: error.localizedDescription)
                }
            }
            await MainActor.run {
                self?.isRunning = false
                self?.runNext()
            }
        }
    }

    private func updateItem(id: UUID, state: QueueItem.State? = nil,
                            progress: Double? = nil, error: String? = nil) {
        guard let idx = items.firstIndex(where: { $0.id == id }) else { return }
        if let state = state { items[idx].state = state }
        if let progress = progress { items[idx].progress = progress }
        if let error = error { items[idx].error = error }
    }
}
