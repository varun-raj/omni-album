//
//  AssetLightboxView.swift
//  OmniAlbum
//
//  Full-screen photo viewer styled like Apple Photos:
//  - Light background with centered photo
//  - Top bar with back, title pill, and menu
//  - Bottom toolbar with share, favorite, info, adjust, delete
//  - Thumbnail scrubber strip
//

import SwiftUI
import Photos
import MapKit
import AVKit
import Kingfisher

struct AssetLightboxView: View {
    let assets: [Asset]
    let selectedIndex: Int
    let viewModel: AlbumDetailViewModel
    let zoomNamespace: Namespace.ID
    let onDismiss: () -> Void

    @State private var currentIndex: Int
    @State private var showDetailsSheet = false
    @State private var isSaving = false
    @State private var isSharing = false
    @State private var saveError: String?
    @State private var showSaveSuccess = false
    @State private var showChrome = true

    init(assets: [Asset], selectedIndex: Int, viewModel: AlbumDetailViewModel, zoomNamespace: Namespace.ID, onDismiss: @escaping () -> Void) {
        self.assets = assets
        self.selectedIndex = selectedIndex
        self.viewModel = viewModel
        self.zoomNamespace = zoomNamespace
        self.onDismiss = onDismiss
        _currentIndex = State(initialValue: selectedIndex)
    }

    private var currentAsset: Asset? {
        guard currentIndex >= 0, currentIndex < assets.count else { return nil }
        return assets[currentIndex]
    }

    private var isCurrentAssetVideo: Bool {
        guard let asset = currentAsset else { return false }
        return viewModel.isVideo(asset)
    }

    private var toastMessage: String {
        if showSaveSuccess { return "Saved to Photos" }
        if isSharing { return "Preparing to share…" }
        if isSaving {
            return isCurrentAssetVideo ? "Saving video…" : "Saving to Photos…"
        }
        return ""
    }

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                // Dark stage; dismissal (drag down / zoom back to the tile) is the system zoom transition's.
                Color.black.ignoresSafeArea()

                // Photo pager, edge to edge
                TabView(selection: $currentIndex) {
                    ForEach(Array(assets.enumerated()), id: \.element.id) { index, asset in
                        PhotoPageView(
                            asset: asset,
                            viewModel: viewModel,
                            onTap: { toggleChrome() }
                        )
                        .tag(index)
                    }
                }
                .tabViewStyle(.page(indexDisplayMode: .never))
                .ignoresSafeArea()

                // Chrome floats over the photo: no title, just close / menu and the action bar
                VStack(spacing: 0) {
                    if showChrome {
                        topBar
                            .transition(.opacity)
                        Spacer()
                        bottomBar
                            .transition(.opacity)
                    }
                }
                .tint(.white)
                .padding(.bottom, geometry.safeAreaInsets.bottom > 0 ? 0 : 8)

