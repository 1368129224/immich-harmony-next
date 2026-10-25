import Foundation

// MARK: - C FFI Bindings via @_silgen_name

@_silgen_name("immich_ios_free_string")
private func c_immich_ios_free_string(_ ptr: UnsafeMutablePointer<CChar>?)

@_silgen_name("immich_ios_is_initialized")
private func c_immich_ios_is_initialized() -> Bool

@_silgen_name("immich_ios_init_core_engine")
private func c_immich_ios_init_core_engine(
  _ dbDir: UnsafePointer<CChar>?,
  _ cacheDir: UnsafePointer<CChar>?
) -> UnsafeMutablePointer<CChar>?

@_silgen_name("immich_ios_init_in_memory")
private func c_immich_ios_init_in_memory(
  _ cacheDir: UnsafePointer<CChar>?
) -> UnsafeMutablePointer<CChar>?

@_silgen_name("immich_ios_login_server")
private func c_immich_ios_login_server(
  _ serverUrl: UnsafePointer<CChar>?,
  _ apiKey: UnsafePointer<CChar>?
) -> UnsafeMutablePointer<CChar>?

@_silgen_name("immich_ios_sync_and_get_buckets")
private func c_immich_ios_sync_and_get_buckets() -> UnsafeMutablePointer<CChar>?

@_silgen_name("immich_ios_get_cached_buckets")
private func c_immich_ios_get_cached_buckets() -> UnsafeMutablePointer<CChar>?

@_silgen_name("immich_ios_fetch_bucket_assets")
private func c_immich_ios_fetch_bucket_assets(
  _ timeBucket: UnsafePointer<CChar>?
) -> UnsafeMutablePointer<CChar>?

@_silgen_name("immich_ios_get_cached_bucket_assets")
private func c_immich_ios_get_cached_bucket_assets(
  _ timeBucket: UnsafePointer<CChar>?
) -> UnsafeMutablePointer<CChar>?

@_silgen_name("immich_ios_ensure_asset_cached")
private func c_immich_ios_ensure_asset_cached(
  _ assetId: UnsafePointer<CChar>?,
  _ mediaType: UnsafePointer<CChar>?
) -> UnsafeMutablePointer<CChar>?

@_silgen_name("immich_ios_prepare_asset_viewer_bundle")
private func c_immich_ios_prepare_asset_viewer_bundle(
  _ assetId: UnsafePointer<CChar>?
) -> UnsafeMutablePointer<CChar>?

@_silgen_name("immich_ios_get_asset_exif")
private func c_immich_ios_get_asset_exif(
  _ assetId: UnsafePointer<CChar>?
) -> UnsafeMutablePointer<CChar>?

@_silgen_name("immich_ios_bulk_upload_check")
private func c_immich_ios_bulk_upload_check(
  _ candidatesJson: UnsafePointer<CChar>?
) -> UnsafeMutablePointer<CChar>?

@_silgen_name("immich_ios_upload_asset")
private func c_immich_ios_upload_asset(
  _ deviceAssetId: UnsafePointer<CChar>?,
  _ deviceId: UnsafePointer<CChar>?,
  _ fileCreatedAt: UnsafePointer<CChar>?,
  _ fileModifiedAt: UnsafePointer<CChar>?,
  _ isFavorite: Bool,
  _ fileBytesPtr: UnsafePointer<UInt8>?,
  _ fileBytesLen: Int,
  _ fileName: UnsafePointer<CChar>?,
  _ livePhotoBytesPtr: UnsafePointer<UInt8>?,
  _ livePhotoBytesLen: Int,
  _ livePhotoName: UnsafePointer<CChar>?
) -> UnsafeMutablePointer<CChar>?

@_silgen_name("immich_ios_add_upload_tombstone")
private func c_immich_ios_add_upload_tombstone(
  _ localAssetId: UnsafePointer<CChar>?,
  _ accountId: UnsafePointer<CChar>?,
  _ reason: UnsafePointer<CChar>?
) -> UnsafeMutablePointer<CChar>?

@_silgen_name("immich_ios_is_upload_tombstoned")
private func c_immich_ios_is_upload_tombstoned(
  _ localAssetId: UnsafePointer<CChar>?
) -> Bool

// MARK: - Data Models

