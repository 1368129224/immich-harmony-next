@testable import Runner
import CryptoKit
import UIKit
import XCTest

final class RunnerTests: XCTestCase {
  func testReleaseUpdateBuildAndLiveContainerLink() throws {
    let manifest = NativeReleaseUpdate(
      bundleIdentifier: "com.immichz.immichz", channel: "main",
      buildNumber: 95, version: "0.0.2+abc1234", commit: "abc1234",
      sha256: String(repeating: "a", count: 64),
      downloadURL: NativeReleaseUpdate.ipaURL
    )
    XCTAssertTrue(try manifest.isNewer(than: 94, bundleID: "com.immichz.immichz"))
    XCTAssertFalse(try manifest.isNewer(than: 95, bundleID: "com.immichz.immichz"))
    let components = try XCTUnwrap(manifest.liveContainerURL.flatMap {
      URLComponents(url: $0, resolvingAgainstBaseURL: false)
    })
    XCTAssertEqual(components.scheme, "livecontainer")
    XCTAssertEqual(components.host, "install")
    XCTAssertEqual(components.queryItems?.first?.name, "url")
    XCTAssertEqual(components.queryItems?.first?.value, NativeReleaseUpdate.ipaURL.absoluteString)
    XCTAssertThrowsError(try manifest.isNewer(than: 94, bundleID: "other.bundle"))
    let tampered = NativeReleaseUpdate(
      bundleIdentifier: manifest.bundleIdentifier, channel: "gemini",
      buildNumber: 96, version: manifest.version, commit: manifest.commit,
      sha256: manifest.sha256, downloadURL: URL(string: "https://example.com/other.ipa")!
    )
    XCTAssertThrowsError(try tampered.isNewer(than: 94, bundleID: "com.immichz.immichz"))

    // Test SHA-256 verification
    let tempFile = FileManager.default.temporaryDirectory.appendingPathComponent("test_\(UUID().uuidString).txt")
    let testData = Data("hello immichz".utf8)
    try testData.write(to: tempFile)
    defer { try? FileManager.default.removeItem(at: tempFile) }

    let correctSHA = "d43336423e82c473f616c1f555a6429fce09ff1295f294893a195c9a176c926f"
    XCTAssertNoThrow(try nativeVerifyDownloadedIPA(at: tempFile, expectedSHA256: correctSHA))
    XCTAssertNoThrow(try nativeVerifyDownloadedIPA(at: tempFile, expectedSHA256: correctSHA.uppercased()))
    XCTAssertThrowsError(try nativeVerifyDownloadedIPA(at: tempFile, expectedSHA256: "0000000000000000000000000000000000000000000000000000000000000000"))
  }

  func testPhotosSourceFilterUsesActualCopyAndVerifiedMatch() {
    XCTAssertTrue(nativePhotosSourceIncludes(.all, hasLocal: true, hasServer: false, hasVerifiedMatch: false))
    XCTAssertFalse(nativePhotosSourceIncludes(.server, hasLocal: true, hasServer: false, hasVerifiedMatch: false))
    XCTAssertTrue(nativePhotosSourceIncludes(.server, hasLocal: true, hasServer: false, hasVerifiedMatch: true))
    XCTAssertTrue(nativePhotosSourceIncludes(.device, hasLocal: true, hasServer: true, hasVerifiedMatch: true))
    XCTAssertTrue(nativePhotosSourceIncludes(.server, hasLocal: false, hasServer: true, hasVerifiedMatch: false))
  }

  func testInitialTimelineWaitsForBothSourcesBeforePositioningAll() {
    XCTAssertFalse(nativeInitialTimelineReady(source: .all, remoteLoaded: true, remoteLoading: false, localSnapshotLoaded: false, localLoading: false))
    XCTAssertFalse(nativeInitialTimelineReady(source: .all, remoteLoaded: false, remoteLoading: false, localSnapshotLoaded: true, localLoading: false))
    XCTAssertFalse(nativeInitialTimelineReady(source: .all, remoteLoaded: true, remoteLoading: false, localSnapshotLoaded: true, localLoading: true))
    XCTAssertTrue(nativeInitialTimelineReady(source: .all, remoteLoaded: true, remoteLoading: false, localSnapshotLoaded: true, localLoading: false))
    XCTAssertTrue(nativeInitialTimelineReady(source: .device, remoteLoaded: false, remoteLoading: true, localSnapshotLoaded: true, localLoading: false))
    XCTAssertTrue(nativeInitialTimelineReady(source: .server, remoteLoaded: true, remoteLoading: false, localSnapshotLoaded: false, localLoading: true))
  }

  func testTimelineBottomAnchorMustBeInsideViewportAtBottom() {
    let viewport = CGRect(x: 0, y: 0, width: 390, height: 700)
    XCTAssertTrue(nativeTimelineBottomReached(
      anchorFrame: CGRect(x: 0, y: 699, width: 390, height: 1),
      viewportFrame: viewport
    ))
    XCTAssertFalse(nativeTimelineBottomReached(
      anchorFrame: CGRect(x: 0, y: 300, width: 390, height: 1),
      viewportFrame: viewport
    ))
    XCTAssertFalse(nativeTimelineBottomReached(
      anchorFrame: CGRect(x: 0, y: 1_299, width: 390, height: 1),
      viewportFrame: viewport
    ))
    XCTAssertFalse(nativeTimelineBottomReached(anchorFrame: .null, viewportFrame: viewport))
  }

