import CryptoKit
import Foundation
import Photos

struct NativeCloudSyncCache: Codable {
  var matchedServerIDs: [String: String] = [:] // localIdentifier -> serverAssetId
  var checkedIDs: [String] = []                // localIdentifiers that were checked
  var checksums: [String: String] = [:]        // localIdentifier -> Base64 SHA-1
}

final class NativeSyncCacheStore: @unchecked Sendable {
  static let shared = NativeSyncCacheStore()
  private let lock = NSLock()
  private let folder: URL
  private var fileURL: URL?
  private var accountKey: String?
  private(set) var matchedServerIDs: [String: String] = [:] // localId -> serverId
  private(set) var reverseMatches: [String: String] = [:]   // serverId -> localId
  private(set) var checkedIDs: Set<String> = []
  private(set) var checksums: [String: String] = [:]
  var identity: String? {
    lock.lock(); defer { lock.unlock() }
    return accountKey
  }
  private let saveQueue = DispatchQueue(label: "immich.sync.cache.save", qos: .utility)

  init(directory: URL? = nil) {
    folder = directory ?? (FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
      ?? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!)
    try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    // The old unscoped cache cannot be trusted as account-specific evidence;
    // re-verify originals after upgrading.
    try? FileManager.default.removeItem(at: folder.appendingPathComponent("native_cloud_sync_cache.json"))
  }

  func configure(server: String, userId: String?) {
    // An unverified legacy or offline session must not inherit any matches.
    let canonicalServer = server.trimmingCharacters(in: .whitespacesAndNewlines)
      .lowercased().replacingOccurrences(of: "/+$", with: "", options: .regularExpression)
    let key = userId.flatMap { $0.isEmpty ? nil : "\(canonicalServer)|\($0)" }
    lock.lock(); defer { lock.unlock() }
    guard key != accountKey else { return }
    saveQueue.sync {} // Drain snapshots queued before changing account.
    accountKey = key
    ImmichCoreBridge.shared.setActiveAccount(key)
    fileURL = key.map { key in
      let digest = SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()
      return folder.appendingPathComponent("native_cloud_sync_cache_\(digest).json")
    }
    matchedServerIDs = [:]
    reverseMatches = [:]
    checkedIDs = []
    checksums = [:]
    guard let fileURL, let data = try? Data(contentsOf: fileURL),
          let decoded = try? JSONDecoder().decode(NativeCloudSyncCache.self, from: data) else { return }
    matchedServerIDs = decoded.matchedServerIDs.filter { $0.key != $0.value }
    checkedIDs = Set(decoded.checkedIDs)
    checksums = decoded.checksums.filter { $0.value.count == 28 }
    for (localId, serverId) in matchedServerIDs { reverseMatches[serverId] = localId }
  }

  func isMatched(localId: String?) -> Bool {
    guard let localId else { return false }
    lock.lock(); defer { lock.unlock() }
    return matchedServerIDs[localId] != nil
  }

  func serverID(for localId: String) -> String? {
    lock.lock(); defer { lock.unlock() }
    return matchedServerIDs[localId]
  }

  func localID(for serverId: String) -> String? {
    lock.lock(); defer { lock.unlock() }
    return reverseMatches[serverId]
  }

  func update(matches: [String: String] = [:], checked: Set<String> = [], newChecksums: [String: String] = [:], expectedIdentity: String? = nil) {
    lock.lock()
    guard accountKey != nil, expectedIdentity == nil || expectedIdentity == accountKey else { lock.unlock(); return }
    var changed = false
    for (k, v) in matches {
      if let previous = matchedServerIDs[k], previous != v { reverseMatches.removeValue(forKey: previous) }
      if let previousLocal = reverseMatches[v], previousLocal != k {
        matchedServerIDs.removeValue(forKey: previousLocal)
      }
      if matchedServerIDs[k] != v {
        matchedServerIDs[k] = v
        reverseMatches[v] = k
        changed = true
      }
    }
    for id in checked {
      if checkedIDs.insert(id).inserted { changed = true }
    }
    for (k, v) in newChecksums {
      if checksums[k] != v {
        checksums[k] = v
        changed = true
      }
    }
    if changed { saveToDiskLocked() }
    lock.unlock()
  }

