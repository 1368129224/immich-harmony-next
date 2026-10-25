import Foundation
import Photos
import SwiftUI
import UIKit

// Native iOS client against the official Immich v3.2.4 OpenAPI.

enum NativeDragSelectionIntent: Equatable {
  case undecided
  case select
  case scroll
}

enum NativePhotosSource: String, CaseIterable, Identifiable {
  case all = "全部"
  case device = "本机"
  case server = "云端"
  var id: String { rawValue }
}

func nativeInitialTimelineReady(
  source: NativePhotosSource,
  remoteLoaded: Bool,
  remoteLoading: Bool,
  localSnapshotLoaded: Bool,
  localLoading: Bool
) -> Bool {
  switch source {
  case .device: return localSnapshotLoaded && !localLoading
  case .server: return remoteLoaded && !remoteLoading
  case .all: return remoteLoaded && !remoteLoading && localSnapshotLoaded && !localLoading
  }
}

func nativeShouldKeepTimelineAtBottom(
  isBootstrapping: Bool,
  userMovedTimeline: Bool,
  pendingSourceChange: Bool,
  hasAssets: Bool,
  positioningInProgress: Bool = false
) -> Bool {
  isBootstrapping && !userMovedTimeline && !pendingSourceChange &&
    hasAssets && !positioningInProgress
}

func nativeTimelineBottomReached(
  anchorFrame: CGRect,
  viewportFrame: CGRect,
  tolerance: CGFloat = 2
) -> Bool {
  guard !anchorFrame.isNull, !viewportFrame.isNull else { return false }
  return anchorFrame.maxY >= viewportFrame.maxY - tolerance &&
    anchorFrame.maxY <= viewportFrame.maxY + tolerance
}

func nativeBottomPullToRefreshThreshold() -> CGFloat { 55.0 }

func nativeIsTimelineNearBottom(
  anchorFrame: CGRect,
  viewportFrame: CGRect,
  threshold: CGFloat = 20
) -> Bool {
  guard !anchorFrame.isNull, !viewportFrame.isNull else { return false }
  return anchorFrame.maxY <= viewportFrame.maxY + threshold
}

func nativeShouldTriggerBottomPullRefresh(
  isAtBottom: Bool,
  dragTranslationY: CGFloat,
  overscrollDistance: CGFloat,
  isRefreshing: Bool
) -> Bool {
  guard isAtBottom, !isRefreshing else { return false }
  let threshold = nativeBottomPullToRefreshThreshold()
  return dragTranslationY <= -threshold || overscrollDistance >= threshold
}

func nativeViewerNextSelectionID(
  deletingID: String,
  orderedIDs: [String]
) -> String? {
  guard let idx = orderedIDs.firstIndex(of: deletingID) else { return nil }
  if idx + 1 < orderedIDs.count {
    return orderedIDs[idx + 1]
  } else if idx - 1 >= 0 {
    return orderedIDs[idx - 1]
  }
  return nil
}

func nativeShouldDismissViewerOnDeletion(
  itemsCountAfterDeletion: Int
) -> Bool {
  itemsCountAfterDeletion <= 0
}

/// Computes a slice window around the current index for smooth virtualized scrolling.
func nativeViewerWindowSlice(currentIndex: Int, totalCount: Int, windowRadius: Int = 15) -> Range<Int> {
  guard totalCount > 0 else { return 0..<0 }
  let lower = max(0, currentIndex - windowRadius)
  let upper = min(totalCount, currentIndex + windowRadius + 1)
  return lower..<upper
}

func nativeFormattedAppVersion(
  shortVersion: String,
  buildNumber: String,
  commit: String
) -> String {
  if !commit.isEmpty && commit != "unknown" && shortVersion.contains(commit) {
    return shortVersion
  }
  let base = buildNumber.isEmpty ? shortVersion : "\(shortVersion)+\(buildNumber)"
  if !commit.isEmpty && commit != "unknown" && !base.contains(commit) {
    return "\(base) (\(commit))"
  }
  return base
}

func nativePhotosSourceIncludes(_ source: NativePhotosSource, hasLocal: Bool, hasServer: Bool, hasVerifiedMatch: Bool) -> Bool {
  switch source {
  case .all: return hasLocal || hasServer
  case .device: return hasLocal
  case .server: return hasServer || (hasLocal && hasVerifiedMatch)
  }
}

func nativeIndexAssetsBySecond(_ assets: [NativeAsset]) -> [Int64: [NativeAsset]] {
  var dict: [Int64: [NativeAsset]] = [:]
  for asset in assets {
    let sec = Int64(asset.date.timeIntervalSince1970)
    dict[sec, default: []].append(asset)
  }
  return dict
}

func nativeFindHeuristicServerMatch(
  local: NativeDeviceAsset,
  serverBySecond: [Int64: [NativeAsset]],
  usedServerIDs: Set<String>
) -> NativeAsset? {
  let localSec = Int64(local.date.timeIntervalSince1970)
  var candidateMatch: NativeAsset? = nil
  var bestDiff: TimeInterval = 2.01

  for s in (localSec - 2)...(localSec + 2) {
    guard let bucket = serverBySecond[s] else { continue }
    for candidate in bucket {
      guard !usedServerIDs.contains(candidate.id) else { continue }
      guard local.isVideo == !candidate.isImage else { continue }
      let diff = abs(local.date.timeIntervalSince(candidate.date))
      if diff <= 2.0 && diff < bestDiff {
        if local.isLivePhoto && candidate.livePhotoVideoId == nil && candidateMatch?.livePhotoVideoId != nil {
          continue
        }
        bestDiff = diff
        candidateMatch = candidate
      }
    }
  }
  return candidateMatch
}

func nativePhotosSelectionActionAvailability(_ items: [NativeGridItem]) -> (server: Int, local: Int, merged: Int) {
  let server = items.filter { $0.server != nil }.count
  let local = items.filter { $0.local != nil }.count
  let merged = items.filter { $0.server != nil && $0.local != nil }.count
  return (server, local, merged)
}

struct NativeBulkOperationSummary: Equatable {
  let succeeded: Int
  let failed: Int
  let unconfirmed: Int
}

func nativeBulkOperationSummary(requestedIDs: [String], responses: [[String: Any]]) -> NativeBulkOperationSummary {
  let requested = Set(requestedIDs)
  var outcomes: [String: [Bool]] = [:]

  for response in responses {
    guard let id = response["id"] as? String, requested.contains(id),
          let success = response["success"] as? Bool else { continue }
    outcomes[id, default: []].append(success)
  }

  var succeeded = 0
  var failed = 0
  for id in requested {
    guard let results = outcomes[id], results.count == 1, let success = results.first else { continue }
    if success { succeeded += 1 } else { failed += 1 }
  }
  return NativeBulkOperationSummary(
    succeeded: succeeded,
    failed: failed,
    unconfirmed: max(0, requested.count - succeeded - failed)
  )
}

func nativeIsVideoFile(_ url: URL) -> Bool {
  ["mov", "mp4", "m4v", "avi", "mkv", "3gp", "webm"].contains(url.pathExtension.lowercased())
}

func nativeClampedPhotosCellSize(_ base: CGFloat, magnification: CGFloat) -> CGFloat {
  min(320, max(72, base * max(0.35, magnification)))
}

func nativePhotoFramePreference(id: String, frame: CGRect, viewportHeight: CGFloat) -> [String: CGRect] {
  guard frame.maxY >= -300, frame.minY <= viewportHeight + 300 else { return [:] }
  return [id: frame]
}

func nativeShouldRefreshPhotoFrames(
  previous: [String: CGRect],
  next: [String: CGRect],
  force: Bool,
  movementThreshold: CGFloat = 12
) -> Bool {
  if force || Set(previous.keys) != Set(next.keys) { return true }
  for (id, frame) in next {
    guard let oldFrame = previous[id] else { return true }
    if abs(frame.minY - oldFrame.minY) >= movementThreshold ||
        abs(frame.minX - oldFrame.minX) >= movementThreshold ||
        abs(frame.width - oldFrame.width) >= 1 || abs(frame.height - oldFrame.height) >= 1 {
      return true
    }
  }
  return false
}

func nativeDragSelectionIntent(for translation: CGSize) -> NativeDragSelectionIntent {
  let horizontal = abs(translation.width)
  let vertical = abs(translation.height)
  guard max(horizontal, vertical) >= 10 else { return .undecided }
  return horizontal >= vertical * 0.5 ? .select : .scroll
}

@MainActor
final class NativeDeviceLibrary: NSObject, ObservableObject, PHPhotoLibraryChangeObserver {
  @Published private(set) var authorized = false
  @Published private(set) var assets: [NativeDeviceAsset] = []
  @Published private(set) var albums: [NativeDeviceAlbum] = []
  @Published private(set) var isLoading = false
  @Published private(set) var hasLoadedInitialSnapshot = false
  @Published private(set) var hasCompletedLiveRefresh = false
  private var refreshGeneration = 0
  private var isObserving = false
  private let accountIdentity = NativeSyncCacheStore.shared.identity

  override init() {
    super.init()
    let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
    authorized = status == .authorized || status == .limited
    if status == .authorized,
       let snapshot = NativePhotoSnapshotStore.shared.device(identity: accountIdentity) {
      assets = snapshot.assets
      albums = snapshot.albums
      hasLoadedInitialSnapshot = true
    } else if authorized {
      // Limited-library selection may have changed outside the app. Query
      // current PhotoKit permissions instead of exposing stale cached IDs.
      // On the first launch after upgrading, get only a small recent window;
      // the complete PhotoKit scan still runs off the first rendered frame.
      let options = PHFetchOptions()
      options.fetchLimit = 96
      options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
      let results = PHAsset.fetchAssets(with: options)
      var recent: [NativeDeviceAsset] = []
      results.enumerateObjects { item, _, _ in
        recent.append(NativeDeviceAsset(
          id: item.localIdentifier,
          date: item.creationDate ?? .distantPast,
          isVideo: item.mediaType == .video,
          isLivePhoto: item.mediaSubtypes.contains(.photoLive),
          contentVersion: Int((item.modificationDate?.timeIntervalSince1970 ?? 0) * 1000),
          isFavorite: item.isFavorite
        ))
      }
      assets = Array(recent.reversed())
      hasLoadedInitialSnapshot = true
    }
  }

  nonisolated func photoLibraryDidChange(_ changeInstance: PHChange) {
    Task { @MainActor [weak self] in
      self?.refresh()
    }
  }

  func requestAccess() async {
    let status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
    if status == .authorized || status == .limited { refresh() }
  }

  func refreshAndWait() async {
    refresh()
    while isLoading {
      try? await Task.sleep(nanoseconds: 50_000_000)
    }
  }

  func refresh() {
    let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
    authorized = status == .authorized || status == .limited
    if authorized && !isObserving {
      PHPhotoLibrary.shared().register(self)
      isObserving = true
    }
    guard authorized else {
      refreshGeneration += 1
      assets = []
      albums = []
      NativePhotoSnapshotStore.shared.clearDevice(expectedIdentity: accountIdentity)
      isLoading = false
      hasLoadedInitialSnapshot = true
      hasCompletedLiveRefresh = true
      return
    }
    refreshGeneration += 1
    let generation = refreshGeneration
    isLoading = true
    Task(priority: .utility) { [weak self] in
      let library = await Task.detached(priority: .utility) {
        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: true)]
        let results = PHAsset.fetchAssets(with: options)
        var entries: [NativeDeviceAsset] = []
        entries.reserveCapacity(results.count)
        results.enumerateObjects { item, _, _ in
          entries.append(NativeDeviceAsset(
            id: item.localIdentifier,
            date: item.creationDate ?? .distantPast,
            isVideo: item.mediaType == .video,
            isLivePhoto: item.mediaSubtypes.contains(.photoLive),
            contentVersion: Int((item.modificationDate?.timeIntervalSince1970 ?? 0) * 1000),
            isFavorite: item.isFavorite
          ))
        }
        let collections = PHAssetCollection.fetchAssetCollections(with: .album, subtype: .any, options: nil)
        var localAlbums: [NativeDeviceAlbum] = []
        collections.enumerateObjects { collection, _, _ in
          let count = PHAsset.fetchAssets(in: collection, options: nil).count
          localAlbums.append(NativeDeviceAlbum(id: collection.localIdentifier, name: collection.localizedTitle ?? "未命名", count: count))
        }
        localAlbums.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        return (entries, localAlbums)
      }.value
      guard let self, self.refreshGeneration == generation else { return }
      await MainActor.run {
        guard self.refreshGeneration == generation else { return }
        let currentStatus = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        guard currentStatus == .authorized || currentStatus == .limited else {
          self.refresh()
          return
        }
        self.assets = library.0
        self.albums = library.1
        NativePhotoSnapshotStore.shared.saveDevice(NativeDeviceSnapshot(
          assets: library.0, albums: library.1
        ), expectedIdentity: self.accountIdentity)
        self.isLoading = false
        self.hasLoadedInitialSnapshot = true
        self.hasCompletedLiveRefresh = true
      }
    }
  }

  func assets(in album: NativeDeviceAlbum) -> [NativeDeviceAsset] {
    guard let collection = PHAssetCollection.fetchAssetCollections(withLocalIdentifiers: [album.id], options: nil).firstObject else { return [] }
    let results = PHAsset.fetchAssets(in: collection, options: nil)
    let ids = Set((0..<results.count).map { results.object(at: $0).localIdentifier })
    return assets.filter { ids.contains($0.id) }
  }

  func firstAsset(in album: NativeDeviceAlbum) -> NativeDeviceAsset? {
    guard let collection = PHAssetCollection.fetchAssetCollections(withLocalIdentifiers: [album.id], options: nil).firstObject else { return nil }
    let options = PHFetchOptions()
    options.fetchLimit = 1
    options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
    let results = PHAsset.fetchAssets(in: collection, options: options)
    guard let first = results.firstObject else { return nil }
    return assets.first { $0.id == first.localIdentifier } ?? NativeDeviceAsset(
      id: first.localIdentifier,
      date: first.creationDate ?? .distantPast,
      isVideo: first.mediaType == .video,
      isLivePhoto: first.mediaSubtypes.contains(.photoLive),
      contentVersion: Int((first.modificationDate?.timeIntervalSince1970 ?? 0) * 1000),
      isFavorite: first.isFavorite
    )
  }

  func createAlbum(named name: String) async -> Bool {
    guard authorized else { return false }
    return await withCheckedContinuation { continuation in
      PHPhotoLibrary.shared().performChanges({
        PHAssetCollectionChangeRequest.creationRequestForAssetCollection(withTitle: name)
      }) { [weak self] success, _ in
        if success {
          DispatchQueue.main.async {
            self?.refresh()
          }
        }
        continuation.resume(returning: success)
      }
    }
  }

  func deleteAlbums(ids: [String]) async -> Bool {
    guard authorized, !ids.isEmpty else { return false }
    return await withCheckedContinuation { continuation in
      let collections = PHAssetCollection.fetchAssetCollections(withLocalIdentifiers: ids, options: nil)
      guard collections.count > 0 else {
        continuation.resume(returning: true)
        return
      }
      PHPhotoLibrary.shared().performChanges({
        PHAssetCollectionChangeRequest.deleteAssetCollections(collections)
      }) { [weak self] success, _ in
        if success {
          DispatchQueue.main.async {
            self?.refresh()
          }
        }
        continuation.resume(returning: success)
      }
    }
  }

  func deleteAssets(ids: [String]) async -> Bool {
    guard authorized, !ids.isEmpty else { return false }
    return await withCheckedContinuation { continuation in
      let fetch = PHAsset.fetchAssets(withLocalIdentifiers: ids, options: nil)
      guard fetch.count == ids.count else {
        continuation.resume(returning: false)
        return
      }
      PHPhotoLibrary.shared().performChanges({
        PHAssetChangeRequest.deleteAssets(fetch)
      }) { [weak self] success, _ in
        if success {
          DispatchQueue.main.async {
            self?.refresh()
          }
        }
        continuation.resume(returning: success)
      }
    }
  }

  func updateFavorite(ids: [String], isFavorite: Bool) async -> Bool {
    guard authorized, !ids.isEmpty else { return false }
    return await withCheckedContinuation { continuation in
      let assets = PHAsset.fetchAssets(withLocalIdentifiers: ids, options: nil)
      guard assets.count == ids.count else {
        continuation.resume(returning: false)
        return
      }
      PHPhotoLibrary.shared().performChanges({
        assets.enumerateObjects { asset, _, _ in
          PHAssetChangeRequest(for: asset).isFavorite = isFavorite
        }
      }) { [weak self] success, _ in
        if success { DispatchQueue.main.async { self?.refresh() } }
        continuation.resume(returning: success)
      }
    }
  }

  func addAssets(_ assetIDs: [String], toAlbum albumID: String) async -> Bool {
    guard authorized, !assetIDs.isEmpty,
          let collection = PHAssetCollection.fetchAssetCollections(withLocalIdentifiers: [albumID], options: nil).firstObject else { return false }
    let assets = PHAsset.fetchAssets(withLocalIdentifiers: assetIDs, options: nil)
    guard assets.count == assetIDs.count else { return false }
    return await withCheckedContinuation { continuation in
      PHPhotoLibrary.shared().performChanges({
        guard let request = PHAssetCollectionChangeRequest(for: collection) else { return }
        request.addAssets(assets)
      }) { [weak self] success, _ in
        if success { DispatchQueue.main.async { self?.refresh() } }
        continuation.resume(returning: success)
      }
    }
  }

  func saveFilesToPhotos(_ urls: [URL]) async -> (saved: Int, failed: Int) {
    guard authorized, !urls.isEmpty else { return (0, urls.count) }
    var saved = 0
    var failed = 0
    for url in urls {
      let success: Bool = await withCheckedContinuation { continuation in
        PHPhotoLibrary.shared().performChanges({
          let request = PHAssetCreationRequest.forAsset()
          if nativeIsVideoFile(url) {
            request.addResource(with: .video, fileURL: url, options: nil)
          } else {
            request.addResource(with: .photo, fileURL: url, options: nil)
          }
        }) { success, _ in
          continuation.resume(returning: success)
        }
      }
      if success { saved += 1 } else { failed += 1 }
    }
    refresh()
    return (saved, failed)
  }
}

