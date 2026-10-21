//
//  LibraryStore.swift
//  OmniAlbum
//
//  Local mirror of an Immich account (assets, EXIF, albums, album membership), filled by the sync engine.
//  The UI reads from here, so opening the app never re-downloads the library.
//

import Foundation

/// What the grid needs per asset. Heavier fields (EXIF) are read on demand.
struct LibraryAsset: Identifiable, Hashable, Sendable {
    let id: String
    let type: String          // "IMAGE" | "VIDEO"
    let fileName: String
    let localDateTime: String // ISO-8601, sorts lexicographically
    let width: Int?
    let height: Int?
    let duration: Int?        // seconds
    let isFavorite: Bool
    let thumbhash: String?

    var isVideo: Bool { type == "VIDEO" }
}

struct LibraryAlbum: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let description: String
    let thumbnailAssetId: String?
    let updatedAt: String
    let assetCount: Int
}

/// A change decoded from the sync stream, ready to apply.
enum LibraryChange: Sendable {
    case asset(SyncAsset)
    case assetDeleted(id: String)
    case exif(SyncExif)
    case album(SyncAlbum)
    case albumDeleted(id: String)
    case albumAsset(albumId: String, assetId: String)
    case albumAssetDeleted(albumId: String, assetId: String)
}

actor LibraryStore {
    private let db: SQLiteDatabase

    init(path: String) throws {
        db = try SQLiteDatabase(path: path)
        try Self.migrate(db)
    }

    /// Database file for one account (`ImmichAccountInfo.id`), outside Documents and excluded from backup
    /// (it can be rebuilt by syncing).
    static func defaultPath(for accountID: String) throws -> String {
        var dir = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent("ImmichLibrary", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? dir.setResourceValues(values)
        let name = accountID.unicodeScalars.map { CharacterSet.alphanumerics.contains($0) ? String($0) : "_" }.joined()
        return dir.appendingPathComponent("\(name).sqlite").path
    }

    private static func migrate(_ db: SQLiteDatabase) throws {
        try db.exec("""
        CREATE TABLE IF NOT EXISTS assets (
            id TEXT PRIMARY KEY, ownerId TEXT, type TEXT, fileName TEXT, checksum TEXT,
            fileCreatedAt TEXT, localDateTime TEXT, width INTEGER, height INTEGER, duration INTEGER,
            isFavorite INTEGER, visibility TEXT, thumbhash TEXT, livePhotoVideoId TEXT, stackId TEXT,
            deletedAt TEXT, isEdited INTEGER
        );
        CREATE INDEX IF NOT EXISTS idx_assets_timeline ON assets (visibility, deletedAt, localDateTime DESC);
        CREATE TABLE IF NOT EXISTS exifs (
            assetId TEXT PRIMARY KEY, city TEXT, state TEXT, country TEXT, make TEXT, model TEXT, lensModel TEXT,
            latitude REAL, longitude REAL, description TEXT, fileSizeInByte INTEGER, iso INTEGER, fNumber REAL,
            focalLength REAL, exposureTime TEXT, rating INTEGER, orientation TEXT, dateTimeOriginal TEXT,
            exifImageWidth INTEGER, exifImageHeight INTEGER
        );
        CREATE TABLE IF NOT EXISTS albums (
            id TEXT PRIMARY KEY, name TEXT, description TEXT, thumbnailAssetId TEXT,
            createdAt TEXT, updatedAt TEXT, sortOrder TEXT
        );
        CREATE TABLE IF NOT EXISTS album_assets (
            albumId TEXT NOT NULL, assetId TEXT NOT NULL, PRIMARY KEY (albumId, assetId)
        );
        CREATE INDEX IF NOT EXISTS idx_album_assets_asset ON album_assets (assetId);
        CREATE TABLE IF NOT EXISTS meta (key TEXT PRIMARY KEY, value TEXT);
        """)
    }

    // MARK: - Applying sync changes

    /// One transaction per batch; the caller acks the server only after this returns.
    func apply(_ changes: [LibraryChange]) throws {
        try db.transaction {
            let upsertAsset = try db.prepare("""
                INSERT OR REPLACE INTO assets (id, ownerId, type, fileName, checksum, fileCreatedAt, localDateTime, width, height,
                    duration, isFavorite, visibility, thumbhash, livePhotoVideoId, stackId, deletedAt, isEdited)
                VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
                """)
            let deleteAsset = try db.prepare("DELETE FROM assets WHERE id = ?")
            let deleteAssetExif = try db.prepare("DELETE FROM exifs WHERE assetId = ?")
            let deleteAssetMembership = try db.prepare("DELETE FROM album_assets WHERE assetId = ?")
            let upsertExif = try db.prepare("""
                INSERT OR REPLACE INTO exifs (assetId, city, state, country, make, model, lensModel, latitude, longitude, description,
                    fileSizeInByte, iso, fNumber, focalLength, exposureTime, rating, orientation, dateTimeOriginal, exifImageWidth, exifImageHeight)
                VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
                """)
            let upsertAlbum = try db.prepare("INSERT OR REPLACE INTO albums (id, name, description, thumbnailAssetId, createdAt, updatedAt, sortOrder) VALUES (?,?,?,?,?,?,?)")
            let deleteAlbum = try db.prepare("DELETE FROM albums WHERE id = ?")
            let deleteAlbumMembership = try db.prepare("DELETE FROM album_assets WHERE albumId = ?")
            let upsertMembership = try db.prepare("INSERT OR IGNORE INTO album_assets (albumId, assetId) VALUES (?,?)")
            let deleteMembership = try db.prepare("DELETE FROM album_assets WHERE albumId = ? AND assetId = ?")

            for change in changes {
                switch change {
                case .asset(let a):
                    try upsertAsset.run([a.id, a.ownerId, a.type, a.originalFileName, a.checksum, a.fileCreatedAt, a.localDateTime,
                                         a.width, a.height, a.duration, a.isFavorite, a.visibility, a.thumbhash,
                                         a.livePhotoVideoId, a.stackId, a.deletedAt, a.isEdited])
                case .assetDeleted(let id):
                    try deleteAsset.run([id]); try deleteAssetExif.run([id]); try deleteAssetMembership.run([id])
                case .exif(let e):
                    try upsertExif.run([e.assetId, e.city, e.state, e.country, e.make, e.model, e.lensModel, e.latitude, e.longitude,
                                        e.description, e.fileSizeInByte, e.iso, e.fNumber, e.focalLength, e.exposureTime, e.rating,
                                        e.orientation, e.dateTimeOriginal, e.exifImageWidth, e.exifImageHeight])
                case .album(let a):
                    try upsertAlbum.run([a.id, a.name, a.description, a.thumbnailAssetId, a.createdAt, a.updatedAt, a.order])
                case .albumDeleted(let id):
                    try deleteAlbum.run([id]); try deleteAlbumMembership.run([id])
                case .albumAsset(let albumId, let assetId):
                    try upsertMembership.run([albumId, assetId])
                case .albumAssetDeleted(let albumId, let assetId):
                    try deleteMembership.run([albumId, assetId])
                }
            }
        }
    }

    /// Forget everything (server asked for a full resync).
    func wipe() throws {
        try db.transaction {
            for table in ["assets", "exifs", "albums", "album_assets"] { try db.exec("DELETE FROM \(table)") }
        }
    }

    // MARK: - Reading

    struct MonthBucket: Hashable, Sendable {
        let month: String // "2024-05"
        let count: Int
    }

    /// Newest-first months with their photo counts, one cheap grouped query (no per-asset work).
    func monthBuckets() throws -> [MonthBucket] {
        let stmt = try db.prepare("""
            SELECT substr(localDateTime, 1, 7) AS month, COUNT(*) FROM assets
            WHERE visibility = 'timeline' AND deletedAt IS NULL AND localDateTime IS NOT NULL
            GROUP BY month ORDER BY month DESC
            """)
        stmt.bind([])
        var out: [MonthBucket] = []
        while stmt.step() { out.append(MonthBucket(month: stmt.text(0) ?? "", count: stmt.int(1) ?? 0)) }
        return out
    }

    func assets(inMonth month: String) throws -> [LibraryAsset] {
        let stmt = try db.prepare(Self.assetSelect + """
            WHERE visibility = 'timeline' AND deletedAt IS NULL AND substr(localDateTime, 1, 7) = ?
            ORDER BY localDateTime DESC
            """)
        stmt.bind([month])
        return Self.rows(stmt)
    }

    /// The whole timeline, newest first: what the viewer pages through.
    func timelineAssets(favoritesOnly: Bool = false, limit: Int? = nil) throws -> [LibraryAsset] {
        let stmt = try db.prepare(Self.assetSelect + """
            WHERE visibility = 'timeline' AND deletedAt IS NULL AND localDateTime IS NOT NULL
            """ + (favoritesOnly ? " AND isFavorite = 1 " : " ") + """
            ORDER BY localDateTime DESC
            """ + (limit.map { " LIMIT \($0)" } ?? ""))
        stmt.bind([])
        return Self.rows(stmt)
    }

    func exif(assetId: String) throws -> SyncExif? {
        let stmt = try db.prepare("""
            SELECT assetId, city, state, country, make, model, lensModel, latitude, longitude, description, fileSizeInByte, iso,
                   fNumber, focalLength, exposureTime, rating, orientation, dateTimeOriginal, exifImageWidth, exifImageHeight
            FROM exifs WHERE assetId = ?
            """)
        stmt.bind([assetId])
        guard stmt.step() else { return nil }
        return SyncExif(assetId: assetId, city: stmt.text(1), state: stmt.text(2), country: stmt.text(3), make: stmt.text(4),
                        model: stmt.text(5), lensModel: stmt.text(6), latitude: stmt.double(7), longitude: stmt.double(8),
                        description: stmt.text(9), fileSizeInByte: stmt.int(10), iso: stmt.int(11), fNumber: stmt.double(12),
                        focalLength: stmt.double(13), exposureTime: stmt.text(14), rating: stmt.int(15), orientation: stmt.text(16),
                        dateTimeOriginal: stmt.text(17), exifImageWidth: stmt.int(18), exifImageHeight: stmt.int(19))
    }

    func albums() throws -> [LibraryAlbum] {
        let stmt = try db.prepare("""
            SELECT a.id, a.name, a.description, a.thumbnailAssetId, a.updatedAt,
                   (SELECT COUNT(*) FROM album_assets m WHERE m.albumId = a.id)
            FROM albums a ORDER BY a.updatedAt DESC
            """)
        stmt.bind([])
        var out: [LibraryAlbum] = []
        while stmt.step() {
            out.append(LibraryAlbum(id: stmt.text(0) ?? "", name: stmt.text(1) ?? "", description: stmt.text(2) ?? "",
                                    thumbnailAssetId: stmt.text(3), updatedAt: stmt.text(4) ?? "", assetCount: stmt.int(5) ?? 0))
        }
        return out
    }

    func assets(inAlbum albumId: String) throws -> [LibraryAsset] {
        let stmt = try db.prepare(Self.assetSelect + """
            WHERE id IN (SELECT assetId FROM album_assets WHERE albumId = ?) AND deletedAt IS NULL
            ORDER BY localDateTime DESC
            """)
        stmt.bind([albumId])
        return Self.rows(stmt)
    }

    struct Counts: Sendable {
        let assets: Int
        let albums: Int
    }

    func counts() throws -> Counts {
        func count(_ sql: String) throws -> Int {
            let s = try db.prepare(sql); s.bind([])
            return s.step() ? (s.int(0) ?? 0) : 0
        }
        return Counts(assets: try count("SELECT COUNT(*) FROM assets WHERE deletedAt IS NULL"), albums: try count("SELECT COUNT(*) FROM albums"))
    }

    // MARK: - Small key/value (last sync time, etc.)

    func setMeta(_ key: String, _ value: String) throws {
        try db.prepare("INSERT OR REPLACE INTO meta (key, value) VALUES (?, ?)").run([key, value])
    }

    func meta(_ key: String) throws -> String? {
        let s = try db.prepare("SELECT value FROM meta WHERE key = ?")
        s.bind([key])
        return s.step() ? s.text(0) : nil
    }

    private static let assetSelect = "SELECT id, type, fileName, localDateTime, width, height, duration, isFavorite, thumbhash FROM assets "

    private static func rows(_ stmt: SQLiteStatement) -> [LibraryAsset] {
        var out: [LibraryAsset] = []
        while stmt.step() {
            out.append(LibraryAsset(id: stmt.text(0) ?? "", type: stmt.text(1) ?? "IMAGE", fileName: stmt.text(2) ?? "",
                                    localDateTime: stmt.text(3) ?? "", width: stmt.int(4), height: stmt.int(5),
                                    duration: stmt.int(6), isFavorite: stmt.bool(7), thumbhash: stmt.text(8)))
        }
        return out
    }
}
