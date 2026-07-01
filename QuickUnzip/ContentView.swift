//
//  ContentView.swift
//  QuickUnzip
//
//  Main window: drag/drop an archive to preview its contents, then extract
//  (smart "here" or to a chosen folder). Shows live progress and a password
//  prompt when the archive is encrypted.
//

import SwiftUI
import AppKit
import UniformTypeIdentifiers
import QuickLookUI

struct ContentView: View {
    @EnvironmentObject private var coordinator: AppCoordinator
    @EnvironmentObject private var vm: ExtractionViewModel
    @EnvironmentObject private var queue: ExtractionQueue
    @State private var isDropTargeted = false
    @State private var savePassword = true
    @State private var passwordInput = ""
    @State private var searchText = ""
    /// Last error from a single-entry preview attempt; non-nil shows an alert.
    @State private var previewError: String?
    /// Multi-selection of tree node ids (in-archive paths). Backs the
    /// List(selection:) binding and the right-click "提取选中项" action.
    @State private var selection: Set<String> = []

    private var hasArchive: Bool { coordinator.currentArchive != nil }

    var body: some View {
        ZStack {
            // Drop zone covering the whole window.
            Color.clear
                .background(.regularMaterial)
                .contentShape(Rectangle())
                .onDrop(of: [.fileURL], delegate: ArchiveDropDelegate(isTargeted: $isDropTargeted) { urls in
                    handleDroppedArchives(urls)
                })

            VStack(spacing: 0) {
                VStack(spacing: 0) {
                    if let url = coordinator.currentArchive {
                        archiveHeader(for: url)
                        Divider()
                        entryList
                    } else {
                        emptyState
                    }
                }
                // Batch extraction queue drawer. Auto-shows when items exist,
                // auto-hides when the queue is emptied. The drawer has a
                // capped height so a long queue never takes over the window.
                if !queue.items.isEmpty {
                    Divider()
                    queueDrawer
                }
            }
            .padding(isDropTargeted ? 18 : 0)
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(Color.accentColor.opacity(isDropTargeted ? 0.8 : 0), lineWidth: 3)
            )

            if vm.isProcessing {
                ProgressOverlay(fraction: vm.progress,
                                current: vm.currentPath,
                                onCancel: { vm.cancelExtraction() })
            }
        }
        .sheet(isPresented: $vm.needsPassword) {
            passwordSheet
        }
        .alert("解压出错", isPresented: $vm.showError) {
            Button("好") { }
        } message: {
            if case .failure(let err) = vm.lastResult {
                Text(err.localizedDescription)
            }
        }
        .onChange(of: coordinator.currentArchive) { _, _ in
            searchText = ""
        }
        .alert("无法预览",
               isPresented: Binding(get: { previewError != nil },
                                    set: { if !$0 { previewError = nil } })) {
            Button("好") { previewError = nil }
        } message: {
            Text(previewError ?? "")
        }
    }

    /// Double-click handler: temp-extracts a single archive entry and pops a
    /// QuickLook panel over the window. Directories and encrypted entries
    /// without a saved password are reported via a non-blocking alert.
    private func previewEntry(_ entry: ArchiveEntry) {
        guard !entry.isDirectory else { return }
        guard let archive = coordinator.currentArchive else { return }
        // Use the saved Keychain password if any; the user will be alerted if
        // the entry turns out to be encrypted and no password is available.
        let password = ExtractionService.loadPassword(for: archive)
        do {
            let url = try EntryPreviewService.extractForPreview(archive: archive,
                                                                entry: entry,
                                                                password: password)
            PreviewController.shared.show(url)
        } catch ArchiveError.encryptedNeedsPassword {
            previewError = "此文件已加密，请先解压整个压缩包（输入密码）后再预览。"
        } catch ArchiveError.entryNotFound(let path) {
            previewError = "未找到条目: \(path)"
        } catch {
            previewError = error.localizedDescription
        }
    }

    // MARK: - Subviews

    @ViewBuilder
    private func archiveHeader(for url: URL) -> some View {
        HStack(spacing: 12) {
            // History navigation (back/forward). Disabled when the relevant
            // stack is empty. Mirrors browser semantics: loading a fresh
            // archive clears the forward stack.
            HStack(spacing: 4) {
                Button {
                    coordinator.goBack()
                } label: {
                    Image(systemName: "chevron.backward")
                }
                .buttonStyle(.borderless)
                .disabled(!coordinator.canGoBack)
                .help(coordinator.canGoBack ? "后退 (\(coordinator.backStack.count))" : "后退")

                Button {
                    coordinator.goForward()
                } label: {
                    Image(systemName: "chevron.forward")
                }
                .buttonStyle(.borderless)
                .disabled(!coordinator.canGoForward)
                .help(coordinator.canGoForward ? "前进 (\(coordinator.forwardStack.count))" : "前进")
            }
            Image(systemName: "archivebox.fill")
                .font(.system(size: 30))
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 2) {
                Text(url.lastPathComponent)
                    .font(.headline)
                    .lineLimit(1)
                HStack(spacing: 8) {
                    Text(coordinator.format.displayName)
                        .font(.caption)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(.quaternary, in: Capsule())
                    Text("\(coordinator.entries.count) 项")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if coordinator.anyEncrypted {
                        Label("加密", systemImage: "lock.fill")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                }
            }
            Spacer()
            toolbar(for: url)
        }
        .padding()
    }

    @ViewBuilder
    private func toolbar(for url: URL) -> some View {
        HStack(spacing: 8) {
            // Under App Sandbox, writing to the archive's parent folder
            // requires user authorization. We route "extract here" through
            // an NSOpenPanel seeded with the parent directory so the user
            // only has to confirm (or pick a different folder). NSOpenPanel
            // grants a security-scoped URL that the engine can write to.
            Button {
                chooseFolderAndExtract(url: url, defaultToParent: true)
            } label: {
                Label("解压到当前目录", systemImage: "arrow.down.circle")
            }
            .disabled(vm.isProcessing)

            Button {
                chooseFolderAndExtract(url: url, defaultToParent: false)
            } label: {
                Label("解压到…", systemImage: "folder.badge.plus")
            }
            .disabled(vm.isProcessing)

            if case .success(let out) = vm.lastResult {
                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([out])
                } label: {
                    Label("在 Finder 中显示", systemImage: "magnifyingglass")
                }
            }
        }
    }

    private var entryList: some View {
        VStack(spacing: 0) {
            // Search field — only shown when there are entries to filter.
            if !coordinator.entries.isEmpty {
                HStack {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.tertiary)
                        .font(.system(size: 13))
                    TextField("过滤条目", text: $searchText)
                        .textFieldStyle(.plain)
                        .font(.system(size: 13))
                    if !searchText.isEmpty {
                        Button {
                            searchText = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.tertiary)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(.bar)
            }
            Divider()
            // Tree view when not searching; flat filtered list when searching.
            // OutlineGroup does not natively filter by search text, so we fall
            // back to a flat List for search results. Selection is bound to a
            // Set<String> of node ids (in-archive paths) and enables the
            // right-click "提取选中项" action.
            List(selection: $selection) {
                if searchText.isEmpty {
                    OutlineGroup(treeNodes, children: \.children) { node in
                        NodeRow(node: node,
                                archive: coordinator.currentArchive,
                                onDoubleTap: { previewNode(node) })
                            .tag(node.id)
                    }
                } else {
                    ForEach(displayedEntries) { entry in
                        NodeRow(node: ArchiveNode(id: entry.path,
                                                  name: entry.name,
                                                  path: entry.path,
                                                  isDirectory: entry.isDirectory,
                                                  size: entry.size,
                                                  mtime: entry.mtime,
                                                  isEncrypted: entry.isEncrypted,
                                                  children: nil),
                                archive: coordinator.currentArchive,
                                onDoubleTap: { previewEntry(entry) })
                            .tag(entry.path)
                    }
                }
            }
            .listStyle(.inset)
            .contextMenu {
                Button("提取选中项") {
                    extractSelectedNodes()
                }
                .disabled(selection.isEmpty || vm.isProcessing)
            }
        }
        .overlay {
            if let err = coordinator.listError {
                ContentUnavailableView("无法读取压缩包", systemImage: "exclamationmark.triangle", description: Text(err))
            } else if coordinator.isLoading {
                ProgressView("读取中…")
            } else if coordinator.entries.isEmpty {
                ProgressView()
            } else if displayedEntries.isEmpty && !searchText.isEmpty {
                ContentUnavailableView("无匹配条目", systemImage: "magnifyingglass")
            }
        }
    }

    /// Tree forest built from the current archive's entries. Recomputed on
    /// every body evaluation; cheap for typical archive sizes (<10k entries).
    private var treeNodes: [ArchiveNode] {
        buildArchiveTree(from: coordinator.entries)
    }

    /// Entries sorted (folders first, then case-insensitive alphabetical) and
    /// filtered by the current search text.
    private var displayedEntries: [ArchiveEntry] {
        let sorted = coordinator.entries.sorted { a, b in
            if a.isDirectory != b.isDirectory { return a.isDirectory }
            return a.path.localizedCaseInsensitiveCompare(b.path) == .orderedAscending
        }
        let trimmed = searchText.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return sorted }
        return sorted.filter { $0.path.localizedCaseInsensitiveContains(trimmed) }
    }

    /// Double-click handler for a tree node. Only files are previewable.
    private func previewNode(_ node: ArchiveNode) {
        guard !node.isDirectory else { return }
        guard let archive = coordinator.currentArchive else { return }
        let password = ExtractionService.loadPassword(for: archive)
        do {
            let url = try EntryPreviewService.extractForPreview(
                archive: archive,
                entry: ArchiveEntry(path: node.path,
                                    size: node.size,
                                    mtime: node.mtime,
                                    isDirectory: node.isDirectory,
                                    isEncrypted: node.isEncrypted),
                password: password)
            PreviewController.shared.show(url)
        } catch {
            previewError = error.localizedDescription
        }
    }

    /// Extracts every selected node (file or directory) into a user-chosen
    /// folder via NSOpenPanel. For directories, all descendants are extracted
    /// by virtue of extracting the matching path prefix.
    private func extractSelectedNodes() {
        guard !selection.isEmpty,
              let archive = coordinator.currentArchive else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "提取到此"
        panel.directoryURL = archive.deletingLastPathComponent()
        guard panel.runModal() == .OK, let dest = panel.url else { return }
        let password = ExtractionService.loadPassword(for: archive)
        // Capture MainActor-isolated state before entering the detached task
        // so no actor-isolated property is referenced off-actor.
        let selectedPaths = Array(selection)
        // Run in background so the UI stays responsive; report via the same
        // progress overlay used for full extractions.
        vm.isProcessing = true
        let engine = LibarchiveEngine.shared
        let scope = archive.startAccessingSecurityScopedResource()
        let destScope = dest.startAccessingSecurityScopedResource()
        Task.detached(priority: .userInitiated) {
            defer {
                if scope { archive.stopAccessingSecurityScopedResource() }
                if destScope { dest.stopAccessingSecurityScopedResource() }
            }
            var failed: [String] = []
            for path in selectedPaths {
                do {
                    _ = try engine.extractEntry(path, at: archive,
                                                to: dest, password: password)
                } catch {
                    failed.append(path)
                }
            }
            // Capture the count as an immutable local before crossing the
            // MainActor boundary so no captured-var warning is emitted.
            let failedCount = failed.count
            await MainActor.run {
                vm.isProcessing = false
                if failedCount == 0 {
                    NSWorkspace.shared.activateFileViewerSelecting([dest])
                } else {
                    vm.lastResult = .failure(ArchiveError.extractEntryFailed(
                        "\(failedCount) 个条目提取失败"))
                    vm.showError = true
                }
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "archivebox")
                .font(.system(size: 64, weight: .light))
                .foregroundStyle(.tertiary)
            Text("拖入压缩包以预览")
                .font(.title3)
                .foregroundStyle(.secondary)
            Text("支持 ZIP / 7z / RAR / TAR / GZ / BZ2 / XZ")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Queue drawer

    /// Bottom drawer showing the batch extraction queue. Each row displays the
    /// archive name, destination, state icon, and a live progress bar when
    /// extracting. Header buttons allow cancelling the run or clearing
    /// finished items.
    private var queueDrawer: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "list.bullet.rectangle")
                    .foregroundStyle(.tint)
                Text("解压队列")
                    .font(.headline)
                Text("\(queue.items.count) 项")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if queue.isRunning {
                    Text("·")
                        .foregroundStyle(.tertiary)
                    Text("进行中")
                        .font(.caption)
                        .foregroundStyle(.tint)
                }
                Spacer()
                if queue.isRunning {
                    Button("全部取消") { queue.cancelAll() }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                }
                Button("清空已完成") { queue.clearFinished() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(queue.items.allSatisfy { $0.state == .pending || $0.state == .extracting })
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            Divider()

            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(queue.items) { item in
                        QueueItemRow(item: item)
                        if item.id != queue.items.last?.id {
                            Divider()
                        }
                    }
                }
            }
            .frame(maxHeight: 200)
        }
        .background(.bar)
    }

    // MARK: - Password sheet

    private var passwordSheet: some View {
        VStack(spacing: 14) {
            Text("压缩包已加密").font(.headline)
            if let url = vm.pendingPasswordURL {
                Text(url.lastPathComponent).font(.caption).foregroundStyle(.secondary)
            }
            SecureField("密码", text: $passwordInput)
                .textFieldStyle(.roundedBorder)
                .frame(width: 260)
            Toggle("保存到钥匙串", isOn: $savePassword)
            HStack {
                Button("取消") {
                    vm.needsPassword = false
                    vm.pendingPasswordURL = nil
                    passwordInput = ""
                }
                Button("解压") {
                    let pw = passwordInput
                    passwordInput = ""
                    Task { await vm.extractWithPassword(pw, saveToKeychain: savePassword) }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(passwordInput.isEmpty)
            }
        }
        .padding(24)
    }

    // MARK: - Actions

    /// Handles one or more archives dropped onto the window.
    /// Single archive: loads it into the preview window (existing behavior).
    /// Multiple archives: prompts for a shared destination folder via
    /// NSOpenPanel (which also grants the sandbox write scope), enqueues all
    /// archives into the batch queue, and loads the first one into the
    /// preview window so the user can browse while the queue runs.
    private func handleDroppedArchives(_ urls: [URL]) {
        let archives = urls.filter { $0.isArchive }
        if archives.count <= 1 {
            if let first = archives.first {
                coordinator.handle(urls: [first], autostart: false)
            }
            return
        }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "解压全部到此"
        panel.message = "将 \(archives.count) 个压缩包解压到此文件夹（每个压缩包会创建独立子目录）"
        guard panel.runModal() == .OK, let dest = panel.url else { return }
        queue.enqueue(archives: archives, destination: dest)
        // Load the first archive into the preview window so the user can
        // browse contents while the queue processes in the background.
        coordinator.load(archives[0])
    }

    /// Shows a folder picker for the extraction destination.
    /// When `defaultToParent` is true (the "解压到当前目录" button), the panel
    /// is seeded with the smart-resolved destination (archive parent or a
    /// dedicated `<stem>/` subfolder) and the prompt is phrased as a one-click
    /// confirmation. The user still has to authorize via the panel because the
    /// App Sandbox does not grant write access to the archive's parent
    /// directory automatically.
    private func chooseFolderAndExtract(url: URL, defaultToParent: Bool) {
        let smartDest = ExtractionService.resolveDestination(for: url, entries: coordinator.entries)
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "解压到这里"
        panel.directoryURL = defaultToParent ? smartDest : url.deletingLastPathComponent()
        if panel.runModal() == .OK, let dest = panel.url {
            Task { await vm.extract(archiveURL: url, to: dest) }
        }
    }
}

