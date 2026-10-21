//
//  UploadTabView.swift
//  OmniAlbum
//
//  The Upload tab: pick where photos go (an Immich account's library or album, or a shared link that
//  allows uploads), pick photos, watch the queue.
//

import SwiftUI

struct UploadTabView: View {
    @ObservedObject private var uploadService = UploadQueueService.shared
    @ObservedObject private var hub = ImmichHub.shared
    @AppStorage("uploadTargetID") private var storedTargetID = ""

    @State private var shareLinkAlbums: [DisplayAlbum] = []
    @State private var showingPicker = false
    @State private var selectedAssets: [SelectedAsset] = []
    @State private var isLoadingPhotos = false
    @State private var loadingProgress = 0
    @State private var loadingTotal = 0
    @State private var justAdded = 0

    private var targets: [UploadTarget] {
        UploadTarget.build(accounts: hub.accounts, albums: hub.albums, shareLinkAlbums: shareLinkAlbums)
    }

    /// The remembered target, else the first one available.
    private var selected: UploadTarget? {
        let all = targets
        return all.first { $0.id == storedTargetID } ?? all.first
    }

    var body: some View {
        NavigationStack {
            List {
                if let selected {
                    Section {
                        NavigationLink {
                            UploadTargetPicker(targets: targets, selectedID: selected.id) { storedTargetID = $0 }
                        } label: {
                            targetRow(selected)
                        }
                    } header: {
                        Text("Upload to")
                    }

                    Section {
                        Button {
                            showingPicker = true
                        } label: {
                            HStack {
                                Spacer()
                                if isLoadingPhotos {
                                    ProgressView()
                                    Text(loadingTotal > 0 ? "Preparing \(loadingProgress) of \(loadingTotal)…" : "Preparing…")
                                } else {
                                    Label("Choose Photos", systemImage: "photo.badge.plus")
                                }
                                Spacer()
                            }
                            .font(.body.weight(.semibold))
                        }
                        .disabled(isLoadingPhotos)
                    } footer: {
                        if justAdded > 0 {
                            Text("Added \(justAdded) photo\(justAdded == 1 ? "" : "s") to the queue.")
                        }
                    }

                    queueSections
                } else {
                    Section {
                        ContentUnavailableView {
                            Label("Nowhere to Upload", systemImage: "icloud.and.arrow.up")
                        } description: {
                            Text("Sign in to Immich in Settings, or add a shared link that allows uploads.")
                        }
                        .listRowBackground(Color.clear)
                    }
                }
            }
            .navigationTitle("Upload")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    if !uploadService.queue.isEmpty { UploadQueueMenu(uploadService: uploadService) }
                }
            }
            .sheet(isPresented: $showingPicker) {
                PHPickerRepresentable(
                    selectedAssets: $selectedAssets,
                    isLoading: $isLoadingPhotos,
                    loadingProgress: $loadingProgress,
                    loadingTotal: $loadingTotal
                )
            }
            .onChange(of: isLoadingPhotos) { old, new in
                // Queue the picked photos once they've been prepared.
                if old && !new && !selectedAssets.isEmpty { queueSelected() }
            }
            .task { shareLinkAlbums = LocalAlbumsService().loadAlbums() }
            .onAppear { shareLinkAlbums = LocalAlbumsService().loadAlbums() }
        }
    }

    @ViewBuilder
    private var queueSections: some View {
        if uploadService.queue.isEmpty {
            Section {
                Text("Photos you upload will appear here with their progress.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .listRowBackground(Color.clear)
            }
        } else {
            UploadQueueSections(uploadService: uploadService)
        }
    }

    private func targetRow(_ target: UploadTarget) -> some View {
        HStack(spacing: 12) {
            ProviderBadge(provider: target.provider, size: 34)
            VStack(alignment: .leading, spacing: 2) {
                Text(target.title).font(.body.weight(.semibold))
                Text(target.group == "Shared links" ? target.subtitle : "\(target.group)")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
        }
    }

    private func queueSelected() {
        guard let destination = selected?.destination, !selectedAssets.isEmpty else { return }
        let tasks = selectedAssets.map(destination.makeTask)
        UploadQueueService.shared.addTasks(tasks)
        justAdded = tasks.count
        selectedAssets.removeAll()
    }
}

// MARK: - Destination picker

private struct UploadTargetPicker: View {
    let targets: [UploadTarget]
    let selectedID: String
    let onSelect: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var search = ""

    private var groups: [(name: String, items: [UploadTarget])] {
        let visible = search.isEmpty ? targets : targets.filter { $0.title.localizedCaseInsensitiveContains(search) }
        var order: [String] = []
        for t in visible where !order.contains(t.group) { order.append(t.group) }
        return order.map { name in (name, visible.filter { $0.group == name }) }
    }

    var body: some View {
        List {
            ForEach(groups, id: \.name) { group in
                Section(group.name) {
                    ForEach(group.items) { target in
                        Button {
                            onSelect(target.id)
                            dismiss()
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: icon(for: target.kind))
                                    .foregroundStyle(.secondary)
                                    .frame(width: 24)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(target.title).foregroundStyle(.primary)
                                    Text(target.subtitle).font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                if target.id == selectedID { Image(systemName: "checkmark").foregroundStyle(Color.accentColor) }
                            }
                        }
                    }
                }
            }
        }
        .searchable(text: $search, prompt: "Search albums")
        .navigationTitle("Upload to")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func icon(for kind: UploadTarget.Kind) -> String {
        switch kind {
        case .immichLibrary: return "photo.stack"
        case .immichAlbum: return "rectangle.stack"
        case .shareLink: return "link"
        }
    }
}