  func testTimelineKeepsBottomOnlyDuringBootstrapWithoutInterruption() {
    XCTAssertTrue(nativeShouldKeepTimelineAtBottom(isBootstrapping: true, userMovedTimeline: false, pendingSourceChange: false, hasAssets: true))
    XCTAssertFalse(nativeShouldKeepTimelineAtBottom(isBootstrapping: false, userMovedTimeline: false, pendingSourceChange: false, hasAssets: true))
    XCTAssertFalse(nativeShouldKeepTimelineAtBottom(isBootstrapping: true, userMovedTimeline: true, pendingSourceChange: false, hasAssets: true))
    XCTAssertFalse(nativeShouldKeepTimelineAtBottom(isBootstrapping: true, userMovedTimeline: false, pendingSourceChange: true, hasAssets: true))
    XCTAssertFalse(nativeShouldKeepTimelineAtBottom(isBootstrapping: true, userMovedTimeline: false, pendingSourceChange: false, hasAssets: false))
    XCTAssertFalse(nativeShouldKeepTimelineAtBottom(isBootstrapping: true, userMovedTimeline: false, pendingSourceChange: false, hasAssets: true, positioningInProgress: true))
  }

  func testTimelineGranularityKeepsDayIdentityAndChronologicalOrder() {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    let dates = [
      DateComponents(year: 2023, month: 12, day: 31),
      DateComponents(year: 2024, month: 1, day: 1),
      DateComponents(year: 2024, month: 1, day: 2),
      DateComponents(year: 2024, month: 2, day: 1)
    ].compactMap { calendar.date(from: $0) }
    let groups = dates.enumerated().map { index, date in
      NativeDayGroup(date: date, assets: [
        NativeGridItem(server: NativeAsset(
          id: "asset-\(index)", date: date, isImage: true,
          isFavorite: false, thumbhash: nil
        ), local: nil)
      ])
    }
    let years = nativeTimelineSections(from: groups, level: "年", calendar: calendar)
    let months = nativeTimelineSections(from: groups, level: "月", calendar: calendar)
    let days = nativeTimelineSections(from: groups, level: "日", calendar: calendar)

    XCTAssertEqual(years.map(\.title), ["2023 年", "2024 年", nil, nil])
    XCTAssertEqual(months.map(\.title), ["2023年12月", "2024年1月", nil, "2024年2月"])
    XCTAssertEqual(years.map(\.id), months.map(\.id))
    XCTAssertEqual(years.map(\.id), days.map(\.id))
    XCTAssertEqual(years.last?.assets.last?.server?.id, "asset-3")
    XCTAssertEqual(months.last?.assets.last?.server?.id, "asset-3")
  }

  func testThumbnailCacheIdentitySurvivesTokenRotation() {
    let first = nativeThumbnailCacheAccountKey(
      server: "https://photos.example/", userId: "alice",
      credential: "old-token"
    )
    let rotated = nativeThumbnailCacheAccountKey(
      server: "https://photos.example", userId: "alice",
      credential: "new-token"
    )
    let other = nativeThumbnailCacheAccountKey(
      server: "https://photos.example", userId: "bob",
      credential: "new-token"
    )
    XCTAssertEqual(first, rotated)
    XCTAssertNotEqual(first, other)
    XCTAssertNotEqual(
      nativeThumbnailCacheAccountKey(
        server: "https://photos.example", userId: nil,
        credential: "old-token"
      ),
      nativeThumbnailCacheAccountKey(
        server: "https://photos.example", userId: nil,
        credential: "new-token"
      )
    )
  }

  func testAccountScopedPhotoSnapshotsRoundTrip() throws {
    let folder = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(
      at: folder, withIntermediateDirectories: true
    )
    defer { try? FileManager.default.removeItem(at: folder) }
    let identity = "https://example.com|alice"
    let hash = SHA256.hash(data: Data(identity.utf8))
      .map { String(format: "%02x", $0) }.joined()
    let asset = NativeAsset(
      id: "server-asset", date: Date(timeIntervalSince1970: 100),
      isImage: true, isFavorite: false, thumbhash: "hash"
    )
    let timeline = NativeTimelineSnapshot(
      assets: [asset], buckets: [NativeBucket(id: "day", count: 1)],
      nextBucket: 1, searchFallbackEnabled: false,
      searchCursor: nil, hasOlder: false
    )
    let local = NativeDeviceAsset(
      id: "local-asset", date: asset.date, isVideo: false,
      contentVersion: 10
    )
    let device = NativeDeviceSnapshot(assets: [local], albums: [])
    let exclusions = NativeTimelineExclusionsSnapshot(
      localAlbumIDs: ["excluded-local"],
      serverAlbumIDs: ["excluded-server"],
      localAssetIDs: ["hidden-local"],
      serverAssetIDs: ["hidden-server"]
    )
    try JSONEncoder().encode(timeline).write(
      to: folder.appendingPathComponent(
        "native_timeline_snapshot_\(hash).json"
      )
    )
    try JSONEncoder().encode(device).write(
      to: folder.appendingPathComponent(
        "native_device_snapshot_\(hash).json"
      )
    )
    try JSONEncoder().encode(exclusions).write(
      to: folder.appendingPathComponent(
        "native_exclusions_snapshot_\(hash).json"
      )
    )
    let event = NativeBackgroundDiagnostic(
      id: UUID(), date: Date(), operation: "时间线", category: "网络超时"
    )
    try JSONEncoder().encode([event]).write(
      to: folder.appendingPathComponent(
        "native_diagnostics_snapshot_\(hash).json"
      )
    )
    let store = NativePhotoSnapshotStore(directory: folder)
    XCTAssertEqual(store.timeline(identity: identity)?.assets.first?.id, asset.id)
    XCTAssertEqual(store.device(identity: identity)?.assets.first?.id, local.id)
    XCTAssertEqual(store.exclusions(identity: identity)?.localAssetIDs, ["hidden-local"])
    XCTAssertEqual(store.diagnostics(identity: identity).first?.category, "网络超时")
    XCTAssertNil(store.timeline(identity: "https://example.com|bob"))
    XCTAssertNil(store.device(identity: "https://example.com|bob"))
    XCTAssertNil(store.exclusions(identity: "https://example.com|bob"))
    XCTAssertTrue(store.diagnostics(identity: "https://example.com|bob").isEmpty)
  }