// MARK: - Drop delegate

private struct ArchiveDropDelegate: DropDelegate {
    @Binding var isTargeted: Bool
    let onDrop: ([URL]) -> Void

    func validateDrop(info: DropInfo) -> Bool {
        info.hasItemsConforming(to: [.fileURL])
    }

    func dropEntered(info: DropInfo) { isTargeted = true }
    func dropExited(info: DropInfo) { isTargeted = false }

    func performDrop(info: DropInfo) -> Bool {
        isTargeted = false
        let providers = info.itemProviders(for: [.fileURL])
        guard !providers.isEmpty else { return false }
        // Collect all dropped file URLs asynchronously, then deliver them in
        // a single main-thread callback. A DispatchGroup waits for every
        // item provider's loadItem to complete; a lock guards the shared
        // array since loadItem callbacks may land on different queues.
        let group = DispatchGroup()
        var collected: [URL] = []
        let lock = NSLock()
        for item in providers {
            group.enter()
            item.loadItem(forTypeIdentifier: UTType.fileURL.identifier,
                          options: nil) { data, _ in
                if let data = data as? Data,
                   let url = URL(dataRepresentation: data, relativeTo: nil),
                   url.isArchive {
                    lock.lock(); collected.append(url); lock.unlock()
                }
                group.leave()
            }
        }
        group.notify(queue: .main) {
            if !collected.isEmpty { onDrop(collected) }
        }
        return true
    }
}

