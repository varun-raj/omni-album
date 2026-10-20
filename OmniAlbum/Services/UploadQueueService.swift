//
//  UploadQueueService.swift
//  OmniAlbum
//
//  Global singleton managing the upload queue with persistence.
//

import Foundation
import Combine
import Network
#if canImport(ActivityKit)
import ActivityKit
#endif

extension Notification.Name {
    static let uploadCompleted = Notification.Name("uploadCompleted")
}

@MainActor
final class UploadQueueService: ObservableObject {
    static let shared = UploadQueueService()

    @Published private(set) var queue: [UploadTask] = []
    @Published private(set) var activeUpload: UploadTask?
    @Published private(set) var isProcessing = false
    @Published private(set) var isWaitingForWiFi = false

    private let persistenceService = UploadQueuePersistenceService()
    private var processingTask: Task<Void, Never>?
    private let networkMonitor = NWPathMonitor()
    private let networkQueue = DispatchQueue(label: "com.skcript.omnialbum.uploadnetwork")
    private var currentNetworkPath: NWPath?

    private var wifiOnlyUpload: Bool {
        UserDefaults.standard.bool(forKey: SettingsKeys.wifiOnlyUpload)
    }

    private var isOnWiFi: Bool {
        currentNetworkPath?.usesInterfaceType(.wifi) == true
    }

    #if canImport(ActivityKit)
    @available(iOS 16.2, *)
    private var currentActivity: Activity<UploadActivityAttributes>?
    #endif

    private init() {
        // Set up network monitoring for Wi-Fi only mode
        networkMonitor.pathUpdateHandler = { [weak self] path in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.currentNetworkPath = path
                // Auto-resume if Wi-Fi becomes available
                if self.isWaitingForWiFi && (path.usesInterfaceType(.wifi) || !self.wifiOnlyUpload) {
                    self.isWaitingForWiFi = false
                    self.startProcessing()
                }
            }
        }
        networkMonitor.start(queue: networkQueue)