  func testAlbumOrdersOldestAboveNewest() {
    let older = Date(timeIntervalSince1970: 100)
    let newer = Date(timeIntervalSince1970: 200)
    XCTAssertEqual(
      nativeSortedResultDays([newer, older], oldestFirst: true),
      [older, newer]
    )
    XCTAssertEqual(
      nativeSortedResultDays([older, newer], oldestFirst: false),
      [newer, older]
    )
  }

  func testViewerNextSelectionIDWhenDeleting() {
    let ids = ["a", "b", "c"]
    XCTAssertEqual(nativeViewerNextSelectionID(deletingID: "b", orderedIDs: ids), "c")
    XCTAssertEqual(nativeViewerNextSelectionID(deletingID: "c", orderedIDs: ids), "b")
    XCTAssertEqual(nativeViewerNextSelectionID(deletingID: "a", orderedIDs: ids), "b")
    XCTAssertNil(nativeViewerNextSelectionID(deletingID: "single", orderedIDs: ["single"]))
    XCTAssertNil(nativeViewerNextSelectionID(deletingID: "missing", orderedIDs: ids))
    XCTAssertTrue(nativeShouldDismissViewerOnDeletion(itemsCountAfterDeletion: 0))
    XCTAssertFalse(nativeShouldDismissViewerOnDeletion(itemsCountAfterDeletion: 2))
  }

  func testViewerKeepsSurvivingCopyOnSamePage() {
    let server = NativeAsset(id: "server-asset", date: Date(timeIntervalSince1970: 100),
                             isImage: true, isFavorite: false, thumbhash: nil)
    let local = NativeDeviceAsset(id: "local-asset", date: server.date,
                                  isVideo: false, contentVersion: 1)
    let merged = NativeGridItem(server: server, local: local)
    let afterLocalDelete = nativeViewerRemainingCopy(of: merged, after: .localOnly)
    XCTAssertEqual(afterLocalDelete?.server?.id, server.id)
    XCTAssertNil(afterLocalDelete?.local)
    let afterRemoteDelete = nativeViewerRemainingCopy(of: merged, after: .remoteOnly)
    XCTAssertEqual(afterRemoteDelete?.local?.id, local.id)
    XCTAssertNil(afterRemoteDelete?.server)
    XCTAssertNil(nativeViewerRemainingCopy(of: merged, after: .all))
  }

  func testAppVersionIncludesCommitHash() {
    XCTAssertEqual(nativeFormattedAppVersion(shortVersion: "0.0.2", buildNumber: "82", commit: "bc5cb40"), "0.0.2+82 (bc5cb40)")
    XCTAssertEqual(nativeFormattedAppVersion(shortVersion: "0.0.2+bc5cb40", buildNumber: "bc5cb40", commit: "bc5cb40"), "0.0.2+bc5cb40")
    XCTAssertEqual(nativeFormattedAppVersion(shortVersion: "0.0.2", buildNumber: "", commit: "bc5cb40"), "0.0.2 (bc5cb40)")
    XCTAssertEqual(nativeFormattedAppVersion(shortVersion: "0.0.2", buildNumber: "82", commit: "unknown"), "0.0.2+82")
  }

  func testViewerWindowSliceClamping() {
    XCTAssertEqual(nativeViewerWindowSlice(currentIndex: 0, totalCount: 10, windowRadius: 3), 0..<4)
    XCTAssertEqual(nativeViewerWindowSlice(currentIndex: 5, totalCount: 10, windowRadius: 2), 3..<8)
    XCTAssertEqual(nativeViewerWindowSlice(currentIndex: 9, totalCount: 10, windowRadius: 3), 6..<10)
    XCTAssertEqual(nativeViewerWindowSlice(currentIndex: 0, totalCount: 0, windowRadius: 5), 0..<0)
    XCTAssertEqual(nativeViewerWindowSlice(currentIndex: 2, totalCount: 3, windowRadius: 10), 0..<3)
  }

  func testViewerImageFitsViewportWithoutCropping() {
    let viewport = CGSize(width: 390, height: 844)
    XCTAssertEqual(nativeAspectFitImageSize(imageSize: CGSize(width: 4000, height: 3000), viewportSize: viewport), CGSize(width: 390, height: 292.5))
    XCTAssertEqual(nativeAspectFitImageSize(imageSize: CGSize(width: 3000, height: 4000), viewportSize: viewport), CGSize(width: 390, height: 520))
    XCTAssertEqual(nativeAspectFitImageSize(imageSize: CGSize(width: 1000, height: 4000), viewportSize: viewport), CGSize(width: 211, height: 844))
    XCTAssertEqual(nativeAspectFitImageSize(imageSize: .zero, viewportSize: viewport), .zero)
  }

  func testViewerZoomRectMatchesViewportAspectRatioAndCentersOnTap() {
    let viewport = CGSize(width: 390, height: 844)
    let imageSize = CGSize(width: 390, height: 520)
    let tapCenter = CGPoint(x: 195, y: 260)
    let rect = nativeViewerZoomRect(for: tapCenter, in: imageSize, viewportSize: viewport, targetScale: 3.0)
    XCTAssertEqual(rect.width, 130, accuracy: 0.001)
    XCTAssertEqual(rect.height, 844.0 / 3.0, accuracy: 0.001)
    XCTAssertEqual(rect.midX, 195, accuracy: 0.001)
    XCTAssertEqual(rect.midY, 260, accuracy: 0.001)

    // Tap outside bounds clamps location
    let tapCorner = CGPoint(x: -50, y: 600)
    let clampedRect = nativeViewerZoomRect(for: tapCorner, in: imageSize, viewportSize: viewport, targetScale: 3.0)
    XCTAssertEqual(clampedRect.midX, 0, accuracy: 0.001)
    XCTAssertEqual(clampedRect.midY, 520, accuracy: 0.001)
  }