// MARK: - Entry row

/// Row view shared by both the tree OutlineGroup and the flat search list.
/// Supports:
///   - double-click preview (files only)
///   - drag-out extraction: dragging a file row to Finder extracts that
///     single entry to a temp folder and provides the resulting file URL as
///     the drag item, so the user can drop it anywhere a file is accepted.
private struct NodeRow: View {
    let node: ArchiveNode
    let archive: URL?
    let onDoubleTap: () -> Void

    private var pathExtension: String {
        (node.path as NSString).pathExtension
    }

    var body: some View {
        HStack(spacing: 10) {
            // Use the real Finder icon for the file type. For directories we
            // use the standard folder icon; for files we ask NSWorkspace for
            // the icon matching the extension (PNG, PDF, ZIP, code, etc. all
            // get their real type icon). Falls back to a generic doc icon.
            if node.isDirectory {
                Image(nsImage: NSWorkspace.shared.icon(for: UTType.folder))
                    .resizable()
                    .frame(width: 20, height: 20)
            } else {
                let utType = UTType(filenameExtension: pathExtension) ?? .data
                Image(nsImage: NSWorkspace.shared.icon(for: utType))
                    .resizable()
                    .frame(width: 20, height: 20)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(node.name)
                    .lineLimit(1)
                Text(node.path)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
            Spacer()
            if node.isEncrypted {
                Image(systemName: "lock.fill").foregroundStyle(.orange)
            }
            Text(node.sizeFormatted)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 80, alignment: .trailing)
        }
        .padding(.vertical, 1)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { onDoubleTap() }
        .help(node.isDirectory ? "" : "双击预览 · 拖出提取")
        // Drag-out extraction: provide a file promise. We use a PromiseItemProvider
        // that lazily extracts the entry to /tmp when Finder actually requests
        // the dropped file, so simply clicking a row does no work.
        .onDrag {
            guard !node.isDirectory, let archive = archive else {
                return NSItemProvider()
            }
            let provider = NSItemProvider()
            provider.suggestedName = node.name
            // Register a file promise for the public.file-url type. The
            // coordinator delivers the actual URL by extracting the entry
            // on demand.
            provider.registerFileRepresentation(forTypeIdentifier: "public.file-url",
                                                fileOptions: [],
                                                visibility: .all) { completion in
                // Extract on a background queue so the drag source thread
                // is not blocked.
                DispatchQueue.global(qos: .userInitiated).async {
                    let password = ExtractionService.loadPassword(for: archive)
                    do {
                        let url = try EntryPreviewService.extractForPreview(
                            archive: archive,
                            entry: ArchiveEntry(path: node.path,
                                                size: node.size,
                                                mtime: node.mtime,
                                                isDirectory: node.isDirectory,
                                                isEncrypted: node.isEncrypted),
                            password: password)
                        completion(url, true, nil)
                    } catch {
                        completion(nil, false, nil)
                    }
                }
                return Progress()
            }
            return provider
        }
    }
}

