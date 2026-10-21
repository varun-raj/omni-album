//
//  ServerBaseURL.swift
//  OmniAlbum
//
//  One place that turns a server URL into the base every provider builds API paths on.
//  Keeps a path prefix, so servers hosted at https://host/immich or https://host/nextcloud work.
//

import Foundation

enum ServerBaseURL {
    /// scheme://host[:port][/prefix] with no trailing slash, query or fragment.
    static func normalize(_ raw: String) -> String? {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if !s.contains("://") { s = "https://" + s }
        guard let url = URL(string: s) else { return nil }
        return make(url, prefixBefore: nil)
    }

    /// Base of the server a share link points at. `marker` is the provider's path segment
    /// ("/share/", "/s/", "/gallery/", ...); everything before its first occurrence is the install prefix.
    static func make(_ url: URL, prefixBefore marker: String?) -> String? {
        guard let host = url.host else { return nil }
        let scheme = url.scheme ?? "https"
        var base = "\(scheme)://\(host)"
        if let port = url.port, (scheme == "https" && port != 443) || (scheme == "http" && port != 80) {
            base += ":\(port)"
        }
        var prefix = url.path
        if let marker, let range = prefix.range(of: marker) {
            prefix = String(prefix[..<range.lowerBound])
        } else if marker != nil {
            prefix = ""
        }
        while prefix.hasSuffix("/") { prefix.removeLast() }
        return base + prefix
    }
}