  func testViewerVerticalSwipeClassification() {
    // Downward swipe to dismiss
    XCTAssertEqual(
      nativeClassifyViewerVerticalSwipe(translation: CGSize(width: 0, height: 130), predictedEnd: CGSize(width: 0, height: 150)),
      .dismiss
    )
    XCTAssertEqual(
      nativeClassifyViewerVerticalSwipe(translation: CGSize(width: 5, height: 50), predictedEnd: CGSize(width: 5, height: 320)),
      .dismiss
    )

    // Upward swipe to show EXIF / details
    XCTAssertEqual(
      nativeClassifyViewerVerticalSwipe(translation: CGSize(width: 0, height: -30), predictedEnd: CGSize(width: 0, height: -40)),
      .showDetails
    )
    XCTAssertEqual(
      nativeClassifyViewerVerticalSwipe(translation: CGSize(width: 2, height: -18), predictedEnd: CGSize(width: 2, height: -90)),
      .showDetails
    )

    // Horizontal swipe should NOT trigger dismiss or details (leaves to TabView paging)
    XCTAssertEqual(
      nativeClassifyViewerVerticalSwipe(translation: CGSize(width: 100, height: 20), predictedEnd: CGSize(width: 200, height: 30)),
      .none
    )
    XCTAssertEqual(
      nativeClassifyViewerVerticalSwipe(translation: CGSize(width: -80, height: -10), predictedEnd: CGSize(width: -150, height: -20)),
      .none
    )
  }

  func testViewerDismissOnlyTargetsVisibleSourceThumbnail() {
    let screen = CGRect(x: 0, y: 0, width: 390, height: 844)
    let source = CGRect(x: 30, y: 100, width: 90, height: 90)
    XCTAssertEqual(nativeViewerVisibleSourceFrame(source, in: screen), source)
    XCTAssertNil(nativeViewerVisibleSourceFrame(CGRect(x: 30, y: -20, width: 90, height: 90), in: screen))
    XCTAssertNil(nativeViewerVisibleSourceFrame(CGRect(x: 30, y: 100, width: 0, height: 90), in: screen))
    XCTAssertNil(nativeViewerVisibleSourceFrame(nil, in: screen))
  }

  func testFilmstripDragSelectsAndClampsAssetIndex() {
    XCTAssertEqual(nativeFilmstripTargetIndex(start: 4, translation: -60, count: 10), 6)
    XCTAssertEqual(nativeFilmstripTargetIndex(start: 4, translation: 30, count: 10), 3)
    XCTAssertEqual(nativeFilmstripTargetIndex(start: 4, translation: -900, count: 10), 9)
    XCTAssertEqual(nativeFilmstripTargetIndex(start: 4, translation: 900, count: 10), 0)
    XCTAssertEqual(nativeFilmstripTargetIndex(start: 0, translation: 10, count: 0), 0)
  }

  func testPhotosPinchCellSizeIsContinuousAndClamped() {
    XCTAssertEqual(nativeClampedPhotosCellSize(100, magnification: 1), 100, accuracy: 0.001)
    XCTAssertEqual(nativeClampedPhotosCellSize(100, magnification: 1.5), 150, accuracy: 0.001)
    XCTAssertEqual(nativeClampedPhotosCellSize(100, magnification: 0.5), 72, accuracy: 0.001)
    XCTAssertEqual(nativeClampedPhotosCellSize(300, magnification: 2), 320, accuracy: 0.001)
  }

  func testPhotoFramePreferencesIgnoreTinyScrollMovementButTrackMeaningfulChanges() {
    let original: [String: CGRect] = ["a": CGRect(x: 0, y: 0, width: 100, height: 100)]
    let tinyMovement: [String: CGRect] = ["a": CGRect(x: 1, y: 2, width: 100, height: 100)]
    let meaningfulMovement: [String: CGRect] = ["a": CGRect(x: 1, y: 15, width: 100, height: 100)]
    let changedSet: [String: CGRect] = ["b": CGRect(x: 0, y: 0, width: 100, height: 100)]

    XCTAssertFalse(nativeShouldRefreshPhotoFrames(previous: original, next: tinyMovement, force: false))
    XCTAssertTrue(nativeShouldRefreshPhotoFrames(previous: original, next: meaningfulMovement, force: false))
    XCTAssertTrue(nativeShouldRefreshPhotoFrames(previous: original, next: tinyMovement, force: true))
    XCTAssertTrue(nativeShouldRefreshPhotoFrames(previous: original, next: changedSet, force: false))
    XCTAssertEqual(nativePhotoFramePreference(id: "offscreen", frame: CGRect(x: 0, y: 1000, width: 100, height: 100), viewportHeight: 800), [:])
    XCTAssertEqual(nativePhotoFramePreference(id: "visible", frame: CGRect(x: 0, y: 10, width: 100, height: 100), viewportHeight: 800).count, 1)
  }

  func testPhotosSourcePredicateKeepsUnloadedVerifiedMatchInCloudFilter() {
    XCTAssertTrue(nativePhotosSourceIncludes(.server, hasLocal: true, hasServer: false, hasVerifiedMatch: true))
    XCTAssertFalse(nativePhotosSourceIncludes(.server, hasLocal: true, hasServer: false, hasVerifiedMatch: false))
  }

  func testPhotosMixedSelectionActionCounts() {
    let local = NativeDeviceAsset(id: "local", date: .distantPast, isVideo: false, contentVersion: 0)
    let server = NativeAsset(id: "server", date: .distantPast, isImage: true, isFavorite: false, thumbhash: nil)
    let items = [NativeGridItem(server: nil, local: local), NativeGridItem(server: server, local: nil), NativeGridItem(server: server, local: local)]
    let availability = nativePhotosSelectionActionAvailability(items)
    XCTAssertEqual(availability.server, 2)
    XCTAssertEqual(availability.local, 2)
    XCTAssertEqual(availability.merged, 1)
  }

  func testBulkOperationSummaryReportsSuccessFailureAndUnconfirmedIDs() {
    let summary = nativeBulkOperationSummary(
      requestedIDs: ["success", "failure", "missing"],
      responses: [
        ["id": "success", "success": true],
        ["id": "failure", "success": false, "errorMessage": "not in album"],
        ["id": "unrequested", "success": true]
      ]
    )
    XCTAssertEqual(summary, NativeBulkOperationSummary(succeeded: 1, failed: 1, unconfirmed: 1))
  }