  func invalidateChecks(localIDs: Set<String>, expectedIdentity: String? = nil) {
    guard !localIDs.isEmpty else { return }
    lock.lock()
    guard expectedIdentity == nil || expectedIdentity == accountKey else { lock.unlock(); return }
    checkedIDs.subtract(localIDs)
    saveToDiskLocked()
    lock.unlock()
  }

  func removeMatches(localIDs: Set<String>) {
    guard !localIDs.isEmpty else { return }
    lock.lock()
    for localID in localIDs {
      if let serverID = matchedServerIDs.removeValue(forKey: localID) {
        reverseMatches.removeValue(forKey: serverID)
      }
    }
    saveToDiskLocked()
    lock.unlock()
  }

  func clear() {
    lock.lock()
    saveQueue.sync {} // Drain snapshots while updates are excluded.
    matchedServerIDs.removeAll()
    reverseMatches.removeAll()
    checkedIDs.removeAll()
    checksums.removeAll()
    let oldURL = fileURL
    fileURL = nil
    accountKey = nil
    if let oldURL { try? FileManager.default.removeItem(at: oldURL) }
    lock.unlock()
  }

  // The snapshot and destination must be selected under the same lock. A
  // previous account's async write may finish later, but can never write to
  // the newly selected account's file.
  private func saveToDiskLocked() {
    guard let fileURL else { return }
    let snapshot = NativeCloudSyncCache(
      matchedServerIDs: matchedServerIDs,
      checkedIDs: Array(checkedIDs),
      checksums: checksums
    )
    saveQueue.async { [fileURL] in
      if let data = try? JSONEncoder().encode(snapshot) {
        try? data.write(to: fileURL, options: .atomic)
      }
    }
  }
}

// Account-scoped metadata snapshots. Thumbnails have their own disk cache;
// neither credentials nor original photo data are written here.
struct NativeTimelineSnapshot: Codable {
  let assets: [NativeAsset]
  let buckets: [NativeBucket]
  let nextBucket: Int
  let searchFallbackEnabled: Bool
  let searchCursor: String?
  let hasOlder: Bool
}

struct NativeDeviceSnapshot: Codable {
  let assets: [NativeDeviceAsset]
  let albums: [NativeDeviceAlbum]
}

struct NativeTimelineExclusionsSnapshot: Codable {
  let localAlbumIDs: Set<String>
  let serverAlbumIDs: Set<String>
  let localAssetIDs: Set<String>
  let serverAssetIDs: Set<String>
}

final class NativePhotoSnapshotStore: @unchecked Sendable {
  static let shared = NativePhotoSnapshotStore()
  private let folder: URL
  private let queue = DispatchQueue(label: "immich.photo.snapshots", qos: .utility)

  init(directory: URL? = nil) {
    folder = directory ?? FileManager.default.urls(
      for: .applicationSupportDirectory, in: .userDomainMask
    )[0]
    try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
  }

  private func url(_ kind: String, identity: String) -> URL {
    let hash = SHA256.hash(data: Data(identity.utf8))
      .map { String(format: "%02x", $0) }.joined()
    return folder.appendingPathComponent("native_\(kind)_snapshot_\(hash).json")
  }

  func timeline(identity: String? = NativeSyncCacheStore.shared.identity) -> NativeTimelineSnapshot? {
    read("timeline", identity: identity)
  }

  func device(identity: String? = NativeSyncCacheStore.shared.identity) -> NativeDeviceSnapshot? {
    read("device", identity: identity)
  }

  private func read<T: Decodable>(_ kind: String, identity: String?) -> T? {
    guard let identity else { return nil }
    return queue.sync {
      guard let data = try? Data(contentsOf: url(kind, identity: identity)) else { return nil }
      return try? JSONDecoder().decode(T.self, from: data)
    }
  }

  func saveTimeline(_ snapshot: NativeTimelineSnapshot, expectedIdentity: String?) {
    save(snapshot, kind: "timeline", identity: expectedIdentity)
  }

  func saveDevice(_ snapshot: NativeDeviceSnapshot, expectedIdentity: String?) {
    save(snapshot, kind: "device", identity: expectedIdentity)
  }

