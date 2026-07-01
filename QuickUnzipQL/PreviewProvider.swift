//
//  PreviewProvider.swift
//  QuickUnzipQL
//
//  QuickLook Preview Extension: when the user selects an archive in Finder and
//  presses Space, QuickLook invokes this provider to render a preview of the
//  archive's contents. We list entries via the shared LibarchiveEngine (the
//  same engine the main app uses) and render an HTML table.
//
//  The extension runs in its own sandboxed process (quicklookd helper). It has
//  no network access and only file-read access brokered by quicklookd. The
//  shared Engine.swift + ArchiveBridge.m are compiled into this target so the
//  extension is fully self-contained.
//

import Foundation
import UniformTypeIdentifiers
import QuickLookUI

@available(macOS 12.0, *)
final class PreviewProvider: QLPreviewProvider, QLPreviewingController {

    // MARK: - QLPreviewingController

    func providePreview(for request: QLFilePreviewRequest,
                        completionHandler handler: @escaping (QLPreviewReply?, Error?) -> Void) {
        // Listing a large archive can be slow; do it off the main thread so
        // the QuickLook UI doesn't block. The completion handler is
        // MainActor-agnostic and safe to call from any queue.
        Task.detached(priority: .userInitiated) {
            let url = request.fileURL
            do {
                let (entries, anyEncrypted) = try LibarchiveEngine.shared.listEntries(at: url)
                let html = Self.renderArchiveHTML(url: url,
                                                   entries: entries,
                                                   anyEncrypted: anyEncrypted)
                Self.deliverHTML(html, handler: handler)
            } catch {
                // Render an error page rather than surfacing a generic QL
                // "preview unavailable" — gives the user actionable context.
                let html = Self.renderErrorHTML(url: url, error: error)
                Self.deliverHTML(html, handler: handler)
            }
        }
    }

    // MARK: - HTML rendering

    private static func deliverHTML(_ html: String,
                                    handler: @escaping (QLPreviewReply?, Error?) -> Void) {
        // QLPreviewReply's data-of-content-type initializer takes a contentSize
        // hint and a data-creation closure. We don't know the natural height
        // ahead of time, so we pass a reasonable default; QuickLook will
        // re-flow based on the HTML's intrinsic size.
        let size = CGSize(width: 720, height: 520)
        let reply = QLPreviewReply(dataOfContentType: .html,
                                   contentSize: size) { reply in
            reply.title = "QuickUnzip"
            return Data(html.utf8)
        }
        handler(reply, nil)
    }