public struct CoreBucketInfo: Codable, Identifiable, Sendable {
  public var id: String { timeBucket }
  public let timeBucket: String
  public let count: Int64
}

public struct CoreExifInfo: Codable, Sendable {
  public let make: String?
  public let model: String?
  public let lensModel: String?
  public let fNumber: Double?
  public let focalLength: Double?
  public let iso: Int64?
  public let exposureTime: String?
  public let dateTimeOriginal: String?
  public let fileSizeInByte: Int64?
  public let city: String?
  public let state: String?
  public let country: String?
  public let latitude: Double?
  public let longitude: Double?
}

public struct CoreAsset: Codable, Identifiable, Sendable {
  public let id: String
  public let assetType: String
  public let fileCreatedAt: String
  public let fileModifiedAt: String?
  public let updatedAt: String?
  public let isFavorite: Bool
  public let duration: String?
  public let livePhotoVideoId: String?
  public let thumbhash: String?
  public let localThumbPath: String?
  public let localPreviewPath: String?
  public let localVideoPath: String?
  public let bucketId: String?
  public let exif: CoreExifInfo?
}

public struct CoreAssetViewerBundle: Codable, Sendable {
  public let assetId: String
  public let assetType: String
  public let imagePath: String
  public let videoPath: String?
  public let isLivePhoto: Bool
  public let duration: String?
}

public struct CoreBulkUploadCheckItem: Codable, Sendable {
  public let id: String
  public let checksum: String
  public init(id: String, checksum: String) {
    self.id = id
    self.checksum = checksum
  }
}

public struct CoreBulkUploadCheckResult: Codable, Sendable {
  public let id: String
  public let action: String // "accept" or "reject"
  public let reason: String? // "duplicate", "tombstoned", etc.
  public let assetId: String?
}

public struct CoreAssetUploadResponse: Codable, Sendable {
  public let id: String
  public let duplicate: Bool
}

public enum ImmichCoreBridgeError: LocalizedError {
  case ffiError(String)
  case invalidUTF8
  case notInitialized
  case jsonDecodeError(String)

  public var errorDescription: String? {
    switch self {
    case .ffiError(let msg): return "ImmichCore FFI Error: \(msg)"
    case .invalidUTF8: return "ImmichCore: Invalid UTF-8 string returned across FFI boundary"
    case .notInitialized: return "ImmichCore: Core engine has not been initialized"
    case .jsonDecodeError(let msg): return "ImmichCore JSON Decode Error: \(msg)"
    }
  }
}

private struct CoreFfiEnvelope<T: Decodable>: Decodable {
  let success: Bool
  let data: T?
  let error: String?
}

// MARK: - Swift Immich Core Bridge

public final class ImmichCoreBridge: @unchecked Sendable {
  public static let shared = ImmichCoreBridge()

  /// When true, operations fall back to built-in simulation / mock mode (ideal for UI Sandbox / previews).
  public var isMockMode: Bool = false

  private let decoder: JSONDecoder = {
    let d = JSONDecoder()
    return d
  }()

  private init() {}

  public var isInitialized: Bool {
    if isMockMode { return true }
    return c_immich_ios_is_initialized()
  }

  /// Initialize the native Rust core engine with local SQLite and cache paths.
  @discardableResult
  public func initializeCoreEngine(
    dbDir: URL? = nil,
    cacheDir: URL? = nil
  ) async throws -> Bool {
    if isMockMode { return true }

    let defaultDocDir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
    let defaultCacheDir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
      .appendingPathComponent("immich_core_cache", isDirectory: true)

    let actualDbDir = dbDir ?? defaultDocDir
    let actualCacheDir = cacheDir ?? defaultCacheDir

    try? FileManager.default.createDirectory(at: actualDbDir, withIntermediateDirectories: true)
    try? FileManager.default.createDirectory(at: actualCacheDir, withIntermediateDirectories: true)

    return try await Task.detached { [self] in
      let res: Bool = try invokeFfi {
        actualDbDir.path.withCString { dbCStr in
          actualCacheDir.path.withCString { cacheCStr in
            c_immich_ios_init_core_engine(dbCStr, cacheCStr)
          }
        }
      }
      return res
    }.value
  }

