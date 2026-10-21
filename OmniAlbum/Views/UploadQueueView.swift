//
//  UploadQueueView.swift
//  OmniAlbum
//
//  Full-page upload queue.
//

import SwiftUI

// MARK: - Upload Queue View (Full Page)

struct UploadQueueView: View {
    @ObservedObject private var uploadService = UploadQueueService.shared

    private var groupedUploads: [(String, [UploadTask])] {
        let grouped = Dictionary(grouping: uploadService.queue) { $0.status }
        var result: [(String, [UploadTask])] = []

        if let uploading = grouped[.uploading], !uploading.isEmpty {
            result.append(("Uploading", uploading))
        }
        if let pending = grouped[.pending], !pending.isEmpty {
            result.append(("Pending", pending))
        }
        if let failed = grouped[.failed], !failed.isEmpty {
            result.append(("Failed", failed))
        }
        if let completed = grouped[.completed], !completed.isEmpty {
            result.append(("Completed", completed))
        }

        return result
    }

    var body: some View {
        Group {
            if uploadService.queue.isEmpty {
                ContentUnavailableView {
                    Label("No Uploads", systemImage: "icloud.and.arrow.up")
                } description: {
                    Text("Photos you upload will appear here.")
                }
            } else {
                List {
                    ForEach(groupedUploads, id: \.0) { section, tasks in
                        Section(section) {
                            ForEach(tasks) { uploadTask in
                                UploadQueueTaskRow(uploadTask: uploadTask)
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle("Upload Queue")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                if !uploadService.queue.isEmpty {
                    Menu {
                        if uploadService.failedCount > 0 {
                            Button {
                                uploadService.retryFailed()
                            } label: {
                                Label("Retry Failed", systemImage: "arrow.clockwise")
                            }
                        }

                        if uploadService.queue.contains(where: { $0.status == .completed }) {
                            Button {
                                uploadService.clearCompleted()
                            } label: {
                                Label("Clear Completed", systemImage: "checkmark.circle")
                            }
                        }

                        Divider()

                        Button(role: .destructive) {
                            uploadService.clearAll()
                        } label: {
                            Label("Clear All", systemImage: "trash")
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                }
            }
        }
    }
}