    private static func renderArchiveHTML(url: URL,
                                          entries: [ArchiveEntry],
                                          anyEncrypted: Bool) -> String {
        let filename = url.lastPathComponent
        let format = ArchiveFormat.from(pathExtension: url.pathExtension)

        // Sort: directories first, then by name (case-insensitive).
        let sorted = entries.sorted { a, b in
            if a.isDirectory != b.isDirectory { return a.isDirectory }
            return a.path.localizedCaseInsensitiveCompare(b.path) == .orderedAscending
        }

        let totalSize = entries.filter { !$0.isDirectory }.reduce(Int64(0)) { $0 + $1.size }
        let dirCount = entries.filter { $0.isDirectory }.count
        let fileCount = entries.count - dirCount
        let encryptedFileCount = entries.filter { $0.isEncrypted && !$0.isDirectory }.count

        var rows = [String]()
        for e in sorted {
            let escapedName = htmlEscape(e.path)
            let icon: String
            let sizeText: String
            if e.isDirectory {
                icon = "<span class=\"icon\">📁</span>"
                sizeText = "—"
            } else {
                icon = "<span class=\"icon\">📄</span>"
                sizeText = e.sizeFormatted
            }
            let encBadge = e.isEncrypted ? "<span class=\"enc\">🔒</span>" : ""
            rows.append("""
                <tr>
                    <td class=\"name\">\(icon) <span>\(escapedName)</span> \(encBadge)</td>
                    <td class=\"size\">\(sizeText)</td>
                </tr>
            """)
        }

        let metaParts: [String] = [
            "\(fileCount) 个文件",
            dirCount > 0 ? "\(dirCount) 个文件夹" : nil,
            ByteCountFormatter.string(fromByteCount: totalSize, countStyle: .file),
            format.displayName
        ].compactMap { $0 }
        let meta = metaParts.joined(separator: " · ")
        // Distinguish "all files encrypted" from "some files encrypted" so the
        // user knows whether a password is required for the whole archive or
        // just part of it.
        let encBanner: String
        if anyEncrypted {
            if fileCount > 0 && encryptedFileCount == fileCount {
                encBanner = "<span class=\"badge\">🔒 已加密</span>"
            } else {
                encBanner = "<span class=\"badge\">部分文件已加密</span>"
            }
        } else {
            encBanner = ""
        }

        let emptyHint = sorted.isEmpty
            ? "<div class=\"empty\">压缩包为空</div>"
            : ""

        return """
        <!DOCTYPE html>
        <html>
        <head>
        <meta charset="utf-8">
        <style>
          * { box-sizing: border-box; }
          body {
            font-family: -apple-system, BlinkMacSystemFont, system-ui, sans-serif;
            padding: 24px 28px;
            color: #1d1d1f;
            margin: 0;
          }
          h1 {
            font-size: 17px;
            font-weight: 600;
            margin: 0 0 4px 0;
            word-break: break-all;
          }
          .meta {
            font-size: 12px;
            color: #6e6e73;
            margin-bottom: 6px;
          }
          .badge {
            display: inline-block;
            background: #ff9500;
            color: white;
            padding: 2px 8px;
            border-radius: 4px;
            font-size: 11px;
            font-weight: 500;
            margin-top: 4px;
          }
          table {
            width: 100%;
            border-collapse: collapse;
            font-size: 13px;
            margin-top: 14px;
          }
          th {
            text-align: left;
            padding: 6px 10px;
            border-bottom: 1px solid #d2d2d7;
            color: #6e6e73;
            font-weight: 500;
            font-size: 11px;
            text-transform: uppercase;
            letter-spacing: 0.04em;
          }
          td {
            padding: 5px 10px;
            border-bottom: 1px solid #f0f0f5;
            vertical-align: middle;
          }
          td.name { word-break: break-all; }
          td.name .icon { display: inline-block; width: 18px; }
          td.size {
            text-align: right;
            color: #6e6e73;
            font-variant-numeric: tabular-nums;
            white-space: nowrap;
            padding-left: 20px;
          }
          .enc { font-size: 11px; }
          .empty {
            padding: 40px 0;
            text-align: center;
            color: #6e6e73;
            font-size: 13px;
          }
          @media (prefers-color-scheme: dark) {
            body { color: #f5f5f7; }
            .meta { color: #86868b; }
            th { border-bottom-color: #38383d; color: #86868b; }
            td { border-bottom-color: #1c1c1e; }
            td.size { color: #86868b; }
          }
        </style>
        </head>
        <body>
          <h1>\(htmlEscape(filename))</h1>
          <div class="meta">\(htmlEscape(meta))</div>
          \(encBanner)
          \(emptyHint)
          \(sorted.isEmpty ? "" : """
          <table>
            <thead><tr><th>名称</th><th style="text-align:right">大小</th></tr></thead>
            <tbody>\n\(rows.joined(separator: "\n"))\n</tbody>
          </table>
          """)
        </body>
        </html>
        """
    }

    private static func renderErrorHTML(url: URL, error: Error) -> String {
        let filename = url.lastPathComponent
        let message: String
        if let archiveError = error as? ArchiveError {
            message = archiveError.errorDescription ?? "未知错误"
        } else {
            message = error.localizedDescription
        }
        return """
        <!DOCTYPE html>
        <html>
        <head>
        <meta charset="utf-8">
        <style>
          body {
            font-family: -apple-system, BlinkMacSystemFont, system-ui, sans-serif;
            padding: 40px 28px;
            color: #1d1d1f;
            text-align: center;
            margin: 0;
          }
          h1 { font-size: 15px; font-weight: 600; margin: 0 0 12px 0; word-break: break-all; }
          .msg { font-size: 13px; color: #6e6e73; line-height: 1.5; }
          @media (prefers-color-scheme: dark) {
            body { color: #f5f5f7; }
            .msg { color: #86868b; }
          }
        </style>
        </head>
        <body>
          <h1>\(htmlEscape(filename))</h1>
          <div class="msg">无法预览此压缩包<br>\(htmlEscape(message))</div>
        </body>
        </html>
        """
    }

    private static func htmlEscape(_ s: String) -> String {
        var out = ""
        out.reserveCapacity(s.count)
        for c in s.unicodeScalars {
            switch c {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            case "\"": out += "&quot;"
            case "'": out += "&#39;"
            default: out.unicodeScalars.append(c)
            }
        }
        return out
    }
}
