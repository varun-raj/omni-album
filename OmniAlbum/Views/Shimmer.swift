//
//  Shimmer.swift
//  OmniAlbum
//
//  Skeleton placeholders: gray shapes with a light sweep, shown while content loads.
//

import SwiftUI

/// A soft highlight that sweeps left to right across the view's own shape.
private struct Shimmer: ViewModifier {
    @State private var sweep = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .overlay {
                if !reduceMotion {
                    GeometryReader { geo in
                        LinearGradient(colors: [.clear, .white.opacity(0.5), .clear], startPoint: .leading, endPoint: .trailing)
                            .frame(width: geo.size.width * 0.5)
                            .offset(x: sweep ? geo.size.width : -geo.size.width * 0.5)
                    }
                    .mask(content)
                }
            }
            .onAppear {
                guard !reduceMotion else { return }
                withAnimation(.linear(duration: 1.4).repeatForever(autoreverses: false)) { sweep = true }
            }
            .accessibilityElement()
            .accessibilityLabel("Loading")
    }
}

extension View {
    func shimmer() -> some View { modifier(Shimmer()) }
}

/// Stand-in for AlbumPhotoGrid: same columns and 2 pt gaps, so the real grid replaces it without a jump.
struct SkeletonPhotoGrid: View {
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    private var columns: [GridItem] {
        Array(repeating: GridItem(.flexible(), spacing: 2), count: horizontalSizeClass == .regular ? 6 : 3)
    }

    var body: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 2) {
                ForEach(0..<42, id: \.self) { _ in
                    Color(.systemGray5).aspectRatio(1, contentMode: .fit)
                }
            }
            .shimmer()
        }
        .scrollDisabled(true)
        .allowsHitTesting(false)
    }
}

/// Stand-in for the albums grid.
struct SkeletonAlbumGrid: View {
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    private var columns: [GridItem] {
        Array(repeating: GridItem(.flexible(), spacing: 12), count: horizontalSizeClass == .regular ? 4 : 2)
    }

    var body: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 12) {
                ForEach(0..<6, id: \.self) { _ in
                    RoundedRectangle(cornerRadius: 20)
                        .fill(Color(.systemGray5))
                        .aspectRatio(1, contentMode: .fit)
                }
            }
            .padding(16)
            .shimmer()
        }
        .scrollDisabled(true)
        .allowsHitTesting(false)
    }
}
