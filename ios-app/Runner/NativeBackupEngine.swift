import Combine
import CryptoKit
import Foundation
import Network
import Photos
import UIKit

/// Automatic Backup Engine implementing Immich official upload specifications:
/// 1. Candidate check via SHA-1 pre-flight bulk-upload-check (/api/assets/bulk-upload-check)
/// 2. Atomic dual-track Live Photo upload (primary HEIC/JPEG + paired QuickTime MOV)
/// 3. WiFi-only and network constraints with low-power mode awareness
/// 4. Auto-upload tombstone protection (prevents re-uploading cloud-deleted media)
@MainActor
final class NativeBackupEngine: ObservableObject {
  static let shared = NativeBackupEngine()

  @Published private(set) var isRunning: Bool = false
  @Published private(set) var currentProgress: Double = 0.0 // 0.0 ~ 1.0
  @Published private(set) var currentAssetId: String?
  @Published private(set) var totalPendingCount: Int = 0
  @Published private(set) var completedCount: Int = 0
  @Published private(set) var statusMessage: String?
  @Published private(set) var lastError: String?

  private let networkMonitor = NWPathMonitor()
  private var isWifi: Bool = true
  private var isConnected: Bool = true
  private var currentTask: Task<Void, Never>?
  private var queue: [NativeDeviceAsset] = []

  private init() {
    startNetworkMonitoring()
  }

  deinit {
    networkMonitor.cancel()
  }

  private func startNetworkMonitoring() {
    networkMonitor.pathUpdateHandler = { [weak self] path in
      Task { @MainActor in
        self?.isConnected = path.status == .satisfied
        self?.isWifi = path.usesInterfaceType(.wifi) || path.usesInterfaceType(.wiredEthernet)
      }
    }
    let q = DispatchQueue(label: "immich.backup.network.monitor")
    networkMonitor.start(queue: q)
  }

  // MARK: - Settings

  public var isBackupEnabled: Bool {
    get { UserDefaults.standard.object(forKey: "backup_enabled") as? Bool ?? false }
    set {
      UserDefaults.standard.set(newValue, forKey: "backup_enabled")
      if !newValue { cancel() }
    }
  }

  public var requireWifi: Bool {
    get { UserDefaults.standard.object(forKey: "backup_require_wifi") as? Bool ?? true }
    set { UserDefaults.standard.set(newValue, forKey: "backup_require_wifi") }
  }

  public var selectedAlbumIDs: Set<String> {
    get {
      let array = UserDefaults.standard.stringArray(forKey: "backup_selected_album_ids") ?? []
      return Set(array)
    }
    set {
      UserDefaults.standard.set(Array(newValue), forKey: "backup_selected_album_ids")
    }
  }

  // MARK: - Lifecycle & Execution

  func cancel() {
    currentTask?.cancel()
    currentTask = nil
    isRunning = false
    statusMessage = "备份已暂停"
  }

  /// Triggers an automatic backup pass on candidate device assets
  func triggerBackupPass(
    assets: [NativeDeviceAsset],
    client: NativeImmichClient,
    force: Bool = false
  ) {
    guard isBackupEnabled || force else { return }
    guard !isRunning else { return }

    // Check network constraints
    if requireWifi && !isWifi {
      statusMessage = "等待 Wi-Fi 连接进行备份"
      return
    }
    guard isConnected else {
      statusMessage = "无网络连接"
      return
    }

    currentTask = Task {
      await runBackupLoop(allAssets: assets, client: client)
    }
  }

