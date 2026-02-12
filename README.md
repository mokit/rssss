# rssss

A native macOS RSS reader built with SwiftUI + Core Data.

## Requirements

- macOS 14+
- Xcode 17+ (includes Swift 6.2 toolchain used by `Package.swift`)

## Quick Start

1. Open the project in Xcode:
   - `open /Users/hans/Documents/programming/swift/rssss/rssss.xcodeproj`
2. Select scheme `rssss`.
3. Run (`Cmd+R`).

### Command-line Test Run

From the repo root:

```bash
xcodebuild -scheme rssss -destination 'platform=macOS' test
```

This is the most reliable command here; `swift test` can fail in restricted environments because SwiftPM writes outside the workspace cache.

## Project Layout

- `Package.swift`: SwiftPM package definition (app target + tests + FeedKit dependency).
- `project.yml`: XcodeGen spec for generating `rssss.xcodeproj`.
- `rssss.xcodeproj`: checked-in Xcode project.
- `rssss/Info.plist`: app metadata.
- `Sources/rssss/`: application source code.
- `Tests/rssssTests/`: unit tests.

## Architecture Overview

### App entry and dependency wiring

- `Sources/rssss/rssss.swift`
  - App entry point (`@main`).
  - Creates and injects:
    - `PersistenceController` (Core Data stack)
    - `FeedStore` (network + parsing + persistence mutations)
    - `RefreshSettingsStore` (UserDefaults-backed settings)
    - `AutoRefreshController` (foreground timer + background scheduler)

### Data layer

- `Sources/rssss/Models.swift`
  - Programmatic Core Data model (no `.xcdatamodeld`).
  - Entities:
    - `Feed`: URL, title, favicon URL, last refresh timestamp, ordering index.
    - `FeedItem`: guid/link/title/summary/pubDate/read state/createdAt.
  - Uniqueness: `Feed.url` is constrained unique.

- `Sources/rssss/Persistence.swift`
  - Builds `NSPersistentContainer` using the programmatic model.
  - Enables automatic lightweight migration.
  - Exposes `markItemsRead(objectIDs:)` for batched background updates.

### Feed ingestion and refresh

- `Sources/rssss/FeedStore.swift`
  - Adds/deletes feeds.
  - Enforces HTTPS-only feed URLs.
  - Fetches feed XML/JSON with retry/backoff for transient URL errors.
  - Parses RSS/Atom/JSON feed formats via `FeedKit`.
  - Deduplicates new items (`Deduper`) and writes updates in a background context.
  - Supports `markAllRead` through `NSBatchUpdateRequest`.

### Scheduling and settings

- `Sources/rssss/AutoRefreshController.swift`
  - Foreground refresh: `Timer`.
  - Background refresh: `NSBackgroundActivityScheduler`.
  - Both use the same interval from settings.

- `Sources/rssss/RefreshSettings.swift`
  - User defaults keys:
    - `refreshIntervalMinutes` (clamped 1...60, default 5)
    - `showLastRefresh` (default true)

### UI layer

- `Sources/rssss/Views/ContentView.swift`
  - Main split layout: sidebar + detail pane.
  - Handles feed selection, add/delete actions, refresh, and mark-all-read.

- `Sources/rssss/FetchedControllers.swift`
  - `NSFetchedResultsController` wrappers that publish:
    - feed list
    - per-feed unread counts
    - items for selected feed

- `Sources/rssss/Views/FeedItemsView.swift`
  - Item list rendering.
  - Keyboard navigation (`j/k`, arrow keys, `o` to open in in-app preview).
  - Read-tracking integration as items scroll past.

- `Sources/rssss/Views/WebPreviewPaneView.swift`
  - Embedded webpage preview pane (`WKWebView`) for item links.
  - Includes explicit `Open in Browser` action in the preview header.

- `Sources/rssss/ReadTracking.swift`
  - Determines which item rows are past viewport top.
  - Batches delayed mark-read updates.

## Dependencies

- [FeedKit](https://github.com/nmdias/FeedKit) (declared in `Package.swift` and `project.yml`)

## Re-generating Xcode Project (Optional)

If you use XcodeGen, regenerate the project from `project.yml`:

```bash
xcodegen generate
```

Then reopen `rssss.xcodeproj`.

## Notes for Contributors

- Tests are in `Tests/rssssTests/rssssTests.swift` and cover data model behavior, refresh/settings logic, and view logic helpers.
- The Core Data schema is code-defined in `Sources/rssss/Models.swift`; schema changes should be made there.