  func testBulkOperationSummaryTreatsDuplicateOrMalformedResponsesAsUnconfirmed() {
    let summary = nativeBulkOperationSummary(
      requestedIDs: ["duplicate", "malformed", "missing"],
      responses: [
        ["id": "duplicate", "success": true],
        ["id": "duplicate", "success": true],
        ["id": "malformed", "success": "yes"]
      ]
    )
    XCTAssertEqual(summary, NativeBulkOperationSummary(succeeded: 0, failed: 0, unconfirmed: 3))
  }

  func testRefreshPreservesOldestLoadedBucketBoundary() {
    let old = (0..<40).map { NativeBucket(id: "bucket\($0)", count: 1) }
    let refreshed = [NativeBucket(id: "new", count: 1)] + old
    XCTAssertEqual(nativeRefreshedBucketBoundary(old: old, next: 25, refreshed: refreshed), 26)
    XCTAssertEqual(nativeRefreshedBucketBoundary(old: old, next: 40, refreshed: refreshed), 41)
    XCTAssertEqual(nativeRefreshedBucketBoundary(old: old, next: 0, refreshed: refreshed), 0)
    XCTAssertEqual(nativeBoundaryAfterFetchingHead(old: old, next: 3, refreshed: refreshed, headSize: 20), 20)
    XCTAssertEqual(nativeBoundaryAfterFetchingHead(old: old, next: 25, refreshed: refreshed, headSize: 20), 26)
    XCTAssertEqual(nativeBoundaryAfterFetchingHead(old: [], next: 0, refreshed: refreshed, headSize: 20), 20)
  }

  func testPartialDeleteTracksOnlyConfirmedServerDeletions() {
    let error = NativeDeleteOperationError.partial(failures: ["本机删除失败"], deletedServerIDs: ["deleted"])
    XCTAssertEqual(error.deletedServerIDs, ["deleted"])
    let serverFailure = NativeDeleteOperationError.partial(failures: ["云端删除失败"], deletedServerIDs: [])
    XCTAssertTrue(serverFailure.deletedServerIDs.isEmpty)
  }

  func testSyncCacheDoesNotCrossAccountsOrLoadLegacyUnscopedEntries() {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = NativeSyncCacheStore(directory: directory)
    store.configure(server: "https://photos.example/", userId: "alice")
    store.update(matches: ["local": "alice-photo"], checked: ["local"], newChecksums: ["local": String(repeating: "A", count: 27) + "="])
    store.configure(server: "https://photos.example/", userId: "bob")
    XCTAssertNil(store.serverID(for: "local"))
    XCTAssertTrue(store.checkedIDs.isEmpty)
    store.configure(server: "https://other.example", userId: "alice")
    XCTAssertNil(store.serverID(for: "local"))
    store.configure(server: "https://photos.example", userId: "alice")
    XCTAssertEqual(store.serverID(for: "local"), "alice-photo")
    store.configure(server: "https://photos.example", userId: nil)
    XCTAssertNil(store.serverID(for: "local"))
    store.configure(server: "https://photos.example", userId: "bob")
    store.update(matches: ["local": "bob-photo"], expectedIdentity: "https://photos.example|alice")
    XCTAssertNil(store.serverID(for: "local"))
    store.clear()
    store.configure(server: "https://photos.example", userId: "bob")
    XCTAssertNil(store.serverID(for: "local"))
  }

  func testVideoFileClassificationForSaveToPhotos() {
    XCTAssertTrue(nativeIsVideoFile(URL(fileURLWithPath: "/tmp/movie.MOV")))
    XCTAssertTrue(nativeIsVideoFile(URL(fileURLWithPath: "/tmp/movie.mp4")))
    XCTAssertFalse(nativeIsVideoFile(URL(fileURLWithPath: "/tmp/image.heic")))
  }

  func testCloudSyncBadgeDistinguishesUnverifiedFromVerifiedUnmatched() {
    let local = NativeDeviceAsset(id: "local", date: .distantPast, isVideo: false, contentVersion: 0)
    let item = NativeGridItem(server: nil, local: local)
    XCTAssertEqual(item.cloudSymbol(matchedServerIDs: [:], checkedIDs: []), "questionmark.icloud")
    XCTAssertEqual(item.cloudSymbol(matchedServerIDs: [:], checkedIDs: ["local"]), "icloud.slash")
    XCTAssertEqual(item.cloudSymbol(matchedServerIDs: ["local": "server"], checkedIDs: ["local"]), "checkmark.icloud")
  }

  func testRecentSearchesStoreRoundTripAndDeduplication() {
    let testKey = "test_recent_searches_\(UUID().uuidString)"
    let store = NativeRecentSearchesStore(userDefaults: .standard, storageKey: testKey, maxCount: 3)
    defer { store.clear() }

    XCTAssertTrue(store.load().isEmpty)

    // Whitespace trimming
    store.add("  cat  ")
    XCTAssertEqual(store.load(), ["cat"])

    // Empty/blank ignored
    store.add("")
    store.add("   \t  ")
    XCTAssertEqual(store.load(), ["cat"])

    // Second item prepends
    store.add("dog")
    XCTAssertEqual(store.load(), ["dog", "cat"])

    // Case-insensitive deduplication moves latest to front
    store.add("CAT")
    XCTAssertEqual(store.load(), ["CAT", "dog"])

    // Max count capping (maxCount = 3)
    store.add("bird")
    store.add("fish")
    XCTAssertEqual(store.load(), ["fish", "bird", "CAT"])

    // Remove single item
    store.remove("bird")
    XCTAssertEqual(store.load(), ["fish", "CAT"])

    // Clear all
    store.clear()
    XCTAssertTrue(store.load().isEmpty)
  }

