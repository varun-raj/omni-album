//
//  UploadProgressViews.swift
//  immich-share
//
//  Upload progress banner and queue management sheet.
//

import SwiftUI
import Photos

// MARK: - Upload Status Icon (Toolbar)

/// Compact upload status icon for toolbar with animated progress ring around cloud icon
struct UploadStatusIcon: View {
    @ObservedObject var uploadService: UploadQueueService
    let albumId: String

    private var albumUploads: [UploadTask] {
        uploadService.uploads(for: albumId)
    }

    private var pendingCount: Int {
        albumUploads.filter { $0.status == .pending || $0.status == .uploading }.count
    }

    private var failedCount: Int {
        albumUploads.filter { $0.status == .failed }.count
    }

    private var completedCount: Int {
        albumUploads.filter { $0.status == .completed }.count
    }

    private var currentProgress: Double {
        guard let active = uploadService.activeUpload, active.albumId == albumId else {
            return 0
        }
        return active.progress
    }

    private var isUploading: Bool {
        uploadService.activeUpload?.albumId == albumId
    }

    /// Compute total progress across all uploads for this album
    private var totalProgress: Double {
        let activeUploads = albumUploads.filter { $0.status == .pending || $0.status == .uploading }
        guard !activeUploads.isEmpty else { return 0 }

        let completedForThisAlbum = albumUploads.filter { $0.status == .completed }.count
        let totalForThisAlbum = completedForThisAlbum + activeUploads.count
        guard totalForThisAlbum > 0 else { return 0 }

        // Progress = completed items + current item's partial progress
        let currentItemProgress = currentProgress
        return (Double(completedForThisAlbum) + currentItemProgress) / Double(totalForThisAlbum)
    }

    var body: some View {
        ZStack {
            if isUploading || pendingCount > 0 {
                // Progress ring around cloud icon
                Circle()
                    .stroke(Color(.systemGray4), lineWidth: 2.5)
                    .frame(width: 28, height: 28)

                Circle()
                    .trim(from: 0, to: totalProgress)
                    .stroke(Color.blue, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                    .frame(width: 28, height: 28)
                    .rotationEffect(.degrees(-90))
                    .animation(.linear(duration: 0.1), value: totalProgress)

                // Cloud icon in center
                Image(systemName: "icloud.and.arrow.up")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.blue)
            } else if failedCount > 0 {
                // Failed state - cloud with error badge
                ZStack(alignment: .topTrailing) {
                    Image(systemName: "icloud.and.arrow.up")
                        .font(.system(size: 20))
                        .foregroundStyle(.primary)

                    Circle()
                        .fill(.red)
                        .frame(width: 14, height: 14)
                        .overlay {
                            Text("\(failedCount)")
                                .font(.system(size: 8, weight: .bold, design: .rounded))
                                .foregroundStyle(.white)
                        }
                        .offset(x: 4, y: -4)
                }
            } else if completedCount > 0 && pendingCount == 0 {
                // All completed - checkmark cloud
                Image(systemName: "checkmark.icloud.fill")
                    .font(.system(size: 20))
                    .foregroundStyle(.green)
            } else {
                // Default idle state (no uploads)
                Image(systemName: "icloud.and.arrow.up")
                    .font(.system(size: 20))
                    .foregroundStyle(.primary)
            }
        }
        .frame(width: 30, height: 30)
    }
}

// MARK: - Upload Progress Banner

struct UploadProgressBanner: View {
    @ObservedObject var uploadService: UploadQueueService
    let albumId: String
    let onTap: () -> Void

    private var albumUploads: [UploadTask] {
        uploadService.uploads(for: albumId)
    }

    private var pendingCount: Int {
        albumUploads.filter { $0.status == .pending || $0.status == .uploading }.count
    }

    private var failedCount: Int {
        albumUploads.filter { $0.status == .failed }.count
    }

    private var completedCount: Int {
        albumUploads.filter { $0.status == .completed }.count
    }

    private var hasUploads: Bool {
        !albumUploads.isEmpty
    }