// MARK: - Queue item row

/// One row in the batch extraction queue drawer. Shows the archive name, its
/// destination path, a state icon, and a live progress bar while extracting.
private struct QueueItemRow: View {
    let item: QueueItem

    var body: some View {
        HStack(spacing: 10) {
            stateIcon
            VStack(alignment: .leading, spacing: 2) {
                Text(item.archiveURL.lastPathComponent)
                    .font(.callout)
                    .lineLimit(1)
                Text(item.destination.path)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let err = item.error, item.state == .failed {
                    Text(err)
                        .font(.caption2)
                        .foregroundStyle(.red)
                        .lineLimit(1)
                }
            }
            Spacer()
            if item.state == .extracting {
                ProgressView(value: item.progress)
                    .frame(width: 120)
                Text("\(Int(item.progress * 100))%")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(width: 40, alignment: .trailing)
            } else {
                stateLabel
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    @ViewBuilder
    private var stateIcon: some View {
        switch item.state {
        case .pending:
            Image(systemName: "clock")
                .foregroundStyle(.tertiary)
        case .extracting:
            Image(systemName: "arrow.down.circle.fill")
                .foregroundStyle(.tint)
        case .succeeded:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .failed:
            Image(systemName: "xmark.circle.fill")
                .foregroundStyle(.red)
        case .cancelled:
            Image(systemName: "minus.circle.fill")
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var stateLabel: some View {
        switch item.state {
        case .pending:
            Text("等待中").font(.caption).foregroundStyle(.secondary)
        case .succeeded:
            Text("完成").font(.caption).foregroundStyle(.green)
        case .failed:
            Text("失败").font(.caption).foregroundStyle(.red)
        case .cancelled:
            Text("已取消").font(.caption).foregroundStyle(.secondary)
        case .extracting:
            EmptyView()
        }
    }
}

// MARK: - Progress overlay

private struct ProgressOverlay: View {
    let fraction: Double
    let current: String
    let onCancel: () -> Void

    var body: some View {
        ZStack {
            Color.black.opacity(0.35).ignoresSafeArea()
            VStack(spacing: 14) {
                ProgressView(value: fraction) {
                    Text("解压中…")
                } currentValueLabel: {
                    if !current.isEmpty {
                        Text(current).font(.caption2).lineLimit(1)
                    } else {
                        Text("\(Int(fraction * 100))%")
                    }
                }
                .frame(width: 280)
                Button(action: onCancel) {
                    Label("取消", systemImage: "xmark.circle")
                        .font(.callout)
                }
                .buttonStyle(.bordered)
            }
            .padding(28)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
        }
        .transition(.opacity)
    }
}

// MARK: - In-archive file preview (QuickLook panel)

/// Bridge to QuickLook's QLPreviewPanel for previewing a single on-disk file
/// (typically a temp-extracted archive entry). The shared panel singleton
/// requires a dataSource implementing QLPreviewPanelDataSource.
final class PreviewController: NSObject, QLPreviewPanelDataSource {
    static let shared = PreviewController()

    private var previewURL: URL?

    /// Shows the QuickLook panel for a single file URL. Replaces any prior
    /// preview content.
    func show(_ url: URL) {
        previewURL = url
        guard let panel = QLPreviewPanel.shared() else { return }
        panel.dataSource = self
        panel.currentPreviewItemIndex = 0
        panel.reloadData()
        panel.makeKeyAndOrderFront(nil)
    }

    // MARK: QLPreviewPanelDataSource

    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        return previewURL == nil ? 0 : 1
    }

    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! {
        // NSURL conforms to QLPreviewItem; if we have no URL we hand back a
        // sentinel path so the panel can display its own "no preview" state.
        let url = previewURL ?? URL(fileURLWithPath: "/dev/null")
        return url as NSURL
    }
}

/// Manages temp extraction of a single archive entry for preview purposes.
/// Files land under NSTemporaryDirectory()/QuickUnzipPreview/<UUID>/ and are
/// cleaned up lazily on the next preview session.
enum EntryPreviewService {
    /// Extracts `entry.path` from `archive` into a fresh temp folder and
    /// returns the on-disk URL of the extracted file. Throws on encrypted /
    /// missing / unreadable entries.
    static func extractForPreview(archive: URL,
                                  entry: ArchiveEntry,
                                  password: String?) throws -> URL {
        // Reset the preview temp dir per session to avoid unbounded growth.
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("QuickUnzipPreview", isDirectory: true)
        if FileManager.default.fileExists(atPath: base.path) {
            try? FileManager.default.removeItem(at: base)
        }
        try FileManager.default.createDirectory(at: base,
                                                withIntermediateDirectories: true)
        let dest = base.appendingPathComponent(UUID().uuidString, isDirectory: true)
        // Sandbox: dropped archive URLs need a security scope to be read.
        let scope = archive.startAccessingSecurityScopedResource()
        defer { if scope { archive.stopAccessingSecurityScopedResource() } }
        return try LibarchiveEngine.shared.extractEntry(entry.path,
                                                        at: archive,
                                                        to: dest,
                                                        password: password)
    }
}

// MARK: - Archive tree

/// A node in the archive's directory tree. Files have `children == nil`;
/// directories have `children == []` (empty) or a populated array.
/// Intermediate directories not explicitly listed in the archive are
/// synthesized so the tree is always navigable.
struct ArchiveNode: Identifiable, Hashable {
    let id: String        // full in-archive path
    let name: String
    let path: String
    var isDirectory: Bool
    let size: Int64
    let mtime: Date
    let isEncrypted: Bool
    var children: [ArchiveNode]?

    var sizeFormatted: String {
        isDirectory ? "—" : ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
    }
}

/// Builds a forest of ArchiveNode from flat entries. Intermediate directories
/// not explicitly present in the archive are synthesized with size 0 and a
/// zero mtime so the tree is always fully navigable.
func buildArchiveTree(from entries: [ArchiveEntry]) -> [ArchiveNode] {
    var nodeMap: [String: ArchiveNode] = [:]
    // parentPath -> sorted child paths. Root is "".
    var parentChildren: [String: [String]] = [:]

    let sorted = entries.sorted {
        $0.path.localizedCaseInsensitiveCompare($1.path) == .orderedAscending
    }

    for entry in sorted {
        let parts = entry.path.split(separator: "/",
                                     omittingEmptySubsequences: true).map(String.init)
        guard !parts.isEmpty else { continue }

        var currentPath = ""
        for (i, part) in parts.enumerated() {
            let isLast = (i == parts.count - 1)
            let fullPath = currentPath.isEmpty ? part : "\(currentPath)/\(part)"
            let parentPath = currentPath

            if isLast {
                // The actual entry.
                nodeMap[fullPath] = ArchiveNode(
                    id: entry.path,
                    name: part,
                    path: entry.path,
                    isDirectory: entry.isDirectory,
                    size: entry.size,
                    mtime: entry.mtime,
                    isEncrypted: entry.isEncrypted,
                    children: entry.isDirectory ? [] : nil
                )
            } else if nodeMap[fullPath] == nil {
                // Implicit intermediate directory: not listed in the archive
                // but implied by a deeper file's path.
                nodeMap[fullPath] = ArchiveNode(
                    id: fullPath,
                    name: part,
                    path: fullPath,
                    isDirectory: true,
                    size: 0,
                    mtime: Date(timeIntervalSince1970: 0),
                    isEncrypted: false,
                    children: []
                )
            }

            if !parentChildren[parentPath, default: []].contains(fullPath) {
                parentChildren[parentPath, default: []].append(fullPath)
            }
            currentPath = fullPath
        }
    }

    // Recursively populate children arrays. Folders first, then alphabetical.
    func fillChildren(path: String) -> [ArchiveNode] {
        guard let childPaths = parentChildren[path] else { return [] }
        var nodes = childPaths.compactMap { nodeMap[$0] }
        nodes.sort { a, b in
            if a.isDirectory != b.isDirectory { return a.isDirectory }
            return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
        }
        for i in nodes.indices where nodes[i].isDirectory {
            nodes[i].children = fillChildren(path: nodes[i].path)
        }
        return nodes
    }

    return fillChildren(path: "")
}