  /// Initialize in-memory database mode for tests or ephemeral previews.
  @discardableResult
  public func initializeInMemory(cacheDir: URL? = nil) async throws -> Bool {
    if isMockMode { return true }
    let defaultCache = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
      .appendingPathComponent("immich_mem_cache", isDirectory: true)
    let actualCache = cacheDir ?? defaultCache
    try? FileManager.default.createDirectory(at: actualCache, withIntermediateDirectories: true)

    return try await Task.detached { [self] in
      let res: Bool = try invokeFfi {
        actualCache.path.withCString { cacheCStr in
          c_immich_ios_init_in_memory(cacheCStr)
        }
      }
      return res
    }.value
  }

  /// Log in and validate server connection through Rust client.
  public func loginServer(serverUrl: String, apiKey: String) async throws -> String {
    if isMockMode {
      return "Mock login successful"
    }

    return try await Task.detached { [self] in
      let msg: String = try invokeFfi {
        serverUrl.withCString { urlCStr in
          apiKey.withCString { keyCStr in
            c_immich_ios_login_server(urlCStr, keyCStr)
          }
        }
      }
      return msg
    }.value
  }

  /// Synchronize time buckets with Immich server and local SQLite cache.
  public func syncAndGetBuckets() async throws -> [CoreBucketInfo] {
    if isMockMode {
      return [
        CoreBucketInfo(timeBucket: "2024-03-01T00:00:00.000Z", count: 18),
        CoreBucketInfo(timeBucket: "2024-02-01T00:00:00.000Z", count: 12),
        CoreBucketInfo(timeBucket: "2024-01-01T00:00:00.000Z", count: 24),
      ]
    }

    return try await Task.detached { [self] in
      let buckets: [CoreBucketInfo] = try invokeFfi {
        c_immich_ios_sync_and_get_buckets()
      }
      return buckets
    }.value
  }

  /// Retrieve cached buckets directly from SQLite without network waiting.
  public func getCachedBuckets() async throws -> [CoreBucketInfo] {
    if isMockMode { return try await syncAndGetBuckets() }

    return try await Task.detached { [self] in
      let buckets: [CoreBucketInfo] = try invokeFfi {
        c_immich_ios_get_cached_buckets()
      }
      return buckets
    }.value
  }

  /// Fetch assets for a time bucket from Immich server and update local SQLite cache.
  public func fetchBucketAssets(timeBucket: String) async throws -> [CoreAsset] {
    if isMockMode {
      return [
        CoreAsset(
          id: "mock-core-live-1",
          assetType: "IMAGE",
          fileCreatedAt: "2024-03-15T10:00:00.000Z",
          fileModifiedAt: nil,
          updatedAt: nil,
          isFavorite: true,
          duration: nil,
          livePhotoVideoId: "mock-core-live-vid-1",
          thumbhash: nil,
          localThumbPath: nil,
          localPreviewPath: nil,
          localVideoPath: nil,
          bucketId: timeBucket,
          exif: nil
        ),
        CoreAsset(
          id: "mock-core-photo-2",
          assetType: "IMAGE",
          fileCreatedAt: "2024-03-14T14:30:00.000Z",
          fileModifiedAt: nil,
          updatedAt: nil,
          isFavorite: false,
          duration: nil,
          livePhotoVideoId: nil,
          thumbhash: nil,
          localThumbPath: nil,
          localPreviewPath: nil,
          localVideoPath: nil,
          bucketId: timeBucket,
          exif: nil
        )
      ]
    }

    return try await Task.detached { [self] in
      let assets: [CoreAsset] = try invokeFfi {
        timeBucket.withCString { bucketCStr in
          c_immich_ios_fetch_bucket_assets(bucketCStr)
        }
      }
      return assets
    }.value
  }

  /// Retrieve cached assets for a bucket directly from SQLite without network waiting.
  public func getCachedBucketAssets(timeBucket: String) async throws -> [CoreAsset] {
    if isMockMode { return try await fetchBucketAssets(timeBucket: timeBucket) }

    return try await Task.detached { [self] in
      let assets: [CoreAsset] = try invokeFfi {
        timeBucket.withCString { bucketCStr in
          c_immich_ios_get_cached_bucket_assets(bucketCStr)
        }
      }
      return assets
    }.value
  }

