//
//  ZoomablePhotoView.swift
//  OmniAlbum
//
//  Pinch / double-tap zoom for a photo, with retry on failure.
//

import SwiftUI
import Kingfisher

// MARK: - Zoomable photo (pinch to zoom, pan when zoomed, double-tap to zoom)
struct ZoomablePhotoView: View {
    let url: URL?
    var viewModel: AlbumDetailViewModel? = nil
    var asset: Asset? = nil
    var isZoomed: Binding<Bool>? = nil
    var onTap: (() -> Void)? = nil

    @State private var scale: CGFloat = 1
    @State private var lastScale: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var lastOffset: CGSize = .zero
    @State private var loadedImage: UIImage?
    @State private var isLoading = true
    @State private var loadFailed = false

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
                        .gesture(magnificationGesture(in: geometry.size))
                        .gesture(scale > 1 ? panGesture(in: geometry.size) : nil)
                        .onTapGesture(count: 2, perform: doubleTapAction)
                        .onTapGesture(count: 1) { onTap?() }
                } else if isLoading {
                    ProgressView()
                        .scaleEffect(1.2)
                } else if loadFailed {
                    failedView
                } else {
                    placeholderView
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
        }
        .onChange(of: scale) { _, new in isZoomed?.wrappedValue = new > 1.05 }
        .task(id: asset?.id ?? url?.absoluteString ?? "") {
            await loadImage()
        }
    }

    private func loadImage() async {
        loadedImage = nil
        loadFailed = false
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
                // The URL for an encrypted asset can't be decoded either: show the failure, don't fall through.
                await MainActor.run {
                    loadFailed = true
                    isLoading = false
                }
                return
            }
        }

        guard let url = url else {
            isLoading = false
            loadFailed = true
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
                loadFailed = true
            }
            isLoading = false
        }
    }

    /// Keeps the zoomed photo covering the screen: it can't be dragged past its own edges.
    private func clamped(_ o: CGSize, in size: CGSize) -> CGSize {
        guard let img = loadedImage, img.size.width > 0, img.size.height > 0 else { return o }
        let fit = min(size.width / img.size.width, size.height / img.size.height)
        let maxX = max(0, (img.size.width * fit * scale - size.width) / 2)
        let maxY = max(0, (img.size.height * fit * scale - size.height) / 2)
        return CGSize(width: min(max(o.width, -maxX), maxX), height: min(max(o.height, -maxY), maxY))
    }

    private func magnificationGesture(in size: CGSize) -> some Gesture {
        MagnificationGesture()
            .onChanged { value in
                let delta = value / lastScale
                lastScale = value
                scale = min(max(scale * delta, minScale), maxScale)
                offset = clamped(offset, in: size) // zooming out pulls the photo back toward the centre
                lastOffset = offset
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

    private func panGesture(in size: CGSize) -> some Gesture {
        DragGesture()
            .onChanged { value in
                offset = clamped(
                    CGSize(width: lastOffset.width + value.translation.width,
                           height: lastOffset.height + value.translation.height),
                    in: size
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

    private var failedView: some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 36))
                .foregroundStyle(.secondary)
            Text("Couldn't load this photo")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Button("Try Again") {
                Task { await loadImage() }
            }
            .buttonStyle(.bordered)
        }
    }

    private var placeholderView: some View {
        Image(systemName: "photo")
            .font(.system(size: 50))
            .foregroundStyle(.secondary)
    }
}
