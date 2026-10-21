//
//  Log.swift
//  OmniAlbum
//
//  One os.Logger per area (filter by category in Console.app).
//

import os

enum Log {
    private static let subsystem = "com.skcript.omnialbum"
    static let app = Logger(subsystem: subsystem, category: "app")
    static let sync = Logger(subsystem: subsystem, category: "sync")
    static let upload = Logger(subsystem: subsystem, category: "upload")
}