struct NativeDeviceAsset: Identifiable, Sendable, Codable {
  let id: String
  let date: Date
  let isVideo: Bool
  var isLivePhoto: Bool = false
  let contentVersion: Int
  var isFavorite: Bool = false
}

struct NativeDeviceAlbum: Identifiable, Sendable, Codable {
  let id: String
  let name: String
  let count: Int
}

private enum NativeLocalThumbnailCache {
  static let images: NSCache<NSString, UIImage> = {
    let cache = NSCache<NSString, UIImage>()
    cache.countLimit = 1500
    cache.totalCostLimit = 160 * 1024 * 1024
    return cache
  }()
  static let manager = PHCachingImageManager()
}

struct NativeDeviceThumbnail: View {
  let asset: NativeDeviceAsset
  var columns: Int = 3
  @State private var image: UIImage?
  @State private var imageRequestID: PHImageRequestID?
  @State private var requestToken = UUID()

  var body: some View {
    Group {
      if let image { Image(uiImage: image).resizable().scaledToFill() }
      else { Rectangle().fill(Color(uiColor: .secondarySystemBackground)) }
    }
    .task(id: "\(asset.id):\(asset.contentVersion):\(targetDimension)") {
      cancelImageRequest()
      image = nil
      let token = requestToken
      let dim = targetDimension
      let key = NSString(string: "\(asset.id):\(asset.contentVersion):\(dim)")
      if let cached = NativeLocalThumbnailCache.images.object(forKey: key) {
        image = cached
        return
      }
      guard !Task.isCancelled else { return }
      guard let source = PHAsset.fetchAssets(
        withLocalIdentifiers: [asset.id], options: nil
      ).firstObject else {
        NativeBackgroundDiagnostics.shared.record(
          "本机缩略图", category: "缓存照片未在系统相册中找到"
        )
        return
      }
      let options = PHImageRequestOptions()
      options.isNetworkAccessAllowed = true
      options.deliveryMode = .opportunistic
      options.resizeMode = .fast
      let targetSize = CGSize(width: dim, height: dim)
      imageRequestID = NativeLocalThumbnailCache.manager.requestImage(
        for: source,
        targetSize: targetSize,
        contentMode: .aspectFill,
        options: options
      ) { result, info in
        guard info?[PHImageCancelledKey] as? Bool != true else { return }
        if let error = info?[PHImageErrorKey] as? Error {
          Task { @MainActor in
            NativeBackgroundDiagnostics.shared.record("本机缩略图", error: error)
          }
          return
        }
        guard let result else { return }
        Task { @MainActor in
          guard requestToken == token else { return }
          NativeLocalThumbnailCache.images.setObject(result, forKey: key, cost: Int(result.size.width * result.size.height * 4))
          image = result
        }
      }
      if Task.isCancelled && requestToken == token { cancelImageRequest() }
    }
    .onDisappear { cancelImageRequest() }
  }

  private func cancelImageRequest() {
    requestToken = UUID()
    if let imageRequestID { NativeLocalThumbnailCache.manager.cancelImageRequest(imageRequestID) }
    imageRequestID = nil
  }

  private var targetDimension: Int {
    if columns <= 2 {
      return 400
    } else if columns <= 4 {
      return 250
    } else if columns <= 7 {
      return 160
    } else {
      return 100
    }
  }
}

struct NativeDeviceGrid: View {
  let client: NativeImmichClient
  @ObservedObject var device: NativeDeviceLibrary
  let title: String
  let assets: [NativeDeviceAsset]
  @State private var columns: Int = 3
  @State private var gestureBaseColumns: Int? = nil
  @State private var selected: NativeGridItem?
  @State private var viewerSourceFrame: CGRect?
  @State private var positioned = false
  private let bottom = "device-bottom"

  private var deviceAssetGroups: [Date: [NativeDeviceAsset]] {
    var calendar = Calendar.autoupdatingCurrent
    calendar.timeZone = .autoupdatingCurrent
    return Dictionary(grouping: assets) { calendar.startOfDay(for: $0.date) }
  }

  var body: some View {
    ScrollViewReader { proxy in
      ScrollView {
        LazyVStack(alignment: .leading, spacing: 4) {
          let groups = deviceAssetGroups
          ForEach(groups.keys.sorted(), id: \.self) { day in
            VStack(alignment: .leading, spacing: 2) {
              Text(NativeImmichClient.formatChineseDate(day)).font(.headline).padding(.horizontal)
              let gridSpacing: CGFloat = columns > 7 ? 1 : 2
              LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: gridSpacing), count: columns), spacing: gridSpacing) {
                ForEach(groups[day] ?? []) { asset in
                  Color.clear
                    .aspectRatio(1, contentMode: .fit)
                    .overlay(
                      GeometryReader { geo in
                        Button {
                          viewerSourceFrame = geo.frame(in: .global)
                          selected = NativeGridItem(server: nil, local: asset)
                        } label: {
                          NativeDeviceThumbnail(asset: asset, columns: columns)
                            .frame(width: geo.size.width, height: geo.size.height)
                            .clipped()
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("设备照片，\(asset.date.formatted())")
                      }
                    )
                    .clipped()
                    .overlay(alignment: .bottomLeading) {
                      if asset.isVideo && columns <= 7 {
                        Image(systemName: "play.fill")
                          .font(.system(size: columns > 4 ? 7 : 11, weight: .bold))
                          .foregroundColor(.white).shadow(color: .black, radius: 2)
                          .padding(columns > 4 ? 1.5 : 3)
                          .allowsHitTesting(false)
                      }
                    }
                }
              }
            }
          }
          Color.clear.frame(height: 1).id(bottom)
        }
      }
      .simultaneousGesture(
        MagnificationGesture()
          .onChanged { value in
            let base = gestureBaseColumns ?? columns
            if gestureBaseColumns == nil {
              gestureBaseColumns = base
            }
            let deadzone: Double = 0.12
            var effectiveValue = value
            if value > 1.0 {
              if value < 1.0 + deadzone { return }
              effectiveValue = 1.0 + (value - 1.0 - deadzone)
            } else {
              if value > 1.0 - deadzone { return }
              effectiveValue = 1.0 - (1.0 - deadzone - value)
            }
            let delta: Double
            if effectiveValue >= 1.0 {
              delta = -(effectiveValue - 1.0) * 4.0
            } else {
              delta = (1.0 / max(0.08, effectiveValue) - 1.0) * 4.0
            }
            let target = min(15, max(1, Int(round(Double(base) + delta))))
            if target != columns {
              UIImpactFeedbackGenerator(style: .medium).impactOccurred()
              withAnimation(.spring(response: 0.28, dampingFraction: 0.82)) {
                columns = target
              }
            }
          }
          .onEnded { _ in
            gestureBaseColumns = nil
          }
      )
      .onChange(of: assets.count) { _ in
        guard !positioned, !assets.isEmpty else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
          withAnimation(.none) { proxy.scrollTo(bottom, anchor: .bottom) }
          positioned = true
        }
      }
      .onAppear {
        if !assets.isEmpty && !positioned {
          DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            withAnimation(.none) { proxy.scrollTo(bottom, anchor: .bottom) }
            positioned = true
          }
        }
      }
    }
    .fullScreenCover(item: $selected) { item in
      NativeUnifiedGalleryViewer(
        client: client,
        device: device,
        items: assets.map { NativeGridItem(server: nil, local: $0) },
        initialItem: item,
        sourceFrame: viewerSourceFrame,
        onDismissViewer: { selected = nil }
      )
    }
    .navigationTitle(title)
  }
}

struct NativeServerAlbum: Identifiable {
  let id: String
  let name: String
  let count: Int
  let thumbnailAssetId: String?
}

func nativePhotosExcludedAlbumIDs(from rawValue: String) -> Set<String> {
  guard let data = rawValue.data(using: .utf8),
        let ids = try? JSONDecoder().decode([String].self, from: data) else { return [] }
  return Set(ids)
}

func nativePhotosAlbumIDsString(_ ids: Set<String>) -> String {
  guard let data = try? JSONEncoder().encode(ids.sorted()),
        let value = String(data: data, encoding: .utf8) else { return "[]" }
  return value
}

func nativePhotosHiddenLocalAssetIDs(
  in albums: [NativeDeviceAlbum],
  excludedAlbumIDs: Set<String>,
  assetsForAlbum: (NativeDeviceAlbum) -> [NativeDeviceAsset]
) -> Set<String> {
  albums
    .filter { excludedAlbumIDs.contains($0.id) }
    .reduce(into: Set<String>()) { result, album in
      result.formUnion(assetsForAlbum(album).map(\.id))
    }
}

struct NativeSearchPage {
  let assets: [NativeAsset]
  let next: String?
}

struct NativeExploreSection: Identifiable {
  let id: String
  let items: [NativeExploreTile]
}

struct NativeExploreTile: Identifiable {
  let id: String
  let name: String
  let asset: NativeAsset?
}

extension NativeImmichClient {
  func searchPage(query: String? = nil, albumId: String? = nil, cursor: String? = nil, filter: [String: Any] = [:]) async throws -> NativeSearchPage {
    var terms = filter
    if let albumId { terms["albumIds"] = ["any": [albumId]] }
    if let query, !query.isEmpty {
      terms["or"] = [
        ["originalFileName": ["like": query]],
        ["originalPath": ["like": query]],
        ["description": ["like": query]],
      ]
    }
    var payload: [String: Any] = [
      "size": 100,
      "orderBy": ["field": "fileCreatedAt", "direction": "desc"],
    ]
    if !terms.isEmpty { payload["filter"] = terms }
    if terms["trashedAt"] != nil { payload["withDeleted"] = true }
    if let cursor { payload["cursor"] = cursor }
    let result = try await send(path: "search/metadata", method: "POST", body: payload)
    guard let page = result["assets"] as? [String: Any], let items = page["items"] as? [[String: Any]] else { throw NativeFeatureError.badResponse }
    return NativeSearchPage(assets: items.compactMap(Self.decodeAsset), next: page["nextCursor"] as? String)
  }

  func smartSearch(query: String, page: Int, filter: [String: Any]) async throws -> NativeSearchPage {
    var payload: [String: Any] = ["query": query, "page": page, "size": 100]
    if !filter.isEmpty { payload["filter"] = filter }
    let response = try await send(path: "search/smart", method: "POST", body: payload)
    guard let assets = response["assets"] as? [String: Any], let rows = assets["items"] as? [[String: Any]] else { throw NativeFeatureError.badResponse }
    let next: String?
    if let str = assets["nextPage"] as? String {
      next = str
    } else if let num = assets["nextPage"] as? NSNumber {
      next = num.stringValue
    } else if let cursor = assets["nextCursor"] as? String {
      next = cursor
    } else if rows.count >= 100 {
      next = "\(page + 1)"
    } else {
      next = nil
    }
    return NativeSearchPage(assets: rows.compactMap(Self.decodeAsset), next: next)
  }

  func explore() async throws -> [NativeExploreSection] {
    let rows = try await nativeArray(path: "search/explore")
    return rows.compactMap { row in
      guard let name = row["fieldName"] as? String, let items = row["items"] as? [[String: Any]] else { return nil }
      return NativeExploreSection(id: name, items: items.compactMap { item in
        guard let value = item["value"] as? String else { return nil }
        return NativeExploreTile(id: value, name: value, asset: (item["data"] as? [String: Any]).flatMap(Self.decodeAsset))
      })
    }
  }

  func nativeArray(path: String) async throws -> [[String: Any]] {
    let base = config.apiEndpoint ?? (NativeImmichClient.normalize(config.serverUrl) + "/api")
    guard let url = URL(string: base + "/" + path) else { throw NativeFeatureError.badResponse }
    var request = URLRequest(url: url)
    if let token = config.accessToken { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
    if let key = config.apiKey { request.setValue(key, forHTTPHeaderField: "x-api-key") }
    let (data, response) = try await URLSession.shared.data(for: request)
    guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { throw NativeFeatureError.badResponse }
    guard let rows = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { throw NativeFeatureError.badResponse }
    return rows
  }

  static func decodeAsset(_ item: [String: Any]) -> NativeAsset? {
    guard let id = item["id"] as? String else { return nil }
    let dateText = (item["localDateTime"] as? String) ?? (item["fileCreatedAt"] as? String) ?? ""
    let date = NativeImmichClient.parseISODate(dateText) ?? .distantPast
    let exif = item["exifInfo"] as? [String: Any] ?? [:]
    let visibility = item["visibility"] as? String ?? "timeline"
    return NativeAsset(
      id: id,
      date: date,
      isImage: (item["type"] as? String) != "VIDEO",
      isFavorite: item["isFavorite"] as? Bool ?? false,
      thumbhash: item["thumbhash"] as? String,
      livePhotoVideoId: item["livePhotoVideoId"] as? String,
      originalFileName: item["originalFileName"] as? String,
      originalMimeType: item["originalMimeType"] as? String,
      width: item["width"] as? Int,
      height: item["height"] as? Int,
      fileSizeInByte: (exif["fileSizeInByte"] as? NSNumber)?.int64Value,
      latitude: (exif["latitude"] as? NSNumber)?.doubleValue,
      longitude: (exif["longitude"] as? NSNumber)?.doubleValue,
      isArchived: visibility.lowercased() == "archive"
    )
  }

  func serverAlbums() async throws -> [NativeServerAlbum] {
    let rows = try await nativeArray(path: "albums")
    return rows.compactMap { row in
      guard let id = row["id"] as? String, let name = row["albumName"] as? String else { return nil }
      let thumbId = row["albumThumbnailAssetId"] as? String
      return NativeServerAlbum(id: id, name: name, count: row["assetCount"] as? Int ?? 0, thumbnailAssetId: thumbId)
    }
  }

  func assetIDs(inServerAlbum albumID: String) async throws -> Set<String> {
    var assetIDs = Set<String>()
    var cursor: String?
    var visitedCursors = Set<String>()
    while true {
      let page = try await searchPage(albumId: albumID, cursor: cursor)
      assetIDs.formUnion(page.assets.map(\.id))
      guard let next = page.next, next != cursor, visitedCursors.insert(next).inserted else { break }
      cursor = next
    }
    return assetIDs
  }
}

private enum NativeFeatureError: LocalizedError {
  case badResponse
  var errorDescription: String? { "服务器返回了无法识别的数据。" }
}

@MainActor
private final class NativeResultsModel: ObservableObject {
  @Published var assets: [NativeAsset] = []
  @Published var loading = false
  @Published var error: String?
  @Published var next: String?
  private var cursors = Set<String>()
  private var smartPage = 1
  private let client: NativeImmichClient
  init(_ client: NativeImmichClient) { self.client = client }

  func load(query: String? = nil, albumId: String? = nil, filter: [String: Any] = [:], reset: Bool = false) async {
    guard !loading else { return }
    if reset { assets = []; next = nil; cursors = []; smartPage = 1 }
    else if !assets.isEmpty && next == nil { return }
    if let next, !cursors.insert(next).inserted { self.next = nil; return }
    loading = true
    error = nil
    defer { loading = false }
    do {
      let page = try await client.searchPage(query: query, albumId: albumId, cursor: next, filter: filter)
      var ids = Set(assets.map(\.id))
      assets += page.assets.filter { ids.insert($0.id).inserted }
      next = page.assets.isEmpty || page.next == next ? nil : page.next
    } catch {
      if let next { cursors.remove(next) }
      self.error = error.localizedDescription
    }
  }

  func clear() { assets = []; next = nil; smartPage = 1; cursors = [] }

  func smart(query: String, filter: [String: Any] = [:], reset: Bool = false) async {
    guard !loading else { return }
    if reset { assets = []; next = nil; smartPage = 1 }
    else if !assets.isEmpty && next == nil { return }
    loading = true
    error = nil
    defer { loading = false }
    do {
      let response = try await client.smartSearch(query: query, page: smartPage, filter: filter)
      var ids = Set(assets.map(\.id))
      assets += response.assets.filter { ids.insert($0.id).inserted }
      next = response.next
      if next != nil { smartPage += 1 }
    } catch { self.error = error.localizedDescription }
  }
}

func nativeSortedResultDays(_ days: [Date], oldestFirst: Bool) -> [Date] {
  days.sorted { oldestFirst ? $0 < $1 : $0 > $1 }
}

struct NativeResultGrid: View {
  let client: NativeImmichClient
  let assets: [NativeAsset]
  var localAssets: [NativeDeviceAsset] = []
  let hasOlder: Bool
  var startsAtLatest = false
  var initialPositionReady = true
  var isSelectingBinding: Binding<Bool>? = nil
  var selectedIDsBinding: Binding<Set<String>>? = nil
  let loadMore: () -> Void

  @State private var internalIsSelecting = false
  @State private var internalSelectedIDs: Set<String> = []