    var body: some View {
        if hasUploads {
            Button(action: onTap) {
                HStack(spacing: 12) {
                    // Status icon
                    if pendingCount > 0 {
                        ProgressView()
                            .scaleEffect(0.8)
                    } else if failedCount > 0 {
                        Image(systemName: "exclamationmark.circle.fill")
                            .foregroundStyle(.red)
                    } else if completedCount > 0 {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    }

                    // Status text
                    VStack(alignment: .leading, spacing: 2) {
                        if pendingCount > 0 {
                            Text("Uploading \(pendingCount) item\(pendingCount == 1 ? "" : "s")")
                                .font(.subheadline.weight(.medium))
                        } else if failedCount > 0 {
                            Text("\(failedCount) upload\(failedCount == 1 ? "" : "s") failed")
                                .font(.subheadline.weight(.medium))
                                .foregroundStyle(.red)
                        } else if completedCount > 0 {
                            Text("\(completedCount) upload\(completedCount == 1 ? "" : "s") completed")
                                .font(.subheadline.weight(.medium))
                                .foregroundStyle(.green)
                        }

                        // Progress bar for active upload
                        if let active = uploadService.activeUpload, active.albumId == albumId {
                            GeometryReader { geometry in
                                ZStack(alignment: .leading) {
                                    Capsule()
                                        .fill(Color(.systemGray5))
                                        .frame(height: 4)

                                    Capsule()
                                        .fill(.blue)
                                        .frame(width: geometry.size.width * active.progress, height: 4)
                                }
                            }
                            .frame(height: 4)
                        }
                    }

                    Spacer()

                    Image(systemName: "chevron.right")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .background(.ultraThinMaterial)
                .clipShape(.rect(cornerRadius: 12))
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
    }
}

// MARK: - Upload Queue Sheet (Used from Album Detail View)

struct UploadQueueSheet: View {
    @ObservedObject var uploadService: UploadQueueService
    let albumId: String?  // nil shows all uploads
    @Environment(\.dismiss) private var dismiss

    private var filteredUploads: [UploadTask] {
        if let albumId = albumId {
            return uploadService.uploads(for: albumId)
        }
        return uploadService.queue
    }

    private var groupedUploads: [(String, [UploadTask])] {
        let grouped = Dictionary(grouping: filteredUploads) { $0.status }
        var result: [(String, [UploadTask])] = []

        // Order: uploading, pending, failed, completed
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
        NavigationStack {
            Group {
                if filteredUploads.isEmpty {
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
            .navigationTitle("Uploads")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Done") {
                        dismiss()
                    }
                }

                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        if uploadService.failedCount > 0 {
                            Button {
                                uploadService.retryFailed()
                            } label: {
                                Label("Retry Failed", systemImage: "arrow.clockwise")
                            }
                        }

                        if filteredUploads.contains(where: { $0.status == .completed }) {
                            Button {
                                uploadService.clearCompleted()
                            } label: {
                                Label("Clear Completed", systemImage: "checkmark.circle")
                            }
                        }

                        if !filteredUploads.isEmpty {
                            Divider()

                            Button(role: .destructive) {
                                uploadService.clearAll()
                            } label: {
                                Label("Clear All", systemImage: "trash")
                            }
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                    .disabled(filteredUploads.isEmpty)
                }
            }
        }
    }
}

// MARK: - Upload Queue Task Row

struct UploadQueueTaskRow: View {
    let uploadTask: UploadTask
    @ObservedObject private var uploadService = UploadQueueService.shared
    @State private var thumbnail: UIImage?

    /// Relevant time to display based on status
    private var displayTime: Date {
        switch uploadTask.status {
        case .completed, .failed:
            return uploadTask.completedAt ?? uploadTask.createdAt
        case .pending, .uploading:
            return uploadTask.createdAt
        }
    }

    /// Format the time for display
    private var timeText: String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: displayTime, relativeTo: Date())
    }