        // Load persisted queue on init
        Task {
            await restoreQueue()
        }
    }

    /// Restore queue from disk on app launch
    func restoreQueue() async {
        do {
            let savedTasks = try await persistenceService.load()
            // Reset any uploads that were in progress to pending
            queue = savedTasks.map { task in
                var mutableTask = task
                if task.status == .uploading {
                    mutableTask.status = .pending
                    mutableTask.progress = 0.0
                }
                return mutableTask
            }
            // Auto-resume if there are pending tasks
            if queue.contains(where: { $0.status == .pending }) {
                startProcessing()
            }
        } catch {
            print("Failed to restore upload queue: \(error)")
        }
    }

    /// Add new upload tasks to the queue
    func addTasks(_ tasks: [UploadTask]) {
        print("UploadQueue: Adding \(tasks.count) tasks")
        queue.append(contentsOf: tasks)
        persistQueue()
        print("UploadQueue: Queue now has \(queue.count) items, starting processing")
        startProcessing()
    }

    /// Start processing the queue
    func startProcessing() {
        guard !isProcessing else {
            print("UploadQueue: Already processing, skipping")
            return
        }
        guard queue.contains(where: { $0.status == .pending }) else {
            print("UploadQueue: No pending tasks to process")
            return
        }

        print("UploadQueue: Starting processing")
        isProcessing = true
        processingTask = Task {
            await processQueue()
        }
    }

    /// Suspends until the current processing run ends (queue drained, paused, or waiting for Wi-Fi).
    func waitUntilIdle() async {
        await processingTask?.value
    }

    /// Pause all uploads
    func pauseAll() {
        isProcessing = false
        processingTask?.cancel()
        processingTask = nil

        // Mark current upload as pending
        if var current = activeUpload {
            current.status = .pending
            current.progress = 0.0
            updateTask(current)
        }
        activeUpload = nil
        endActivityIfNeeded()
    }

    /// Retry all failed uploads
    func retryFailed() {
        for index in queue.indices where queue[index].status == .failed {
            queue[index].status = .pending
            queue[index].progress = 0.0
            queue[index].errorMessage = nil
        }
        persistQueue()
        startProcessing()
    }

    /// Retry a specific failed task
    func retryTask(_ task: UploadTask) {
        guard let index = queue.firstIndex(where: { $0.id == task.id }) else { return }
        queue[index].status = .pending
        queue[index].progress = 0.0
        queue[index].errorMessage = nil
        persistQueue()
        startProcessing()
    }

    /// Remove a task from the queue
    func removeTask(_ task: UploadTask) {
        queue.removeAll { $0.id == task.id }
        persistQueue()
    }

    /// Remove all completed tasks
    func clearCompleted() {
        queue.removeAll { $0.status == .completed }
        persistQueue()
    }

    /// Clear the entire queue
    func clearAll() {
        pauseAll()
        queue.removeAll()
        persistQueue()
    }

    /// Get pending uploads for a specific album
    func pendingUploads(for albumId: String) -> [UploadTask] {
        queue.filter { $0.albumId == albumId && ($0.status == .pending || $0.status == .uploading) }
    }

    /// Get all uploads for a specific album
    func uploads(for albumId: String) -> [UploadTask] {
        queue.filter { $0.albumId == albumId }
    }

    /// Count of pending/uploading tasks
    var pendingCount: Int {
        queue.filter { $0.status == .pending || $0.status == .uploading }.count
    }

    /// Count of failed tasks
    var failedCount: Int {
        queue.filter { $0.status == .failed }.count
    }

    // MARK: - Private Methods

    private func processQueue() async {
        print("UploadQueue: processQueue started")
        var isFirstUpload = true

        while !Task.isCancelled {
            // Check Wi-Fi requirement
            if wifiOnlyUpload && !isOnWiFi {
                print("UploadQueue: Wi-Fi only mode, waiting for Wi-Fi...")
                isWaitingForWiFi = true
                isProcessing = false
                endActivityIfNeeded()
                return
            }

            // Find next pending task
            guard let nextIndex = queue.firstIndex(where: { $0.status == .pending }) else {
                print("UploadQueue: No more pending tasks, stopping")
                isProcessing = false
                activeUpload = nil
                endActivityIfNeeded()
                return
            }

            // Mark as uploading
            print("UploadQueue: Uploading task at index \(nextIndex): \(queue[nextIndex].fileName)")
            queue[nextIndex].status = .uploading
            activeUpload = queue[nextIndex]
            persistQueue()

            // Start Live Activity on first upload
            if isFirstUpload {
                startActivityIfNeeded(for: queue[nextIndex])
                isFirstUpload = false
            }

            let failedTaskId = queue[nextIndex].id
            do {
                let currentTask = queue[nextIndex]
                let providerType = PhotoProvider(rawValue: currentTask.provider) ?? .immich
                guard let taskProvider = ProviderRegistry.shared.provider(for: providerType) else {
                    queue[nextIndex].status = .failed
                    queue[nextIndex].errorMessage = "Unknown provider: \(currentTask.provider)"
                    queue[nextIndex].completedAt = Date()
                    activeUpload = nil
                    persistQueue()
                    continue
                }
                let taskId = currentTask.id
                let assetId = try await taskProvider.uploadAsset(
                    task: currentTask
                ) { [weak self] progress in
                    Task { @MainActor in
                        self?.updateProgress(id: taskId, progress: progress)
                        self?.updateActivityProgress(
                            progress,
                            currentFile: currentTask.fileName,
                            albumId: currentTask.albumId
                        )
                    }
                }

                // Success. Task may have been removed while uploading; re-resolve by id.
                print("UploadQueue: Upload succeeded for \(currentTask.fileName), assetId: \(assetId)")
                if let index = queue.firstIndex(where: { $0.id == taskId }) {
                    queue[index].status = .completed
                    queue[index].progress = 1.0
                    queue[index].uploadedAssetId = assetId
                    queue[index].completedAt = Date()
                }
                let completedTask = currentTask
                activeUpload = nil
                persistQueue()

                // Notify that upload completed (for album refresh)
                NotificationCenter.default.post(
                    name: .uploadCompleted,
                    object: nil,
                    userInfo: ["albumId": completedTask.albumId]
                )

            } catch {
                // Cancelled by pauseAll: it already reset the task to pending.
                if Task.isCancelled { return }
                print("UploadQueue: Upload failed for \(failedTaskId): \(error.localizedDescription)")
                if let index = queue.firstIndex(where: { $0.id == failedTaskId }) {
                    queue[index].status = .failed
                    queue[index].errorMessage = error.localizedDescription
                    queue[index].completedAt = Date()
                }
                activeUpload = nil
                persistQueue()
            }
        }

        isProcessing = false
        endActivityIfNeeded()
    }

    private func updateProgress(id: UUID, progress: Double) {
        guard let index = queue.firstIndex(where: { $0.id == id }) else { return }
        queue[index].progress = progress
        if let active = activeUpload, active.id == queue[index].id {
            activeUpload = queue[index]
        }
    }

    private func updateTask(_ task: UploadTask) {
        if let index = queue.firstIndex(where: { $0.id == task.id }) {
            queue[index] = task
            persistQueue()
        }
    }

    private func persistQueue() {
        Task.detached { [weak self, queue = self.queue] in
            guard let self = self else { return }
            do {
                try await self.persistenceService.save(queue)
            } catch {
                print("Failed to persist upload queue: \(error)")
            }
        }
    }

    // MARK: - Live Activity Management

    #if canImport(ActivityKit)
    @available(iOS 16.2, *)
    private func startLiveActivity(for task: UploadTask) {
        let authInfo = ActivityAuthorizationInfo()
        print("Live Activity - areActivitiesEnabled: \(authInfo.areActivitiesEnabled)")
        print("Live Activity - frequentPushesEnabled: \(authInfo.frequentPushesEnabled)")

        guard authInfo.areActivitiesEnabled else {
            let appName = Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
                ?? Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String
                ?? "App"
            print("Live Activities are not enabled - check Settings > \(appName) > Live Activities")
            return
        }

        // End any existing activity first
        endLiveActivity()

        let albumTasks = queue.filter { $0.albumId == task.albumId }
        let pendingCount = albumTasks.filter { $0.status == .pending || $0.status == .uploading }.count
        let completedCount = albumTasks.filter { $0.status == .completed }.count
        let totalCount = pendingCount + completedCount

        let attributes = UploadActivityAttributes(albumId: task.albumId)
        let contentState = UploadActivityAttributes.ContentState(
            progress: 0,
            remainingCount: pendingCount,
            totalCount: totalCount,
            currentFileName: task.fileName,
            albumName: task.albumName,
            hasFailures: false,
            completedCount: completedCount
        )

        do {
            let activity = try Activity.request(
                attributes: attributes,
                content: .init(state: contentState, staleDate: nil),
                pushType: nil
            )
            currentActivity = activity
            print("Live Activity started successfully: \(activity.id)")
        } catch {
            print("Failed to start Live Activity: \(error.localizedDescription)")
            if let activityError = error as? ActivityAuthorizationError {
                print("ActivityAuthorizationError: \(activityError)")
            }
        }
    }

    @available(iOS 16.2, *)
    private func updateLiveActivity(progress: Double, currentFile: String, albumId: String) {
        guard let activity = currentActivity else { return }

        let albumTasks = queue.filter { $0.albumId == albumId }
        let pendingCount = albumTasks.filter { $0.status == .pending || $0.status == .uploading }.count
        let completedCount = albumTasks.filter { $0.status == .completed }.count
        let failedCount = albumTasks.filter { $0.status == .failed }.count
        let totalCount = albumTasks.count

        let contentState = UploadActivityAttributes.ContentState(
            progress: progress,
            remainingCount: pendingCount,
            totalCount: totalCount,
            currentFileName: currentFile,
            albumName: albumTasks.first?.albumName ?? "",
            hasFailures: failedCount > 0,
            completedCount: completedCount
        )

        Task {
            await activity.update(.init(state: contentState, staleDate: nil))
        }
    }

    @available(iOS 16.2, *)
    private func endLiveActivity() {
        guard let activity = currentActivity else { return }

        Task {
            await activity.end(nil, dismissalPolicy: .immediate)
            print("Live Activity ended: \(activity.id)")
        }
        currentActivity = nil
    }
    #endif

    /// Called when starting to process uploads
    private func startActivityIfNeeded(for task: UploadTask) {
        #if canImport(ActivityKit)
        if #available(iOS 16.2, *) {
            startLiveActivity(for: task)
        }
        #endif
    }

    /// Called when upload progress updates
    private func updateActivityProgress(_ progress: Double, currentFile: String, albumId: String) {
        #if canImport(ActivityKit)
        if #available(iOS 16.2, *) {
            updateLiveActivity(progress: progress, currentFile: currentFile, albumId: albumId)
        }
        #endif
    }

    /// Called when all uploads are done
    private func endActivityIfNeeded() {
        #if canImport(ActivityKit)
        if #available(iOS 16.2, *) {
            endLiveActivity()
        }
        #endif
    }
}