                // Toast overlay for sharing/saving
                if isSharing || isSaving || showSaveSuccess {
                    VStack {
                        Spacer()
                        HStack(spacing: 12) {
                            if showSaveSuccess {
                                Image(systemName: "checkmark.circle.fill")
                                    .font(.title3)
                                    .foregroundStyle(.white)
                            } else {
                                ProgressView()
                                    .tint(.white)
                            }
                            Text(toastMessage)
                                .font(.subheadline.weight(.medium))
                                .foregroundStyle(.white)
                        }
                        .padding(.horizontal, 20)
                        .padding(.vertical, 14)
                        .background(showSaveSuccess ? Color.green.opacity(0.9) : Color.black.opacity(0.75), in: Capsule())
                        .padding(.bottom, 140)
                    }
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .animation(.spring(response: 0.3, dampingFraction: 0.8), value: isSharing)
                    .animation(.spring(response: 0.3, dampingFraction: 0.8), value: isSaving)
                    .animation(.spring(response: 0.3, dampingFraction: 0.8), value: showSaveSuccess)
                }
            }
            .animation(.easeInOut(duration: 0.2), value: showChrome)
        }
        .sheet(isPresented: $showDetailsSheet) {
            if let asset = currentAsset {
                AssetDetailsSheet(asset: asset, viewModel: viewModel)
            }
        }
        .alert("Error", isPresented: .constant(saveError != nil)) {
            Button("OK") { saveError = nil }
        } message: {
            Text(saveError ?? "")
        }
        .animation(.easeInOut(duration: 0.25), value: showChrome)
        .navigationTransition(.zoom(sourceID: currentAsset?.id ?? "", in: zoomNamespace))
    }

    // MARK: - Top Bar

    private var topBar: some View {
        HStack(spacing: 16) {
            Button {
                onDismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(.primary)
                    .frame(width: 36, height: 36)
                    .background(.ultraThinMaterial, in: Circle())
            }
            .accessibilityLabel("Close")

            Spacer()

            Spacer()

            Menu {
                if viewModel.showMetadata {
                    Button {
                        showDetailsSheet = true
                    } label: {
                        Label("Info", systemImage: "info.circle")
                    }
                }
                if viewModel.allowDownload {
                    Button {
                        saveCurrentPhoto()
                    } label: {
                        Label("Save to Photos", systemImage: "square.and.arrow.down")
                    }
                    Button {
                        shareCurrentPhoto()
                    } label: {
                        Label("Share", systemImage: "square.and.arrow.up")
                    }
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(.primary)
                    .frame(width: 36, height: 36)
                    .background(.ultraThinMaterial, in: Circle())
            }
            .accessibilityLabel("More")
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 8)
    }

    // MARK: - Bottom Bar

    private var bottomBar: some View {
        HStack(spacing: 20) {
            if viewModel.allowDownload {
                Button {
                    shareCurrentPhoto()
                } label: {
                    if isSharing {
                        ProgressView()
                            .frame(width: 44, height: 44)
                    } else {
                        Image(systemName: "square.and.arrow.up")
                            .font(.system(size: 18, weight: .medium))
                            .frame(width: 44, height: 44)
                            .background(.ultraThinMaterial, in: Circle())
                    }
                }
                .disabled(isSharing || currentAsset == nil)
                .accessibilityLabel("Share")
            }

            if viewModel.showMetadata {
                Button {
                    showDetailsSheet = true
                } label: {
                    Image(systemName: "info.circle")
                        .font(.system(size: 18, weight: .medium))
                        .frame(width: 44, height: 44)
                        .background(.ultraThinMaterial, in: Circle())
                }
                .accessibilityLabel("Info")
            }

            if viewModel.allowDownload {
                Button {
                    saveCurrentPhoto()
                } label: {
                    if isSaving {
                        ProgressView()
                            .frame(width: 44, height: 44)
                    } else {
                        Image(systemName: isCurrentAssetVideo ? "arrow.down.circle" : "arrow.down.to.line")
                            .font(.system(size: 18, weight: .medium))
                            .frame(width: 44, height: 44)
                            .background(.ultraThinMaterial, in: Circle())
                    }
                }
                .disabled(isSaving)
                .accessibilityLabel("Save to Photos")
            }
        }
        .foregroundStyle(.primary)
        .padding(.vertical, 12)
    }

    private func toggleChrome() {
        withAnimation(.easeInOut(duration: 0.25)) {
            showChrome.toggle()
        }
    }

    // MARK: - Share Photo

    private func shareCurrentPhoto() {
        guard let asset = currentAsset else { return }
        isSharing = true

        let generator = UIImpactFeedbackGenerator(style: .medium)
        generator.impactOccurred()

        Task {
            do {
                let data: Data
                if let decryptedData = try await viewModel.loadImageData(for: asset, variant: .original) {
                    data = decryptedData
                } else {
                    let url = viewModel.originalURL(for: asset)
                        ?? viewModel.previewURL(for: asset)
                        ?? viewModel.thumbnailURL(for: asset)
                    guard let url = url else {
                        isSharing = false
                        return
                    }
                    let (urlData, _) = try await URLSession.shared.data(from: url)
                    data = urlData
                }

                let tempDir = FileManager.default.temporaryDirectory
                let tempFile = tempDir.appendingPathComponent(asset.originalFileName)
                try? FileManager.default.removeItem(at: tempFile)
                try data.write(to: tempFile)

                await MainActor.run {
                    isSharing = false
                    ShareHelper.share(items: [tempFile])
                }
            } catch {
                await MainActor.run {
                    isSharing = false
                    saveError = "Failed to load image: \(error.localizedDescription)"
                }
            }
        }
    }

    // MARK: - Save Photo/Video

    private func saveCurrentPhoto() {
        guard let asset = currentAsset else { return }
        isSaving = true
        saveError = nil

        let generator = UIImpactFeedbackGenerator(style: .medium)
        generator.impactOccurred()

        if viewModel.isVideo(asset) {
            saveVideo(asset: asset)
        } else {
            saveImage(asset: asset)
        }
    }

    private func saveImage(asset: Asset) {
        Task {
            do {
                // Try decrypted data path first (for Ente and similar providers)
                if let decryptedData = try await viewModel.loadImageData(for: asset, variant: .original) {
                    try await saveDataToPhotos(decryptedData, fileName: asset.originalFileName)
                    return
                }
            } catch {
                await MainActor.run {
                    isSaving = false
                    saveError = "Failed to save: \(error.localizedDescription)"
                }
                return
            }

            // Fall back to URL-based loading
            let url = viewModel.originalURL(for: asset)
                ?? viewModel.previewURL(for: asset)
                ?? viewModel.thumbnailURL(for: asset)
            guard let url = url else {
                isSaving = false
                saveError = "No image URL available."
                return
            }

            let result = await withCheckedContinuation { continuation in
                KingfisherManager.shared.retrieveImage(with: url) { result in
                    continuation.resume(returning: result)
                }
            }

            switch result {
            case .success(let value):
                do {
                    try await PHPhotoLibrary.shared().performChanges {
                        PHAssetChangeRequest.creationRequestForAsset(from: value.image)
                    }
                    await MainActor.run {
                        showSaveSuccessToast()
                    }
                } catch {
                    await MainActor.run {
                        isSaving = false
                        saveError = error.localizedDescription
                    }
                }
            case .failure:
                if url == viewModel.originalURL(for: asset) {
                    let fallbackURL = viewModel.previewURL(for: asset) ?? viewModel.thumbnailURL(for: asset)
                    if let fallbackURL = fallbackURL {
                        await saveImageFromURL(fallbackURL)
                        return
                    }
                }
                await MainActor.run {
                    isSaving = false
                    saveError = "Failed to download image."
                }
            }
        }
    }

    private func saveImageFromURL(_ url: URL) async {
        let result = await withCheckedContinuation { continuation in
            KingfisherManager.shared.retrieveImage(with: url) { result in
                continuation.resume(returning: result)
            }
        }

        switch result {
        case .success(let value):
            do {
                try await PHPhotoLibrary.shared().performChanges {
                    PHAssetChangeRequest.creationRequestForAsset(from: value.image)
                }
                await MainActor.run {
                    showSaveSuccessToast()
                }
            } catch {
                await MainActor.run {
                    isSaving = false
                    saveError = error.localizedDescription
                }
            }
        case .failure(let error):
            await MainActor.run {
                isSaving = false
                saveError = error.localizedDescription
            }
        }
    }

    /// Save raw file data to Photos library via temp file (preserves original format)
    private func saveDataToPhotos(_ data: Data, fileName: String) async throws {
        let tempDir = FileManager.default.temporaryDirectory
        let tempFile = tempDir.appendingPathComponent(fileName)
        try? FileManager.default.removeItem(at: tempFile)
        try data.write(to: tempFile)

        let ext = (fileName as NSString).pathExtension.lowercased()
        let videoExtensions = ["mp4", "mov", "avi", "mkv", "webm", "m4v"]

        do {
            if videoExtensions.contains(ext) {
                try await PHPhotoLibrary.shared().performChanges {
                    PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: tempFile)
                }
            } else {
                try await PHPhotoLibrary.shared().performChanges {
                    PHAssetChangeRequest.creationRequestForAssetFromImage(atFileURL: tempFile)
                }
            }
            try? FileManager.default.removeItem(at: tempFile)
            await MainActor.run {
                showSaveSuccessToast()
            }
        } catch {
            try? FileManager.default.removeItem(at: tempFile)
            throw error
        }
    }

    private func saveVideo(asset: Asset) {
        Task {
            do {
                // Try decrypted data path first (for Ente and similar providers)
                if let decryptedData = try await viewModel.loadImageData(for: asset, variant: .original) {
                    try await saveDataToPhotos(decryptedData, fileName: asset.originalFileName)
                    return
                }
            } catch {
                await MainActor.run {
                    isSaving = false
                    saveError = "Failed to save: \(error.localizedDescription)"
                }
                return
            }

            // Fall back to URL-based download
            guard let videoURL = viewModel.videoPlaybackURL(for: asset) else {
                isSaving = false
                saveError = "No video URL available."
                return
            }

            do {
                let (tempURL, _) = try await URLSession.shared.download(from: videoURL)
                let tempDir = FileManager.default.temporaryDirectory
                let videoFile = tempDir.appendingPathComponent(UUID().uuidString + ".mp4")

                try FileManager.default.moveItem(at: tempURL, to: videoFile)

                try await PHPhotoLibrary.shared().performChanges {
                    PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: videoFile)
                }

                try? FileManager.default.removeItem(at: videoFile)

                await MainActor.run {
                    showSaveSuccessToast()
                }
            } catch {
                await MainActor.run {
                    isSaving = false
                    saveError = error.localizedDescription
                }
            }
        }
    }

    private func showSaveSuccessToast() {
        isSaving = false
        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
            showSaveSuccess = true
        }
        let successGenerator = UINotificationFeedbackGenerator()
        successGenerator.notificationOccurred(.success)

        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                showSaveSuccess = false
            }
        }
    }
}

