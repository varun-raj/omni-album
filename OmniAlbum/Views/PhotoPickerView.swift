//
//  PhotoPickerView.swift
//  OmniAlbum
//
//  Photo picker for selecting images to upload to an album.
//

import SwiftUI
import PhotosUI
import UIKit

struct PhotoPickerView: View {
    let album: DisplayAlbum
    @Environment(\.dismiss) private var dismiss

    @State private var showingPicker = false
    @State private var selectedAssets: [SelectedAsset] = []
    @State private var isProcessing = false
    @State private var isLoadingPhotos = false
    @State private var loadingProgress = 0
    @State private var loadingTotal = 0
    @State private var processedCount = 0
    @State private var hasShownPicker = false

    var body: some View {
        VStack(spacing: 0) {
            if isLoadingPhotos {
                // Loading photos from library
                Spacer()

                VStack(spacing: 20) {
                    ProgressView()
                        .scaleEffect(1.5)

                    Text("Loading photos...")
                        .font(.headline)

                    if loadingTotal > 0 {
                        Text("\(loadingProgress) of \(loadingTotal)")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }

                Spacer()

            } else if selectedAssets.isEmpty && !isProcessing {
                // Empty state - prompt to select
                Spacer()

                VStack(spacing: 20) {
                    Image(systemName: "photo.badge.plus")
                        .font(.system(size: 70))
                        .foregroundStyle(.blue)

                    Text("Add Photos")
                        .font(.title.bold())

                    Text("Select photos to upload to\n\"\(album.albumName)\"")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)

                    Button {
                        showingPicker = true
                    } label: {
                        Label("Choose Photos", systemImage: "photo.on.rectangle.angled")
                            .font(.headline)
                            .padding(.horizontal, 32)
                            .padding(.vertical, 14)
                            .background(.blue)
                            .foregroundStyle(.white)
                            .clipShape(Capsule())
                    }
                    .padding(.top, 8)
                }

                Spacer()

            } else if !selectedAssets.isEmpty && !isProcessing {
                // Selected photos preview
                Spacer()

                VStack(spacing: 24) {
                    // Stacked photos preview
                    SelectedPhotosStack(assets: selectedAssets)

                    // Action buttons
                    VStack(spacing: 12) {
                        Button {
                            uploadSelected()
                        } label: {
                            HStack {
                                Image(systemName: "arrow.up.circle.fill")
                                Text("Upload \(selectedAssets.count) Photo\(selectedAssets.count == 1 ? "" : "s")")
                            }
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 16)
                            .background(.green)
                            .foregroundStyle(.white)
                            .clipShape(.rect(cornerRadius: 14))
                        }

                        HStack(spacing: 12) {
                            Button {
                                showingPicker = true
                            } label: {
                                HStack {
                                    Image(systemName: "plus")
                                    Text("Add More")
                                }
                                .font(.subheadline.weight(.medium))
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 12)
                                .background(Color(.systemGray5))
                                .foregroundStyle(.primary)
                                .clipShape(.rect(cornerRadius: 10))
                            }

                            Button {
                                selectedAssets.removeAll()
                            } label: {
                                HStack {
                                    Image(systemName: "xmark")
                                    Text("Clear")
                                }
                                .font(.subheadline.weight(.medium))
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 12)
                                .background(Color(.systemGray5))
                                .foregroundStyle(.red)
                                .clipShape(.rect(cornerRadius: 10))
                            }
                        }
                    }
                    .padding(.horizontal, 24)
                }

                Spacer()

            } else if isProcessing {
                // Processing indicator
                Spacer()

                VStack(spacing: 16) {
                    ProgressView()
                        .scaleEffect(1.5)

                    Text("Adding to upload queue...")
                        .font(.headline)

                    Text("\(processedCount) of \(selectedAssets.count)")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                Spacer()
            }
        }
        .navigationTitle("Upload")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showingPicker) {
            PHPickerRepresentable(
                selectedAssets: $selectedAssets,
                isLoading: $isLoadingPhotos,
                loadingProgress: $loadingProgress,
                loadingTotal: $loadingTotal
            )
        }
        .onAppear {
            // Auto-show picker on first appear
            if !hasShownPicker {
                hasShownPicker = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    showingPicker = true
                }
            }
        }
    }

    private func uploadSelected() {
        guard !selectedAssets.isEmpty else {
            print("Upload: No assets selected")
            return
        }

        print("Upload: Starting upload of \(selectedAssets.count) assets")
        isProcessing = true
        processedCount = 0

        var tasks: [UploadTask] = []

        for asset in selectedAssets {
            processedCount += 1

            let task = UploadTask(
                albumId: album.albumId,
                albumName: album.albumName,
                baseURL: album.baseURL,
                shareKey: album.shareKey,
                password: album.password,
                localAssetIdentifier: asset.localIdentifier,
                fileName: asset.fileName,
                fileSize: asset.fileSize,
                provider: album.provider.rawValue
            )
            tasks.append(task)
        }

        // Add all tasks to the queue
        if !tasks.isEmpty {
            print("Upload: Adding \(tasks.count) tasks to queue")
            UploadQueueService.shared.addTasks(tasks)
            print("Upload: Tasks added, queue now has \(UploadQueueService.shared.queue.count) items")

            // Refresh album data after uploads complete
            Task {
                // Wait a moment for uploads to start processing
                try? await Task.sleep(nanoseconds: 500_000_000)
                // Trigger refresh on the album view model
                await AlbumDetailViewModel.instance(for: album.albumId)?.refresh()
            }
        }

        isProcessing = false
        selectedAssets.removeAll()
        dismiss()
    }
}

// MARK: - Selected Asset Model

