//
//  AlbumCSV.swift
//  OmniAlbum
//
//  Album list <-> CSV, for backup and moving between devices.
//

import Foundation

enum AlbumCSV {
    static let header = "albumName,shareLink,assetCount,allowUpload,allowDownload,provider"

    static func export(_ albums: [DisplayAlbum]) -> String {
        func quoted(_ s: String) -> String { "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }
        var csv = header + "\n"
        for album in albums {
            csv += "\(quoted(album.albumName)),\(quoted(album.shareLink)),\(album.assetCount ?? 0),\(album.allowUpload),\(album.allowDownload),\(album.provider.rawValue)\n"
        }
        return csv
    }

    /// Share links and their providers from a CSV. Supports the current format
    /// (albumName,shareLink,...,provider) and the legacy one (albumName,baseURL,shareKey,albumId,...,provider).
    static func parseShareLinks(_ content: String) -> [(link: String, provider: PhotoProvider)] {
        let lines = content.components(separatedBy: .newlines)
        guard let headerLine = lines.first else { return [] }
        let headerFields = parseLine(headerLine).map { $0.lowercased().trimmingCharacters(in: .whitespaces) }
        let isCurrentFormat = headerFields.contains("sharelink")

        var results: [(String, PhotoProvider)] = []
        for line in lines.dropFirst() where !line.isEmpty {
            let fields = parseLine(line)
            if isCurrentFormat {
                guard fields.count >= 2, !fields[1].isEmpty else { continue }
                let link = fields[1]
                let provider = (fields.count >= 6 ? PhotoProvider(rawValue: fields[5]) : nil)
                    ?? ProviderRegistry.shared.detectProvider(from: link)
                    ?? .immich
                results.append((link, provider))
            } else {
                guard fields.count >= 4 else { continue }
                let provider = fields.count > 7 ? (PhotoProvider(rawValue: fields[7]) ?? .immich) : .immich
                results.append((ShareLinkBuilder.link(provider: provider, baseURL: fields[1], shareKey: fields[2]), provider))
            }
        }
        return results
    }

    /// One CSV line; commas inside quotes stay, and "" inside quotes is a literal quote.
    static func parseLine(_ line: String) -> [String] {
        var fields: [String] = []
        var field = ""
        var inQuotes = false
        var chars = line.makeIterator()
        var next = chars.next()
        while let c = next {
            next = chars.next()
            if c == "\"" {
                if inQuotes, next == "\"" {
                    field.append("\"")
                    next = chars.next()
                } else {
                    inQuotes.toggle()
                }
            } else if c == "," && !inQuotes {
                fields.append(field)
                field = ""
            } else {
                field.append(c)
            }
        }
        fields.append(field)
        return fields
    }
}