// MARK: - Asset Page View (Photo or Video)

private struct PhotoPageView: View {
    let asset: Asset
    let viewModel: AlbumDetailViewModel
    let onTap: () -> Void

    var body: some View {
        if viewModel.isVideo(asset) {
            VideoPlayerView(
                videoURL: viewModel.videoPlaybackURL(for: asset),
                thumbnailURL: viewModel.thumbnailURL(for: asset),
                onTap: onTap
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipShape(.rect(cornerRadius: 0))
        } else {
            let url = viewModel.previewURL(for: asset) ?? viewModel.thumbnailURL(for: asset)
            ZoomablePhotoView(
                url: url,
                viewModel: viewModel.requiresDecryption ? viewModel : nil,
                asset: viewModel.requiresDecryption ? asset : nil,
                onTap: onTap
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipShape(.rect(cornerRadius: 0))
        }
    }
}

// MARK: - Video Player View

private struct VideoPlayerView: View {
    let videoURL: URL?
    let thumbnailURL: URL?
    let onTap: () -> Void

    @State private var player: AVPlayer?
    @State private var isPlaying = false
    @State private var showControls = true

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                if let player = player {
                    VideoPlayer(player: player)
                        .frame(width: geometry.size.width, height: geometry.size.height)
                        .onTapGesture {
                            if isPlaying {
                                withAnimation { showControls.toggle() }
                            } else {
                                onTap()
                            }
                        }
                } else {
                    // Thumbnail while loading
                    if let thumbnailURL = thumbnailURL {
                        KFImage(thumbnailURL)
                            .placeholder {
                                placeholderView
                            }
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                    } else {
                        placeholderView
                    }
                }

                // Play button overlay
                if !isPlaying {
                    Button {
                        startPlayback()
                    } label: {
                        Circle()
                            .fill(.ultraThinMaterial)
                            .frame(width: 80, height: 80)
                            .overlay {
                                Image(systemName: "play.fill")
                                    .font(.system(size: 32))
                                    .foregroundStyle(.primary)
                                    .offset(x: 3) // Visual centering for play icon
                            }
                    }
                }

                // Playback controls overlay
                if isPlaying && showControls {
                    VStack {
                        Spacer()
                        HStack(spacing: 32) {
                            Button {
                                player?.seek(to: .zero)
                            } label: {
                                Image(systemName: "backward.fill")
                                    .font(.title2)
                            }

                            Button {
                                togglePlayPause()
                            } label: {
                                Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                                    .font(.title)
                            }

                            Button {
                                // Forward 10 seconds
                                if let player = player {
                                    let currentTime = player.currentTime()
                                    let newTime = CMTimeAdd(currentTime, CMTime(seconds: 10, preferredTimescale: 1))
                                    player.seek(to: newTime)
                                }
                            } label: {
                                Image(systemName: "forward.fill")
                                    .font(.title2)
                            }
                        }
                        .foregroundStyle(.white)
                        .padding(.vertical, 16)
                        .padding(.horizontal, 32)
                        .background(.ultraThinMaterial, in: Capsule())
                        .padding(.bottom, 40)
                    }
                    .transition(.opacity)
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
        }
        .onDisappear {
            player?.pause()
            player = nil
        }
    }

    private var placeholderView: some View {
        ZStack {
            Color(.systemGray5)
            Image(systemName: "video")
                .font(.system(size: 50))
                .foregroundStyle(.secondary)
        }
    }

    private func startPlayback() {
        guard let videoURL = videoURL else { return }

        if player == nil {
            player = AVPlayer(url: videoURL)
        }
        player?.play()
        isPlaying = true

        // Auto-hide controls after 3 seconds
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            if isPlaying {
                withAnimation { showControls = false }
            }
        }
    }

