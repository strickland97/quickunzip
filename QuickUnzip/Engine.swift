//
//  Engine.swift
//  QuickUnzip
//
//  Swift layer over the libarchive Obj-C bridge: models, the engine protocol,
//  and the concrete LibarchiveEngine. Format is inferred from the file
//  extension (cosmetic); actual reading is delegated to libarchive, which
//  auto-detects the real container format.
//

import Foundation

// MARK: - Models

enum ArchiveFormat: Int {
    case unknown = 0
    case zip, rar, sevenZip, tar, gzip, bzip2, xz, lzip, zstd, cab, iso, lha

    /// Maps a file extension to a best-guess format label for display.
    static func from(pathExtension ext: String) -> ArchiveFormat {
        switch ext.lowercased() {
        case "zip":          return .zip
        case "rar":          return .rar
        case "7z":           return .sevenZip
        case "tar", "tgz", "tbz2", "txz": return .tar
        case "gz":           return .gzip
        case "bz2":          return .bzip2
        case "xz":           return .xz
        case "lz":           return .lzip
        case "zst":          return .zstd
        case "cab":          return .cab
        case "iso":          return .iso
        case "lha", "lzh":   return .lha
        default:             return .unknown
        }
    }

    var displayName: String {
        switch self {
        case .unknown:  return "未知"
        case .zip:      return "ZIP"
        case .rar:      return "RAR"
        case .sevenZip: return "7Z"
        case .tar:      return "TAR"
        case .gzip:     return "GZip"
        case .bzip2:    return "BZip2"
        case .xz:       return "XZ"
        case .lzip:     return "LZip"
        case .zstd:     return "Zstandard"
        case .cab:      return "CAB"
        case .iso:      return "ISO"
        case .lha:      return "LHA"
        }
    }

    /// Extensions this app accepts as archives (for drag/drop and Services).
    static let acceptedExtensions: Set<String> = [
        "zip", "rar", "7z", "tar", "tgz", "tbz2", "tbz", "txz", "tlz",
        "gz", "bz2", "xz", "lz", "zst", "cab", "iso", "lha", "lzh"
    ]
}

struct ArchiveEntry: Identifiable, Hashable {
    let path: String
    let size: Int64
    let mtime: Date
    let isDirectory: Bool
    let isEncrypted: Bool

    var id: String { path }
    var name: String { (path as NSString).lastPathComponent }
    var depth: Int { path.split(separator: "/").count }

    var sizeFormatted: String {
        ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
    }
}

// MARK: - Errors

enum ArchiveError: LocalizedError {
    case openFailed(String)
    case listFailed(String)
    case extractFailed(String)
    case extractEntryFailed(String)
    case encryptedNeedsPassword
    case entryNotFound(String)
    case cancelled
    case unknown(String)

    var errorDescription: String? {
        switch self {
        case .openFailed(let m):           return "打开压缩包失败: \(m)"
        case .listFailed(let m):           return "读取内容列表失败: \(m)"
        case .extractFailed(let m):        return "解压失败: \(m)"
        case .extractEntryFailed(let m):   return "提取条目失败: \(m)"
        case .encryptedNeedsPassword:      return "压缩包已加密，需要密码"
        case .entryNotFound(let m):        return "未找到条目: \(m)"
        case .cancelled:                   return "已取消"
        case .unknown(let m):              return m
        }
    }
}

// MARK: - Engine protocol

protocol ArchiveEngine: AnyObject {
    /// Lists entries and reports whether any entry is encrypted.
    func listEntries(at url: URL) throws -> (entries: [ArchiveEntry], anyEncrypted: Bool)

    /// Extracts every entry into `destination`. `progress` is called from a
    /// background context with a 0..1 fraction and the current entry path;
    /// returning `false` from `progress` cancels the extraction.
    func extractAll(at url: URL,
                    to destination: URL,
                    password: String?,
                    progress: ((Double, String) -> Bool)?) throws

    /// Extracts a single entry (identified by its in-archive path) into
    /// `destination`. Returns the on-disk URL of the extracted file.
    func extractEntry(_ entryPath: String,
                      at url: URL,
                      to destination: URL,
                      password: String?) throws -> URL
}

// MARK: - libarchive implementation

// LibarchiveEngine is stateless: every call opens a fresh `struct archive *`
// handle (see ArchiveBridge.m), so concurrent calls are independent. Marking
// it @unchecked Sendable lets the detached extraction task capture it without
// tripping Swift 6 strict-concurrency isolation checks.
final class LibarchiveEngine: ArchiveEngine, @unchecked Sendable {
    static let shared = LibarchiveEngine()

    func listEntries(at url: URL) throws -> (entries: [ArchiveEntry], anyEncrypted: Bool) {
        let reader = QUArchiveReader(fileURL: url)
        let raw: [QUArchiveEntry]
        do {
            raw = try reader.listEntries()
        } catch {
            // Opening happens lazily inside listEntries, so this covers both
            // open failures and read failures.
            throw ArchiveError.listFailed(error.localizedDescription)
        }
        var anyEncrypted = false
        let entries = raw.map { e in
            if e.isEncrypted { anyEncrypted = true }
            return ArchiveEntry(
                path: e.pathname,
                size: e.size,
                mtime: Date(timeIntervalSince1970: TimeInterval(e.mtime)),
                isDirectory: e.isDirectory,
                isEncrypted: e.isEncrypted
            )
        }
        return (entries, anyEncrypted)
    }

    func extractAll(at url: URL,
                    to destination: URL,
                    password: String?,
                    progress: ((Double, String) -> Bool)?) throws {
        let reader = QUArchiveReader(fileURL: url)
        do {
            try reader.extractAll(toDirectory: destination,
                                  password: password,
                                  progress: { fraction, path in
                // Forward the cancel decision back to the bridge.
                return progress?(fraction, path) ?? true
            })
        } catch let err as NSError {
            // Bridge reports an encrypted-without-password condition as
            // domain "QUArchive", code 5; user-initiated cancellation as code 6.
            if err.domain == "QUArchive" && err.code == 5 {
                throw ArchiveError.encryptedNeedsPassword
            }
            if err.domain == "QUArchive" && err.code == 6 {
                throw ArchiveError.cancelled
            }
            throw ArchiveError.extractFailed(err.localizedDescription)
        }
    }

    func extractEntry(_ entryPath: String,
                      at url: URL,
                      to destination: URL,
                      password: String?) throws -> URL {
        let reader = QUArchiveReader(fileURL: url)
        do {
            try reader.extractEntry(atPath: entryPath,
                                    toDirectory: destination,
                                    password: password)
        } catch let err as NSError {
            if err.domain == "QUArchive" && err.code == 5 {
                throw ArchiveError.encryptedNeedsPassword
            }
            if err.domain == "QUArchive" && err.code == 7 {
                throw ArchiveError.entryNotFound(entryPath)
            }
            throw ArchiveError.extractEntryFailed(err.localizedDescription)
        }
        return destination.appendingPathComponent(entryPath)
    }
}

// MARK: - URL helpers

extension URL {
    /// True if this URL looks like an archive QuickUnzip can handle.
    var isArchive: Bool {
        ArchiveFormat.acceptedExtensions.contains(pathExtension.lowercased())
    }

    /// The stem of the archive name (e.g. "foo" for "foo.zip", "foo" for "foo.tar.gz").
    var archiveStem: String {
        let name = self.deletingPathExtension().lastPathComponent
        // Handle double extensions like .tar.gz / .tar.bz2
        if name.lowercased().hasSuffix(".tar") {
            return (name as NSString).deletingPathExtension
        }
        return name
    }
}
