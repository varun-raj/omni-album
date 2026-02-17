<p align="center">
  <img src="OmniAlbum/Resources/Assets.xcassets/AppIcon.appiconset/AppIcon.png" width="128" height="128" alt="OmniAlbum icon" style="border-radius: 22%;">
</p>

<h1 align="center">OmniAlbum</h1>

<p align="center">
  A native iOS app for browsing shared photo albums from multiple self-hosted photo services — all in one place.
</p>

<p align="center">
  <img src="https://img.shields.io/badge/platform-iOS_26-blue" alt="iOS 26+">
  <img src="https://img.shields.io/badge/swift-5-orange" alt="Swift 5">
  <img src="https://img.shields.io/badge/license-MIT-green" alt="MIT License">
</p>

---

## Supported Providers

| Provider | Status | Features |
|----------|--------|----------|
| **Immich** | Full support | Browse, upload, EXIF, password-protected links |
| **Nextcloud** | Full support | Browse shared photo albums |
| **PhotoPrism** | Full support | Browse shared albums |
| **Ente** | Full support | Browse with client-side decryption |
| **Lychee** | Full support | Browse public galleries |

## Features

- **Multi-provider** — Add share links from any supported service and view them side by side
- **Photos-like UI** — Grid and list views, full-screen lightbox with pinch-to-zoom, swipe navigation, and thumbnail scrubber
- **Upload support** — Upload photos from your library to Immich albums (with background upload and Live Activity progress)
- **iCloud sync** — Album list syncs across your devices via CloudKit
- **Spotlight search** — Albums are indexed for system-wide search
- **EXIF details** — View camera, lens, location, and map for each photo
- **Offline banner** — Network connectivity monitoring with visual indicator
- **Home screen widget** — Recent albums widget with provider-specific thumbnails
- **Export/Import** — CSV backup of your album list

## Requirements

- iOS 26.1+ / Xcode 26.1+
- An Apple Developer account (for CloudKit and code signing)

## Getting Started

1. **Clone the repository**
   ```bash
   git clone https://github.com/user/omnialbum.git
   cd omnialbum
   ```

2. **Open in Xcode**
   ```bash
   open OmniAlbum.xcodeproj
   ```

3. **Set up CloudKit** — See [CLOUDKIT_SETUP.md](CLOUDKIT_SETUP.md) for the required schema

4. **Build & Run** — Select a simulator or device and press Cmd+R

Dependencies (Kingfisher for image caching, swift-sodium for Ente decryption) are managed via Swift Package Manager and resolve automatically on first build.

## Architecture

```
OmniAlbum/
├── App/                  # App entry point, tab bar
├── Models/               # Data types (Asset, AlbumDetail, PhotoProvider, etc.)
├── Views/                # SwiftUI views (albums grid, lightbox, settings)
├── ViewModels/           # ObservableObject view models
├── Services/             # CloudKit, Spotlight, upload queue, networking
├── Providers/            # Provider abstraction layer
│   ├── ShareLinkProvider.swift   # Protocol
│   ├── ProviderRegistry.swift    # Provider lookup
│   ├── Immich/
│   ├── Nextcloud/
│   ├── PhotoPrism/
│   ├── Ente/
│   └── Lychee/
└── Resources/            # Assets, Info.plist, entitlements
```

**Key patterns:**
- `ShareLinkProvider` protocol abstracts each photo service — add a new provider by conforming to this protocol and registering it in `ProviderRegistry`
- Views use generic `Asset` / `AlbumDetail` types, not provider-specific models
- Local-first persistence with JSON, synced to CloudKit
- `@MainActor` isolation throughout (compiler flag enabled)

## License

MIT