  /// Download and ensure that an asset media (thumbnail, preview, or video) is cached in sandbox.
  public func ensureAssetCached(assetId: String, mediaType: String) async throws -> String {
    if isMockMode {
      return "/tmp/mock_cache/\(mediaType)/\(assetId).\(mediaType == "video" ? "mp4" : "jpg")"
    }

    return try await Task.detached { [self] in
      let path: String = try invokeFfi {
        assetId.withCString { idCStr in
          mediaType.withCString { typeCStr in
            c_immich_ios_ensure_asset_cached(idCStr, typeCStr)
          }
        }
      }
      return path
    }.value
  }

  /// Prepare the full viewer bundle (cached image preview, motion video if live photo, duration).
  public func prepareAssetViewerBundle(assetId: String) async throws -> CoreAssetViewerBundle {
    if isMockMode {
      return CoreAssetViewerBundle(
        assetId: assetId,
        assetType: "IMAGE",
        imagePath: "/tmp/mock_cache/preview/\(assetId).jpg",
        videoPath: "/tmp/mock_cache/video/\(assetId).mp4",
        isLivePhoto: true,
        duration: nil
      )
    }

    return try await Task.detached { [self] in
      let bundle: CoreAssetViewerBundle = try invokeFfi {
        assetId.withCString { idCStr in
          c_immich_ios_prepare_asset_viewer_bundle(idCStr)
        }
      }
      return bundle
    }.value
  }

  /// Retrieve EXIF metadata from local DB cache or remote server.
  public func getAssetExif(assetId: String) async throws -> CoreExifInfo? {
    if isMockMode {
      return CoreExifInfo(
        make: "Apple",
        model: "iPhone 16 Pro",
        lensModel: "24mm f/1.78",
        fNumber: 1.78,
        focalLength: 24.0,
        iso: 64,
        exposureTime: "1/250s",
        dateTimeOriginal: "2024-03-15 10:00:00",
        fileSizeInByte: 3500000,
        city: "San Francisco",
        state: "CA",
        country: "United States",
        latitude: 37.7749,
        longitude: -122.4194
      )
    }

    return try await Task.detached { [self] in
      let exif: CoreExifInfo? = try invokeFfiOptional {
        assetId.withCString { idCStr in
          c_immich_ios_get_asset_exif(idCStr)
        }
      }
      return exif
    }.value
  }

  /// Bulk upload check candidate assets against Immich server and local tombstones.
  public func bulkUploadCheck(candidates: [CoreBulkUploadCheckItem]) async throws -> [CoreBulkUploadCheckResult] {
    if isMockMode {
      return candidates.map {
        CoreBulkUploadCheckResult(id: $0.id, action: "accept", reason: nil, assetId: nil)
      }
    }

    let jsonStr = String(data: try JSONEncoder().encode(candidates), encoding: .utf8) ?? "[]"

    return try await Task.detached { [self] in
      let results: [CoreBulkUploadCheckResult] = try invokeFfi {
        jsonStr.withCString { c_immich_ios_bulk_upload_check($0) }
      }
      return results
    }.value
  }

  /// Upload a single asset with full dual-track support (primary photo/video + optional Live Photo paired video).
  public func uploadAsset(
    deviceAssetId: String,
    deviceId: String,
    fileCreatedAt: String,
    fileModifiedAt: String,
    isFavorite: Bool,
    fileData: Data,
    fileName: String,
    livePhotoData: Data? = nil,
    livePhotoName: String? = nil
  ) async throws -> CoreAssetUploadResponse {
    if isMockMode {
      return CoreAssetUploadResponse(id: UUID().uuidString, duplicate: false)
    }

    return try await Task.detached { [self] in
      let res: CoreAssetUploadResponse = try invokeFfi {
        deviceAssetId.withCString { cId in
          deviceId.withCString { cDev in
            fileCreatedAt.withCString { cCreated in
              fileModifiedAt.withCString { cModified in
                fileName.withCString { cName in
                  fileData.withUnsafeBytes { rawBytes in
                    let ptr = rawBytes.bindMemory(to: UInt8.self).baseAddress
                    if let liveData = livePhotoData, let lName = livePhotoName {
                      return liveData.withUnsafeBytes { rawLiveBytes in
                        let livePtr = rawLiveBytes.bindMemory(to: UInt8.self).baseAddress
                        return lName.withCString { cLiveName in
                          c_immich_ios_upload_asset(
                            cId, cDev, cCreated, cModified, isFavorite,
                            ptr, fileData.count, cName,
                            livePtr, liveData.count, cLiveName
                          )
                        }
                      }
                    } else {
                      return c_immich_ios_upload_asset(
                        cId, cDev, cCreated, cModified, isFavorite,
                        ptr, fileData.count, cName,
                        nil, 0, nil
                      )
                    }
                  }
                }
              }
            }
          }
        }
      }
      return res
    }.value
  }

