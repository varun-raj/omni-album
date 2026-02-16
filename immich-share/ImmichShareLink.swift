//
//  ImmichShareLink.swift
//  immich-share
//
//  Parses Immich share URLs to extract base URL and key/token for API calls.
//

import Foundation

struct ParsedShareLink {
    let baseURL: String
    let key: String?
    let slug: String?
    let token: String?
}

enum ShareLinkParseError: LocalizedError {
    case notAValidURL(String)
    case missingSharePath
    case missingKeyOrToken

    var errorDescription: String? {
        switch self {
        case .notAValidURL(let s): return "Not a valid URL: \(s)"
        case .missingSharePath: return "URL must be an Immich share link (path contains /share/)."
        case .missingKeyOrToken: return "Share link must include a key or token."
        }
    }
}

enum ImmichShareLink {
    /// Parses a full share URL (e.g. https://my.immich.app/share/KEY or .../share/slug?key=KEY).
    /// Returns base URL (scheme + host + port) and key (from path after /share/ or from query).
    static func parse(_ urlString: String) throws -> ParsedShareLink {
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        var s = trimmed
        if !s.contains("://") { s = "https://" + s }
        guard let url = URL(string: s), let host = url.host else {
            throw ShareLinkParseError.notAValidURL(trimmed)
        }
        let path = url.path
        guard path.contains("/share/") else {
            throw ShareLinkParseError.missingSharePath
        }
        let scheme = url.scheme ?? "https"
        var base = "\(scheme)://\(host)"
        if let port = url.port, (scheme == "https" && port != 443) || (scheme == "http" && port != 80) {
            base += ":\(port)"
        }
        let pathParts = path.split(separator: "/")
        guard let shareIndex = pathParts.firstIndex(of: "share"), shareIndex + 1 < pathParts.count else {
            throw ShareLinkParseError.missingKeyOrToken
        }
        let afterShare = String(pathParts[shareIndex + 1])
        var key: String? = url.queryItems?["key"]
        var slug: String?
        var token: String?
        if key == nil {
            key = afterShare
            token = afterShare
        } else {
            slug = afterShare
        }
        guard key != nil, !(key ?? "").isEmpty else {
            throw ShareLinkParseError.missingKeyOrToken
        }
        return ParsedShareLink(baseURL: base, key: key, slug: slug?.isEmpty == true ? nil : slug, token: token)
    }
}

private extension URL {
    var queryItems: [String: String]? {
        guard let comp = URLComponents(url: self, resolvingAgainstBaseURL: false), let items = comp.queryItems else { return nil }
        var dict: [String: String] = [:]
        for item in items {
            if let v = item.value { dict[item.name] = v }
        }
        return dict.isEmpty ? nil : dict
    }
}