    private func togglePlayPause() {
        if player?.rate == 0 {
            player?.play()
            isPlaying = true
        } else {
            player?.pause()
            isPlaying = false
        }
    }
}

// MARK: - Thumbnail Cell

private struct ThumbnailCell: View {
    let url: URL?
    let isSelected: Bool
    var isVideo: Bool = false

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            Group {
                if let url = url {
                    KFImage(url)
                        .placeholder {
                            Color(.systemGray4)
                        }
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                } else {
                    Color(.systemGray4)
                }
            }
            .frame(width: 44, height: 44)
            .clipShape(.rect(cornerRadius: 6))

            // Video indicator
            if isVideo {
                Image(systemName: "play.fill")
                    .font(.system(size: 8))
                    .foregroundStyle(.white)
                    .padding(3)
                    .background(.black.opacity(0.5), in: Circle())
                    .padding(2)
            }
        }
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(Color.accentColor, lineWidth: isSelected ? 3 : 0)
        )
        .shadow(color: isSelected ? .accentColor.opacity(0.3) : .clear, radius: 4)
        .animation(.easeInOut(duration: 0.15), value: isSelected)
    }
}

// MARK: - Asset Details Sheet (clean info panel)
struct AssetDetailsSheet: View {
    let asset: Asset
    let viewModel: AlbumDetailViewModel

