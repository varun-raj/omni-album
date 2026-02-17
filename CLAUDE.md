# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

OmniAlbum is a native iOS/macOS SwiftUI app that lets users view shared albums from multiple self-hosted photo servers (Immich, Nextcloud, PhotoPrism, Lychee, Ente). Users paste share links, and the app fetches and displays albums with their photos in a Photos-like interface.

## Build & Run

This is an Xcode project. Open `OmniAlbum.xcodeproj` in Xcode and build/run from there (Cmd+R). There are no external dependencies or package managers.

**CloudKit Setup Required**: Before the app can save/fetch albums, you must create the `Album` record type in CloudKit Dashboard. See `CLOUDKIT_SETUP.md` for the schema and instructions.

## Architecture

### Data Flow
1. **Share Link Parsing** (`ImmichShareLink.swift`) - Extracts base URL and key/token from Immich share URLs
2. **API Layer** (`ImmichShareService.swift`) - Fetches shared link metadata and album assets from Immich API
3. **Persistence** (`CloudKitAlbumsService.swift`) - Stores added albums in CloudKit private database for sync across devices
4. **View Models** - `AggregatorViewModel` manages album list; `AlbumDetailViewModel` manages assets for a single album

### Key Components
- `ContentView` - Album grid (2-column, Photos-style)
- `AlbumDetailView` - Asset grid (3-column) with lightbox
- `AssetLightboxView` - Full-screen gallery with zoom, swipe, share, save to Photos, and EXIF details sheet
- `LazyLoadingImage` / `CachedAsyncImage` - In-memory image cache (~150MB, 200 items) with deduped in-flight requests

### API Models (`ImmichModels.swift`)
- `SharedLinkResponse` - From `GET /api/shared-links/me?key=...`
- `AlbumWithAssetsResponse` - From `GET /api/albums/{id}?key=...`
- `ImmichAsset` - Individual photo/video with full EXIF metadata

### CloudKit Schema
Container: `iCloud.com.skcript.omnialbum`
Record type: `Album` with fields: `id`, `albumName`, `albumThumbnailAssetId`, `baseURL`, `shareKey`, `albumId`, `assetCount`, `createdAt`

## SwiftUI Patterns

The project follows modern SwiftUI conventions. Key patterns:

- ViewModels are `@MainActor` classes using `ObservableObject` with `@Published` properties
- Views use `@StateObject` for owned ViewModels, `@ObservedObject` for passed ones
- Use `foregroundStyle()` not `foregroundColor()`, `clipShape(.rect(cornerRadius:))` not `cornerRadius()`
- Use `.task { }` for async work tied to view lifecycle
- Use `NavigationStack` with `navigationDestination(for:)` for type-safe navigation

See `.cursor/skills/swiftui-expert-skill/SKILL.md` for comprehensive SwiftUI best practices reference.