  /// Add tombstone to prevent an asset from being automatically re-uploaded (e.g. after cloud deletion)
  public func addUploadTombstone(localAssetId: String, accountId: String, reason: String = "deleted_from_cloud") async throws {
    if isMockMode { return }
    let _: Bool = try await Task.detached { [self] in
      try invokeFfi {
        localAssetId.withCString { cId in
          accountId.withCString { cAcc in
            reason.withCString { cRea in
              c_immich_ios_add_upload_tombstone(cId, cAcc, cRea)
            }
          }
        }
      }
    }.value
  }

  /// Check whether a local asset has been tombstoned
  public func isUploadTombstoned(localAssetId: String) -> Bool {
    if isMockMode { return false }
    return localAssetId.withCString { c_immich_ios_is_upload_tombstoned($0) }
  }

  // MARK: - Private FFI execution helper

  private func invokeFfi<T: Decodable>(_ block: () -> UnsafeMutablePointer<CChar>?) throws -> T {
    let ptr = block()
    guard let cStr = ptr else {
      throw ImmichCoreBridgeError.ffiError("FFI returned NULL pointer")
    }
    defer { c_immich_ios_free_string(cStr) }

    guard let str = String(validatingUTF8: cStr) else {
      throw ImmichCoreBridgeError.invalidUTF8
    }

    guard let data = str.data(using: .utf8) else {
      throw ImmichCoreBridgeError.invalidUTF8
    }

    let envelope: CoreFfiEnvelope<T>
    do {
      envelope = try decoder.decode(CoreFfiEnvelope<T>.self, from: data)
    } catch {
      throw ImmichCoreBridgeError.jsonDecodeError("Failed to decode JSON: \(str). Error: \(error)")
    }

    if envelope.success {
      if let val = envelope.data {
        return val
      } else if T.self == Bool.self, let b = true as? T {
        return b
      } else {
        throw ImmichCoreBridgeError.ffiError("FFI returned success with missing data payload")
      }
    } else {
      throw ImmichCoreBridgeError.ffiError(envelope.error ?? "Unknown Rust core error")
    }
  }

  private func invokeFfiOptional<T: Decodable>(_ block: () -> UnsafeMutablePointer<CChar>?) throws -> T? {
    let ptr = block()
    guard let cStr = ptr else {
      throw ImmichCoreBridgeError.ffiError("FFI returned NULL pointer")
    }
    defer { c_immich_ios_free_string(cStr) }

    guard let str = String(validatingUTF8: cStr) else {
      throw ImmichCoreBridgeError.invalidUTF8
    }

    guard let data = str.data(using: .utf8) else {
      throw ImmichCoreBridgeError.invalidUTF8
    }

    let envelope: CoreFfiEnvelope<T>
    do {
      envelope = try decoder.decode(CoreFfiEnvelope<T>.self, from: data)
    } catch {
      throw ImmichCoreBridgeError.jsonDecodeError("Failed to decode JSON: \(str). Error: \(error)")
    }

    if envelope.success {
      return envelope.data
    } else {
      throw ImmichCoreBridgeError.ffiError(envelope.error ?? "Unknown Rust core error")
    }
  }
}

// MARK: - Extension to Convert to NativeAsset

extension CoreAsset {
  func toNativeAsset() -> NativeAsset {
    let date = NativeImmichClient.parseISODate(fileCreatedAt) ?? .distantPast
    return NativeAsset(
      id: id,
      date: date,
      isImage: assetType.uppercased() != "VIDEO",
      isFavorite: isFavorite,
      thumbhash: thumbhash,
      livePhotoVideoId: livePhotoVideoId,
      originalFileName: nil,
      originalMimeType: nil,
      width: nil,
      height: nil,
      fileSizeInByte: exif?.fileSizeInByte,
      latitude: exif?.latitude,
      longitude: exif?.longitude,
      isArchived: false
    )
  }
}
