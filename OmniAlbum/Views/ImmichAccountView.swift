//
//  ImmichAccountView.swift
//  OmniAlbum
//
//  Beta: sign in to an Immich account, sync it to the device, browse the cached timeline.
//

import SwiftUI

struct ImmichAccountView: View {
    @StateObject private var viewModel = ImmichAccountViewModel()

    var body: some View {
        Group {
            if viewModel.credentials == nil {
                SignInForm(viewModel: viewModel)
            } else {
                AccountTimeline(viewModel: viewModel)
            }
        }
        .navigationTitle("Immich Account")
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - Sign in

private struct SignInForm: View {
    @ObservedObject var viewModel: ImmichAccountViewModel
    @State private var server = ""
    @State private var email = ""
    @State private var password = ""

    private var canSignIn: Bool { !server.isEmpty && !email.isEmpty && !password.isEmpty && !viewModel.isSigningIn }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text("Sign in to browse your whole library, not just shared links. It's copied to this device once, then only changes sync.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                field("Server", symbol: "server.rack") {
                    TextField("https://photos.example.com", text: $server)
                        .textContentType(.URL).keyboardType(.URL)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                }
                field("Email", symbol: "envelope") {
                    TextField("you@example.com", text: $email)
                        .textContentType(.username).keyboardType(.emailAddress)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                }
                field("Password", symbol: "lock") {
                    SecureField("Password", text: $password).textContentType(.password)
                }

                Text("Syncing needs a normal sign-in. Immich doesn't allow API keys to sync.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)

                if let error = viewModel.errorMessage {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.footnote)
                        .foregroundStyle(.red)
                        .padding(14)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.red.opacity(0.1), in: .rect(cornerRadius: 16))
                }
            }
            .padding(20)
        }
        .safeAreaInset(edge: .bottom) {
            Button {
                Task { await viewModel.signIn(server: server, email: email, password: password) }
            } label: {
                HStack(spacing: 8) {
                    if viewModel.isSigningIn { ProgressView().tint(.white) }
                    Text(viewModel.isSigningIn ? "Signing in…" : "Sign In").font(.body.weight(.semibold))
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
            }
            .buttonStyle(.borderedProminent)
            .buttonBorderShape(.capsule)
            .controlSize(.large)
            .disabled(!canSignIn)
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            .background(.bar)
        }
    }

    private func field<Content: View>(_ title: String, symbol: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.footnote.weight(.semibold)).foregroundStyle(.secondary).padding(.horizontal, 4)
            HStack(spacing: 10) {
                Image(systemName: symbol).foregroundStyle(.secondary)
                content()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .background(Color(.secondarySystemBackground), in: .rect(cornerRadius: 20))
        }
    }
}

// MARK: - Timeline

private struct AccountTimeline: View {
    @ObservedObject var viewModel: ImmichAccountViewModel
    @State private var confirmSignOut = false
    @State private var confirmReset = false

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 2), count: 3)

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 0, pinnedViews: [.sectionHeaders]) {
                statusCard
                    .padding(16)

                ForEach(viewModel.months, id: \.month) { bucket in
                    Section {
                        MonthGrid(viewModel: viewModel, month: bucket.month, count: bucket.count, columns: columns)
                    } header: {
                        Text(monthTitle(bucket.month))
                            .font(.headline)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 8)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(.bar)
                    }
                }
            }
        }
        .refreshable { await viewModel.sync() }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button("Sync Now", systemImage: "arrow.triangle.2.circlepath") { Task { await viewModel.sync() } }
                    Button("Download Everything Again", systemImage: "arrow.counterclockwise") { confirmReset = true }
                    Divider()
                    Button("Sign Out", systemImage: "rectangle.portrait.and.arrow.right", role: .destructive) { confirmSignOut = true }
                } label: {
                    Image(systemName: "ellipsis")
                }
            }
        }
        .confirmationDialog("Sign out?", isPresented: $confirmSignOut, titleVisibility: .visible) {
            Button("Sign Out", role: .destructive) { viewModel.signOut() }
        } message: {
            Text("The copy of your library on this device is deleted. Your photos on the server aren't touched.")
        }
        .confirmationDialog("Download everything again?", isPresented: $confirmReset, titleVisibility: .visible) {
            Button("Download Again", role: .destructive) { Task { await viewModel.resetLocalData() } }
        }
    }

    private var statusCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(viewModel.credentials?.email ?? "").font(.subheadline.weight(.semibold))
                    Text(viewModel.credentials.flatMap { URL(string: $0.server)?.host } ?? "")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if viewModel.isSyncing { ProgressView() }
            }

            if viewModel.isSyncing {
                Text("\(viewModel.progress.phase) \(viewModel.progress.linesRead) changes")
                    .font(.footnote).foregroundStyle(.secondary)
            } else if let counts = viewModel.counts {
                Text("\(counts.assets) photos & videos · \(counts.albums) album\(counts.albums == 1 ? "" : "s")")
                    .font(.footnote).foregroundStyle(.secondary)
                if let last = viewModel.lastSyncText {
                    let took = viewModel.lastSummary.map { String(format: " in %.1f s", $0.duration) + ($0.applied == 0 ? ", nothing new" : ", \($0.applied) changes") } ?? ""
                    Text("Synced \(last)\(took)").font(.caption).foregroundStyle(.tertiary)
                }
            }

            if let error = viewModel.errorMessage {
                Label(error, systemImage: "exclamationmark.triangle.fill").font(.footnote).foregroundStyle(.red)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemBackground), in: .rect(cornerRadius: 20))
    }

    private func monthTitle(_ month: String) -> String {
        let parts = month.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 2, let date = Calendar.current.date(from: DateComponents(year: parts[0], month: parts[1])) else { return month }
        return Formatters.monthTitle.string(from: date)
    }
}

/// One month's tiles, read from the local database only when the month scrolls into view.
private struct MonthGrid: View {
    @ObservedObject var viewModel: ImmichAccountViewModel
    let month: String
    let count: Int
    let columns: [GridItem]
    @State private var assets: [LibraryAsset] = []

    var body: some View {
        LazyVGrid(columns: columns, spacing: 2) {
            ForEach(assets) { asset in
                Color.clear
                    .aspectRatio(1, contentMode: .fit)
                    .overlay { CachedAsyncImage(url: viewModel.thumbnailURL(asset.id)) }
                    .clipped()
                    .overlay(alignment: .bottomTrailing) {
                        if asset.isVideo {
                            Image(systemName: "play.fill")
                                .font(.system(size: 9, weight: .bold))
                                .foregroundStyle(.white)
                                .padding(6)
                        }
                    }
            }
        }
        // Reserve the right height before the rows load, so scrolling doesn't jump.
        .frame(minHeight: assets.isEmpty ? CGFloat((count + 2) / 3) * 130 : nil, alignment: .top)
        .task(id: viewModel.dataVersion) { assets = await viewModel.assets(inMonth: month) }
    }
}