  func testNativeFilterLocalAssetsByQueryAndFilename() {
    let d1 = Date(timeIntervalSince1970: 1715342400) // 2024-05-10
    let d2 = Date(timeIntervalSince1970: 1718452800) // 2024-06-15
    let d3 = Date(timeIntervalSince1970: 1721476800) // 2024-07-20

    let a1 = NativeDeviceAsset(id: "loc1", date: d1, isVideo: false, contentVersion: 1)
    let a2 = NativeDeviceAsset(id: "loc2", date: d2, isVideo: false, contentVersion: 1)
    let a3 = NativeDeviceAsset(id: "loc3", date: d3, isVideo: true, contentVersion: 1)
    let all = [a1, a2, a3]

    let mockLookup: (String) -> String? = { id in
      switch id {
      case "loc1": return "IMG_1234.JPG"
      case "loc2": return "Vacation_Summer.png"
      case "loc3": return "Beach_Party.mov"
      default: return nil
      }
    }

    // Keyword matching
    let hitVacation = nativeFilterLocalAssets(
      assets: all, query: "vacation", filterPhotos: true, filterVideos: true,
      favoritesOnly: false, useAfter: false, after: .distantPast,
      useBefore: false, before: .distantFuture, filenameLookup: mockLookup
    )
    XCTAssertEqual(hitVacation.map(\.id), ["loc2"])

    // Case insensitivity
    let hitSummer = nativeFilterLocalAssets(
      assets: all, query: "SUMMER", filterPhotos: true, filterVideos: true,
      favoritesOnly: false, useAfter: false, after: .distantPast,
      useBefore: false, before: .distantFuture, filenameLookup: mockLookup
    )
    XCTAssertEqual(hitSummer.map(\.id), ["loc2"])

    // No match
    let hitNone = nativeFilterLocalAssets(
      assets: all, query: "nonexistent", filterPhotos: true, filterVideos: true,
      favoritesOnly: false, useAfter: false, after: .distantPast,
      useBefore: false, before: .distantFuture, filenameLookup: mockLookup
    )
    XCTAssertTrue(hitNone.isEmpty)

    // Nil/empty query passes all
    let hitAll = nativeFilterLocalAssets(
      assets: all, query: nil, filterPhotos: true, filterVideos: true,
      favoritesOnly: false, useAfter: false, after: .distantPast,
      useBefore: false, before: .distantFuture, filenameLookup: mockLookup
    )
    XCTAssertEqual(hitAll.count, 3)
  }

  func testNativeFilterLocalAssetsByMediaTypeAndFavorites() {
    let now = Date()
    let photoNormal = NativeDeviceAsset(id: "p1", date: now, isVideo: false, contentVersion: 1, isFavorite: false)
    let photoFav = NativeDeviceAsset(id: "p2", date: now, isVideo: false, contentVersion: 1, isFavorite: true)
    let videoFav = NativeDeviceAsset(id: "v1", date: now, isVideo: true, contentVersion: 1, isFavorite: true)
    let all = [photoNormal, photoFav, videoFav]

    // Photos only
    let photosOnly = nativeFilterLocalAssets(
      assets: all, query: nil, filterPhotos: true, filterVideos: false,
      favoritesOnly: false, useAfter: false, after: .distantPast,
      useBefore: false, before: .distantFuture
    )
    XCTAssertEqual(photosOnly.map(\.id), ["p1", "p2"])

    // Videos only
    let videosOnly = nativeFilterLocalAssets(
      assets: all, query: nil, filterPhotos: false, filterVideos: true,
      favoritesOnly: false, useAfter: false, after: .distantPast,
      useBefore: false, before: .distantFuture
    )
    XCTAssertEqual(videosOnly.map(\.id), ["v1"])

    // Neither photos nor videos
    let neither = nativeFilterLocalAssets(
      assets: all, query: nil, filterPhotos: false, filterVideos: false,
      favoritesOnly: false, useAfter: false, after: .distantPast,
      useBefore: false, before: .distantFuture
    )
    XCTAssertTrue(neither.isEmpty)

    // Favorites only
    let favs = nativeFilterLocalAssets(
      assets: all, query: nil, filterPhotos: true, filterVideos: true,
      favoritesOnly: true, useAfter: false, after: .distantPast,
      useBefore: false, before: .distantFuture
    )
    XCTAssertEqual(favs.map(\.id), ["p2", "v1"])

    // Favorites and photos only
    let favPhotos = nativeFilterLocalAssets(
      assets: all, query: nil, filterPhotos: true, filterVideos: false,
      favoritesOnly: true, useAfter: false, after: .distantPast,
      useBefore: false, before: .distantFuture
    )
    XCTAssertEqual(favPhotos.map(\.id), ["p2"])
  }

  func testNativeFilterLocalAssetsByDateRange() {
    let jan = Date(timeIntervalSince1970: 1704888000) // 2024-01-10
    let jun = Date(timeIntervalSince1970: 1718020800) // 2024-06-10
    let dec = Date(timeIntervalSince1970: 1733832000) // 2024-12-10

    let a1 = NativeDeviceAsset(id: "jan", date: jan, isVideo: false, contentVersion: 1)
    let a2 = NativeDeviceAsset(id: "jun", date: jun, isVideo: false, contentVersion: 1)
    let a3 = NativeDeviceAsset(id: "dec", date: dec, isVideo: false, contentVersion: 1)
    let all = [a1, a2, a3]

    let may1 = Date(timeIntervalSince1970: 1714564800) // 2024-05-01
    let jul1 = Date(timeIntervalSince1970: 1719835200) // 2024-07-01

    // After May 1 -> June & Dec
    let afterMay = nativeFilterLocalAssets(
      assets: all, query: nil, filterPhotos: true, filterVideos: true,
      favoritesOnly: false, useAfter: true, after: may1,
      useBefore: false, before: .distantFuture
    )
    XCTAssertEqual(afterMay.map(\.id), ["jun", "dec"])

    // Before July 1 -> Jan & June
    let beforeJul = nativeFilterLocalAssets(
      assets: all, query: nil, filterPhotos: true, filterVideos: true,
      favoritesOnly: false, useAfter: false, after: .distantPast,
      useBefore: true, before: jul1
    )
    XCTAssertEqual(beforeJul.map(\.id), ["jan", "jun"])

    // Range May 1 - July 1 -> June only
    let rangeMayJul = nativeFilterLocalAssets(
      assets: all, query: nil, filterPhotos: true, filterVideos: true,
      favoritesOnly: false, useAfter: true, after: may1,
      useBefore: true, before: jul1
    )
    XCTAssertEqual(rangeMayJul.map(\.id), ["jun"])
  }