    var body: some View {
        HStack(spacing: 12) {
            // Thumbnail from Photos library
            thumbnailView
                .frame(width: 50, height: 50)
                .clipShape(.rect(cornerRadius: 8))

            // Info
            VStack(alignment: .leading, spacing: 3) {
                Text(uploadTask.fileName)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)

                // Album name
                HStack(spacing: 4) {
                    Image(systemName: "rectangle.stack")
                        .font(.system(size: 9))
                    Text(uploadTask.albumName)
                        .lineLimit(1)
                }
                .font(.caption)
                .foregroundStyle(.secondary)

                // Time and file size
                HStack(spacing: 4) {
                    Text(timeText)

                    if let fileSize = uploadTask.fileSize {
                        Text("•")
                        Text(formatBytes(fileSize))
                    }
                }
                .font(.caption2)
                .foregroundStyle(.tertiary)

                // Progress or error
                if uploadTask.status == .uploading {
                    ProgressView(value: uploadTask.progress)
                        .progressViewStyle(.linear)
                } else if uploadTask.status == .failed, let error = uploadTask.errorMessage {
                    Text(error)
                        .font(.caption2)
                        .foregroundStyle(.red)
                        .lineLimit(1)
                }
            }

            Spacer()

            // Action button
            actionButton
        }
        .padding(.vertical, 4)
        .task {
            await loadThumbnail()
        }
    }

    @ViewBuilder
    private var thumbnailView: some View {
        if let thumbnail = thumbnail {
            Image(uiImage: thumbnail)
                .resizable()
                .aspectRatio(contentMode: .fill)
        } else {
            // Fallback with status indicator
            Rectangle()
                .fill(Color(.systemGray5))
                .overlay {
                    statusIcon
                }
        }
    }

    @ViewBuilder
    private var statusIcon: some View {
        switch uploadTask.status {
        case .pending:
            Image(systemName: "clock")
                .foregroundStyle(.secondary)
        case .uploading:
            ProgressView()
                .scaleEffect(0.7)
        case .completed:
            Image(systemName: "checkmark")
                .foregroundStyle(.green)
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
        }
    }

    @ViewBuilder
    private var actionButton: some View {
        switch uploadTask.status {
        case .failed:
            HStack(spacing: 12) {
                Button {
                    uploadService.retryTask(uploadTask)
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .foregroundStyle(.blue)
                }
                .buttonStyle(.plain)

                Button {
                    uploadService.removeTask(uploadTask)
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        case .pending:
            Button {
                uploadService.removeTask(uploadTask)
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        case .completed:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .uploading:
            EmptyView()
        }
    }

    private func loadThumbnail() async {
        let fetchResult = PHAsset.fetchAssets(withLocalIdentifiers: [uploadTask.localAssetIdentifier], options: nil)
        guard let asset = fetchResult.firstObject else { return }

        let options = PHImageRequestOptions()
        options.deliveryMode = .highQualityFormat
        options.isNetworkAccessAllowed = true
        options.resizeMode = .fast
        options.isSynchronous = false

        let targetSize = CGSize(width: 100, height: 100)

        // Use actor to ensure continuation is only resumed once
        let imageActor = ImageLoadActor()

        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            PHImageManager.default().requestImage(
                for: asset,
                targetSize: targetSize,
                contentMode: .aspectFill,
                options: options
            ) { image, info in
                Task {
                    let shouldResume = await imageActor.tryResume()
                    if shouldResume {
                        await MainActor.run {
                            if let image = image {
                                self.thumbnail = image
                            }
                        }
                        continuation.resume()
                    }
                }
            }
        }
    }

    private func formatBytes(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }
}

// MARK: - Image Load Actor

/// Actor to ensure PHImageManager callback only resumes continuation once
private actor ImageLoadActor {
    private var hasResumed = false

    func tryResume() -> Bool {
        if hasResumed { return false }
        hasResumed = true
        return true
    }
}

// MARK: - Previews

#Preview("Upload Status Icon") {
    HStack(spacing: 20) {
        UploadStatusIcon(uploadService: .shared, albumId: "test")
    }
    .padding()
}

#Preview("Upload Queue Sheet") {
    UploadQueueSheet(
        uploadService: .shared,
        albumId: nil
    )
}