  @State private var isDragSelecting = false
  @State private var dragSelectionIntent: NativeDragSelectionIntent = .undecided
  @State private var longPressDragIntent: NativeDragSelectionIntent = .undecided
  @State private var isMagnifying = false
  @State private var columns: Int = 4
  @State private var gestureBaseColumns: Int? = nil

  @State private var dragInitialSelectedIDs: Set<String> = []
  @State private var dragSelectMode: Bool = true
  @State private var dragStartLocation: CGPoint? = nil
  @State private var dragStartAssetID: String? = nil
  @State private var itemBounds: [String: CGRect] = [:]

  @State private var activeViewerItem: NativeGridItem?
  @State private var viewerSourceFrame: CGRect?
  @State private var userMovedGrid = false
  @State private var bottomPositionTask: Task<Void, Never>?

  private let bottomAnchor = "result-grid-bottom"

  private var isSelecting: Bool {
    isSelectingBinding?.wrappedValue ?? internalIsSelecting
  }

  private var selectedIDs: Set<String> {
    selectedIDsBinding?.wrappedValue ?? internalSelectedIDs
  }

  private func setIsSelecting(_ value: Bool) {
    if let binding = isSelectingBinding {
      binding.wrappedValue = value
    } else {
      internalIsSelecting = value
    }
  }

  private func setSelectedIDs(_ value: Set<String>) {
    if let binding = selectedIDsBinding {
      binding.wrappedValue = value
    } else {
      internalSelectedIDs = value
    }
  }

  init(
    client: NativeImmichClient,
    assets: [NativeAsset],
    localAssets: [NativeDeviceAsset] = [],
    hasOlder: Bool,
    startsAtLatest: Bool = false,
    initialPositionReady: Bool = true,
    isSelecting: Binding<Bool>? = nil,
    selectedIDs: Binding<Set<String>>? = nil,
    loadMore: @escaping () -> Void
  ) {
    self.client = client
    self.assets = assets
    self.localAssets = localAssets
    self.hasOlder = hasOlder
    self.startsAtLatest = startsAtLatest
    self.initialPositionReady = initialPositionReady
    self.isSelectingBinding = isSelecting
    self.selectedIDsBinding = selectedIDs
    self.loadMore = loadMore
  }

  private var merged: [NativeGridItem] {
    let matched = NativeSyncCacheStore.shared.matchedServerIDs
    let serverById = Dictionary(assets.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })

    var usedServerIDs = Set<String>()
    var items: [NativeGridItem] = []
    items.reserveCapacity(assets.count + localAssets.count)

    let unmatchedServers = assets.filter { !matched.values.contains($0.id) }
    let serverBySec = nativeIndexAssetsBySecond(unmatchedServers)

    for localAsset in localAssets {
      if let serverID = matched[localAsset.id], let serverAsset = serverById[serverID] {
        items.append(NativeGridItem(server: serverAsset, local: localAsset))
        usedServerIDs.insert(serverAsset.id)
      } else if let heuristicServer = nativeFindHeuristicServerMatch(local: localAsset, serverBySecond: serverBySec, usedServerIDs: usedServerIDs) {
        items.append(NativeGridItem(server: heuristicServer, local: localAsset))
        usedServerIDs.insert(heuristicServer.id)
      } else {
        items.append(NativeGridItem(server: nil, local: localAsset))
      }
    }

    for serverAsset in assets {
      if !usedServerIDs.contains(serverAsset.id) {
        items.append(NativeGridItem(server: serverAsset, local: nil))
      }
    }

    return items.sorted { $0.date == $1.date ? $0.id < $1.id : $0.date < $1.date }
  }

  private var mergedGroups: [Date: [NativeGridItem]] {
    var calendar = Calendar.autoupdatingCurrent
    calendar.timeZone = .autoupdatingCurrent
    return Dictionary(grouping: merged) { calendar.startOfDay(for: $0.date) }
  }

  var body: some View {
    ScrollViewReader { scrollProxy in
      ScrollView {
        LazyVStack(spacing: 4) {
          if startsAtLatest && hasOlder && !assets.isEmpty {
            Button("加载更早照片", action: loadMore)
              .frame(maxWidth: .infinity).padding(16)
          }
          ForEach(
            nativeSortedResultDays(Array(mergedGroups.keys), oldestFirst: startsAtLatest),
            id: \.self
          ) { day in
          VStack(alignment: .leading, spacing: 2) {
            Text(NativeImmichClient.formatChineseDate(day)).font(.headline).frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal)
            let gridSpacing: CGFloat = columns > 7 ? 1 : 2
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: gridSpacing), count: columns), spacing: gridSpacing) {
              ForEach(mergedGroups[day] ?? []) { entry in
                ZStack(alignment: .topTrailing) {
                  Color.clear
                    .aspectRatio(1, contentMode: .fit)
                    .overlay(
                      GeometryReader { geo in
                        Group {
                          if let asset = entry.server { NativeThumbnail(client: client, asset: asset, columns: columns) }
                          else if let asset = entry.local { NativeDeviceThumbnail(asset: asset, columns: columns) }
                        }
                        .frame(width: geo.size.width, height: geo.size.height)
                        .clipped()
                        .contentShape(Rectangle())
                        .onTapGesture {
                          guard !isMagnifying else { return }
                          if isSelecting {
                            toggleSelection(entry.id)
                          } else {
                            viewerSourceFrame = geo.frame(in: .global)
                            activeViewerItem = entry
                          }
                        }
                        .preference(key: NativeItemFramePreferenceKey.self, value: [entry.id: geo.frame(in: .named("resultGridScrollSpace"))])
                      }
                    )
                    .clipped()
                    .overlay(alignment: .bottomLeading) {
                      if entry.isVideo && columns <= 7 {
                        Image(systemName: "play.fill")
                          .font(.system(size: columns > 4 ? 7 : 11, weight: .bold))
                          .foregroundColor(.white).shadow(color: .black, radius: 2)
                          .padding(columns > 4 ? 1.5 : 3)
                      }
                    }
                    .overlay(alignment: .bottomTrailing) {
                      if columns <= 7 {
                        Image(systemName: entry.cloudSymbol())
                          .font(.system(size: columns > 4 ? 7 : 13, weight: .semibold))
                          .foregroundColor(.white).shadow(color: .black, radius: 2)
                          .padding(columns > 4 ? 1.5 : 3)
                          .allowsHitTesting(false)
                          .allowsHitTesting(false)
                      }
                    }

                  if isSelecting {
                    ZStack {
                      Circle()
                        .fill(selectedIDs.contains(entry.id) ? Color.blue : Color.black.opacity(0.35))
                        .frame(width: 22, height: 22)
                      if selectedIDs.contains(entry.id) {
                        Image(systemName: "checkmark")
                          .font(.system(size: 11, weight: .bold))
                          .foregroundColor(.white)
                      } else {
                        Circle()
                          .stroke(Color.white, lineWidth: 1.5)
                          .frame(width: 20, height: 20)
                      }
                    }
                    .padding(columns > 4 ? 2 : 4)
                    .allowsHitTesting(false)
                  }
                }
                .contentShape(Rectangle())
                .onLongPressGesture(minimumDuration: 0.28, maximumDistance: 15) {
                  guard !isMagnifying else { return }
                  if !isSelecting {
                    enterSelection(startingWith: entry.id)
                  } else {
                    startDragSelectionInSelectMode(startingWith: entry.id)
                  }
                }
                .simultaneousGesture(
                  DragGesture(minimumDistance: 4, coordinateSpace: .named("resultGridScrollSpace"))
                    .onChanged { drag in
                      guard isSelecting, !isMagnifying else { return }
                      if dragSelectionIntent == .undecided {
                        let intent = nativeDragSelectionIntent(for: drag.translation)
                        if intent != .undecided { dragSelectionIntent = intent }
                      }
                      guard dragSelectionIntent == .select else { return }
                      if !isDragSelecting {
                        guard let hitID = itemBounds.first(where: { $0.value.contains(drag.startLocation) })?.key else { return }
                        isDragSelecting = true
                        startDragSelectionInSelectMode(startingWith: hitID, at: drag.startLocation)
                      }
                      handle2DDragSelection(at: drag.location)
                    }
                    .onEnded { _ in
                      isDragSelecting = false
                      dragSelectionIntent = .undecided
                      finishDragSelection()
                    }
                )
                .id(entry.id)
              }
            }
          }
        }
          if !startsAtLatest && hasOlder && !assets.isEmpty {
            ProgressView().frame(maxWidth: .infinity).padding(16)
              .onAppear { loadMore() }
          }
          if startsAtLatest {
            Color.clear.frame(maxWidth: .infinity).frame(height: 1)
              .id(bottomAnchor)
          }
        }
      }
      .onAppear { positionAtLatest(proxy: scrollProxy) }
      .onChange(of: initialPositionReady) { _ in
        positionAtLatest(proxy: scrollProxy)
      }
      .onChange(of: merged.last?.id) { _ in
        positionAtLatest(proxy: scrollProxy)
      }
      .onChange(of: merged.count) { _ in
        positionAtLatest(proxy: scrollProxy)
      }
      .simultaneousGesture(
        DragGesture(minimumDistance: 20)
          .onChanged { drag in
            guard startsAtLatest, !isSelecting,
                  abs(drag.translation.height) > 25 else { return }
            userMovedGrid = true
            bottomPositionTask?.cancel()
          }
      )
    }
    .onDisappear { bottomPositionTask?.cancel() }
    .coordinateSpace(name: "resultGridScrollSpace")
    .nativeScrollDisabled(isDragSelecting)
    .onPreferenceChange(NativeItemFramePreferenceKey.self) { frames in
      itemBounds = frames
    }
    .simultaneousGesture(
      LongPressGesture(minimumDuration: 0.28, maximumDistance: 15)
        .sequenced(before: DragGesture(coordinateSpace: .named("resultGridScrollSpace")))
        .onChanged { value in
          guard !isMagnifying else { return }
          switch value {
          case .first:
            break
          case .second(true, let drag):
            if let drag = drag, longPressDragIntent == .undecided {
              let intent = nativeDragSelectionIntent(for: drag.translation)
              if intent != .undecided { longPressDragIntent = intent }
            }
            guard longPressDragIntent == .select else { break }
            if !isDragSelecting {
              isDragSelecting = true
              let loc = drag?.startLocation ?? drag?.location
              if let loc = loc,
                 let hitID = itemBounds.first(where: { $0.value.contains(loc) })?.key {
                if !isSelecting {
                  enterSelection(startingWith: hitID, at: loc)
                } else {
                  startDragSelectionInSelectMode(startingWith: hitID, at: loc)
                }
              }
            }
            if let drag = drag {
              handle2DDragSelection(at: drag.location)
            }
          default:
            break
          }
        }
        .onEnded { _ in
          isDragSelecting = false
          longPressDragIntent = .undecided
          finishDragSelection()
        }
    )
    .simultaneousGesture(
      MagnificationGesture()
        .onChanged { value in
          guard !isSelecting else { return }
          if !isMagnifying {
            isMagnifying = true
          }
          let base = gestureBaseColumns ?? columns
          if gestureBaseColumns == nil {
            gestureBaseColumns = base
          }
          let deadzone: Double = 0.12
          var effectiveValue = value
          if value > 1.0 {
            if value < 1.0 + deadzone { return }
            effectiveValue = 1.0 + (value - 1.0 - deadzone)
          } else {
            if value > 1.0 - deadzone { return }
            effectiveValue = 1.0 - (1.0 - deadzone - value)
          }
          let delta: Double
          if effectiveValue >= 1.0 {
            delta = -(effectiveValue - 1.0) * 4.0
          } else {
            delta = (1.0 / max(0.08, effectiveValue) - 1.0) * 4.0
          }
          let target = min(15, max(1, Int(round(Double(base) + delta))))
          if target != columns {
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            withAnimation(.spring(response: 0.28, dampingFraction: 0.82)) {
              columns = target
            }
          }
        }
        .onEnded { _ in
          gestureBaseColumns = nil
          DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            isMagnifying = false
          }
        }
    )
    .fullScreenCover(item: $activeViewerItem) { item in
      NativeUnifiedGalleryViewer(
        client: client,
        device: NativeDeviceLibrary(),
        items: merged,
        initialItem: item,
        sourceFrame: viewerSourceFrame,
        onDismissViewer: { activeViewerItem = nil }
      )
    }
  }

  private func positionAtLatest(proxy: ScrollViewProxy) {
    guard startsAtLatest, initialPositionReady, !userMovedGrid,
          !merged.isEmpty else { return }
    bottomPositionTask?.cancel()
    bottomPositionTask = Task { @MainActor in
      for delay in [0, 60, 180, 350, 700] {
        if delay > 0 {
          try? await Task.sleep(nanoseconds: UInt64(delay) * 1_000_000)
        }
        guard !Task.isCancelled, !userMovedGrid else { return }
        withAnimation(.none) {
          proxy.scrollTo(bottomAnchor, anchor: .bottom)
        }
      }
      bottomPositionTask = nil
    }
  }

  private func enterSelection(startingWith id: String, at location: CGPoint? = nil) {
    guard !isSelecting else { return }
    UIImpactFeedbackGenerator(style: .heavy).impactOccurred()
    setIsSelecting(true)
    dragStartAssetID = id
    let startLoc = location ?? itemBounds[id].map { CGPoint(x: $0.midX, y: $0.midY) }
    dragStartLocation = startLoc
    dragInitialSelectedIDs = selectedIDs
    let alreadySelected = selectedIDs.contains(id)
    dragSelectMode = !alreadySelected
    var updated = selectedIDs
    if dragSelectMode {
      updated.insert(id)
    } else {
      updated.remove(id)
    }
    setSelectedIDs(updated)
  }

  private func startDragSelectionInSelectMode(startingWith id: String, at location: CGPoint? = nil) {
    guard dragStartAssetID != id || dragStartLocation == nil else { return }
    UIImpactFeedbackGenerator(style: .heavy).impactOccurred()
    dragStartAssetID = id
    let startLoc = location ?? itemBounds[id].map { CGPoint(x: $0.midX, y: $0.midY) }
    dragStartLocation = startLoc
    dragInitialSelectedIDs = selectedIDs
    let alreadySelected = selectedIDs.contains(id)
    dragSelectMode = !alreadySelected
    var updated = selectedIDs
    if dragSelectMode {
      updated.insert(id)
    } else {
      updated.remove(id)
    }
    setSelectedIDs(updated)
  }

  private func handle2DDragSelection(at location: CGPoint) {
    guard isSelecting else { return }
    if dragStartLocation == nil {
      dragStartLocation = location
      dragInitialSelectedIDs = selectedIDs
      if let hitID = itemBounds.first(where: { $0.value.contains(location) })?.key {
        dragStartAssetID = hitID
        dragSelectMode = !selectedIDs.contains(hitID)
      } else {
        dragSelectMode = true
      }
    }

    let startLoc = dragStartLocation ?? location
    let minX = min(startLoc.x, location.x)
    let minY = min(startLoc.y, location.y)
    let maxX = max(startLoc.x, location.x)
    let maxY = max(startLoc.y, location.y)

    let selectionRect = CGRect(
      x: minX,
      y: minY,
      width: max(maxX - minX, 6),
      height: max(maxY - minY, 6)
    )

    var itemsInRect = Set<String>()
    for (id, frame) in itemBounds {
      if frame.intersects(selectionRect) {
        itemsInRect.insert(id)
      }
    }
    if let startID = dragStartAssetID {
      itemsInRect.insert(startID)
    }

    var updated = dragInitialSelectedIDs
    if dragSelectMode {
      updated.formUnion(itemsInRect)
    } else {
      updated.subtract(itemsInRect)
    }

    if updated != selectedIDs {
      UIImpactFeedbackGenerator(style: .light).impactOccurred()
      setSelectedIDs(updated)
    }
  }

  private func finishDragSelection() {
    dragStartLocation = nil
    dragStartAssetID = nil
    dragInitialSelectedIDs.removeAll()
  }

  private func toggleSelection(_ id: String) {
    UIImpactFeedbackGenerator(style: .light).impactOccurred()
    var updated = selectedIDs
    if updated.contains(id) {
      updated.remove(id)
    } else {
      updated.insert(id)
    }
    setSelectedIDs(updated)
  }
}

enum NativeAssetState {
  case local
  case remote
  case merged
  case unknown
}

enum NativeDeleteTargetScope {
  case all
  case localOnly
}

// A partial deletion keeps the other copy on the very same viewer page.
func nativeViewerRemainingCopy(of item: NativeGridItem, after scope: NativeDeleteTargetScope) -> NativeGridItem? {
  switch scope {
  case .all: return nil
  case .localOnly: return item.server.map { NativeGridItem(server: $0, local: nil) }
  }
}

enum NativeDeleteOperationError: LocalizedError {
  case partial(failures: [String], deletedServerIDs: Set<String>)

  var deletedServerIDs: Set<String> {
    switch self {
    case .partial(_, let ids): return ids
    }
  }

  var errorDescription: String? {
    switch self {
    case .partial(let failures, _): return "部分删除未成功：\(failures.joined(separator: "；"))"
    }
  }
}