struct SelectedAsset: Identifiable {
    let id = UUID()
    let localIdentifier: String
    let fileName: String
    let fileSize: Int64?
    let thumbnail: UIImage?
}

// MARK: - Stacked Photos Preview

struct SelectedPhotosStack: View {
    let assets: [SelectedAsset]

    private let imageSize: CGFloat = 120
    private let stackOffset: CGFloat = 25

    var body: some View {
        VStack(spacing: 20) {
            // Stacked images
            ZStack {
                // Show up to 3 images stacked
                ForEach(Array(assets.prefix(3).enumerated().reversed()), id: \.element.id) { index, asset in
                    if let image = asset.thumbnail {
                        Image(uiImage: image)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                            .frame(width: imageSize, height: imageSize)
                            .clipShape(.rect(cornerRadius: 16))
                            .shadow(color: .black.opacity(0.2), radius: 10, x: 0, y: 5)
                            .rotationEffect(.degrees(Double(index - 1) * 8))
                            .offset(x: CGFloat(index - 1) * stackOffset)
                    }
                }

                // Badge showing count
                if assets.count > 1 {
                    ZStack {
                        Circle()
                            .fill(.blue)
                            .frame(width: 44, height: 44)
                            .shadow(color: .blue.opacity(0.4), radius: 6, x: 0, y: 3)

                        Text("\(assets.count)")
                            .font(.system(size: 18, weight: .bold, design: .rounded))
                            .foregroundStyle(.white)
                    }
                    .offset(x: 55, y: -55)
                }
            }
            .frame(height: imageSize + 50)

            // Label
            Text("\(assets.count) photo\(assets.count == 1 ? "" : "s") ready to upload")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - PHPicker UIKit Wrapper

struct PHPickerRepresentable: UIViewControllerRepresentable {
    @Binding var selectedAssets: [SelectedAsset]
    @Binding var isLoading: Bool
    @Binding var loadingProgress: Int
    @Binding var loadingTotal: Int
    @Environment(\.dismiss) private var dismiss

    func makeUIViewController(context: Context) -> PHPickerViewController {
        var config = PHPickerConfiguration(photoLibrary: .shared())
        config.selectionLimit = 0  // 0 = unlimited selection
        config.filter = .any(of: [.images, .videos])
        config.selection = .ordered

        let picker = PHPickerViewController(configuration: config)
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: PHPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    class Coordinator: NSObject, PHPickerViewControllerDelegate {
        let parent: PHPickerRepresentable

        init(_ parent: PHPickerRepresentable) {
            self.parent = parent
        }

        func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
            // Dismiss picker immediately for better UX
            picker.dismiss(animated: true)

            guard !results.isEmpty else {
                return
            }

            // Get asset identifiers
            let identifiers = results.compactMap { $0.assetIdentifier }
            print("PhotoPicker: Selected \(results.count) items, got \(identifiers.count) identifiers")

            guard !identifiers.isEmpty else {
                print("PhotoPicker: No asset identifiers found - user may have limited photo access")
                return
            }

            // Show loading state
            DispatchQueue.main.async {
                self.parent.isLoading = true
                self.parent.loadingTotal = identifiers.count
                self.parent.loadingProgress = 0
            }

            // Process in background
            DispatchQueue.global(qos: .userInitiated).async {
                let fetchResult = PHAsset.fetchAssets(withLocalIdentifiers: identifiers, options: nil)

                var assets: [SelectedAsset] = []
                let imageManager = PHCachingImageManager()
                let thumbnailSize = CGSize(width: 240, height: 240)
                let options = PHImageRequestOptions()
                options.isSynchronous = true
                options.deliveryMode = .fastFormat
                options.resizeMode = .fast

                fetchResult.enumerateObjects { phAsset, index, _ in
                    // Update progress on main thread
                    DispatchQueue.main.async {
                        self.parent.loadingProgress = index + 1
                    }

                    // Get thumbnail
                    var thumbnail: UIImage?
                    imageManager.requestImage(
                        for: phAsset,
                        targetSize: thumbnailSize,
                        contentMode: .aspectFill,
                        options: options
                    ) { image, _ in
                        thumbnail = image
                    }

                    // Get filename and size
                    let resources = PHAssetResource.assetResources(for: phAsset)
                    let fileName = resources.first?.originalFilename ?? self.generateFileName(for: phAsset)
                    let fileSize = resources.first.flatMap { resource -> Int64? in
                        resource.value(forKey: "fileSize") as? Int64
                    }

                    let asset = SelectedAsset(
                        localIdentifier: phAsset.localIdentifier,
                        fileName: fileName,
                        fileSize: fileSize,
                        thumbnail: thumbnail
                    )
                    assets.append(asset)
                }

                // Update UI on main thread
                print("PhotoPicker: Processed \(assets.count) assets with thumbnails")
                DispatchQueue.main.async {
                    self.parent.selectedAssets.append(contentsOf: assets)
                    self.parent.isLoading = false
                    print("PhotoPicker: Updated selectedAssets, now has \(self.parent.selectedAssets.count) items")
                }
            }
        }

        private func generateFileName(for asset: PHAsset) -> String {
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyyMMdd_HHmmss"
            let datePart = formatter.string(from: asset.creationDate ?? Date())
            let ext = asset.mediaType == .video ? "mp4" : "jpg"
            return "IMG_\(datePart).\(ext)"
        }
    }
}

#Preview {
    NavigationStack {
        PhotoPickerView(album: DisplayAlbum(
            id: "1",
            albumName: "Test Album",
            albumThumbnailAssetId: nil,
            baseURL: "https://example.com",
            shareKey: "abc123",
            albumId: "album-1",
            assetCount: 10,
            allowUpload: true
        ))
    }
}
