# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

OmniAlbum is a native iOS SwiftUI app that lets users view (and, where the provider allows, upload to) shared albums from self-hosted photo servers: Immich, Nextcloud, PhotoPrism, Lychee and Ente. Users paste share links; the app fetches the album and shows it in a Photos-style grid and viewer.

## Build, Run, Test

Open `OmniAlbum.xcodeproj` in Xcode (Cmd+R). Targets: `OmniAlbum` (app), `UploadWidgetExtension` (widgets + upload Live Activity), `OmniAlbumTests` (unit tests).

```sh
# build
xcodebuild -project OmniAlbum.xcodeproj -scheme OmniAlbum -destination 'generic/platform=iOS Simulator' build
# tests (needs a simulator)
xcodebuild test -project OmniAlbum.xcodeproj -scheme OmniAlbum -destination 'platform=iOS Simulator,name=<simulator name>'
```

Swift packages (via Xcode, no manual setup): Kingfisher (image loading/caching), Sodium (Ente's libsodium crypto).

**CloudKit setup required**: create the `Album` record type in CloudKit Dashboard first, see `CLOUDKIT_SETUP.md`. Container: `iCloud.com.skcript.omnialbum`. App Group (widgets): `group.com.skcript.omnialbum`.

## Architecture

### Providers (`OmniAlbum/Providers`)
Each service implements `ShareLinkProvider` (parse link, fetch info/detail, build thumbnail/preview/original/video URLs, upload, optional client-side decryption) and is registered in `ProviderRegistry`. `PhotoProvider` (Models) is the enum identifying them.
- Immich: `ImmichProvider` + `Services/ImmichShareService`, `ImmichShareLink`, `ImmichUploadService`
- Nextcloud, PhotoPrism, Lychee: `*Provider` + `*Service`
- Ente: `EnteProvider/Service/Crypto`: media is decrypted on device (`requiresClientDecryption`)
- PhotoPrism has no upload. Providers' share keys can be composite (`a|b|c`), see `ShareLinkBuilder`.

### Server URLs
`ServerBaseURL` is the only place that turns a URL into a base (`scheme://host[:port][/prefix]`). It keeps a path prefix so servers hosted under e.g. `/immich` work. Build API URLs by appending to the base path (`comp.path += "/api/..."`), never by replacing it.

### Data flow and storage
1. Link is parsed by the provider, `fetchSharedLinkInfo` validates it, `AggregatorViewModel.addAlbum` stores a `DisplayAlbum`.
2. **Local-first**: `LocalAlbumsService` (`Documents/albums.json`, `StoredAlbum`) loads instantly; `CloudKitAlbumsService` syncs when the iCloud Sync setting is on. Merge keeps local-only albums and pushes them up (no tombstones: a delete on another device can resurface until deleted again).
3. **Passwords live in the Keychain** (`PasswordStore`, keyed per share link, synced via iCloud Keychain when sync is on). They are never written to albums.json, the upload queue file or CloudKit; `StoredAlbum`/`UploadTask` omit them on encode and re-read them on decode.
4. `AlbumDetailViewModel` loads one album's assets and publishes `albumDataUpdated` (keyed by link id) so the list updates counts/covers.
5. Widgets read `SharedAlbumData` from the App Group (album entries and "On This Day" asset pools).

### UI (`OmniAlbum/Views`)
- `ContentView`: albums grid/list. Cards are rounded, shadowless, with name/count/badges overlaid. Long-press: copy/share link, delete (confirmation).
- `AlbumDetailView` + `AlbumPhotoGrid`: native SwiftUI grid of square tiles; each tile is a `matchedTransitionSource`.
- `AssetLightboxView`: viewer opened with the system zoom transition (`.navigationTransition(.zoom)`), paged `TabView` (only pages within 2 of the current are built), film strip, tap cycles light+chrome / black+no chrome, swipe up for `AssetDetailsSheet`. Photos use `ZoomablePhotoView`, videos `VideoPlayerView`.
- `AddAlbumSheet` (single + bulk), `SettingsView` (+ `CacheSettingsView`, `UploadQueueView`), `PhotoPickerView` (choose photos to upload).
- Loading states use `Shimmer` skeletons (`SkeletonPhotoGrid`, `SkeletonAlbumGrid`).
- `CachedAsyncImage` (Kingfisher) downsamples to `maxPixel` (default 512).

### Uploads
`UploadQueueService` (singleton, persisted via `UploadQueuePersistenceService`) tracks tasks **by id, never by index**. Assets are exported to disk with `AssetFileExporter` (no whole-file `Data`); Immich builds its multipart body on disk. A `BGProcessingTask` resumes the queue and completes when it drains. Live Activity via `UploadActivityAttributes`.

### Shared helpers
`AssetActions` (share / save to Photos), `ShareHelper`, `Formatters` (reuse date formatters), `AlbumCSV` (backup import/export), `Log` (os.Logger: `Log.app/sync/upload`; don't use `print`).

## Conventions
- ViewModels are `@MainActor` `ObservableObject`s with `@Published`; views use `@StateObject` for owned ones, `@ObservedObject` for passed ones.
- Use `foregroundStyle()` not `foregroundColor()`, `clipShape(.rect(cornerRadius:))` not `cornerRadius()`, `.task {}` for async work tied to a view, `NavigationStack` with `navigationDestination(for:)`.
- No shadows on cards/badges; rounded corners (20 pt on album cards).
- Plain, testable logic goes in `Services/` with tests in `OmniAlbumTests/` (`ServerBaseURL`, `AlbumCSV`, `LocalAlbumsService`, ...). `LocalAlbumsService(fileURL:)` is injectable for tests.
- App Transport Security allows only local networking (`NSAllowsLocalNetworking`); `http://` to a public hostname will not load.

See `.cursor/skills/swiftui-expert-skill/SKILL.md` for broader SwiftUI guidance.
