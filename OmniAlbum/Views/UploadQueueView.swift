//
//  UploadQueueView.swift
//  OmniAlbum
//
//  Full-page upload queue.
//

import SwiftUI

// MARK: - Shared queue pieces (Settings > Upload Queue, and the Upload tab)

/// The queue grouped by status, as List sections.
struct UploadQueueSections: View {
    @ObservedObject var uploadService: UploadQueueService

    private var groupedUploads: [(String, [UploadTask])] {
        let grouped = Dictionary(grouping: uploadService.queue) { $0.status }
        return [("Uploading", UploadStatus.uploading), ("Pending", .pending), ("Failed", .failed), ("Completed", .completed)]
            .compactMap { title, status in grouped[status].flatMap { $0.isEmpty ? nil : (title, $0) } }
    }

    var body: some View {
        ForEach(groupedUploads, id: \.0) { section, tasks in
            Section(section) {
                ForEach(tasks) { UploadQueueTaskRow(uploadTask: $0) }
            }
        }
    }
}

/// Retry failed / clear completed / clear all.
struct UploadQueueMenu: View {
    @ObservedObject var uploadService: UploadQueueService

    var body: some View {
        Menu {
            if uploadService.failedCount > 0 {
                Button { uploadService.retryFailed() } label: { Label("Retry Failed", systemImage: "arrow.clockwise") }
            }
            if uploadService.queue.contains(where: { $0.status == .completed }) {
                Button { uploadService.clearCompleted() } label: { Label("Clear Completed", systemImage: "checkmark.circle") }
            }
            Divider()
            Button(role: .destructive) { uploadService.clearAll() } label: { Label("Clear All", systemImage: "trash") }
        } label: {
            Image(systemName: "ellipsis.circle")
        }
    }
}

// MARK: - Upload Queue View (Full Page)

struct UploadQueueView: View {
    @ObservedObject private var uploadService = UploadQueueService.shared

    var body: some View {
        Group {
            if uploadService.queue.isEmpty {
                ContentUnavailableView {
                    Label("No Uploads", systemImage: "icloud.and.arrow.up")
                } description: {
                    Text("Photos you upload will appear here.")
                }
            } else {
                List { UploadQueueSections(uploadService: uploadService) }
            }
        }
        .navigationTitle("Upload Queue")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                if !uploadService.queue.isEmpty { UploadQueueMenu(uploadService: uploadService) }
            }
        }
    }
}