  func testNativeFilterLocalAssetsByAlbum() {
    let a1 = NativeDeviceAsset(id: "loc1", date: Date(), isVideo: false, contentVersion: 1)
    let a2 = NativeDeviceAsset(id: "loc2", date: Date(), isVideo: false, contentVersion: 1)
    let a3 = NativeDeviceAsset(id: "loc3", date: Date(), isVideo: false, contentVersion: 1)
    let all = [a1, a2, a3]

    let inAlbum = nativeFilterLocalAssets(
      assets: all, query: nil, filterPhotos: true, filterVideos: true,
      favoritesOnly: false, useAfter: false, after: .distantPast,
      useBefore: false, before: .distantFuture, allowedLocalAssetIDs: ["loc1", "loc3"]
    )
    XCTAssertEqual(inAlbum.map(\.id), ["loc1", "loc3"])

    // Empty allowed IDs (e.g. server album) excludes all local assets
    let inEmptyAlbum = nativeFilterLocalAssets(
      assets: all, query: nil, filterPhotos: true, filterVideos: true,
      favoritesOnly: false, useAfter: false, after: .distantPast,
      useBefore: false, before: .distantFuture, allowedLocalAssetIDs: []
    )
    XCTAssertTrue(inEmptyAlbum.isEmpty)
  }

  func testNativeFilterSearchResultsBySource() {
    let s1 = NativeAsset(id: "S1", date: Date(timeIntervalSince1970: 100), isImage: true, isFavorite: false, thumbhash: nil)
    let s2 = NativeAsset(id: "S2", date: Date(timeIntervalSince1970: 200), isImage: true, isFavorite: false, thumbhash: nil)
    let s3 = NativeAsset(id: "S3", date: Date(timeIntervalSince1970: 300), isImage: true, isFavorite: false, thumbhash: nil)
    let servers = [s1, s2, s3]

    let l1 = NativeDeviceAsset(id: "L1", date: s1.date, isVideo: false, contentVersion: 1)
    let l2 = NativeDeviceAsset(id: "L2", date: s2.date, isVideo: false, contentVersion: 1)
    let l4 = NativeDeviceAsset(id: "L4", date: Date(timeIntervalSince1970: 400), isVideo: false, contentVersion: 1)
    let locals = [l1, l2, l4]

    let matched = ["L1": "S1", "L2": "S2"]

    // All source: retains all
    let allResult = nativeFilterSearchResultsBySource(source: .all, serverAssets: servers, localAssets: locals, matchedServerIDs: matched)
    XCTAssertEqual(allResult.server.count, 3)
    XCTAssertEqual(allResult.local.count, 3)

    // Device source: only device assets and matched server copies (S3 is excluded)
    let deviceResult = nativeFilterSearchResultsBySource(source: .device, serverAssets: servers, localAssets: locals, matchedServerIDs: matched)
    XCTAssertEqual(deviceResult.local.map(\.id), ["L1", "L2", "L4"])
    XCTAssertEqual(deviceResult.server.map(\.id), ["S1", "S2"])

    // Server source: only server assets and matched local copies (L4 is excluded)
    let serverResult = nativeFilterSearchResultsBySource(source: .server, serverAssets: servers, localAssets: locals, matchedServerIDs: matched)
    XCTAssertEqual(serverResult.server.map(\.id), ["S1", "S2", "S3"])
    XCTAssertEqual(serverResult.local.map(\.id), ["L1", "L2"])
  }

  func testNativeDeduplicateServerAssets() {
    let s1 = NativeAsset(id: "S1", date: .distantPast, isImage: true, isFavorite: false, thumbhash: nil)
    let s2 = NativeAsset(id: "S2", date: .distantPast, isImage: true, isFavorite: false, thumbhash: nil)
    let s3 = NativeAsset(id: "S3", date: .distantPast, isImage: true, isFavorite: false, thumbhash: nil)

    let merged = nativeDeduplicateServerAssets(existing: [s1, s2], incoming: [s2, s3])
    XCTAssertEqual(merged.map(\.id), ["S1", "S2", "S3"])
  }

  func testNativeSearchRaceConditionResolution() {
    XCTAssertFalse(nativeShouldAcceptSearchResult(requestGeneration: 1, currentGeneration: 2))
    XCTAssertTrue(nativeShouldAcceptSearchResult(requestGeneration: 2, currentGeneration: 2))
    XCTAssertFalse(nativeShouldAcceptSearchResult(requestGeneration: 3, currentGeneration: 2))
  }

  func testNativeTimelineRefreshTTLAdaptsToNetworkType() {
    // Wi-Fi / unmetered
    XCTAssertEqual(nativeTimelineRefreshTTL(isCellular: false, isExpensive: false), 30.0)

    // Cellular / mobile data
    XCTAssertEqual(nativeTimelineRefreshTTL(isCellular: true, isExpensive: false), 180.0)

    // Metered / expensive connection (e.g. hotspot or Low Data Mode)
    XCTAssertEqual(nativeTimelineRefreshTTL(isCellular: false, isExpensive: true), 180.0)
    XCTAssertEqual(nativeTimelineRefreshTTL(isCellular: true, isExpensive: true), 180.0)
  }

