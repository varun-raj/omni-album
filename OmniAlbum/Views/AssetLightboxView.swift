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
import Kingfisher

struct AssetLightboxView: View {
    let assets: [Asset]
    let selectedIndex: Int
    let viewModel: AlbumDetailViewModel
    let zoomNamespace: Namespace.ID
    let onDismiss: () -> Void

    @State private var currentIndex: Int
    @State private var showDetailsSheet = false
    @State private var isZoomed = false
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
                // Tap cycles: light stage with all the chrome <-> black stage with nothing.
                // Dismissal (drag down / zoom back to the tile) is the system zoom transition's.
                (showChrome ? Color(.systemBackground) : Color.black).ignoresSafeArea()

                // Photo pager, edge to edge
                TabView(selection: $currentIndex) {
                    ForEach(Array(assets.enumerated()), id: \.element.id) { index, asset in
                        // Pages far from the current one stay empty: a TabView otherwise builds every
                        // page (image loads, players) up front, which hurts in albums with thousands of photos.
                        Group {
                            if abs(index - currentIndex) <= 2 {
                                PhotoPageView(
                                    asset: asset,
                                    viewModel: viewModel,
                                    isZoomed: $isZoomed,
                                    onTap: { toggleChrome() }
                                )
                            } else {
                                Color.clear
                            }
                        }
                        .tag(index)
                    }
                }
                .tabViewStyle(.page(indexDisplayMode: .never))
                .ignoresSafeArea()
                .simultaneousGesture(swipeUpForDetails)
                .onChange(of: currentIndex) { _, _ in isZoomed = false }

                // Chrome floats over the photo: no title, just close / menu and the action bar
                VStack(spacing: 0) {
                    if showChrome {
                        topBar
                            .transition(.opacity)
                        Spacer()
                        thumbnailStrip
                            .transition(.opacity)
                        bottomBar
                            .transition(.opacity)
                    }
                }
                .tint(.primary)
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
                    .presentationDetents([.medium, .large])
            }
        }
        .alert("Error", isPresented: .constant(saveError != nil)) {
            Button("OK") { saveError = nil }
        } message: {
            Text(saveError ?? "")
        }
        .animation(.easeInOut(duration: 0.25), value: showChrome)
        .statusBarHidden(!showChrome) // dark status text would vanish on the black stage
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

    // MARK: - Film strip

    private var thumbnailStrip: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 3) {
                    ForEach(Array(assets.enumerated()), id: \.element.id) { index, asset in
                        ThumbnailCell(
                            url: viewModel.thumbnailURL(for: asset),
                            isSelected: currentIndex == index,
                            isVideo: viewModel.isVideo(asset)
                        )
                        .padding(.horizontal, currentIndex == index ? 5 : 0) // the current one opens a gap, like Photos
                        .onTapGesture { currentIndex = index }
                        .accessibilityElement()
                        .accessibilityLabel(asset.originalFileName)
                        .accessibilityAddTraits(currentIndex == index ? [.isButton, .isSelected] : .isButton)
                        .id(index)
                    }
                }
                .padding(.horizontal, 16)
            }
            .frame(height: 52)
            .animation(.easeInOut(duration: 0.2), value: currentIndex)
            .onChange(of: currentIndex) { _, newIndex in
                withAnimation(.easeInOut(duration: 0.2)) { proxy.scrollTo(newIndex, anchor: .center) }
            }
            .onAppear { proxy.scrollTo(currentIndex, anchor: .center) }
        }
    }

    /// Photos-style: flick up on the photo for its details. Ignored while zoomed (that's a pan) or when metadata is hidden.
    private var swipeUpForDetails: some Gesture {
        DragGesture(minimumDistance: 30)
            .onEnded { value in
                guard viewModel.showMetadata, !isZoomed else { return }
                let up = -value.translation.height
                guard up > 80, up > abs(value.translation.width) * 1.5 else { return }
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                showDetailsSheet = true
            }
    }

    private func toggleChrome() {
        withAnimation(.easeInOut(duration: 0.3)) {
            showChrome.toggle()
        }
    }

    // MARK: - Share / Save

    private func shareCurrentPhoto() {
        guard let asset = currentAsset else { return }
        isSharing = true
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()

        Task {
            do {
                try await AssetActions.share(asset, viewModel: viewModel)
            } catch {
                saveError = "Failed to load: \(error.localizedDescription)"
            }
            isSharing = false
        }
    }

    private func saveCurrentPhoto() {
        guard let asset = currentAsset else { return }
        isSaving = true
        saveError = nil
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()

        Task {
            do {
                try await AssetActions.saveToPhotos(asset, viewModel: viewModel)
                showSaveSuccessToast()
            } catch {
                isSaving = false
                saveError = "Failed to save: \(error.localizedDescription)"
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
    @Binding var isZoomed: Bool
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
                isZoomed: $isZoomed,
                onTap: onTap
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipShape(.rect(cornerRadius: 0))
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
                        .setProcessor(DownsamplingImageProcessor(size: CGSize(width: 160, height: 160)))
                        .scaleFactor(1)
                        .cacheOriginalImage()
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
