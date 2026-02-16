//
//  MainTabView.swift
//  immich-share
//
//  Main tab bar with Albums and Settings tabs.
//

import SwiftUI

struct MainTabView: View {
    @State private var selectedTab = 0

    var body: some View {
        TabView(selection: $selectedTab) {
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
    }
}

#Preview {
    MainTabView()
}