  func exclusions(identity: String? = NativeSyncCacheStore.shared.identity) -> NativeTimelineExclusionsSnapshot? {
    read("exclusions", identity: identity)
  }

  func saveExclusions(_ snapshot: NativeTimelineExclusionsSnapshot, expectedIdentity: String?) {
    save(snapshot, kind: "exclusions", identity: expectedIdentity)
  }

  func diagnostics(identity: String? = NativeSyncCacheStore.shared.identity) -> [NativeBackgroundDiagnostic] {
    read("diagnostics", identity: identity) ?? []
  }

  func saveDiagnostics(_ entries: [NativeBackgroundDiagnostic], expectedIdentity: String?) {
    save(entries, kind: "diagnostics", identity: expectedIdentity)
  }

  private func save<T: Encodable>(_ snapshot: T, kind: String, identity: String?) {
    guard let identity, NativeSyncCacheStore.shared.identity == identity else { return }
    queue.async { [self] in
      guard NativeSyncCacheStore.shared.identity == identity,
            let data = try? JSONEncoder().encode(snapshot) else { return }
      try? data.write(to: url(kind, identity: identity), options: .atomic)
    }
  }

  func clearDevice(expectedIdentity: String?) {
    guard let identity = expectedIdentity,
          NativeSyncCacheStore.shared.identity == identity else { return }
    queue.sync {
      try? FileManager.default.removeItem(at: url("device", identity: identity))
    }
  }

  func clearCurrentAccount() {
    guard let identity = NativeSyncCacheStore.shared.identity else { return }
    queue.sync {
      for kind in ["timeline", "device", "exclusions", "diagnostics"] {
        try? FileManager.default.removeItem(at: url(kind, identity: identity))
      }
    }
  }
}

// The server confirms an uploaded copy only when its SHA1 matches the actual
// PhotoKit original resource. Unreadable or cloud-only originals stay unknown.
@MainActor
final class NativeCloudStatus: ObservableObject {
  @Published private(set) var matchedServerIDs: [String: String]
  @Published private(set) var checkedIDs: Set<String>
  @Published private(set) var failedVerificationIDs: Set<String> = []
  @Published private(set) var message: String?
  @Published private(set) var failedCount = 0
  @Published private(set) var isRunning = false
  private var checksums: [String: String]
  private let accountIdentity: String?
  private var running = false
  private var generation = 0
  private var failedIDs: Set<String> = []

  init() {
    let store = NativeSyncCacheStore.shared
    self.matchedServerIDs = store.matchedServerIDs
    self.checkedIDs = store.checkedIDs
    self.checksums = store.checksums
    self.accountIdentity = store.identity
  }

  func forgetMatches(localIDs: Set<String>) {
    guard !localIDs.isEmpty else { return }
    NativeSyncCacheStore.shared.removeMatches(localIDs: localIDs)
    for id in localIDs { matchedServerIDs.removeValue(forKey: id) }
  }

  func reset() {
    generation += 1
    failedIDs = []
    failedVerificationIDs = []
    failedCount = 0
    message = nil
    running = false
    isRunning = false
  }

  func clearCache() {
    reset()
    matchedServerIDs = [:]
    checkedIDs = []
    failedVerificationIDs = []
    checksums = [:]
    NativeSyncCacheStore.shared.clear()
  }

  func retry(_ assets: [NativeDeviceAsset], client: NativeImmichClient) async {
    let retryWithNetwork = !failedIDs.isEmpty
    if retryWithNetwork { failedIDs = [] }
    await check(assets, client: client, allowNetwork: retryWithNetwork)
    if failedCount > 0 && message == nil {
      message = "有 \(failedCount) 项原件暂时无法读取；可下载 iCloud 原件后重新核验。"
    }
  }

