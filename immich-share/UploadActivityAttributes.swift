//
//  UploadActivityAttributes.swift
//  immich-share
//
//  Live Activity attributes for upload progress on Dynamic Island.
//

#if canImport(ActivityKit)
import ActivityKit
#endif
import Foundation

#if canImport(ActivityKit)
@available(iOS 16.2, *)
struct UploadActivityAttributes: ActivityAttributes {
    /// Dynamic content state - changes during the activity
    public struct ContentState: Codable, Hashable {
        /// Current upload progress (0.0 - 1.0)
        var progress: Double
        /// Number of items remaining to upload
        var remainingCount: Int
        /// Total items being uploaded
        var totalCount: Int
        /// Current file being uploaded
        var currentFileName: String
        /// Album name
        var albumName: String
        /// Has any uploads failed
        var hasFailures: Bool
        /// Number of completed uploads
        var completedCount: Int
    }

    /// Album ID this activity is for
    var albumId: String
}
#endif