  func testNativeShouldRefreshTimelineRespectsTTL() {
    let now = Date(timeIntervalSince1970: 10000)

    // Wi-Fi (TTL 30s)
    XCTAssertFalse(nativeShouldRefreshTimeline(lastRefreshTime: now.addingTimeInterval(-10), now: now, isCellular: false))
    XCTAssertFalse(nativeShouldRefreshTimeline(lastRefreshTime: now.addingTimeInterval(-29), now: now, isCellular: false))
    XCTAssertTrue(nativeShouldRefreshTimeline(lastRefreshTime: now.addingTimeInterval(-30), now: now, isCellular: false))
    XCTAssertTrue(nativeShouldRefreshTimeline(lastRefreshTime: now.addingTimeInterval(-60), now: now, isCellular: false))

    // Cellular (TTL 180s)
    XCTAssertFalse(nativeShouldRefreshTimeline(lastRefreshTime: now.addingTimeInterval(-30), now: now, isCellular: true))
    XCTAssertFalse(nativeShouldRefreshTimeline(lastRefreshTime: now.addingTimeInterval(-120), now: now, isCellular: true))
    XCTAssertFalse(nativeShouldRefreshTimeline(lastRefreshTime: now.addingTimeInterval(-179), now: now, isCellular: true))
    XCTAssertTrue(nativeShouldRefreshTimeline(lastRefreshTime: now.addingTimeInterval(-180), now: now, isCellular: true))
    XCTAssertTrue(nativeShouldRefreshTimeline(lastRefreshTime: now.addingTimeInterval(-300), now: now, isCellular: true))

    // Initial / distant past
    XCTAssertTrue(nativeShouldRefreshTimeline(lastRefreshTime: .distantPast, now: now, isCellular: false))
    XCTAssertTrue(nativeShouldRefreshTimeline(lastRefreshTime: .distantPast, now: now, isCellular: true))
  }

  func testNativeBottomPullToRefreshDetection() {
    let viewport = CGRect(x: 0, y: 0, width: 390, height: 800)

    // When near bottom (anchorFrame.maxY around or inside viewport)
    let bottomAnchor = CGRect(x: 0, y: 798, width: 390, height: 1)
    XCTAssertTrue(nativeIsTimelineNearBottom(anchorFrame: bottomAnchor, viewportFrame: viewport))

    // When not at bottom (e.g. anchorFrame is far below viewport)
    let offscreenAnchor = CGRect(x: 0, y: 2500, width: 390, height: 1)
    XCTAssertFalse(nativeIsTimelineNearBottom(anchorFrame: offscreenAnchor, viewportFrame: viewport))

    // Null frames
    XCTAssertFalse(nativeIsTimelineNearBottom(anchorFrame: .null, viewportFrame: viewport))
    XCTAssertFalse(nativeIsTimelineNearBottom(anchorFrame: bottomAnchor, viewportFrame: .null))

    // Threshold check
    XCTAssertEqual(nativeBottomPullToRefreshThreshold(), 55.0)

    // Refresh trigger conditions
    // 1. At bottom and pulled up >= 55pt
    XCTAssertTrue(nativeShouldTriggerBottomPullRefresh(
      isAtBottom: true,
      dragTranslationY: -60,
      overscrollDistance: 60,
      isRefreshing: false
    ))

    // 2. At bottom but insufficient pull (< 55pt)
    XCTAssertFalse(nativeShouldTriggerBottomPullRefresh(
      isAtBottom: true,
      dragTranslationY: -30,
      overscrollDistance: 30,
      isRefreshing: false
    ))

    // 3. Not at bottom (scrolling in middle of list), even with large drag
    XCTAssertFalse(nativeShouldTriggerBottomPullRefresh(
      isAtBottom: false,
      dragTranslationY: -80,
      overscrollDistance: 80,
      isRefreshing: false
    ))

    // 4. Pulling downward at bottom (scrolling back up)
    XCTAssertFalse(nativeShouldTriggerBottomPullRefresh(
      isAtBottom: true,
      dragTranslationY: 40,
      overscrollDistance: 0,
      isRefreshing: false
    ))

    // 5. Already refreshing
    XCTAssertFalse(nativeShouldTriggerBottomPullRefresh(
      isAtBottom: true,
      dragTranslationY: -70,
      overscrollDistance: 70,
      isRefreshing: true
    ))
  }

  func testImmichCoreBridgeMockLifecycle() async throws {
    let bridge = ImmichCoreBridge.shared
    bridge.isMockMode = true
    defer { bridge.isMockMode = false }

    XCTAssertTrue(bridge.isInitialized)
    let initOk = try await bridge.initializeCoreEngine()
    XCTAssertTrue(initOk)

    let loginMsg = try await bridge.loginServer(serverUrl: "https://photos.example.com", apiKey: "test-key")
    XCTAssertTrue(loginMsg.contains("successful"))

    let buckets = try await bridge.syncAndGetBuckets()
    XCTAssertEqual(buckets.count, 3)
    XCTAssertEqual(buckets.first?.id, "2024-03-01T00:00:00.000Z")

    let assets = try await bridge.fetchBucketAssets(timeBucket: "2024-03-01T00:00:00.000Z")
    XCTAssertEqual(assets.count, 2)
    let nativeAsset = assets[0].toNativeAsset()
    XCTAssertEqual(nativeAsset.id, "mock-core-live-1")
    XCTAssertTrue(nativeAsset.isImage)
    XCTAssertTrue(nativeAsset.isFavorite)

    let cachedPath = try await bridge.ensureAssetCached(assetId: "mock-core-live-1", mediaType: "thumbnail")
    XCTAssertTrue(cachedPath.contains("mock-core-live-1"))

    let bundle = try await bridge.prepareAssetViewerBundle(assetId: "mock-core-live-1")
    XCTAssertEqual(bundle.assetId, "mock-core-live-1")
    XCTAssertTrue(bundle.isLivePhoto)

    let exif = try await bridge.getAssetExif(assetId: "mock-core-live-1")
    XCTAssertEqual(exif?.make, "Apple")
    XCTAssertEqual(exif?.model, "iPhone 16 Pro")
  }
}