@MainActor
func nativeDeleteGridItems(
  _ items: [NativeGridItem],
  scope: NativeDeleteTargetScope = .all,
  client: NativeImmichClient,
  device: NativeDeviceLibrary
) async throws {
  var serverIDs: [String] = []
  var localIDs: [String] = []

  for item in items {
    switch scope {
    case .all:
      if let sid = item.server?.id { serverIDs.append(sid) }
      if let lid = item.local?.id { localIDs.append(lid) }
    case .localOnly:
      if let lid = item.local?.id { localIDs.append(lid) }
    }
  }

  let uniqueServerIDs = Array(Set(serverIDs)).sorted()
  let uniqueLocalIDs = Array(Set(localIDs)).sorted()
  var failures = [String]()
  var deletedServerIDs = Set<String>()

  if !uniqueServerIDs.isEmpty {
    do {
      try await client.deleteAssets(ids: uniqueServerIDs)
      deletedServerIDs = Set(uniqueServerIDs)
    } catch { failures.append("云端：\(error.localizedDescription)") }
  }
  // If the cloud step failed, do not proceed with local deletion. Leaving
  // both copies intact is safer than destroying the last usable original.
  if failures.isEmpty, !uniqueLocalIDs.isEmpty, !(await device.deleteAssets(ids: uniqueLocalIDs)) {
    failures.append("本机：照片权限不足或系统删除失败")
  }
  if !failures.isEmpty { throw NativeDeleteOperationError.partial(failures: failures, deletedServerIDs: deletedServerIDs) }
}

struct NativeGridItem: Identifiable {
  let server: NativeAsset?
  let local: NativeDeviceAsset?

  var id: String {
    if let local { return "local:\(local.id)" }
    if let server, let localID = NativeSyncCacheStore.shared.localID(for: server.id) {
      return "local:\(localID)"
    }
    return "server:\(server?.id ?? "")"
  }

  var isFavorite: Bool { server?.isFavorite ?? local?.isFavorite ?? false }

  var date: Date { server?.date ?? local?.date ?? .distantPast }

  var isVideo: Bool {
    if let server { return !server.isImage }
    if let local { return local.isVideo }
    return false
  }

  var state: NativeAssetState {
    if let local {
      if server != nil || NativeSyncCacheStore.shared.isMatched(localId: local.id) { return .merged }
      if NativeSyncCacheStore.shared.checkedIDs.contains(local.id) { return .local }
      return .unknown
    }
    return .remote
  }

  func cloudSymbol(
    matchedServerIDs: [String: String] = NativeSyncCacheStore.shared.matchedServerIDs,
    checkedIDs: Set<String> = NativeSyncCacheStore.shared.checkedIDs
  ) -> String {
    if let local {
      if server != nil || matchedServerIDs[local.id] != nil { return "checkmark.icloud" }
      return checkedIDs.contains(local.id) ? "icloud.slash" : "questionmark.icloud"
    }
    return "cloud"
  }
}

final class NativeRecentSearchesStore {
  static let shared = NativeRecentSearchesStore()
  private let userDefaults: UserDefaults
  private let storageKey: String
  private let maxCount: Int

  init(userDefaults: UserDefaults = .standard, storageKey: String = "immich_device_recent_searches", maxCount: Int = 15) {
    self.userDefaults = userDefaults
    self.storageKey = storageKey
    self.maxCount = maxCount
  }

  func load() -> [String] {
    userDefaults.stringArray(forKey: storageKey) ?? []
  }

  func add(_ query: String) {
    let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return }
    var current = load()
    current.removeAll { $0.caseInsensitiveCompare(trimmed) == .orderedSame }
    current.insert(trimmed, at: 0)
    if current.count > maxCount {
      current = Array(current.prefix(maxCount))
    }
    userDefaults.set(current, forKey: storageKey)
  }

  func remove(_ query: String) {
    var current = load()
    current.removeAll { $0 == query }
    userDefaults.set(current, forKey: storageKey)
  }

  func clear() {
    userDefaults.removeObject(forKey: storageKey)
  }
}

enum NativeSearchAlbumFilter: Hashable, Identifiable {
  case all
  case server(id: String, name: String)
  case local(id: String, name: String)

  var id: String {
    switch self {
    case .all: return "all"
    case .server(let id, _): return "server:\(id)"
    case .local(let id, _): return "local:\(id)"
    }
  }

  var displayName: String {
    switch self {
    case .all: return "全部相册"
    case .server(_, let name): return "\(name) (云端)"
    case .local(_, let name): return "\(name) (本机)"
    }
  }

  var shortName: String {
    switch self {
    case .all: return "全部相册"
    case .server(_, let name): return name
    case .local(_, let name): return name
    }
  }

  var isLocal: Bool {
    if case .local = self { return true }
    return false
  }

  var isServer: Bool {
    if case .server = self { return true }
    return false
  }
}

final class NativeLocalAssetFilenameCache {
  static let shared = NativeLocalAssetFilenameCache()
  private var cache: [String: String] = [:]
  private let lock = NSLock()

  func filename(for localID: String) -> String? {
    lock.lock()
    if let cached = cache[localID] {
      lock.unlock()
      return cached
    }
    lock.unlock()

    guard let phAsset = PHAsset.fetchAssets(withLocalIdentifiers: [localID], options: nil).firstObject else {
      return nil
    }
    let name = (phAsset.value(forKey: "filename") as? String)
      ?? PHAssetResource.assetResources(for: phAsset).first?.originalFilename

    if let name {
      lock.lock()
      cache[localID] = name
      lock.unlock()
    }
    return name
  }

  func clear() {
    lock.lock()
    cache.removeAll()
    lock.unlock()
  }
}

func nativeFilterLocalAssets(
  assets: [NativeDeviceAsset],
  query: String?,
  filterPhotos: Bool,
  filterVideos: Bool,
  favoritesOnly: Bool,
  useAfter: Bool,
  after: Date,
  useBefore: Bool,
  before: Date,
  allowedLocalAssetIDs: Set<String>? = nil,
  filenameLookup: ((String) -> String?)? = nil
) -> [NativeDeviceAsset] {
  guard filterPhotos || filterVideos else { return [] }

  let trimmedQuery = query?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
  let hasQuery = trimmedQuery != nil && !trimmedQuery!.isEmpty

  var calendar = Calendar.autoupdatingCurrent
  calendar.timeZone = .autoupdatingCurrent
  let startAfter = useAfter ? calendar.startOfDay(for: after) : nil
  let endBefore = useBefore ? (calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: before)) ?? before) : nil

  let lookup = filenameLookup ?? { NativeLocalAssetFilenameCache.shared.filename(for: $0) }

  return assets.filter { asset in
    // Media type filter
    if asset.isVideo && !filterVideos { return false }
    if !asset.isVideo && !filterPhotos { return false }

    // Favorites filter
    if favoritesOnly && !asset.isFavorite { return false }

    // Date filters
    if let startAfter, asset.date < startAfter { return false }
    if let endBefore, asset.date > endBefore { return false }

    // Album filter
    if let allowedIDs = allowedLocalAssetIDs, !allowedIDs.contains(asset.id) {
      return false
    }

    // Query filter (filename or formatted date match)
    if let q = trimmedQuery, hasQuery {
      if let fname = lookup(asset.id)?.lowercased(), fname.contains(q) {
        return true
      }
      let dateString = NativeImmichClient.formatChineseDate(asset.date)
      if dateString.contains(q) {
        return true
      }
      return false
    }

    return true
  }
}

func nativeFilterSearchResultsBySource(
  source: NativePhotosSource,
  serverAssets: [NativeAsset],
  localAssets: [NativeDeviceAsset],
  matchedServerIDs: [String: String]
) -> (server: [NativeAsset], local: [NativeDeviceAsset]) {
  switch source {
  case .all:
    return (serverAssets, localAssets)
  case .device:
    let localIDs = Set(localAssets.map(\.id))
    let matchedServerIDSet = Set(matchedServerIDs.filter { localIDs.contains($0.key) }.values)
    let filteredServer = serverAssets.filter { matchedServerIDSet.contains($0.id) }
    return (filteredServer, localAssets)
  case .server:
    let serverIDSet = Set(serverAssets.map(\.id))
    let localIDsWithServerMatch = Set(matchedServerIDs.compactMap { localID, serverID in
      serverIDSet.contains(serverID) ? localID : nil
    })
    let filteredLocal = localAssets.filter { localIDsWithServerMatch.contains($0.id) }
    return (serverAssets, filteredLocal)
  }
}

func nativeShouldAcceptSearchResult(requestGeneration: Int, currentGeneration: Int) -> Bool {
  requestGeneration == currentGeneration
}

func nativeDeduplicateServerAssets(existing: [NativeAsset], incoming: [NativeAsset]) -> [NativeAsset] {
  var seen = Set(existing.map(\.id))
  var result = existing
  for asset in incoming {
    if seen.insert(asset.id).inserted {
      result.append(asset)
    }
  }
  return result
}

@MainActor
final class NativeUnifiedSearchModel: ObservableObject {
  @Published var serverAssets: [NativeAsset] = []
  @Published var localAssets: [NativeDeviceAsset] = []
  @Published var loading = false
  @Published var serverError: String?
  @Published var smartSearchDegraded = false
  @Published var smartErrorMessage: String?
  @Published var hasMore = false
  @Published var hasLoaded = false

  private let client: NativeImmichClient
  private(set) var currentGeneration = 0
  private var metadataCursor: String?
  private var hasMoreMetadata = false
  private var smartPage = 1
  private var hasMoreSmart = false
  private var seenServerAssetIDs = Set<String>()

  private var lastQuery: String?
  private var lastServerFilter: [String: Any] = [:]
  private var lastServerAlbumID: String?

  init(_ client: NativeImmichClient) {
    self.client = client
  }

  func clear() {
    currentGeneration += 1
    serverAssets = []
    localAssets = []
    loading = false
    serverError = nil
    smartSearchDegraded = false
    smartErrorMessage = nil
    hasMore = false
    hasLoaded = false
    seenServerAssetIDs.removeAll()
    metadataCursor = nil
    smartPage = 1
    hasMoreMetadata = false
    hasMoreSmart = false
    lastQuery = nil
    lastServerFilter = [:]
    lastServerAlbumID = nil
  }

  func search(
    query: String?,
    source: NativePhotosSource,
    filterPhotos: Bool,
    filterVideos: Bool,
    favoritesOnly: Bool,
    useAfter: Bool,
    after: Date,
    useBefore: Bool,
    before: Date,
    albumFilter: NativeSearchAlbumFilter,
    device: NativeDeviceLibrary,
    reset: Bool = true
  ) async {
    guard filterPhotos || filterVideos else {
      if reset { clear() }
      return
    }

    currentGeneration += 1
    let gen = currentGeneration

    if reset {
      serverAssets = []
      localAssets = []
      seenServerAssetIDs.removeAll()
      metadataCursor = nil
      smartPage = 1
      hasMoreMetadata = false
      hasMoreSmart = false
      serverError = nil
      smartSearchDegraded = false
      smartErrorMessage = nil
    }

    loading = true
    hasLoaded = true
    defer {
      if gen == currentGeneration {
        loading = false
        hasMore = hasMoreMetadata || hasMoreSmart
      }
    }

    let trimmedQuery = query?.trimmingCharacters(in: .whitespacesAndNewlines)
    let effectiveQuery = (trimmedQuery?.isEmpty == false) ? trimmedQuery : nil

    // Build server filters
    var serverFilters: [String: Any] = [:]
    if filterPhotos != filterVideos {
      serverFilters["type"] = ["eq": filterPhotos ? "IMAGE" : "VIDEO"]
    }
    if favoritesOnly {
      serverFilters["isFavorite"] = ["eq": true]
    }
    let formatter = ISO8601DateFormatter()
    if useAfter {
      serverFilters["takenAt"] = ["gte": formatter.string(from: after)]
    }
    if useBefore {
      var bounds = serverFilters["takenAt"] as? [String: String] ?? [:]
      let endOfDay = Calendar.current.date(byAdding: .day, value: 1, to: Calendar.current.startOfDay(for: before)) ?? before
      bounds["lte"] = formatter.string(from: endOfDay)
      serverFilters["takenAt"] = bounds
    }

    var serverAlbumId: String? = nil
    var localAlbumIDs: Set<String>? = nil

    switch albumFilter {
    case .all:
      break
    case .server(let id, _):
      serverAlbumId = id
    case .local(let id, _):
      if let localAlbum = device.albums.first(where: { $0.id == id }) {
        localAlbumIDs = Set(device.assets(in: localAlbum).map(\.id))
      } else {
        localAlbumIDs = []
      }
    }

    lastQuery = effectiveQuery
    lastServerFilter = serverFilters
    lastServerAlbumID = serverAlbumId

    // 1. Local Search Task
    var matchedLocals: [NativeDeviceAsset] = []
    if source != .server {
      if albumFilter.isServer {
        matchedLocals = []
      } else {
        matchedLocals = nativeFilterLocalAssets(
          assets: device.assets,
          query: effectiveQuery,
          filterPhotos: filterPhotos,
          filterVideos: filterVideos,
          favoritesOnly: favoritesOnly,
          useAfter: useAfter,
          after: after,
          useBefore: useBefore,
          before: before,
          allowedLocalAssetIDs: localAlbumIDs
        )
      }
    }

    guard nativeShouldAcceptSearchResult(requestGeneration: gen, currentGeneration: currentGeneration) else { return }
    self.localAssets = matchedLocals

    // 2. Server Search Task
    if source == .device || albumFilter.isLocal {
      self.serverAssets = []
      self.hasMoreMetadata = false
      self.hasMoreSmart = false
      return
    }

    var newServerAssets: [NativeAsset] = []

    if let q = effectiveQuery {
      let captureServerAlbumId = serverAlbumId
      let captureServerFilters = serverFilters

      // Parallel Dual-Track Search
      async let metadataSearch: (page: NativeSearchPage?, error: Error?) = {
        do {
          let page = try await client.searchPage(query: q, albumId: captureServerAlbumId, cursor: nil, filter: captureServerFilters)
          return (page, nil)
        } catch {
          return (nil, error)
        }
      }()

      async let smartSearch: NativeSearchPage? = {
        do {
          return try await client.smartSearch(query: q, page: 1, filter: captureServerFilters)
        } catch {
          return nil
        }
      }()

      let (metadataOutcome, smartPageResult) = await (metadataSearch, smartSearch)
      guard nativeShouldAcceptSearchResult(requestGeneration: gen, currentGeneration: currentGeneration) else { return }

      if let meta = metadataOutcome.page {
        metadataCursor = meta.next
        hasMoreMetadata = meta.next != nil
        for a in meta.assets {
          if seenServerAssetIDs.insert(a.id).inserted {
            newServerAssets.append(a)
          }
        }
      }

      if let smart = smartPageResult {
        smartPage = 2
        hasMoreSmart = smart.next != nil
        for a in smart.assets {
          if seenServerAssetIDs.insert(a.id).inserted {
            newServerAssets.append(a)
          }
        }
      } else {
        smartSearchDegraded = true
        smartErrorMessage = "智能搜索不可用，已展示普通与本机搜索结果"
      }

      if metadataOutcome.page == nil && smartPageResult == nil {
        if let err = metadataOutcome.error {
          serverError = err.localizedDescription
        } else {
          serverError = "服务器搜索失败"
        }
      }
    } else {
      // Pure metadata search without text query
      do {
        let meta = try await client.searchPage(query: nil, albumId: serverAlbumId, cursor: nil, filter: serverFilters)
        guard nativeShouldAcceptSearchResult(requestGeneration: gen, currentGeneration: currentGeneration) else { return }
        metadataCursor = meta.next
        hasMoreMetadata = meta.next != nil
        hasMoreSmart = false
        for a in meta.assets {
          if seenServerAssetIDs.insert(a.id).inserted {
            newServerAssets.append(a)
          }
        }
      } catch {
        guard nativeShouldAcceptSearchResult(requestGeneration: gen, currentGeneration: currentGeneration) else { return }
        serverError = error.localizedDescription
      }
    }

    guard nativeShouldAcceptSearchResult(requestGeneration: gen, currentGeneration: currentGeneration) else { return }
    self.serverAssets = newServerAssets
  }

  func loadMore() async {
    guard !loading, hasMore else { return }
    let gen = currentGeneration
    loading = true
    defer {
      if gen == currentGeneration {
        loading = false
        hasMore = hasMoreMetadata || hasMoreSmart
      }
    }

    var newItems: [NativeAsset] = []

    if hasMoreMetadata, let cursor = metadataCursor {
      do {
        let page = try await client.searchPage(query: lastQuery, albumId: lastServerAlbumID, cursor: cursor, filter: lastServerFilter)
        guard nativeShouldAcceptSearchResult(requestGeneration: gen, currentGeneration: currentGeneration) else { return }
        metadataCursor = page.next
        hasMoreMetadata = page.next != nil
        for a in page.assets {
          if seenServerAssetIDs.insert(a.id).inserted {
            newItems.append(a)
          }
        }
      } catch {
        hasMoreMetadata = false
      }
    }

    if hasMoreSmart, let query = lastQuery {
      do {
        let page = try await client.smartSearch(query: query, page: smartPage, filter: lastServerFilter)
        guard nativeShouldAcceptSearchResult(requestGeneration: gen, currentGeneration: currentGeneration) else { return }
        smartPage += 1
        hasMoreSmart = page.next != nil
        for a in page.assets {
          if seenServerAssetIDs.insert(a.id).inserted {
            newItems.append(a)
          }
        }
      } catch {
        hasMoreSmart = false
      }
    }

    guard nativeShouldAcceptSearchResult(requestGeneration: gen, currentGeneration: currentGeneration) else { return }
    self.serverAssets += newItems
  }
}

private struct FilterTagView: View {
  let label: String
  let onRemove: () -> Void

