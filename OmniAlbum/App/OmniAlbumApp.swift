//
//  OmniAlbumApp.swift
//  OmniAlbum
//
//  Created by Varun on 04/02/26.
//

import os
import SwiftUI
import CoreSpotlight
import BackgroundTasks

@main
struct OmniAlbumApp: App {
    @StateObject private var networkMonitor = NetworkMonitor.shared
    @StateObject private var deepLinkRouter = DeepLinkRouter()
    @State private var showSplash = true
    @State private var mainContentScale: CGFloat = 0.92
    @State private var mainContentOpacity: Double = 0
    @Environment(\.scenePhase) private var scenePhase

    init() {
        // Register default settings
        UserDefaults.standard.register(defaults: [
            SettingsKeys.iCloudSyncEnabled: true,
            SettingsKeys.wifiOnlyUpload: false
        ])

        // Configure Kingfisher image cache
        ImageCacheConfig.configure()

        // Register background task
        BGTaskScheduler.shared.register(
            forTaskWithIdentifier: "com.skcript.omnialbum.upload",
            using: nil
        ) { task in
            guard let processingTask = task as? BGProcessingTask else { return }
            Task { @MainActor in
                let uploadService = UploadQueueService.shared
                var expired = false
                processingTask.expirationHandler = {
                    Task { @MainActor in
                        expired = true
                        uploadService.pauseAll()
                    }
                }
                if uploadService.pendingCount > 0 {
                    uploadService.startProcessing()
                }
                await uploadService.waitUntilIdle()
                processingTask.setTaskCompleted(success: !expired)
            }
        }
    }

    var body: some Scene {
        WindowGroup {
            ZStack {
                MainTabView()
                    .environmentObject(networkMonitor)
                    .environmentObject(deepLinkRouter)
                    .onOpenURL { url in
                        deepLinkRouter.handle(url: url)
                    }
                    .onContinueUserActivity(CSSearchableItemActionType) { activity in
                        if let albumId = activity.userInfo?[CSSearchableItemActivityIdentifier] as? String {
                            deepLinkRouter.handle(url: URL(string: "omnialbum://photo?albumId=\(albumId)")!)
                        }
                    }
                    .onChange(of: scenePhase) { _, newPhase in
                        if newPhase == .background {
                            scheduleBackgroundUploadIfNeeded()
                        }
                    }
                    .scaleEffect(mainContentScale)
                    .opacity(mainContentOpacity)

                if showSplash {
                    SplashScreenView()
                        .transition(
                            .asymmetric(
                                insertion: .identity,
                                removal: .move(edge: .top)
                                    .combined(with: .opacity)
                            )
                        )
                        .zIndex(1)
                }
            }
            .task {
                try? await Task.sleep(for: .seconds(1.8))
                withAnimation(.spring(response: 0.6, dampingFraction: 0.85)) {
                    showSplash = false
                    mainContentScale = 1.0
                    mainContentOpacity = 1.0
                }
            }
        }
    }

    private func scheduleBackgroundUploadIfNeeded() {
        let uploadService = UploadQueueService.shared
        guard uploadService.pendingCount > 0 else { return }

        let request = BGProcessingTaskRequest(identifier: "com.skcript.omnialbum.upload")
        request.requiresNetworkConnectivity = true
        request.requiresExternalPower = false

        do {
            try BGTaskScheduler.shared.submit(request)
            Log.app.notice("Background upload task scheduled")
        } catch {
            Log.app.error("Failed to schedule background upload: \(error.localizedDescription)")
        }
    }
}
