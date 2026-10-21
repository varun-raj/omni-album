//
//  AssetDetailsSheet.swift
//  OmniAlbum
//
//  Details panel (date, camera, location) for a photo or video.
//

import SwiftUI
import MapKit

/// Loads EXIF the source keeps outside the asset (account libraries) before showing the panel.
struct AssetDetailsContainer: View {
    let asset: Asset
    let source: any AssetSource
    @State private var resolved: Asset?

    var body: some View {
        AssetDetailsSheet(asset: resolved ?? asset)
            .task {
                if asset.exif == nil, let exif = await source.exif(for: asset) { resolved = asset.withExif(exif) }
            }
    }
}

// MARK: - Asset Details Sheet (clean info panel)
struct AssetDetailsSheet: View {
    let asset: Asset

    @Environment(\.dismiss) private var dismiss

    private var dateTimeFormatted: String? {
        let s = asset.createdAt ?? ""
        guard !s.isEmpty else { return nil }
        guard let date = Formatters.parseISO(s) else { return s }
        return "\(Formatters.dayLong.string(from: date)) at \(Formatters.time.string(from: date))"
    }

    private var formatPill: String {
        let mime = asset.providerData?["originalMimeType"] ?? (asset.type == .video ? "video" : "image")
        if mime.uppercased().contains("HEIF") || mime.uppercased().contains("HEIC") { return "HEIF" }
        if mime.uppercased().contains("JPEG") || mime.uppercased().contains("JPG") { return "JPEG" }
        if mime.uppercased().contains("PNG") { return "PNG" }
        if mime.uppercased().contains("VIDEO") { return "VIDEO" }
        return mime.split(separator: "/").last.map(String.init)?.uppercased() ?? "FILE"
    }

    private var deviceLine: String? {
        guard let exif = asset.exif else { return nil }
        let make = exif.make ?? ""
        let model = exif.model ?? ""
        if make.isEmpty && model.isEmpty { return nil }
        if make.isEmpty { return model }
        if model.isEmpty { return make }
        // Avoid duplication like "Apple iPhone 15 Pro"
        if model.lowercased().contains(make.lowercased()) { return model }
        return "\(make) \(model)"
    }

    private var cameraSettingsLine: String? {
        guard let exif = asset.exif else { return nil }
        var parts: [String] = []
        if let focal = exif.focalLength { parts.append(String(format: "%.0fmm", focal)) }
        if let f = exif.fNumber { parts.append(String(format: "ƒ/%.1f", f)) }
        if let exp = exif.exposureTime, !exp.isEmpty { parts.append(exp + "s") }
        if let iso = exif.iso { parts.append("ISO \(iso)") }
        return parts.isEmpty ? nil : parts.joined(separator: "  ")
    }

    private var dimensionsLine: String? {
        let w = asset.exif?.width ?? asset.width
        let h = asset.exif?.height ?? asset.height
        guard let w, let h else { return nil }
        let mp = Double(w * h) / 1_000_000
        return String(format: "%.1f MP • %d × %d", mp, w, h)
    }

    private var fileSizeLine: String? {
        guard let size = asset.exif?.fileSizeInBytes else { return nil }
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: size)
    }

    private var locationText: String? {
        guard let exif = asset.exif else { return nil }
        var parts: [String] = []
        if let city = exif.city, !city.isEmpty { parts.append(city) }
        if let state = exif.state, !state.isEmpty { parts.append(state) }
        if let country = exif.country, !country.isEmpty { parts.append(country) }
        return parts.isEmpty ? nil : parts.joined(separator: ", ")
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    // Date & Time
                    if let dt = dateTimeFormatted {
                        VStack(alignment: .leading, spacing: 4) {
                            Label("Date & Time", systemImage: "calendar")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text(dt)
                                .font(.subheadline)
                        }
                    }

                    // File Info
                    VStack(alignment: .leading, spacing: 4) {
                        Label("File", systemImage: "doc")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(asset.originalFileName)
                            .font(.subheadline)
                        HStack(spacing: 8) {
                            Text(formatPill)
                                .font(.caption2.weight(.medium))
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(.secondary.opacity(0.2))
                                .clipShape(.capsule)
                            if let size = fileSizeLine {
                                Text(size)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }

                    // Device & Camera
                    if let device = deviceLine {
                        VStack(alignment: .leading, spacing: 4) {
                            Label("Camera", systemImage: "camera")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text(device)
                                .font(.subheadline)
                            if let settings = cameraSettingsLine {
                                Text(settings)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .monospacedDigit()
                            }
                        }
                    }

                    // Dimensions
                    if let dims = dimensionsLine {
                        VStack(alignment: .leading, spacing: 4) {
                            Label("Dimensions", systemImage: "aspectratio")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text(dims)
                                .font(.subheadline)
                        }
                    }

                    // Location
                    if let exif = asset.exif, let lat = exif.latitude, let lon = exif.longitude {
                        VStack(alignment: .leading, spacing: 8) {
                            Label("Location", systemImage: "location")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            if let loc = locationText {
                                Text(loc)
                                    .font(.subheadline)
                            }
                            MapDetailView(latitude: lat, longitude: lon)
                                .frame(height: 180)
                                .clipShape(.rect(cornerRadius: 12))
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 20)
                .padding(.vertical, 16)
            }
            .navigationTitle("Info")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
            .toolbarBackground(.visible, for: .navigationBar)
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }
}

// MARK: - Map for location (EXIF lat/lon)
struct MapDetailView: View {
    let latitude: Double
    let longitude: Double

    var body: some View {
        Map(initialPosition: .region(MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: latitude, longitude: longitude),
            span: MKCoordinateSpan(latitudeDelta: 0.01, longitudeDelta: 0.01)
        ))) {
            Annotation("", coordinate: CLLocationCoordinate2D(latitude: latitude, longitude: longitude)) {
                Image(systemName: "moon.fill")
                    .font(.caption)
                    .foregroundStyle(.primary)
            }
        }
        .mapStyle(.standard)
    }
}