    @Environment(\.dismiss) private var dismiss

    private var dateTimeFormatted: String? {
        let s = asset.createdAt ?? ""
        guard !s.isEmpty else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let date = formatter.date(from: s) ?? ISO8601DateFormatter().date(from: s)
        guard let date = date else { return s }
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "EEEE, d MMMM yyyy"
        let timeFormatter = DateFormatter()
        timeFormatter.dateFormat = "HH:mm"
        return "\(dateFormatter.string(from: date)) at \(timeFormatter.string(from: date))"
    }

    private var formatPill: String {
        let mime = asset.providerData?["originalMimeType"] ?? (asset.type == .video ? "video" : "image")
        if mime.uppercased().contains("HEIF") || mime.uppercased().contains("HEIC") { return "HEIF" }
        if mime.uppercased().contains("JPEG") || mime.uppercased().contains("JPG") { return "JPEG" }
        if mime.uppercased().contains("PNG") { return "PNG" }
        if mime.uppercased().contains("VIDEO") { return "VIDEO" }
        return mime.split(separator: "/").last.map(String.init)?.uppercased() ?? "FILE"
    }

    private var deviceLine: String? {
        guard let exif = asset.exif else { return nil }
        let make = exif.make ?? ""
        let model = exif.model ?? ""
        if make.isEmpty && model.isEmpty { return nil }
        if make.isEmpty { return model }
        if model.isEmpty { return make }
        // Avoid duplication like "Apple iPhone 15 Pro"
        if model.lowercased().contains(make.lowercased()) { return model }
        return "\(make) \(model)"
    }

