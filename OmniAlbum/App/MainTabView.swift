//
//  MainTabView.swift
//  OmniAlbum
//
//  Main tab bar with Albums and Settings tabs.
//

import SwiftUI

struct MainTabView: View {
    @EnvironmentObject private var networkMonitor: NetworkMonitor
    @EnvironmentObject private var deepLinkRouter: DeepLinkRouter

    var body: some View {
        ZStack(alignment: .top) {
            TabView(selection: $deepLinkRouter.selectedTab) {
                ContentView()
                    .tabItem {
                        Label("Albums", systemImage: "photo.on.rectangle.angled")
                    }
                    .tag(0)

                SettingsView()
                    .tabItem {
                        Label("Settings", systemImage: "gear")
                    }
                    .tag(1)
            }

            // Offline banner
            if !networkMonitor.isConnected {
                HStack(spacing: 8) {
                    Image(systemName: "wifi.slash")
                        .font(.caption.weight(.semibold))
                    Text("No internet connection")
                        .font(.caption.weight(.medium))
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(.red.opacity(0.9), in: Capsule())
                .padding(.top, 2)
                .transition(.move(edge: .top).combined(with: .opacity))
                .animation(.spring(response: 0.3, dampingFraction: 0.8), value: networkMonitor.isConnected)
            }
        }
    }
}

#Preview {
    MainTabView()
        .environmentObject(NetworkMonitor.shared)
        .environmentObject(DeepLinkRouter())
}
