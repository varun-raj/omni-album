//
//  VideoPlayerView.swift
//  OmniAlbum
//
//  Inline video player used by the viewer.
//

import SwiftUI
import AVKit
import Kingfisher

// MARK: - Video Player View

struct VideoPlayerView: View {
    let videoURL: URL?
    let thumbnailURL: URL?
    var headers: [String: String]? = nil
    var cacheScope: String? = nil
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
                        KFImage(source: .network(ImageLoading.resource(for: thumbnailURL, scope: cacheScope)))
                            .requestModifier(ImageLoading.modifier(headers: headers))
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
            // .playback so sound isn't muted by the silent switch and AirPlay / external playback can take over
            try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
            try? AVAudioSession.sharedInstance().setActive(true)
            // The header key is what AVFoundation reads for authenticated streams (the constant isn't public API)
            let asset = AVURLAsset(url: videoURL, options: headers.map { ["AVURLAssetHTTPHeaderFieldsKey": $0] })
            let newPlayer = AVPlayer(playerItem: AVPlayerItem(asset: asset))
            newPlayer.allowsExternalPlayback = true
            player = newPlayer
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