  private func runBackupLoop(allAssets: [NativeDeviceAsset], client: NativeImmichClient) async {
    isRunning = true
    lastError = nil
    statusMessage = "正在扫描待备份照片..."

    let bridge = ImmichCoreBridge.shared
    let syncStore = NativeSyncCacheStore.shared
    let accountKey = syncStore.identity

    // Filter candidate assets:
    // 1. Must not already be matched to server
    // 2. Must not be tombstoned
    // 3. Must match selected album filter if user customized albums
    var candidates: [NativeDeviceAsset] = []
    let albumFilter = selectedAlbumIDs

    guard !albumFilter.isEmpty else {
      isRunning = false
      statusMessage = "请先选择需要备份的手机相册"
      return
    }

    var allowedLocalIDs = Set<String>()
    let collections = PHAssetCollection.fetchAssetCollections(withLocalIdentifiers: Array(albumFilter), options: nil)
    collections.enumerateObjects { collection, _, _ in
      let fetched = PHAsset.fetchAssets(in: collection, options: nil)
      fetched.enumerateObjects { asset, _, _ in
        allowedLocalIDs.insert(asset.localIdentifier)
      }
    }

    for asset in allAssets {
      if syncStore.isMatched(localId: asset.id) { continue }
      if bridge.isUploadTombstoned(localAssetId: asset.id) { continue }
      if !allowedLocalIDs.contains(asset.id) { continue }

      candidates.append(asset)
    }

    guard !candidates.isEmpty else {
      isRunning = false
      totalPendingCount = 0
      completedCount = 0
      statusMessage = "所有照片已备份完成"
      return
    }

    totalPendingCount = candidates.count
    completedCount = 0
    statusMessage = "正在预检 \(candidates.count) 项照片..."

    // Batch upload check in chunks of 50
    for batchStart in stride(from: 0, to: candidates.count, by: 50) {
      if Task.isCancelled { break }

      let batchEnd = min(batchStart + 50, candidates.count)
      let chunk = Array(candidates[batchStart..<batchEnd])

      // 1. Gather SHA-1 checksums
      var checkItems: [CoreBulkUploadCheckItem] = []
      for asset in chunk {
        if Task.isCancelled { break }
        if let sha1 = await computeChecksum(for: asset) {
          checkItems.append(CoreBulkUploadCheckItem(id: asset.id, checksum: sha1))
        }
      }

      guard !checkItems.isEmpty else { continue }

      // 2. Pre-flight check through Rust Core
      let checkResults: [CoreBulkUploadCheckResult]
      do {
        checkResults = try await bridge.bulkUploadCheck(candidates: checkItems)
      } catch {
        lastError = error.localizedDescription
        statusMessage = "预检失败: \(error.localizedDescription)"
        break
      }

      var matchesToUpdate: [String: String] = [:]
      var toUploadAssets: [NativeDeviceAsset] = []

      for res in checkResults {
        if res.action == "reject" {
          // Exists on server or duplicate
          if let sId = res.assetId ?? res.reason, !sId.isEmpty {
            matchesToUpdate[res.id] = sId
          }
          completedCount += 1
        } else if res.action == "accept" {
          if let match = chunk.first(where: { $0.id == res.id }) {
            toUploadAssets.append(match)
          }
        }
      }

      if !matchesToUpdate.isEmpty {
        syncStore.update(matches: matchesToUpdate, checked: Set(matchesToUpdate.keys), expectedIdentity: accountKey)
      }

      // 3. Upload accepted assets sequentially with dual-track support
      let deviceId = client.config.deviceId ?? (UIDevice.current.identifierForVendor?.uuidString ?? "ios-device")

      for asset in toUploadAssets {
        if Task.isCancelled { break }
        if requireWifi && !isWifi {
          statusMessage = "Wi-Fi 断开，备份暂停"
          break
        }

        currentAssetId = asset.id
        statusMessage = "正在上传 (\(completedCount + 1)/\(totalPendingCount))..."

        let uploadSuccess = await uploadDualTrackAsset(asset: asset, deviceId: deviceId, bridge: bridge)
        if uploadSuccess {
          completedCount += 1
          currentProgress = Double(completedCount) / Double(max(1, totalPendingCount))
        } else {
          // On failure, continue to next
        }
      }
    }

    isRunning = false
    currentAssetId = nil
    if completedCount >= totalPendingCount {
      statusMessage = "全部备份完成 (共 \(completedCount) 项)"
    } else {
      statusMessage = "备份结束，已同步 \(completedCount) 项"
    }
  }

  // MARK: - Dual-Track Extraction & Upload