  var body: some View {
    HStack(spacing: 4) {
      Text(label)
        .font(.caption2)
        .lineLimit(1)
      Button(action: onRemove) {
        Image(systemName: "xmark")
          .font(.system(size: 8, weight: .bold))
      }
      .buttonStyle(.plain)
    }
    .padding(.horizontal, 8)
    .padding(.vertical, 4)
    .background(Color.accentColor.opacity(0.12))
    .foregroundColor(.accentColor)
    .cornerRadius(12)
  }
}

private struct NativeSearchView: View {
  let client: NativeImmichClient
  @ObservedObject var device: NativeDeviceLibrary
  @StateObject private var model: NativeUnifiedSearchModel

  @State private var term = ""
  @State private var sourceFilter: NativePhotosSource = .all
  @State private var filterPhotos = true
  @State private var filterVideos = true
  @State private var favoritesOnly = false
  @State private var useAfter = false
  @State private var after = Date()
  @State private var useBefore = false
  @State private var before = Date()
  @State private var selectedAlbum: NativeSearchAlbumFilter = .all

  @State private var recentSearches: [String] = []
  @State private var explore: [NativeExploreSection] = []
  @State private var exploreError: String?
  @State private var serverAlbums: [NativeServerAlbum] = []
  @State private var debounceTask: Task<Void, Never>?

  init(client: NativeImmichClient, device: NativeDeviceLibrary) {
    self.client = client
    self.device = device
    _model = StateObject(wrappedValue: NativeUnifiedSearchModel(client))
  }

  private var hasActiveFilters: Bool {
    !filterPhotos || !filterVideos || favoritesOnly || useAfter || useBefore || selectedAlbum != .all || sourceFilter != .all
  }

  private var isAtExploreHome: Bool {
    term.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !hasActiveFilters && !model.hasLoaded
  }

  private var displayResults: (server: [NativeAsset], local: [NativeDeviceAsset]) {
    nativeFilterSearchResultsBySource(
      source: sourceFilter,
      serverAssets: model.serverAssets,
      localAssets: model.localAssets,
      matchedServerIDs: NativeSyncCacheStore.shared.matchedServerIDs
    )
  }

  private func formatShortDate(_ date: Date) -> String {
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyy/MM/dd"
    return formatter.string(from: date)
  }

  private func resetFilters() {
    sourceFilter = .all
    filterPhotos = true
    filterVideos = true
    favoritesOnly = false
    useAfter = false
    useBefore = false
    selectedAlbum = .all
    runSearch(immediate: true)
  }

  var body: some View {
    NavigationView {
      VStack(spacing: 0) {
        // Search bar & menu
        HStack(spacing: 8) {
          HStack {
            Image(systemName: "magnifyingglass")
              .foregroundColor(.secondary)
            TextField("搜索照片、视频、地点或描述", text: $term)
              .submitLabel(.search)
              .onSubmit {
                debounceTask?.cancel()
                runSearch(immediate: true)
              }
            if !term.isEmpty {
              Button {
                term = ""
                debounceTask?.cancel()
                if !hasActiveFilters {
                  model.clear()
                } else {
                  runSearch(immediate: true)
                }
              } label: {
                Image(systemName: "xmark.circle.fill")
                  .foregroundColor(.secondary)
              }
            }
          }
          .padding(.horizontal, 10)
          .padding(.vertical, 8)
          .background(Color(uiColor: .secondarySystemBackground))
          .cornerRadius(10)

          Menu {
            Picker("来源", selection: $sourceFilter) {
              Text("全部来源").tag(NativePhotosSource.all)
              Text("仅本机").tag(NativePhotosSource.device)
              Text("仅云端").tag(NativePhotosSource.server)
            }

            Menu("相册: \(selectedAlbum.shortName)") {
              Button("全部相册") { selectedAlbum = .all }
              if !serverAlbums.isEmpty {
                Section("云端相册") {
                  ForEach(serverAlbums) { alb in
                    Button(alb.name) { selectedAlbum = .server(id: alb.id, name: alb.name) }
                  }
                }
              }
              if !device.albums.isEmpty {
                Section("本机相册") {
                  ForEach(device.albums) { alb in
                    Button(alb.name) { selectedAlbum = .local(id: alb.id, name: alb.name) }
                  }
                }
              }
            }

            Section("媒体类型") {
              Toggle("照片", isOn: $filterPhotos)
              Toggle("视频", isOn: $filterVideos)
            }

            Section("属性") {
              Toggle("只看收藏", isOn: $favoritesOnly)
            }

            Section("拍摄日期") {
              Toggle("开始日期", isOn: $useAfter)
              Toggle("结束日期", isOn: $useBefore)
            }

            if hasActiveFilters {
              Divider()
              Button("重置所有筛选", role: .destructive) {
                resetFilters()
              }
            }
          } label: {
            ZStack(alignment: .topTrailing) {
              Image(systemName: hasActiveFilters ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
                .font(.system(size: 22))
                .padding(4)
              if hasActiveFilters {
                Circle()
                  .fill(Color.accentColor)
                  .frame(width: 8, height: 8)
                  .offset(x: -2, y: 2)
              }
            }
          }
        }
        .padding(.horizontal)
        .padding(.top, 4)
        .padding(.bottom, 6)

        // Segmented source filter
        Picker("来源", selection: $sourceFilter) {
          Text("全部").tag(NativePhotosSource.all)
          Text("本机").tag(NativePhotosSource.device)
          Text("云端").tag(NativePhotosSource.server)
        }
        .pickerStyle(.segmented)
        .padding(.horizontal)
        .padding(.bottom, hasActiveFilters || useAfter || useBefore ? 4 : 8)

        // Active filter tags
        if hasActiveFilters {
          ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
              if sourceFilter != .all {
                FilterTagView(label: "来源: \(sourceFilter.rawValue)") {
                  sourceFilter = .all
                }
              }
              if !filterPhotos {
                FilterTagView(label: "仅视频") {
                  filterPhotos = true
                }
              }
              if !filterVideos {
                FilterTagView(label: "仅照片") {
                  filterVideos = true
                }
              }
              if favoritesOnly {
                FilterTagView(label: "已收藏") {
                  favoritesOnly = false
                }
              }
              if useAfter {
                FilterTagView(label: "从 \(formatShortDate(after))") {
                  useAfter = false
                }
              }
              if useBefore {
                FilterTagView(label: "至 \(formatShortDate(before))") {
                  useBefore = false
                }
              }
              if selectedAlbum != .all {
                FilterTagView(label: "相册: \(selectedAlbum.shortName)") {
                  selectedAlbum = .all
                }
              }
              Button("重置") {
                resetFilters()
              }
              .font(.caption2)
              .foregroundColor(.secondary)
              .padding(.horizontal, 4)
            }
            .padding(.horizontal)
            .padding(.bottom, 6)
          }
        }

        // Date pickers
        if useAfter {
          DatePicker("从", selection: $after, displayedComponents: .date)
            .padding(.horizontal)
            .padding(.vertical, 2)
        }
        if useBefore {
          DatePicker("至", selection: $before, displayedComponents: .date)
            .padding(.horizontal)
            .padding(.vertical, 2)
        }

        // Status banners
        if model.smartSearchDegraded, let msg = model.smartErrorMessage {
          HStack(spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
              .foregroundColor(.orange)
              .font(.caption)
            Text(msg)
              .font(.caption)
              .foregroundColor(.secondary)
            Spacer()
          }
          .padding(.horizontal)
          .padding(.vertical, 4)
          .background(Color.orange.opacity(0.1))
        }

        if model.serverError != nil && !displayResults.local.isEmpty {
          HStack(spacing: 6) {
            Image(systemName: "wifi.slash")
              .foregroundColor(.secondary)
              .font(.caption)
            Text("无法连接服务器，当前仅展示本机搜索结果")
              .font(.caption)
              .foregroundColor(.secondary)
            Spacer()
            Button("重试") { runSearch(immediate: true) }
              .font(.caption)
          }
          .padding(.horizontal)
          .padding(.vertical, 4)
          .background(Color.secondary.opacity(0.1))
        }

        if let err = model.serverError, displayResults.local.isEmpty && displayResults.server.isEmpty && !model.loading {
          HStack {
            Text(err).font(.caption).foregroundColor(.secondary)
            Button("重试") { runSearch(immediate: true) }
          }
          .padding(8)
        }

        if sourceFilter == .device && !device.authorized {
          VStack(spacing: 8) {
            Image(systemName: "photo.on.rectangle.angled")
              .font(.system(size: 36))
              .foregroundColor(.secondary)
            Text("未授权访问系统照片")
              .font(.headline)
            Text("请允许访问系统照片以搜索本机照片")
              .font(.caption)
              .foregroundColor(.secondary)
            Button("前往设置") {
              if let url = URL(string: UIApplication.openSettingsURLString) {
                UIApplication.shared.open(url)
              }
            }
            .buttonStyle(.bordered)
          }
          .padding()
        }

        // Main content area
        if isAtExploreHome {
          ScrollView {
            VStack(alignment: .leading, spacing: 20) {
              if !recentSearches.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                  HStack {
                    Text("最近搜索").font(.headline)
                    Spacer()
                    Button("清空") {
                      NativeRecentSearchesStore.shared.clear()
                      recentSearches = []
                    }
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                  }

                  ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                      ForEach(recentSearches, id: \.self) { searchItem in
                        HStack(spacing: 6) {
                          Button {
                            term = searchItem
                            debounceTask?.cancel()
                            runSearch(immediate: true)
                          } label: {
                            HStack(spacing: 4) {
                              Image(systemName: "magnifyingglass")
                                .font(.system(size: 11))
                                .foregroundColor(.secondary)
                              Text(searchItem)
                                .font(.subheadline)
                                .lineLimit(1)
                            }
                          }
                          .buttonStyle(.plain)

                          Button {
                            NativeRecentSearchesStore.shared.remove(searchItem)
                            recentSearches = NativeRecentSearchesStore.shared.load()
                          } label: {
                            Image(systemName: "xmark")
                              .font(.system(size: 10, weight: .bold))
                              .foregroundColor(.secondary)
                          }
                          .buttonStyle(.plain)
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(Color(uiColor: .secondarySystemBackground))
                        .cornerRadius(16)
                      }
                    }
                  }
                }
              }

              if let exploreError {
                HStack {
                  Text(exploreError).font(.caption).foregroundColor(.secondary)
                  Button("重试探索") { Task { await loadExplore() } }
                }
              }

              if !explore.isEmpty {
                VStack(alignment: .leading, spacing: 16) {
                  Text("探索分类").font(.headline)
                  ForEach(explore) { section in
                    VStack(alignment: .leading, spacing: 8) {
                      Text(section.id).font(.subheadline).foregroundColor(.secondary)
                      ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                          ForEach(section.items) { tile in
                            Button {
                              term = tile.name
                              debounceTask?.cancel()
                              runSearch(immediate: true)
                            } label: {
                              VStack(alignment: .leading, spacing: 4) {
                                Color.clear
                                  .frame(width: 108, height: 108)
                                  .overlay(
                                    GeometryReader { geo in
                                      Group {
                                        if let asset = tile.asset {
                                          NativeThumbnail(client: client, asset: asset)
                                        } else {
                                          Rectangle().fill(Color(uiColor: .secondarySystemBackground))
                                            .overlay {
                                              Image(systemName: "photo")
                                                .foregroundColor(.secondary)
                                            }
                                        }
                                      }
                                      .frame(width: geo.size.width, height: geo.size.height)
                                      .clipped()
                                    }
                                  )
                                  .clipped()
                                  .cornerRadius(8)
                                Text(tile.name)
                                  .font(.caption)
                                  .lineLimit(1)
                              }
                              .frame(width: 108)
                            }
                            .buttonStyle(.plain)
                          }
                        }
                      }
                    }
                  }
                }
              }

              Text("本机尚未上传的照片仅支持文件名和基础信息搜索")
                .font(.caption)
                .foregroundColor(.secondary)
                .padding(.top, 8)
            }
            .padding()
          }
        } else if displayResults.server.isEmpty && displayResults.local.isEmpty && !model.loading && model.hasLoaded {
          Spacer()
          VStack(spacing: 12) {
            Image(systemName: "magnifyingglass")
              .font(.system(size: 44))
              .foregroundColor(.secondary)
            Text("没有找到匹配的照片或视频")
              .font(.headline)
              .foregroundColor(.secondary)
            Text("尝试更换关键词或减少筛选条件")
              .font(.caption)
              .foregroundColor(.secondary)
          }
          Spacer()
        } else {
          NativeResultGrid(
            client: client,
            assets: displayResults.server,
            localAssets: displayResults.local,
            hasOlder: model.hasMore,
            startsAtLatest: true
          ) {
            Task { await model.loadMore() }
          }
        }

        if model.loading {
          ProgressView().padding(8)
        }
      }
      .navigationTitle("搜索")
      .task {
        recentSearches = NativeRecentSearchesStore.shared.load()
        await loadExplore()
        await loadServerAlbums()
      }
      .onChange(of: term) { newTerm in
        debounceTask?.cancel()
        let trimmed = newTerm.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
          if !hasActiveFilters {
            model.clear()
          } else {
            runSearch(immediate: true)
          }
        } else {
          debounceTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 350_000_000)
            guard !Task.isCancelled else { return }
            runSearch(immediate: false)
          }
        }
      }
      .onChange(of: sourceFilter) { _ in runSearch(immediate: true) }
      .onChange(of: filterPhotos) { _ in runSearch(immediate: true) }
      .onChange(of: filterVideos) { _ in runSearch(immediate: true) }
      .onChange(of: favoritesOnly) { _ in runSearch(immediate: true) }
      .onChange(of: useAfter) { _ in runSearch(immediate: true) }
      .onChange(of: useBefore) { _ in runSearch(immediate: true) }
      .onChange(of: after) { _ in if useAfter { runSearch(immediate: true) } }
      .onChange(of: before) { _ in if useBefore { runSearch(immediate: true) } }
      .onChange(of: selectedAlbum) { _ in runSearch(immediate: true) }
    }
    .navigationViewStyle(.stack)
  }

  private func runSearch(immediate: Bool = false) {
    let trimmed = term.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.isEmpty && !hasActiveFilters {
      debounceTask?.cancel()
      model.clear()
      return
    }
    if !trimmed.isEmpty {
      NativeRecentSearchesStore.shared.add(trimmed)
      recentSearches = NativeRecentSearchesStore.shared.load()
    }
    Task {
      await model.search(
        query: trimmed.isEmpty ? nil : trimmed,
        source: sourceFilter,
        filterPhotos: filterPhotos,
        filterVideos: filterVideos,
        favoritesOnly: favoritesOnly,
        useAfter: useAfter,
        after: after,
        useBefore: useBefore,
        before: before,
        albumFilter: selectedAlbum,
        device: device,
        reset: true
      )
    }
  }

  private func loadExplore() async {
    guard explore.isEmpty else { return }
    do {
      explore = try await client.explore()
      exploreError = nil
    } catch {
      exploreError = error.localizedDescription
    }
  }

  private func loadServerAlbums() async {
    guard serverAlbums.isEmpty else { return }
    do {
      serverAlbums = try await client.serverAlbums()
    } catch {
      // Non-fatal
    }
  }
}

enum NativeAlbumOrigin {
  case merged
  case server
  case local
}

private struct NativeAlbumEntry: Identifiable, Equatable {
  let id: String
  let title: String
  let server: NativeServerAlbum?
  let device: NativeDeviceAlbum?
  let origin: NativeAlbumOrigin

  static func == (lhs: NativeAlbumEntry, rhs: NativeAlbumEntry) -> Bool {
    lhs.id == rhs.id
  }

  var countDescription: String {
    let s = server?.count ?? 0
    let d = device?.count ?? 0
    switch origin {
    case .merged:
      return "\(s) 项 · 本机 \(d)"
    case .server:
      return "\(s) 项 · 云端"
    case .local:
      return "\(d) 项 · 本机"
    }
  }
}

private struct NativeAlbumCoverView: View {
  let client: NativeImmichClient
  @ObservedObject var device: NativeDeviceLibrary
  let entry: NativeAlbumEntry
  let mergeAlbums: Bool

  var body: some View {
    Color.clear
      .aspectRatio(1, contentMode: .fit)
      .overlay(
        Group {
          if let thumbId = entry.server?.thumbnailAssetId {
            NativeThumbnail(
              client: client,
              asset: NativeAsset(id: thumbId, date: .distantPast, isImage: true, isFavorite: false, thumbhash: nil),
              columns: 2
            )
          } else if let devAlbum = entry.device, let firstLocal = device.firstAsset(in: devAlbum) {
            NativeDeviceThumbnail(asset: firstLocal, columns: 2)
          } else {
            ZStack {
              Color(uiColor: .secondarySystemBackground)
              Image(systemName: "photo.on.rectangle")
                .font(.system(size: 32))
                .foregroundColor(.secondary)
            }
          }
        }
      )
      .clipped()
      .cornerRadius(10)
      .overlay(alignment: .bottomTrailing) {
        if !mergeAlbums {
          Image(systemName: entry.origin == .server ? "cloud.fill" : "iphone")
            .font(.system(size: 11, weight: .bold))
            .foregroundColor(.white)
            .padding(5)
            .background(Color.black.opacity(0.6))
            .clipShape(Circle())
            .padding(6)
        }
      }
  }
}