  func check(_ assets: [NativeDeviceAsset], client: NativeImmichClient, allowNetwork: Bool = false) async {
    let syncEnabled = UserDefaults.standard.object(forKey: "backup_enabled") as? Bool ?? true
    guard syncEnabled else {
      message = "同步已暂停"
      return
    }
    guard !running, accountIdentity != nil, NativeSyncCacheStore.shared.identity == accountIdentity else { return }
    let toCheck = assets.reversed().filter { matchedServerIDs[$0.id] == nil && (allowNetwork || !failedIDs.contains($0.id)) }
    guard !toCheck.isEmpty else { return }

    running = true
    isRunning = true
    let current = generation
    defer {
      if current == generation {
        running = false
        isRunning = false
        failedCount = failedIDs.count
        if failedCount > 0 {
          NativeBackgroundDiagnostics.shared.record(
            "读取照片原件", category: "无法读取 \(failedCount) 项原件"
          )
        }
      }
    }
    message = nil

    for batch in stride(from: 0, to: toCheck.count, by: 50) {
      guard current == generation, NativeSyncCacheStore.shared.identity == accountIdentity else { return }
      let slice = Array(toCheck[batch..<min(batch + 50, toCheck.count)])

      var hashes: [[String: String]] = []
      var newlyComputedChecksums: [String: String] = [:]

      await withTaskGroup(of: (String, String?).self) { group in
        for asset in slice {
          if let cached = checksums[asset.id] {
            group.addTask { (asset.id, cached) }
          } else {
            group.addTask(priority: .utility) {
              let hash = await Self.checksum(for: asset, allowNetwork: allowNetwork)
              return (asset.id, hash)
            }
          }
        }
        for await (id, hash) in group {
          if let hash {
            hashes.append(["id": id, "checksum": hash])
            newlyComputedChecksums[id] = hash
          } else {
            failedIDs.insert(id)
            failedVerificationIDs.insert(id)
          }
        }
      }

      guard current == generation, NativeSyncCacheStore.shared.identity == accountIdentity else { return }
      let unreadable = Set(slice.map(\.id)).subtracting(hashes.compactMap { $0["id"] })
      if !unreadable.isEmpty {
        checkedIDs.subtract(unreadable)
        NativeSyncCacheStore.shared.invalidateChecks(localIDs: unreadable, expectedIdentity: accountIdentity)
      }
      if !newlyComputedChecksums.isEmpty {
        for (k, v) in newlyComputedChecksums { checksums[k] = v }
        NativeSyncCacheStore.shared.update(newChecksums: newlyComputedChecksums, expectedIdentity: accountIdentity)
      }

      guard !hashes.isEmpty else { continue }

      do {
        let response = try await client.send(path: "assets/bulk-upload-check", method: "POST", body: ["assets": hashes])
        guard current == generation, NativeSyncCacheStore.shared.identity == accountIdentity else { return }
        guard let results = response["results"] as? [[String: Any]] else {
          let invalidIDs = Set(hashes.compactMap { $0["id"] })
          failedVerificationIDs.formUnion(invalidIDs)
          checkedIDs.subtract(invalidIDs)
          NativeSyncCacheStore.shared.invalidateChecks(localIDs: invalidIDs, expectedIdentity: accountIdentity)
          message = "服务器的上传状态核验响应格式异常。"
          NativeBackgroundDiagnostics.shared.record(
            "上传状态核验", category: "服务器响应格式异常"
          )
          return
        }

        let submitted = Set(hashes.compactMap { $0["id"] })
        var responseByID: [String: [[String: Any]]] = [:]
        for result in results {
          guard let id = result["id"] as? String, submitted.contains(id) else { continue }
          responseByID[id, default: []].append(result)
        }
        var newMatches: [String: String] = [:]
        var newChecked: Set<String> = []
        for (id, entries) in responseByID where entries.count == 1 {
          let result = entries[0]
          guard let action = result["action"] as? String else { continue }
          if action == "reject", let serverID = result["assetId"] as? String, !serverID.isEmpty {
            newMatches[id] = serverID
            newChecked.insert(id)
          } else if action == "accept" {
            newChecked.insert(id)
          }
        }

        for (k, v) in newMatches { matchedServerIDs[k] = v }
        checkedIDs.formUnion(newChecked)
        failedVerificationIDs.subtract(newChecked)
        failedIDs.subtract(newChecked)
        NativeSyncCacheStore.shared.update(matches: newMatches, checked: newChecked, expectedIdentity: accountIdentity)

        let invalidIDs = submitted.subtracting(newChecked)
        if !invalidIDs.isEmpty {
          failedVerificationIDs.formUnion(invalidIDs)
          checkedIDs.subtract(invalidIDs)
          NativeSyncCacheStore.shared.invalidateChecks(localIDs: invalidIDs, expectedIdentity: accountIdentity)
          message = "服务器有 \(invalidIDs.count) 项未返回唯一有效的核验结果，状态暂时未知。"
          NativeBackgroundDiagnostics.shared.record(
            "上传状态核验", category: "核验结果缺失（\(invalidIDs.count) 项）"
          )
        }
      } catch {
        let invalidIDs = Set(hashes.compactMap { $0["id"] })
        failedVerificationIDs.formUnion(invalidIDs)
        checkedIDs.subtract(invalidIDs)
        NativeSyncCacheStore.shared.invalidateChecks(localIDs: invalidIDs, expectedIdentity: accountIdentity)
        message = "无法向服务器核验上传状态：\(error.localizedDescription)"
        NativeBackgroundDiagnostics.shared.record("上传状态核验", error: error)
        return
      }
    }
  }

