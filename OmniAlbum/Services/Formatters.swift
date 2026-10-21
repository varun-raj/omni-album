//
//  Formatters.swift
//  OmniAlbum
//
//  Shared, reused formatters (building a DateFormatter per call is slow in lists and grids).
//

import Foundation

enum Formatters {
    private static let isoFractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private static let isoPlain = ISO8601DateFormatter()

    /// Provider timestamps, with or without fractional seconds.
    static func parseISO(_ string: String) -> Date? {
        isoFractional.date(from: string) ?? isoPlain.date(from: string)
    }

    static let shortMonth = pattern("MMM")
    static let year = pattern("yyyy")
    static let dayLong = pattern("EEEE, d MMMM yyyy")
    static let time = pattern("HH:mm")
    static let fileDate = pattern("yyyy-MM-dd")

    private static func pattern(_ p: String) -> DateFormatter {
        let f = DateFormatter()
        f.dateFormat = p
        return f
    }
}