private struct NativeAlbumCard: View {
  let client: NativeImmichClient
  @ObservedObject var device: NativeDeviceLibrary
  let entry: NativeAlbumEntry
  let mergeAlbums: Bool
  let isSelecting: Bool
  let isSelected: Bool

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      ZStack(alignment: .topTrailing) {
        NativeAlbumCoverView(client: client, device: device, entry: entry, mergeAlbums: mergeAlbums)
        if isSelecting {
          ZStack {
            Circle()
              .fill(isSelected ? Color.blue : Color.black.opacity(0.35))
              .frame(width: 24, height: 24)
            if isSelected {
              Image(systemName: "checkmark")
                .font(.system(size: 12, weight: .bold))
                .foregroundColor(.white)
            } else {
              Circle()
                .stroke(Color.white, lineWidth: 1.5)
                .frame(width: 22, height: 22)
            }
          }
          .padding(8)
        }
      }
      VStack(alignment: .leading, spacing: 2) {
        Text(entry.title)
          .font(.subheadline)
          .fontWeight(.medium)
          .foregroundColor(.primary)
          .lineLimit(1)
        Text(entry.countDescription)
          .font(.caption2)
          .foregroundColor(.secondary)
          .lineLimit(1)
      }
      .frame(maxWidth: .infinity, alignment: .leading)
    }
  }
}

private struct NativeAlbumsView: View {
  let client: NativeImmichClient
  @ObservedObject var device: NativeDeviceLibrary
  @AppStorage("immichz_merge_albums") private var mergeAlbums = true
  @State private var serverAlbums: [NativeServerAlbum] = []
  @State private var error: String?
  @State private var loaded = false
  @State private var isLoading = false

  @State private var isSelecting = false
  @State private var isDragSelecting = false
  @State private var dragSelectionIntent: NativeDragSelectionIntent = .undecided
  @State private var longPressDragIntent: NativeDragSelectionIntent = .undecided
  @State private var selectedAlbumIDs: Set<String> = []
  @State private var itemBounds: [String: CGRect] = [:]
  @State private var dragStartLocation: CGPoint? = nil
  @State private var dragStartAlbumID: String? = nil
  @State private var dragInitialSelectedIDs: Set<String> = []
  @State private var dragSelectMode: Bool = true
  @State private var activeEntry: NativeAlbumEntry? = nil
  @State private var showCreateAlbum = false
  @State private var newAlbumName = ""
  @State private var showCreateDestination = false
  @State private var showDeleteOptions = false
  @State private var showDeleteAssetsWarning = false
  @State private var showMutationError = false
  @State private var isMutating = false

  private let gridColumns = [
    GridItem(.flexible(), spacing: 14),
    GridItem(.flexible(), spacing: 14)
  ]

  private var entries: [NativeAlbumEntry] {
    if mergeAlbums {
      let serverGroups = Dictionary(grouping: serverAlbums) { $0.name.trimmingCharacters(in: .whitespaces).folding(options: .caseInsensitive, locale: .current) }
      let localGroups = Dictionary(grouping: device.albums) { $0.name.trimmingCharacters(in: .whitespaces).folding(options: .caseInsensitive, locale: .current) }
      let combined = Set(serverGroups.keys).union(localGroups.keys)
      return combined.sorted().flatMap { key -> [NativeAlbumEntry] in
        let remote = serverGroups[key] ?? []
        let local = localGroups[key] ?? []
        if remote.count == 1 && local.count == 1 {
          return [NativeAlbumEntry(id: "pair:\(remote[0].id):\(local[0].id)", title: remote[0].name, server: remote[0], device: local[0], origin: .merged)]
        }
        return remote.map { NativeAlbumEntry(id: "server:\($0.id)", title: $0.name, server: $0, device: nil, origin: .server) }
          + local.map { NativeAlbumEntry(id: "local:\($0.id)", title: $0.name, server: nil, device: $0, origin: .local) }
      }
    } else {
      var result: [NativeAlbumEntry] = []
      for s in serverAlbums {
        result.append(NativeAlbumEntry(id: "server:\(s.id)", title: s.name, server: s, device: nil, origin: .server))
      }
      for d in device.albums {
        result.append(NativeAlbumEntry(id: "local:\(d.id)", title: d.name, server: nil, device: d, origin: .local))
      }
      return result
    }
  }

  var body: some View {
    NavigationView {
      ScrollView {
        VStack(alignment: .leading, spacing: 16) {
          if let active = activeEntry {
            NavigationLink(
              destination: NativeAlbumDetail(client: client, device: device, entry: active, mergeAlbums: mergeAlbums),
              isActive: Binding(
                get: { activeEntry != nil },
                set: { if !$0 { activeEntry = nil } }
              )
            ) {
              EmptyView()
            }
            .hidden()
          }

          if !device.authorized {
            Button("允许访问设备相册（可选）") { Task { await device.requestAccess() } }
              .font(.footnote)
              .padding(.horizontal)
          }
          if let error {
            HStack {
              Text(error).font(.caption).foregroundColor(.red)
              Button("重试") { Task { await reload() } }.font(.caption)
            }
            .padding(.horizontal)
          }

          LazyVGrid(columns: gridColumns, spacing: 16) {
            ForEach(entries) { entry in
              NativeAlbumCard(
                client: client,
                device: device,
                entry: entry,
                mergeAlbums: mergeAlbums,
                isSelecting: isSelecting,
                isSelected: selectedAlbumIDs.contains(entry.id)
              )
              .background(
                GeometryReader { geo in
                  Color.clear
                    .preference(key: NativeItemFramePreferenceKey.self, value: [entry.id: geo.frame(in: .named("albumsScrollSpace"))])
                }
              )
              .contentShape(Rectangle())
              .onTapGesture {
                if isSelecting {
                  toggleAlbumSelection(entry.id)
                } else {
                  activeEntry = entry
                }
              }
              .onLongPressGesture(minimumDuration: 0.28, maximumDistance: 15) {
                if !isSelecting {
                  enterAlbumSelection(startingWith: entry.id)
                } else {
                  startDragSelectionInAlbumMode(startingWith: entry.id)
                }
              }
              .simultaneousGesture(
                DragGesture(minimumDistance: 4, coordinateSpace: .named("albumsScrollSpace"))
                  .onChanged { drag in
                    guard isSelecting else { return }
                    if dragSelectionIntent == .undecided {
                      let intent = nativeDragSelectionIntent(for: drag.translation)
                      if intent != .undecided { dragSelectionIntent = intent }
                    }
                    guard dragSelectionIntent == .select else { return }
                    if !isDragSelecting {
                      guard let hitID = itemBounds.first(where: { $0.value.contains(drag.startLocation) })?.key else { return }
                      isDragSelecting = true
                      startDragSelectionInAlbumMode(startingWith: hitID, at: drag.startLocation)
                    }
                    handle2DDragSelection(at: drag.location)
                  }
                  .onEnded { _ in
                    isDragSelecting = false
                    dragSelectionIntent = .undecided
                    finishDragSelection()
                  }
              )
              .id(entry.id)
            }
          }
          .padding(.horizontal, 16)
          .padding(.top, 8)
          .padding(.bottom, 24)
        }
      }
      .coordinateSpace(name: "albumsScrollSpace")
      .nativeScrollDisabled(isDragSelecting)
      .onPreferenceChange(NativeItemFramePreferenceKey.self) { frames in
        itemBounds = frames
      }
      .simultaneousGesture(
        LongPressGesture(minimumDuration: 0.28, maximumDistance: 15)
          .sequenced(before: DragGesture(coordinateSpace: .named("albumsScrollSpace")))
          .onChanged { value in
            switch value {
            case .first:
              break
            case .second(true, let drag):
              if let drag = drag, longPressDragIntent == .undecided {
                let intent = nativeDragSelectionIntent(for: drag.translation)
                if intent != .undecided { longPressDragIntent = intent }
              }
              guard longPressDragIntent == .select else { break }
              if !isDragSelecting {
                isDragSelecting = true
                let loc = drag?.startLocation ?? drag?.location
                if let loc = loc,
                   let hitID = itemBounds.first(where: { $0.value.contains(loc) })?.key {
                  if !isSelecting {
                    enterAlbumSelection(startingWith: hitID, at: loc)
                  } else {
                    startDragSelectionInAlbumMode(startingWith: hitID, at: loc)
                  }
                }
              }
              if let drag = drag {
                handle2DDragSelection(at: drag.location)
              }
            default:
              break
            }
          }
        .onEnded { _ in
          isDragSelecting = false
          longPressDragIntent = .undecided
          finishDragSelection()
        }
      )
      .navigationTitle("")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .navigationBarLeading) {
          if isSelecting {
            Button("取消") {
              isSelecting = false
              selectedAlbumIDs.removeAll()
            }
          } else {
            HStack(spacing: 6) {
              Text("\(entries.count) 个相册").font(.caption).foregroundColor(.secondary)
              if isLoading {
                ProgressView()
                  .scaleEffect(0.7)
              }
            }
          }
        }
        ToolbarItem(placement: .principal) {
          if isSelecting {
            Text("已选 \(selectedAlbumIDs.count) 个相册").font(.headline)
          }
        }
        ToolbarItemGroup(placement: .navigationBarTrailing) {
          if isSelecting {
            Button(role: .destructive) { showDeleteOptions = true } label: {
              Image(systemName: "trash")
            }
            .disabled(selectedAlbumIDs.isEmpty || isMutating)
            Button("全选") { selectedAlbumIDs = Set(entries.map(\.id)) }
          } else {
            Button { showCreateAlbum = true } label: { Image(systemName: "plus") }
            Button {
              Task {
                await reload()
                device.refresh()
              }
            } label: { Image(systemName: "arrow.clockwise") }
          }
        }
      }
      .alert("新建相册", isPresented: $showCreateAlbum) {
        TextField("相册名称", text: $newAlbumName)
        Button("取消", role: .cancel) { newAlbumName = "" }
        Button("下一步") { showCreateDestination = true }
      } message: {
        Text("输入新相册名称。")
      }
      .confirmationDialog("创建相册的位置", isPresented: $showCreateDestination, titleVisibility: .visible) {
        Button("Immich 服务器") { Task { await createAlbum(local: false) } }
        if device.authorized {
          Button("本机照片图库") { Task { await createAlbum(local: true) } }
        }
        Button("取消", role: .cancel) {}
      }
      .confirmationDialog("删除选中的相册", isPresented: $showDeleteOptions, titleVisibility: .visible) {
        Button("仅删除相册", role: .destructive) { Task { await deleteSelectedAlbums(includingAssets: false) } }
        Button("删除相册及其中的照片", role: .destructive) { showDeleteAssetsWarning = true }
        Button("取消", role: .cancel) {}
      } message: {
        Text("合并相册会删除两端相册。")
      }
      .alert("永久删除相册中的照片？", isPresented: $showDeleteAssetsWarning) {
        Button("取消", role: .cancel) {}
        Button("删除照片与相册", role: .destructive) { Task { await deleteSelectedAlbums(includingAssets: true) } }
      } message: {
        Text("会从 Immich 及本机照片图库删除这些照片，即使照片也属于其他相册。此操作无法在应用内撤销。")
      }
      .alert("删除失败", isPresented: $showMutationError) {
        Button("确定", role: .cancel) { error = nil }
      } message: { Text(error ?? "未知错误") }
      .refreshable { await reload(); device.refresh() }
      .task { if !loaded { loaded = true; await reload() } }
    }
    .navigationViewStyle(.stack)
  }

  private func reload() async {
    isDragSelecting = false
    finishDragSelection()
    isLoading = true
    defer { isLoading = false }
    do { serverAlbums = try await client.serverAlbums(); error = nil }
    catch { self.error = error.localizedDescription }
  }

  private func createAlbum(local: Bool) async {
    let name = newAlbumName.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !name.isEmpty, !isMutating else { return }
    isMutating = true
    defer { isMutating = false }
    do {
      if local {
        guard await device.createAlbum(named: name) else { throw NativeFeatureError.badResponse }
      } else {
        _ = try await client.createAlbum(name: name)
      }
      newAlbumName = ""
      await reload()
    } catch {
      self.error = "新建相册失败：\(error.localizedDescription)"
      showMutationError = true
    }
  }

  private func deleteSelectedAlbums(includingAssets: Bool) async {
    guard !isMutating else { return }
    isDragSelecting = false
    finishDragSelection()
    let selected = entries.filter { selectedAlbumIDs.contains($0.id) }
    guard !selected.isEmpty else { return }
    isMutating = true
    defer {
      isMutating = false
      isDragSelecting = false
      finishDragSelection()
      device.refresh()
    }
    var failures: [String] = []
    var removedRemoteIDs = Set<String>()
    for entry in selected {
      do {
        if includingAssets {
          var remoteIDs = Set<String>()
          if let server = entry.server {
            var cursor: String? = nil
            repeat {
              let page = try await client.searchPage(albumId: server.id, cursor: cursor)
              remoteIDs.formUnion(page.assets.map(\.id))
              cursor = page.next
            } while cursor != nil
          }
          let remainingRemoteIDs = remoteIDs.subtracting(removedRemoteIDs)
          if !remainingRemoteIDs.isEmpty {
            try await client.deleteAssets(ids: Array(remainingRemoteIDs))
            removedRemoteIDs.formUnion(remainingRemoteIDs)
          }
          if let local = entry.device {
            let localIDs = device.assets(in: local).map(\.id)
            if !localIDs.isEmpty {
              guard await device.deleteAssets(ids: localIDs) else { throw NativeFeatureError.badResponse }
            }
          }
        }
        if let server = entry.server { try await client.deleteAlbum(id: server.id) }
        if let local = entry.device {
          guard await device.deleteAlbums(ids: [local.id]) else { throw NativeFeatureError.badResponse }
        }
        selectedAlbumIDs.remove(entry.id)
      } catch { failures.append("\(entry.title)：\(error.localizedDescription)") }
    }
    await reload()
    if failures.isEmpty {
      isSelecting = false
    } else {
      error = "部分删除失败：" + failures.joined(separator: "；")
      showMutationError = true
    }
  }

  private func enterAlbumSelection(startingWith id: String, at location: CGPoint? = nil) {
    guard !isSelecting else { return }
    UIImpactFeedbackGenerator(style: .heavy).impactOccurred()
    isSelecting = true
    dragStartAlbumID = id
    let startLoc = location ?? itemBounds[id].map { CGPoint(x: $0.midX, y: $0.midY) }
    dragStartLocation = startLoc
    dragInitialSelectedIDs = selectedAlbumIDs
    let alreadySelected = selectedAlbumIDs.contains(id)
    dragSelectMode = !alreadySelected
    if dragSelectMode {
      selectedAlbumIDs.insert(id)
    } else {
      selectedAlbumIDs.remove(id)
    }
  }

  private func startDragSelectionInAlbumMode(startingWith id: String, at location: CGPoint? = nil) {
    guard dragStartAlbumID != id || dragStartLocation == nil else { return }
    UIImpactFeedbackGenerator(style: .heavy).impactOccurred()
    dragStartAlbumID = id
    let startLoc = location ?? itemBounds[id].map { CGPoint(x: $0.midX, y: $0.midY) }
    dragStartLocation = startLoc
    dragInitialSelectedIDs = selectedAlbumIDs
    let alreadySelected = selectedAlbumIDs.contains(id)
    dragSelectMode = !alreadySelected
    if dragSelectMode {
      selectedAlbumIDs.insert(id)
    } else {
      selectedAlbumIDs.remove(id)
    }
  }

  private func handle2DDragSelection(at location: CGPoint) {
    guard isSelecting else { return }
    if dragStartLocation == nil {
      dragStartLocation = location
      dragInitialSelectedIDs = selectedAlbumIDs
      if let hitID = itemBounds.first(where: { $0.value.contains(location) })?.key {
        dragStartAlbumID = hitID
        dragSelectMode = !selectedAlbumIDs.contains(hitID)
      } else {
        dragSelectMode = true
      }
    }

    let startLoc = dragStartLocation ?? location
    let minX = min(startLoc.x, location.x)
    let minY = min(startLoc.y, location.y)
    let maxX = max(startLoc.x, location.x)
    let maxY = max(startLoc.y, location.y)

    let selectionRect = CGRect(
      x: minX,
      y: minY,
      width: max(maxX - minX, 6),
      height: max(maxY - minY, 6)
    )

    var itemsInRect = Set<String>()
    for (id, frame) in itemBounds {
      if frame.intersects(selectionRect) {
        itemsInRect.insert(id)
      }
    }
    if let startID = dragStartAlbumID {
      itemsInRect.insert(startID)
    }

    var updated = dragInitialSelectedIDs
    if dragSelectMode {
      updated.formUnion(itemsInRect)
    } else {
      updated.subtract(itemsInRect)
    }

    if updated != selectedAlbumIDs {
      UIImpactFeedbackGenerator(style: .light).impactOccurred()
      selectedAlbumIDs = updated
    }
  }

  private func finishDragSelection() {
    dragStartLocation = nil
    dragStartAlbumID = nil
    dragInitialSelectedIDs.removeAll()
  }

  private func toggleAlbumSelection(_ id: String) {
    UIImpactFeedbackGenerator(style: .light).impactOccurred()
    if selectedAlbumIDs.contains(id) {
      selectedAlbumIDs.remove(id)
    } else {
      selectedAlbumIDs.insert(id)
    }
  }
}

private struct NativeAlbumDetail: View {
  let client: NativeImmichClient
  @ObservedObject var device: NativeDeviceLibrary
  let entry: NativeAlbumEntry
  let mergeAlbums: Bool
  @StateObject private var model: NativeResultsModel