    private var cameraSettingsLine: String? {
        guard let exif = asset.exif else { return nil }
        var parts: [String] = []
        if let focal = exif.focalLength { parts.append(String(format: "%.0fmm", focal)) }
        if let f = exif.fNumber { parts.append(String(format: "ƒ/%.1f", f)) }
        if let exp = exif.exposureTime, !exp.isEmpty { parts.append(exp + "s") }
        if let iso = exif.iso { parts.append("ISO \(iso)") }
        return parts.isEmpty ? nil : parts.joined(separator: "  ")
    }

    private var dimensionsLine: String? {
        let w = asset.exif?.width ?? asset.width
        let h = asset.exif?.height ?? asset.height
        guard let w, let h else { return nil }
        let mp = Double(w * h) / 1_000_000
        return String(format: "%.1f MP • %d × %d", mp, w, h)
    }

    private var fileSizeLine: String? {
        guard let size = asset.exif?.fileSizeInBytes else { return nil }
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: size)
    }

    private var locationText: String? {
        guard let exif = asset.exif else { return nil }
        var parts: [String] = []
        if let city = exif.city, !city.isEmpty { parts.append(city) }
        if let state = exif.state, !state.isEmpty { parts.append(state) }
        if let country = exif.country, !country.isEmpty { parts.append(country) }
        return parts.isEmpty ? nil : parts.joined(separator: ", ")
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    // Date & Time
                    if let dt = dateTimeFormatted {
                        VStack(alignment: .leading, spacing: 4) {
                            Label("Date & Time", systemImage: "calendar")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text(dt)
                                .font(.subheadline)
                        }
                    }

                    // File Info
                    VStack(alignment: .leading, spacing: 4) {
                        Label("File", systemImage: "doc")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(asset.originalFileName)
                            .font(.subheadline)
                        HStack(spacing: 8) {
                            Text(formatPill)
                                .font(.caption2.weight(.medium))
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(.secondary.opacity(0.2))
                                .clipShape(.capsule)
                            if let size = fileSizeLine {
                                Text(size)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }

                    // Device & Camera
                    if let device = deviceLine {
                        VStack(alignment: .leading, spacing: 4) {
                            Label("Camera", systemImage: "camera")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text(device)
                                .font(.subheadline)
                            if let settings = cameraSettingsLine {
                                Text(settings)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .monospacedDigit()
                            }
                        }
                    }

                    // Dimensions
                    if let dims = dimensionsLine {
                        VStack(alignment: .leading, spacing: 4) {
                            Label("Dimensions", systemImage: "aspectratio")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text(dims)
                                .font(.subheadline)
                        }
                    }

                    // Location
                    if let exif = asset.exif, let lat = exif.latitude, let lon = exif.longitude {
                        VStack(alignment: .leading, spacing: 8) {
                            Label("Location", systemImage: "location")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            if let loc = locationText {
                                Text(loc)
                                    .font(.subheadline)
                            }
                            MapDetailView(latitude: lat, longitude: lon)
                                .frame(height: 180)
                                .clipShape(.rect(cornerRadius: 12))
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 20)
                .padding(.vertical, 16)
            }
            .navigationTitle("Info")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
            .toolbarBackground(.visible, for: .navigationBar)
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }
}

// MARK: - Map for location (EXIF lat/lon)
struct MapDetailView: View {
    let latitude: Double
    let longitude: Double

    var body: some View {
        Map(initialPosition: .region(MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: latitude, longitude: longitude),
            span: MKCoordinateSpan(latitudeDelta: 0.01, longitudeDelta: 0.01)
        ))) {
            Annotation("", coordinate: CLLocationCoordinate2D(latitude: latitude, longitude: longitude)) {
                Image(systemName: "moon.fill")
                    .font(.caption)
                    .foregroundStyle(.primary)
            }
        }
        .mapStyle(.standard)
    }
}

// MARK: - Zoomable photo (pinch to zoom, pan when zoomed, double-tap to zoom)
struct ZoomablePhotoView: View {
    let url: URL?
    var viewModel: AlbumDetailViewModel? = nil
    var asset: Asset? = nil
    var onTap: (() -> Void)? = nil

    @State private var scale: CGFloat = 1
    @State private var lastScale: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var lastOffset: CGSize = .zero
    @State private var loadedImage: UIImage?
    @State private var isLoading = true