  nonisolated private static func checksum(for deviceAsset: NativeDeviceAsset, allowNetwork: Bool) async -> String? {
    guard let phAsset = PHAsset.fetchAssets(withLocalIdentifiers: [deviceAsset.id], options: nil).firstObject else { return nil }
    guard let resource = phAsset.getResource() else { return nil }

    final class RequestRef: @unchecked Sendable {
      var id: PHAssetResourceDataRequestID?
    }
    let requestRef = RequestRef()

    return await withTaskCancellationHandler(operation: {
      if Task.isCancelled { return nil }
      let options = PHAssetResourceRequestOptions()
      options.isNetworkAccessAllowed = allowNetwork

      return await withCheckedContinuation { continuation in
        var hasher = Insecure.SHA1()
        requestRef.id = PHAssetResourceManager.default().requestData(
          for: resource,
          options: options,
          dataReceivedHandler: { bytes in
            hasher.update(data: bytes)
          },
          completionHandler: { error in
            if error != nil {
              continuation.resume(returning: nil)
            } else {
              // Immich canonical checksum format: Base64 encoded SHA1 hash
              let base64Hash = Data(hasher.finalize()).base64EncodedString()
              continuation.resume(returning: base64Hash)
            }
          }
        )
      }
    }, onCancel: {
      if let requestId = requestRef.id {
        PHAssetResourceManager.default().cancelDataRequest(requestId)
      }
    })
  }
}

// Resource selection mirrors official Immich app PHAssetExtensions.swift
extension PHAsset {
  func getResource() -> PHAssetResource? {
    let resources = PHAssetResource.assetResources(for: self)
    let filteredResources = resources.filter { $0.isMediaResource && isValidResourceType($0.type) }

    guard !filteredResources.isEmpty else { return nil }

    if filteredResources.count == 1 {
      return filteredResources.first
    }

    if let currentResource = filteredResources.first(where: { $0.isCurrent }) {
      return currentResource
    }

    if let fullSizeResource = filteredResources.first(where: { isFullSizeResourceType($0.type) }) {
      return fullSizeResource
    }

    return filteredResources.first
  }

  private func isValidResourceType(_ type: PHAssetResourceType) -> Bool {
    switch mediaType {
    case .image:
      return [.photo, .alternatePhoto, .fullSizePhoto].contains(type)
    case .video:
      return [.video, .fullSizeVideo, .fullSizePairedVideo].contains(type)
    default:
      return false
    }
  }

  private func isFullSizeResourceType(_ type: PHAssetResourceType) -> Bool {
    switch mediaType {
    case .image:
      return type == .fullSizePhoto
    case .video:
      return type == .fullSizeVideo
    default:
      return false
    }
  }
}

// Resource properties mirror official Immich app PHAssetResourceExtensions.swift
extension PHAssetResource {
  var isCurrent: Bool {
    return (value(forKey: "isCurrent") as? Bool) ?? false
  }

  var isMediaResource: Bool {
    var isMedia = type != .adjustmentData
    if #available(iOS 17, *) {
      isMedia = isMedia && type != .photoProxy
    }
    return isMedia
  }
}