  @State private var isSelecting = false
  @State private var selectedIDs: Set<String> = []
  @State private var showDeleteConfirmation = false
  @State private var showLocalDeleteWarning = false
  @State private var pendingDeleteScope: NativeDeleteTargetScope = .all
  @State private var deletionError: String?
  @State private var isDeleting = false
  @State private var batchShareItems: [Any]? = nil
  @State private var isPreparingBatchShare = false
  @State private var initialLoadCompleted = false

  init(client: NativeImmichClient, device: NativeDeviceLibrary, entry: NativeAlbumEntry, mergeAlbums: Bool) {
    self.client = client
    self.device = device
    self.entry = entry
    self.mergeAlbums = mergeAlbums
    _model = StateObject(wrappedValue: NativeResultsModel(client))
  }

  private var localAssetsToDisplay: [NativeDeviceAsset] {
    if mergeAlbums {
      return entry.device.map { device.assets(in: $0) } ?? []
    } else {
      return entry.origin == .local ? (entry.device.map { device.assets(in: $0) } ?? []) : []
    }
  }

  private var serverAssetsToDisplay: [NativeAsset] {
    if mergeAlbums {
      return model.assets
    } else {
      return entry.origin == .server ? model.assets : []
    }
  }

  var body: some View {
    VStack(spacing: 0) {
      if let error = model.error {
        HStack {
          Text(error).font(.caption).foregroundColor(.red)
          Button("重试") { Task { await model.load(albumId: entry.server?.id, reset: model.assets.isEmpty) } }
            .font(.caption)
        }
        .padding(6)
      }
      NativeResultGrid(
        client: client,
        assets: serverAssetsToDisplay,
        localAssets: localAssetsToDisplay,
        hasOlder: entry.server != nil && model.next != nil,
        startsAtLatest: true,
        initialPositionReady: entry.server == nil || initialLoadCompleted,
        isSelecting: $isSelecting,
        selectedIDs: $selectedIDs
      ) {
        if let id = entry.server?.id { Task { await model.load(albumId: id) } }
      }
      if model.loading { ProgressView().padding(8) }
    }
    .navigationTitle(isSelecting ? "" : entry.title)
    .navigationBarTitleDisplayMode(.inline)
    .toolbar {
      ToolbarItem(placement: .navigationBarLeading) {
        if isSelecting {
          Button("取消") {
            isSelecting = false
            selectedIDs.removeAll()
          }
        }
      }
      ToolbarItem(placement: .principal) {
        if isSelecting {
          Text("已选 \(selectedIDs.count) 项").font(.headline)
        }
      }
      ToolbarItem(placement: .navigationBarTrailing) {
        if isSelecting {
          Button("全选") {
            let matched = NativeSyncCacheStore.shared.matchedServerIDs
            let serverById = Dictionary(serverAssetsToDisplay.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            var usedServerIDs = Set<String>()
            var ids: [String] = []
            for local in localAssetsToDisplay {
              if let sID = matched[local.id], let sAsset = serverById[sID] {
                ids.append("local:\(local.id)")
                usedServerIDs.insert(sAsset.id)
              } else {
                ids.append("local:\(local.id)")
              }
            }
            for server in serverAssetsToDisplay {
              if !usedServerIDs.contains(server.id) {
                ids.append("server:\(server.id)")
              }
            }
            selectedIDs = Set(ids)
          }
        } else {
          Button("选择") {
            isSelecting = true
          }
        }
      }
    }
    .safeAreaInset(edge: .bottom, spacing: 0) {
      if isSelecting {
        HStack {
          Button {
            triggerBatchShare()
          } label: {
            if isPreparingBatchShare {
              ProgressView()
                .scaleEffect(0.85)
                .frame(width: 28, height: 28)
            } else {
              Image(systemName: "square.and.arrow.up")
                .font(.system(size: 21, weight: .regular))
            }
          }
          .disabled(selectedIDs.isEmpty || isPreparingBatchShare)

          Spacer()

          Button(role: .destructive) {
            if selectedTargets.allSatisfy({ $0.server != nil && $0.local == nil }) {
              requestRemoteOnlyDeletion()
            } else {
              showDeleteConfirmation = true
            }
          } label: {
            Image(systemName: "trash")
              .font(.system(size: 21, weight: .regular))
              .foregroundColor(selectedIDs.isEmpty || isDeleting ? .secondary : .red)
          }
          .disabled(selectedIDs.isEmpty || isDeleting)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial)
      }
    }
    .sheet(item: Binding<NativeSharePayload?>(
      get: { batchShareItems.map { NativeSharePayload(contents: $0) } },
      set: { if $0 == nil { batchShareItems = nil } }
    )) { payload in
      NativeActivityView(activityItems: payload.content)
    }
    .confirmationDialog("删除选中的 \(selectedIDs.count) 项照片", isPresented: $showDeleteConfirmation, titleVisibility: .visible) {
      Button("全部删除（本地与云端）", role: .destructive) { Task { await deleteSelectedPhotos(scope: .all) } }
      if selectedTargets.contains(where: { $0.local != nil && $0.server == nil }) {
        Button("仅删除本地照片", role: .destructive) { Task { await deleteSelectedPhotos(scope: .localOnly) } }
      }
      Button("取消", role: .cancel) {}
    } message: {
      Text("确定要删除所选照片吗？操作将同步移除对应副本。")
    }
    .alert("本机删除确认", isPresented: $showLocalDeleteWarning) {
      Button("取消", role: .cancel) {}
      Button("继续删除", role: .destructive) {
        let targets = selectedTargets
        let scope = pendingDeleteScope
        Task { await performSelectedDeletion(targets: targets, scope: scope) }
      }
    } message: { Text("删除本机照片会永久从系统照片中移除；若开启 iCloud 照片，可能同步到其他设备。") }
    .alert("删除失败", isPresented: Binding(get: { deletionError != nil }, set: { if !$0 { deletionError = nil } })) {
      Button("确定", role: .cancel) { deletionError = nil }
    } message: { Text(deletionError ?? "未知错误") }
    .task {
      if let server = entry.server {
        await model.load(albumId: server.id, reset: true)
      }
      initialLoadCompleted = true
    }
  }

  private var selectedTargets: [NativeGridItem] {
    let matched = NativeSyncCacheStore.shared.matchedServerIDs
    let serverByID = Dictionary(serverAssetsToDisplay.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    let items = localAssetsToDisplay.map { local -> NativeGridItem in
      NativeGridItem(server: matched[local.id].flatMap { serverByID[$0] }, local: local)
    } + serverAssetsToDisplay.filter { server in
      !localAssetsToDisplay.contains { matched[$0.id] == server.id }
    }.map { NativeGridItem(server: $0, local: nil) }
    return items.filter { selectedIDs.contains($0.id) }
  }

  private func deleteSelectedPhotos(scope: NativeDeleteTargetScope = .all) async {
    pendingDeleteScope = scope
    guard !isDeleting else { return }
    let targets = selectedTargets
    guard !targets.isEmpty else { return }
    if targets.contains(where: { $0.local != nil }) {
      pendingDeleteScope = scope
      showLocalDeleteWarning = true
      return
    }
    await performSelectedDeletion(targets: targets, scope: scope)
  }

  private func performSelectedDeletion(targets: [NativeGridItem], scope: NativeDeleteTargetScope) async {
    guard !isDeleting, !targets.isEmpty else { return }
    isDeleting = true
    defer { isDeleting = false }
    do {
      try await nativeDeleteGridItems(targets, scope: scope, client: client, device: device)
      if scope != .localOnly {
        let deletedIDs = Set(targets.compactMap { $0.server?.id })
        NativeSyncCacheStore.shared.removeMatches(localIDs: Set(targets.compactMap { item in
          guard let local = item.local, let serverID = NativeSyncCacheStore.shared.serverID(for: local.id),
                deletedIDs.contains(serverID) else { return nil }
          return local.id
        }))
      }
      selectedIDs.removeAll()
      isSelecting = false
      device.refresh()
      if let id = entry.server?.id { await model.load(albumId: id, reset: true) }
    } catch {
      if let partial = error as? NativeDeleteOperationError {
        NativeSyncCacheStore.shared.removeMatches(localIDs: Set(targets.compactMap { item in
          guard let local = item.local, let serverID = NativeSyncCacheStore.shared.serverID(for: local.id),
                partial.deletedServerIDs.contains(serverID) else { return nil }
          return local.id
        }))
      }
      deletionError = "可能已有部分照片删除成功，请刷新确认。\(error.localizedDescription)"
      device.refresh()
      if let id = entry.server?.id { await model.load(albumId: id, reset: true) }
    }
  }

  private func triggerBatchShare() {
    guard !isPreparingBatchShare else { return }
    let targets = selectedTargets
    guard !targets.isEmpty else { return }
    isPreparingBatchShare = true
    UIImpactFeedbackGenerator(style: .light).impactOccurred()
    Task {
      let result = await nativePrepareBatchShare(items: targets, client: client)
      await MainActor.run {
        isPreparingBatchShare = false
        if !result.files.isEmpty {
          batchShareItems = result.files
          if result.failed > 0 { deletionError = "已准备 \(result.files.count) 项原件；\(result.failed) 项暂不可用。" }
        }
      }
    }
  }
}

private struct NativePhotosPageSettingsView: View {
  let client: NativeImmichClient
  @ObservedObject var device: NativeDeviceLibrary
  @AppStorage("immichz_photos_excluded_local_album_ids") private var excludedLocalIDsRaw = "[]"
  @AppStorage("immichz_photos_excluded_server_album_ids") private var excludedServerIDsRaw = "[]"
  @State private var serverAlbums: [NativeServerAlbum] = []
  @State private var serverError: String?
  @State private var isLoadingServerAlbums = false

  private var excludedLocalIDs: Set<String> {
    nativePhotosExcludedAlbumIDs(from: excludedLocalIDsRaw)
  }

  private var excludedServerIDs: Set<String> {
    nativePhotosExcludedAlbumIDs(from: excludedServerIDsRaw)
  }

  var body: some View {
    List {
      Section {
        Text("关闭相册开关后，该相册中的照片将从照片页隐藏；相册内照片若同时属于其他相册，也会一并隐藏。未归入相册的照片仍会显示。")
          .font(.footnote)
          .foregroundColor(.secondary)
      }

      Section("设备相册") {
        if !device.authorized {
          Button("允许访问设备相册") {
            Task { await device.requestAccess() }
          }
        } else if device.albums.isEmpty {
          Text("没有可配置的设备相册").foregroundColor(.secondary)
        } else {
          ForEach(device.albums) { album in
            Toggle(isOn: Binding(
              get: { !excludedLocalIDs.contains(album.id) },
              set: { isShown in
                var updated = excludedLocalIDs
                if isShown { updated.remove(album.id) } else { updated.insert(album.id) }
                excludedLocalIDsRaw = nativePhotosAlbumIDsString(updated)
              }
            )) {
              HStack {
                Text(album.name)
                Spacer()
                Text("\(album.count)").font(.caption).foregroundColor(.secondary)
              }
            }
          }
        }
      }

      Section("Immich 相册") {
        if isLoadingServerAlbums {
          ProgressView("正在加载相册…")
        } else if let serverError {
          VStack(alignment: .leading, spacing: 8) {
            Text(serverError).font(.footnote).foregroundColor(.red)
            Button("重试") { Task { await loadServerAlbums() } }
          }
        } else if serverAlbums.isEmpty {
          Text("没有可配置的 Immich 相册").foregroundColor(.secondary)
        } else {
          ForEach(serverAlbums) { album in
            Toggle(isOn: Binding(
              get: { !excludedServerIDs.contains(album.id) },
              set: { isShown in
                var updated = excludedServerIDs
                if isShown { updated.remove(album.id) } else { updated.insert(album.id) }
                excludedServerIDsRaw = nativePhotosAlbumIDsString(updated)
              }
            )) {
              HStack {
                Text(album.name)
                Spacer()
                Text("\(album.count)").font(.caption).foregroundColor(.secondary)
              }
            }
          }
        }
      }
    }
    .navigationTitle("照片页")
    .navigationBarTitleDisplayMode(.inline)
    .task { await loadServerAlbums() }
  }

  @MainActor
  private func loadServerAlbums() async {
    isLoadingServerAlbums = true
    defer { isLoadingServerAlbums = false }
    do {
      serverAlbums = try await client.serverAlbums().sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
      serverError = nil
    } catch {
      serverError = "加载 Immich 相册失败：\(error.localizedDescription)"
    }
  }
}

private struct NativeLibraryView: View {
  let client: NativeImmichClient
  @ObservedObject var device: NativeDeviceLibrary
  @ObservedObject var matchedAssetDiagnostics: NativeMatchedAssetDiagnostics
  @AppStorage("immichz_merge_albums") private var mergeAlbums = true
  @State private var features: [String: Any] = [:]
  @State private var showDebugSheet = false
  @State private var versionTapCount = 0
  @State private var lastVersionTapTime: Date = .distantPast

  private var buildCommit: String {
    guard let value = Bundle.main.object(forInfoDictionaryKey: "ImmichZGitCommit") as? String,
          !value.isEmpty,
          value != "$(IMMICHZ_GIT_COMMIT)" else { return "unknown" }
    return value
  }

  private var appVersion: String {
    let shortVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.2"
    let buildNumber = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? ""
    return nativeFormattedAppVersion(
      shortVersion: shortVersion,
      buildNumber: buildNumber,
      commit: buildCommit
    )
  }

  private func handleVersionTap() {
    let now = Date()
    if now.timeIntervalSince(lastVersionTapTime) > 1.2 {
      versionTapCount = 1
    } else {
      versionTapCount += 1
    }
    lastVersionTapTime = now

    if versionTapCount >= 3 {
      versionTapCount = 0
      UIImpactFeedbackGenerator(style: .heavy).impactOccurred()
      showDebugSheet = true
    } else {
      UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }
  }

  var body: some View {
    NavigationView {
      List {
        Section("相册偏好") {
          Toggle("合并本地和远端相册", isOn: $mergeAlbums)
          NavigationLink("照片页") {
            NativePhotosPageSettingsView(client: client, device: device)
          }
        }
        Section("快捷入口") {
          NavigationLink("收藏") { NativeFilteredView(client: client, title: "收藏", filter: ["isFavorite": ["eq": true]]) }
          NavigationLink("归档") { NativeFilteredView(client: client, title: "归档", filter: ["visibility": ["eq": "archive"]]) }
          NavigationLink("共享链接") {
            NativeLibrarySection(client: client, title: "共享链接", path: "shared-links", query: []) { row in
              guard let id = row["id"] as? String else { return nil }
              return LibraryRow(id: id, title: row["description"] as? String ?? row["slug"] as? String ?? "共享链接", detail: row["type"] as? String ?? "", assetID: nil)
            }
          }
          if features["trash"] as? Bool == true {
            NavigationLink("回收站") { NativeFilteredView(client: client, title: "回收站", filter: ["trashedAt": ["ne": NSNull()]]) }
          }
        }
        Section("集合") {
          if features["facialRecognition"] as? Bool != false { NavigationLink("人物") { NativePeopleView(client: client) } }
          if features["map"] as? Bool != false { NavigationLink("地点") { NativePlacesView(client: client) } }
          NavigationLink("本机") {
            if device.authorized { NativeDeviceGrid(client: client, device: device, title: "本机照片", assets: device.assets) }
            else { Button("允许访问设备相册") { Task { await device.requestAccess() } } }
          }
          NavigationLink("回忆") {
            NativeLibrarySection(client: client, title: "回忆", path: "memories", query: []) { row in
              guard let id = row["id"] as? String else { return nil }
              return LibraryRow(id: id, title: row["type"] as? String ?? "回忆", detail: row["memoryAt"] as? String ?? "", assetID: nil)
            }
          }
        }
        Section("快捷访问") {
          NavigationLink("服务器文件夹") { NativeFoldersView(client: client) }
          NavigationLink("锁定文件夹 · 开发中") { NativeFallbackNote() }
          NavigationLink("伙伴共享") {
            NativeLibrarySection(client: client, title: "伙伴共享", path: "partners", query: [URLQueryItem(name: "direction", value: "shared-by")]) { row in
              guard let id = row["id"] as? String else { return nil }
              return LibraryRow(id: id, title: row["name"] as? String ?? row["email"] as? String ?? "伙伴", detail: row["email"] as? String ?? "", assetID: nil)
            }
          }
          NavigationLink("标签") {
            NativeLibrarySection(client: client, title: "标签", path: "tags", query: []) { row in
              guard let id = row["id"] as? String else { return nil }
              return LibraryRow(id: id, title: row["value"] as? String ?? row["name"] as? String ?? "标签", detail: "", assetID: id)
            }
          }
        }
        Section("应用更新") {
          NavigationLink {
            NativeAppUpdateView()
          } label: {
            Label("检查更新", systemImage: "arrow.down.app")
          }
        }
        Section("调试") {
          Button("后台诊断与错误记录") { showDebugSheet = true }
        }
        Section {
          HStack {
            Spacer()
            Text("版本 \(appVersion)")
              .font(.footnote.monospaced())
              .foregroundColor(.secondary)
              .contentShape(Rectangle())
              .onTapGesture {
                handleVersionTap()
              }
            Spacer()
          }
          .listRowBackground(Color.clear)
        }
      }
      .navigationTitle("设置")
      .sheet(isPresented: $showDebugSheet) {
        NativePerformanceDebugView(
          client: client, device: device,
          matchedAssetDiagnostics: matchedAssetDiagnostics,
          backgroundDiagnostics: .shared
        )
      }
      .task {
        do { features = try await client.send(path: "server/features") }
        catch {
          features = [:]
          NativeBackgroundDiagnostics.shared.record("读取服务器功能", error: error)
        }
      }
    }.navigationViewStyle(.stack)
  }
}

// MARK: - Performance Debug View

struct NativePerformanceDebugView: View {
  let client: NativeImmichClient
  @ObservedObject var device: NativeDeviceLibrary
  @ObservedObject var matchedAssetDiagnostics: NativeMatchedAssetDiagnostics
  @ObservedObject var backgroundDiagnostics: NativeBackgroundDiagnostics
  @Environment(\.dismiss) private var dismiss

  @State private var isRunningBenchmarks = false
  @State private var pingLatency: Int? = nil
  @State private var pingStatus: String = "未测"
  @State private var timelineLoadTimeMs: Int? = nil
  @State private var serverAssetCount: Int? = nil
  @State private var serverVideoCount: Int? = nil
  @State private var serverStorageUsage: String? = nil
  @State private var serverVersion: String? = nil
  @State private var diskCacheFiles: Int = 0
  @State private var diskCacheBytes: Int64 = 0
  @State private var matchedCount: Int = 0
  @State private var memoryFootprintMB: Double = 0
  @State private var isClearingCache = false
  @State private var alertMessage: String? = nil
  @State private var showAlert = false

  var body: some View {
    NavigationView {
      List {
        Section(header: Text("网络与服务器延迟")) {
          HStack {
            Text("服务器地址")
            Spacer()
            Text(client.config.serverUrl)
              .font(.caption.monospaced())
              .foregroundColor(.secondary)
              .lineLimit(1)
          }
          HStack {
            Text("连接延迟 (Ping)")
            Spacer()
            if let latency = pingLatency {
              Text("\(latency) ms")
                .foregroundColor(latency < 150 ? .green : (latency < 400 ? .orange : .red))
                .font(.body.monospacedDigit())
            } else {
              Text(pingStatus).foregroundColor(.secondary)
            }
          }
          HStack {
            Text("时间线接口耗时 (/timeline/buckets)")
            Spacer()
            if let t = timelineLoadTimeMs {
              Text("\(t) ms")
                .foregroundColor(t < 300 ? .green : .orange)
                .font(.body.monospacedDigit())
            } else {
              Text("未测量").foregroundColor(.secondary)
            }
          }
          if let ver = serverVersion {
            HStack {
              Text("服务器版本")
              Spacer()
              Text(ver).font(.caption.monospaced()).foregroundColor(.secondary)
            }
          }
        }

        Section(header: Text("照片库统计")) {
          HStack {
            Text("本地授权照片数")
            Spacer()
            Text("\(device.assets.filter { !$0.isVideo }.count) 张照片 / \(device.assets.filter { $0.isVideo }.count) 个视频")
              .font(.subheadline)
              .foregroundColor(.secondary)
          }
          HStack {
            Text("本地资产总数")
            Spacer()
            Text("\(device.assets.count) 项").bold()
          }
          HStack {
            Text("服务器照片数")
            Spacer()
            if let count = serverAssetCount {
              Text("\(count) 张").bold()
            } else {
              Text("加载中…").foregroundColor(.secondary)
            }
          }
          if let videos = serverVideoCount {
            HStack {
              Text("服务器视频数")
              Spacer()
              Text("\(videos) 个").bold()
            }
          }
          if let usage = serverStorageUsage {
            HStack {
              Text("服务器存储占用")
              Spacer()
              Text(usage).foregroundColor(.secondary)
            }
          }
          HStack {
            Text("本地/云端哈希匹配数")
            Spacer()
            Text("\(matchedCount) 项").foregroundColor(.secondary)
          }
        }

        Section {
          if backgroundDiagnostics.entries.isEmpty {
            Text("暂无后台错误").foregroundColor(.secondary)
          }
          ForEach(backgroundDiagnostics.entries) { event in
            VStack(alignment: .leading, spacing: 4) {
              HStack {
                Text(event.operation).font(.subheadline.weight(.medium))
                Spacer()
                Text(event.date, style: .relative)
                  .font(.caption).foregroundColor(.secondary)
              }
              Text(event.category).font(.caption).foregroundColor(.secondary)
            }
          }
          Text("仅保存错误类别、操作名称及时间；不记录照片 ID、服务器响应或登录凭据。")
            .font(.caption).foregroundColor(.secondary)
        } header: {
          Text("后台错误记录")
        }

        Section {
          HStack { Text("尝试请求"); Spacer(); Text("\(matchedAssetDiagnostics.attempted) 次") }
          HStack { Text("成功加载"); Spacer(); Text("\(matchedAssetDiagnostics.loaded) 项") }
          HStack { Text("正在请求"); Spacer(); Text("\(matchedAssetDiagnostics.pending) 项") }
          HStack { Text("仍未加载"); Spacer(); Text("\(matchedAssetDiagnostics.unresolvedCount) 项") }
          if let lastAttempt = matchedAssetDiagnostics.lastAttempt {
            HStack { Text("最近尝试"); Spacer(); Text(lastAttempt, style: .date); Text(lastAttempt, style: .time) }
              .font(.caption)
          }
          if let lastFailure = matchedAssetDiagnostics.lastFailure {
            HStack { Text("最近失败"); Spacer(); Text(lastFailure, style: .date); Text(lastFailure, style: .time) }
              .font(.caption)
          }
          if let category = matchedAssetDiagnostics.lastFailureCategory {
            HStack { Text("最近失败原因"); Spacer(); Text(category).foregroundColor(.secondary) }
          }
          ForEach(matchedAssetDiagnostics.failureCounts.keys.sorted(), id: \.self) { category in
            HStack {
              Text(category)
              Spacer()
              Text("\(matchedAssetDiagnostics.failureCounts[category, default: 0]) 项").foregroundColor(.secondary)
            }
          }
          Text("此处统计的是已核验匹配后，获取云端资产详情的结果；与原件指纹核验失败不同。401/403 请检查登录状态；404 请检查云端资产是否仍存在；网络或超时请检查连接并刷新照片页。不会展示照片 ID 或凭据。")
            .font(.caption).foregroundColor(.secondary)
        } header: {
          Text("已匹配云端资产详情")
        } footer: {
          Text("仅记录当前登录会话内的请求；切换账号后重置。")
        }

        Section(header: Text("缓存与内存")) {
          HStack {
            Text("缩略图磁盘缓存文件数")
            Spacer()
            Text("\(diskCacheFiles) 个").foregroundColor(.secondary)
          }
          HStack {
            Text("缩略图磁盘缓存体积")
            Spacer()
            Text(formatBytes(diskCacheBytes)).bold()
          }
          HStack {
            Text("App 内存占用 (Resident Memory)")
            Spacer()
            Text(String(format: "%.1f MB", memoryFootprintMB))
              .font(.body.monospacedDigit())
              .foregroundColor(memoryFootprintMB > 300 ? .orange : .secondary)
          }
          Button(role: .destructive) {
            clearCaches()
          } label: {
            HStack {
              if isClearingCache {
                ProgressView().scaleEffect(0.8)
                Text("正在清除…")
              } else {
                Text("清除本地缩略图缓存")
              }
            }
          }
          .disabled(isClearingCache)
        }

        Section(header: Text("调试操作")) {
          Button {
            Task { await runDiagnostics() }
          } label: {
            HStack {
              Image(systemName: "arrow.triangle.2.circlepath")
              Text(isRunningBenchmarks ? "正在测试中…" : "重新运行性能诊断测试")
            }
          }
          .disabled(isRunningBenchmarks)
        }
      }
      .navigationTitle("性能调试 (Debug)")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .navigationBarTrailing) {
          Button("完成") { dismiss() }
        }
      }
      .alert(isPresented: $showAlert) {
        Alert(title: Text("提示"), message: Text(alertMessage ?? ""), dismissButton: .default(Text("好")))
      }
      .task {
        backgroundDiagnostics.configureForCurrentAccount()
        await runDiagnostics()
      }
    }
  }