    private let minScale: CGFloat = 1
    private let maxScale: CGFloat = 5

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                if let image = loadedImage {
                    Image(uiImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(maxWidth: geometry.size.width, maxHeight: geometry.size.height)
                        .scaleEffect(scale)
                        .offset(offset)
                        .gesture(magnificationGesture)
                        .gesture(scale > 1 ? panGesture : nil)
                        .onTapGesture(count: 2, perform: doubleTapAction)
                        .onTapGesture(count: 1) { onTap?() }
                } else if isLoading {
                    ProgressView()
                        .scaleEffect(1.2)
                } else {
                    placeholderView
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
        }
        .task(id: asset?.id ?? url?.absoluteString ?? "") {
            await loadImage()
        }
    }

    private func loadImage() async {
        loadedImage = nil
        isLoading = true

        // Try decrypted data path first (for Ente and similar providers)
        if let viewModel = viewModel, let asset = asset {
            do {
                if let data = try await viewModel.loadImageData(for: asset, variant: .preview) {
                    await MainActor.run {
                        loadedImage = UIImage(data: data)
                        isLoading = false
                    }
                    return
                }
            } catch {
                // Fall through to URL-based loading
            }
        }

        guard let url = url else {
            isLoading = false
            return
        }

        // Use Kingfisher for caching
        let result = await withCheckedContinuation { continuation in
            KingfisherManager.shared.retrieveImage(with: url) { result in
                continuation.resume(returning: result)
            }
        }

        await MainActor.run {
            switch result {
            case .success(let value):
                loadedImage = value.image
            case .failure:
                loadedImage = nil
            }
            isLoading = false
        }
    }

    private var magnificationGesture: some Gesture {
        MagnificationGesture()
            .onChanged { value in
                let delta = value / lastScale
                lastScale = value
                scale = min(max(scale * delta, minScale), maxScale)
            }
            .onEnded { _ in
                lastScale = 1
                if scale <= 1.05 {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                        scale = 1
                        offset = .zero
                        lastOffset = .zero
                    }
                }
            }
    }

    private var panGesture: some Gesture {
        DragGesture()
            .onChanged { value in
                offset = CGSize(
                    width: lastOffset.width + value.translation.width,
                    height: lastOffset.height + value.translation.height
                )
            }
            .onEnded { _ in
                lastOffset = offset
            }
    }

    private func doubleTapAction() {
        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
            if scale > 1 {
                scale = 1
                offset = .zero
                lastOffset = .zero
            } else {
                scale = 2.5
            }
        }
    }

    private var placeholderView: some View {
        Image(systemName: "photo")
            .font(.system(size: 50))
            .foregroundStyle(.secondary)
    }
}

// MARK: - Share Helper

enum ShareHelper {
    @MainActor
    static func share(items: [Any]) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            let activityVC = UIActivityViewController(activityItems: items, applicationActivities: nil)

            guard let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
                  let rootVC = windowScene.windows.first?.rootViewController else {
                return
            }

            var topVC = rootVC
            while let presented = topVC.presentedViewController {
                topVC = presented
            }

            if let popover = activityVC.popoverPresentationController {
                popover.sourceView = topVC.view
                popover.sourceRect = CGRect(x: topVC.view.bounds.midX, y: topVC.view.bounds.midY, width: 0, height: 0)
                popover.permittedArrowDirections = []
            }

            topVC.present(activityVC, animated: true)
        }
    }

    @MainActor
    static func share(image: UIImage) {
        // Small delay to let gesture system settle (helps avoid "gesture gate timed out" on simulator)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            let activityVC = UIActivityViewController(activityItems: [image], applicationActivities: nil)

            // Get the key window's root view controller
            guard let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
                  let rootVC = windowScene.windows.first?.rootViewController else {
                return
            }

            // Find the topmost presented view controller
            var topVC = rootVC
            while let presented = topVC.presentedViewController {
                topVC = presented
            }

            // For iPad, set the popover source
            if let popover = activityVC.popoverPresentationController {
                popover.sourceView = topVC.view
                popover.sourceRect = CGRect(x: topVC.view.bounds.midX, y: topVC.view.bounds.midY, width: 0, height: 0)
                popover.permittedArrowDirections = []
            }

            topVC.present(activityVC, animated: true)
        }
    }
}
