//
//  UploadQueuePersistenceService.swift
//  immich-share
//
//  Persists upload queue to local JSON file for resume on app restart.
//

import Foundation

actor UploadQueuePersistenceService {
    private let fileURL: URL

    init() {
        let documentsDirectory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        self.fileURL = documentsDirectory.appendingPathComponent("upload_queue.json")
    }

    /// Save the upload queue to disk
    func save(_ tasks: [UploadTask]) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(tasks)
        try data.write(to: fileURL, options: .atomic)
    }

    /// Load the upload queue from disk
    func load() throws -> [UploadTask] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return []
        }

        let data = try Data(contentsOf: fileURL)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode([UploadTask].self, from: data)
    }

    /// Delete the persisted queue file
    func clear() throws {
        if FileManager.default.fileExists(atPath: fileURL.path) {
            try FileManager.default.removeItem(at: fileURL)
        }
    }
}