  private func runDiagnostics() async {
    guard !isRunningBenchmarks else { return }
    isRunningBenchmarks = true
    defer { isRunningBenchmarks = false }

    updateMemoryAndDiskCache()
    matchedCount = NativeSyncCacheStore.shared.matchedServerIDs.count

    // 1. Measure Ping latency
    let pingStart = Date()
    do {
      _ = try await client.send(path: "server/ping")
      pingLatency = Int(Date().timeIntervalSince(pingStart) * 1000)
      pingStatus = "正常"
    } catch {
      pingLatency = nil
      pingStatus = "连接失败: \(error.localizedDescription)"
    }

    // 2. Measure /timeline/buckets latency
    let timelineStart = Date()
    do {
      let buckets = try await client.timelineBuckets()
      timelineLoadTimeMs = Int(Date().timeIntervalSince(timelineStart) * 1000)
      let totalBucketAssets = buckets.reduce(0) { $0 + $1.count }
      if serverAssetCount == nil {
        serverAssetCount = totalBucketAssets
      }
    } catch {
      timelineLoadTimeMs = nil
    }

    // 3. Query server statistics
    do {
      let stats = try await client.send(path: "server/statistics")
      if let photos = stats["photos"] as? Int {
        serverAssetCount = photos
      }
      if let videos = stats["videos"] as? Int {
        serverVideoCount = videos
      }
      if let usageBytes = stats["usage"] as? Int64 {
        serverStorageUsage = formatBytes(usageBytes)
      } else if let usageBytes = stats["usage"] as? Int {
        serverStorageUsage = formatBytes(Int64(usageBytes))
      }
    } catch {}

    // 4. Query server version
    do {
      let verObj = try await client.send(path: "server/version")
      if let major = verObj["major"], let minor = verObj["minor"], let patch = verObj["patch"] {
        serverVersion = "\(major).\(minor).\(patch)"
      }
    } catch {}

    updateMemoryAndDiskCache()
  }

  private func updateMemoryAndDiskCache() {
    Task {
      let (count, bytes) = await NativeThumbnailDiskCache.shared.diskUsage()
      await MainActor.run {
        diskCacheFiles = count
        diskCacheBytes = bytes
      }
    }

    var info = mach_task_basic_info()
    var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size) / 4
    let kerr = withUnsafeMutablePointer(to: &info) {
      $0.withMemoryRebound(to: integer_t.self, capacity: 1) {
        task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
      }
    }
    if kerr == KERN_SUCCESS {
      memoryFootprintMB = Double(info.resident_size) / (1024.0 * 1024.0)
    }
  }

  private func clearCaches() {
    isClearingCache = true
    UIImpactFeedbackGenerator(style: .medium).impactOccurred()
    Task {
      await NativeThumbnailDiskCache.shared.clearAll()
      NativeThumbnailCache.images.removeAllObjects()
      NativeLocalThumbnailCache.images.removeAllObjects()
      await MainActor.run {
        isClearingCache = false
        updateMemoryAndDiskCache()
        alertMessage = "本地缩略图缓存已清理；照片指纹与云端匹配关系保持不变"
        showAlert = true
        UINotificationFeedbackGenerator().notificationOccurred(.success)
      }
    }
  }

  private func formatBytes(_ bytes: Int64) -> String {
    let formatter = ByteCountFormatter()
    formatter.allowedUnits = [.useAll]
    formatter.countStyle = .file
    return formatter.string(fromByteCount: bytes)
  }
}

private struct NativeFallbackNote: View {
  var body: some View { Text("此功能暂未提供。").padding() }
}

struct NativeFilteredView: View {
  let client: NativeImmichClient
  let title: String
  let filter: [String: Any]
  @StateObject private var model: NativeResultsModel
  init(client: NativeImmichClient, title: String, filter: [String: Any]) {
    self.client = client; self.title = title; self.filter = filter
    _model = StateObject(wrappedValue: NativeResultsModel(client))
  }
  var body: some View {
    VStack {
      if let error = model.error { Text(error); Button("重试") { Task { await model.load(filter: filter, reset: model.assets.isEmpty) } } }
      NativeResultGrid(client: client, assets: model.assets, hasOlder: model.next != nil) { Task { await model.load(filter: filter) } }
      if model.loading { ProgressView() }
    }
    .navigationTitle(title)
    .task { await model.load(filter: filter, reset: true) }
  }
}

final class TabBarFinderView: UIView {
  var onSetup: ((UIView) -> Void)?

  override func didMoveToWindow() {
    super.didMoveToWindow()
    if window != nil {
      onSetup?(self)
    }
  }
}

private struct TabBarDoubleTapHelper: UIViewRepresentable {
  let onPhotosDoubleTap: () -> Void

  func makeCoordinator() -> Coordinator {
    Coordinator(onPhotosDoubleTap: onPhotosDoubleTap)
  }

  func makeUIView(context: Context) -> TabBarFinderView {
    let view = TabBarFinderView()
    view.backgroundColor = .clear
    view.isUserInteractionEnabled = false
    view.onSetup = { [weak coordinator = context.coordinator] v in
      coordinator?.setup(from: v)
    }
    DispatchQueue.main.async {
      context.coordinator.setup(from: view)
    }
    return view
  }

  func updateUIView(_ uiView: TabBarFinderView, context: Context) {
    context.coordinator.onPhotosDoubleTap = onPhotosDoubleTap
    context.coordinator.setup(from: uiView)
  }

  final class Coordinator: NSObject, UIGestureRecognizerDelegate {
    var onPhotosDoubleTap: () -> Void
    private weak var tabBar: UITabBar?
    private var doubleTapGesture: UITapGestureRecognizer?

    init(onPhotosDoubleTap: @escaping () -> Void) {
      self.onPhotosDoubleTap = onPhotosDoubleTap
    }

    func setup(from view: UIView) {
      guard let tabBar = findTabBar(from: view) else { return }
      if self.tabBar === tabBar { return }
      if let existing = doubleTapGesture, let oldBar = self.tabBar {
        oldBar.removeGestureRecognizer(existing)
      }
      self.tabBar = tabBar

      let doubleTap = UITapGestureRecognizer(target: self, action: #selector(handleDoubleTap(_:)))
      doubleTap.numberOfTapsRequired = 2
      doubleTap.cancelsTouchesInView = false
      doubleTap.delaysTouchesEnded = false
      doubleTap.delegate = self
      tabBar.addGestureRecognizer(doubleTap)
      self.doubleTapGesture = doubleTap
    }

    private func findTabBar(from view: UIView) -> UITabBar? {
      var responder: UIResponder? = view
      while let r = responder {
        if let tc = r as? UITabBarController { return tc.tabBar }
        if let vc = r as? UIViewController, let tc = vc.tabBarController { return tc.tabBar }
        responder = r.next
      }
      if let window = view.window ?? UIApplication.shared.connectedScenes
        .compactMap({ ($0 as? UIWindowScene)?.keyWindow })
        .first {
        return findTabBarIn(view: window)
      }
      return nil
    }

    private func findTabBarIn(view: UIView) -> UITabBar? {
      if let bar = view as? UITabBar { return bar }
      for sub in view.subviews {
        if let bar = findTabBarIn(view: sub) { return bar }
      }
      return nil
    }

    @objc private func handleDoubleTap(_ gesture: UITapGestureRecognizer) {
      guard let tabBar = self.tabBar ?? gesture.view as? UITabBar else { return }
      let location = gesture.location(in: tabBar)
      let width = tabBar.bounds.width
      guard width > 0 else { return }
      let tabWidth = width / 4.0
      if location.x >= 0 && location.x <= tabWidth && location.y >= 0 && location.y <= tabBar.bounds.height {
        onPhotosDoubleTap()
      }
    }

    func gestureRecognizer(
      _ gestureRecognizer: UIGestureRecognizer,
      shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
    ) -> Bool {
      true
    }
  }
}

struct NativeTabShell: View {
  let client: NativeImmichClient
  let onLogout: () -> Void
  @StateObject private var device = NativeDeviceLibrary()
  @StateObject private var matchedAssetDiagnostics = NativeMatchedAssetDiagnostics()
  @State private var selectedTab = 0
  @State private var didStartLibrary = false

  var body: some View {
    TabView(selection: $selectedTab) {
      NativePhotosView(client: client, device: device, onLogout: onLogout, matchedAssetDiagnostics: matchedAssetDiagnostics)
        .tabItem { Label("照片", systemImage: "photo.on.rectangle") }
        .tag(0)
      NativeSearchView(client: client, device: device)
        .tabItem { Label("搜索", systemImage: "magnifyingglass") }
        .tag(1)
      NativeAlbumsView(client: client, device: device)
        .tabItem { Label("相册", systemImage: "rectangle.stack") }
        .tag(2)
      NativeLibraryView(client: client, device: device, matchedAssetDiagnostics: matchedAssetDiagnostics)
        .tabItem { Label("设置", systemImage: "gearshape") }
        .tag(3)
    }
    .onAppear {
      guard !didStartLibrary else { return }
      didStartLibrary = true
      // Let the first Photos frame render before scanning the system library.
      Task { @MainActor in
        try? await Task.sleep(nanoseconds: 50_000_000)
        guard !Task.isCancelled else { return }
        device.refresh()
      }
    }
    .background(
      TabBarDoubleTapHelper {
        selectedTab = 0
        // Let Photos reappear before delivering the scroll request when
        // double-tapping the tab from another screen.
        DispatchQueue.main.async {
          NotificationCenter.default.post(name: .immichScrollPhotosToBottom, object: nil)
        }
      }
    )
  }
}
