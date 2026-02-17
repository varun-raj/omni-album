//
//  OmniAlbumApp.swift
//  OmniAlbum
//
//  Created by Varun on 04/02/26.
//

import SwiftUI
import CoreSpotlight
import BackgroundTasks

@main
struct OmniAlbumApp: App {
    @StateObject private var networkMonitor = NetworkMonitor.shared
    @State private var spotlightAlbumId: String?
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
                if uploadService.pendingCount > 0 {
                    uploadService.startProcessing()
                }
                // Complete the task after a reasonable time
                processingTask.expirationHandler = {
                    uploadService.pauseAll()
                }
                // Mark task complete when uploads finish or after timeout
                Task {
                    try? await Task.sleep(for: .seconds(25))
                    processingTask.setTaskCompleted(success: true)
                }
            }
        }
    }

    var body: some Scene {
        WindowGroup {
            MainTabView()
                .environmentObject(networkMonitor)
                .onContinueUserActivity(CSSearchableItemActionType) { activity in
                    if let albumId = activity.userInfo?[CSSearchableItemActivityIdentifier] as? String {
                        spotlightAlbumId = albumId
                    }
                }
                .onChange(of: scenePhase) { _, newPhase in
                    if newPhase == .background {
                        scheduleBackgroundUploadIfNeeded()
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
            print("Background upload task scheduled")
        } catch {
            print("Failed to schedule background upload: \(error.localizedDescription)")
        }
    }
}