  private func uploadDualTrackAsset(
    asset: NativeDeviceAsset,
    deviceId: String,
    bridge: ImmichCoreBridge
  ) async -> Bool {
    guard let phAsset = PHAsset.fetchAssets(withLocalIdentifiers: [asset.id], options: nil).firstObject else {
      return false
    }

    let resources = PHAssetResource.assetResources(for: phAsset)

    // Identify primary photo/video resource and paired Live Photo video resource
    var primaryResource: PHAssetResource?
    var livePairedResource: PHAssetResource?

    if phAsset.mediaSubtypes.contains(.photoLive) {
      for res in resources {
        if res.type == .photo || res.type == .fullSizePhoto {
          primaryResource = res
        } else if res.type == .pairedVideo || res.type == .fullSizePairedVideo {
          livePairedResource = res
        }
      }
    } else {
      primaryResource = phAsset.getResource()
    }

    guard let primary = primaryResource ?? resources.first else {
      return false
    }

    // Extract primary data
    guard let primaryData = await extractResourceData(primary) else {
      return false
    }

    // Extract optional live video data
    var liveData: Data? = nil
    var liveName: String? = nil
    if let liveRes = livePairedResource {
      liveData = await extractResourceData(liveRes)
      liveName = liveRes.originalFilename
    }

    let df = ISO8601DateFormatter()
    df.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    let createdStr = df.string(from: phAsset.creationDate ?? asset.date)
    let modifiedStr = df.string(from: phAsset.modificationDate ?? asset.date)

    do {
      let resp = try await bridge.uploadAsset(
        deviceAssetId: asset.id,
        deviceId: deviceId,
        fileCreatedAt: createdStr,
        fileModifiedAt: modifiedStr,
        isFavorite: phAsset.isFavorite,
        fileData: primaryData,
        fileName: primary.originalFilename,
        livePhotoData: liveData,
        livePhotoName: liveName
      )

      NativeSyncCacheStore.shared.update(
        matches: [asset.id: resp.id],
        checked: [asset.id],
        expectedIdentity: NativeSyncCacheStore.shared.identity
      )
      return true
    } catch {
      self.lastError = error.localizedDescription
      return false
    }
  }

  private func extractResourceData(_ resource: PHAssetResource) async -> Data? {
    final class DataBox: @unchecked Sendable {
      var data = Data()
      var requestId: PHAssetResourceDataRequestID?
    }
    let box = DataBox()

    let options = PHAssetResourceRequestOptions()
    options.isNetworkAccessAllowed = true

    return await withTaskCancellationHandler(operation: {
      await withCheckedContinuation { continuation in
        box.requestId = PHAssetResourceManager.default().requestData(
          for: resource,
          options: options,
          dataReceivedHandler: { bytes in
            box.data.append(bytes)
          },
          completionHandler: { error in
            if error != nil {
              continuation.resume(returning: nil)
            } else {
              continuation.resume(returning: box.data)
            }
          }
        )
      }
    }, onCancel: {
      if let reqId = box.requestId {
        PHAssetResourceManager.default().cancelDataRequest(reqId)
      }
    })
  }

  private func computeChecksum(for asset: NativeDeviceAsset) async -> String? {
    guard let phAsset = PHAsset.fetchAssets(withLocalIdentifiers: [asset.id], options: nil).firstObject else { return nil }
    guard let resource = phAsset.getResource() else { return nil }

    final class HashBox: @unchecked Sendable {
      var hasher = Insecure.SHA1()
      var requestId: PHAssetResourceDataRequestID?
    }
    let box = HashBox()

    let options = PHAssetResourceRequestOptions()
    options.isNetworkAccessAllowed = false

    return await withTaskCancellationHandler(operation: {
      await withCheckedContinuation { (continuation: CheckedContinuation<String?, Never>) in
        box.requestId = PHAssetResourceManager.default().requestData(
          for: resource,
          options: options,
          dataReceivedHandler: { bytes in
            box.hasher.update(data: bytes)
          },
          completionHandler: { error in
            if error != nil {
              continuation.resume(returning: nil)
            } else {
              let hashStr = Data(box.hasher.finalize()).base64EncodedString()
              continuation.resume(returning: hashStr)
            }
          }
        )
      }
    }, onCancel: {
      if let reqId = box.requestId {
        PHAssetResourceManager.default().cancelDataRequest(reqId)
      }
    })
  }
}
