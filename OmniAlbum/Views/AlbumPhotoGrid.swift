//
//  AlbumPhotoGrid.swift
//  OmniAlbum
//
//  Native Photos-style grid: square tiles, 2 pt gaps, edge to edge. Each tile is a matched
//  transition source, so opening a photo uses the system zoom transition (and its interactive dismiss).
//

import SwiftUI

struct AlbumPhotoGrid: View {
    @ObservedObject var viewModel: AlbumDetailViewModel
    let namespace: Namespace.ID
    let onSelect: (Asset) -> Void
    let onShare: (Asset) -> Void
    let onSave: (Asset) -> Void

    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    private static let gap: CGFloat = 2

    private var columns: [GridItem] {
        Array(repeating: GridItem(.flexible(), spacing: Self.gap), count: horizontalSizeClass == .regular ? 6 : 3)
    }

    var body: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: Self.gap) {
                ForEach(viewModel.assets) { asset in
                    Button {
                        onSelect(asset)
                    } label: {
                        tile(asset)
                    }
                    .buttonStyle(.plain)
                    .matchedTransitionSource(id: asset.id, in: namespace)
                    .contextMenu {
                        if viewModel.allowDownload, asset.type == .image {
                            Button("Share", systemImage: "square.and.arrow.up") { onShare(asset) }
                            Button("Save to Photos", systemImage: "square.and.arrow.down") { onSave(asset) }
                        }
                    }
                    .accessibilityLabel(asset.type == .video ? "Video, \(asset.originalFileName)" : asset.originalFileName)
                }
            }
        }
        .refreshable { await viewModel.refresh() }
    }

    private func tile(_ asset: Asset) -> some View {
        Color.clear
            .aspectRatio(1, contentMode: .fit)
            .overlay { CachedAsyncImage(url: viewModel.thumbnailURL(for: asset)) }
            .clipped()
            .contentShape(Rectangle())
            .overlay(alignment: .bottomTrailing) {
                if asset.type == .video { videoBadge(asset) }
            }
    }

    private func videoBadge(_ asset: Asset) -> some View {
        HStack(spacing: 3) {
            Image(systemName: "play.fill")
                .font(.system(size: 8, weight: .semibold))
            if let text = Self.durationText(asset.duration) {
                Text(text)
                    .font(.system(size: 10, weight: .medium, design: .rounded))
            }
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(.black.opacity(0.6), in: Capsule())
        .padding(6)
    }

    /// "H:MM:SS" from the providers -> "M:SS".
    private static func durationText(_ duration: String?) -> String? {
        guard let duration, duration != "0:00:00", !duration.isEmpty else { return nil }
        let parts = duration.split(separator: ":").compactMap { Int($0) }
        switch parts.count {
        case 3: return String(format: "%d:%02d", parts[0] * 60 + parts[1], parts[2])
        case 2: return String(format: "%d:%02d", parts[0], parts[1])
        default: return duration
        }
    }
}
