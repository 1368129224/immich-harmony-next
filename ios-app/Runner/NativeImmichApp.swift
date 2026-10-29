import AuthenticationServices
import Combine
import CryptoKit
import Foundation
import Network
import Photos
import PhotosUI
import Security
import SwiftUI
import UIKit

@MainActor
private func nativeData(from url: URL, using session: URLSession = .shared) async throws -> (Data, URLResponse) {
  let (data, response) = try await session.data(from: url)
  return (data, response)
}

private func nativeData(for request: URLRequest, using session: URLSession = .shared) async throws -> (Data, URLResponse) {
  let (data, response) = try await session.data(for: request)
  return (data, response)
}

// MARK: - Native session and API

struct NativeServerConfig: Codable, Identifiable, Equatable {
  var id: String { "\(serverUrl)|\(userId ?? credential ?? "default")" }
  var serverUrl: String
  var apiEndpoint: String?
  var accessToken: String?
  var apiKey: String?
  var deviceId: String?
  var userId: String? = nil
  var userEmail: String? = nil
  var userName: String? = nil

  var credential: String? { accessToken ?? apiKey }
}

enum NativeSessionStore {
  private static let service = "com.immichz.session"
  private static let account = "immich.server_config"
  private static let fallbackKey = "immichz.session.fallback"
  private static let allAccountsKey = "immichz.saved_accounts_list"

  static func read() -> NativeServerConfig? {
    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: account,
      kSecReturnData as String: true,
      kSecMatchLimit as String: kSecMatchLimitOne,
    ]
    var result: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &result)
    if status == errSecSuccess, let data = result as? Data,
       let config = try? JSONDecoder().decode(NativeServerConfig.self, from: data) {
      return config
    }

    // Unsigned installations may not have Keychain access.
    if let raw = UserDefaults.standard.string(forKey: fallbackKey),
       let data = raw.data(using: .utf8),
       let config = try? JSONDecoder().decode(NativeServerConfig.self, from: data) {
      return config
    }
    return nil
  }

  static func save(_ config: NativeServerConfig) throws {
    let data = try JSONEncoder().encode(config)
    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: account,
    ]
    let attributes: [String: Any] = [kSecValueData as String: data]
    let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
    let writeStatus: OSStatus
    if status == errSecItemNotFound {
      var insert = query
      insert[kSecValueData as String] = data
      writeStatus = SecItemAdd(insert as CFDictionary, nil)
    } else {
      writeStatus = status
    }
    if writeStatus == errSecSuccess {
      UserDefaults.standard.removeObject(forKey: fallbackKey)
    } else {
      UserDefaults.standard.set(String(data: data, encoding: .utf8), forKey: fallbackKey)
    }

    // Also persist into saved accounts list
    saveToHistory(config)
  }

  static func savedAccounts() -> [NativeServerConfig] {
    guard let data = UserDefaults.standard.data(forKey: allAccountsKey),
          let list = try? JSONDecoder().decode([NativeServerConfig].self, from: data) else {
      if let current = read() { return [current] }
      return []
    }
    return list
  }

  static func saveToHistory(_ config: NativeServerConfig) {
    var list = savedAccounts()
    if let idx = list.firstIndex(where: { $0.id == config.id || ($0.serverUrl == config.serverUrl && $0.userId == config.userId) }) {
      list[idx] = config
    } else {
      list.append(config)
    }
    if let data = try? JSONEncoder().encode(list) {
      UserDefaults.standard.set(data, forKey: allAccountsKey)
    }
  }

  static func removeAccount(id: String) {
    var list = savedAccounts()
    list.removeAll { $0.id == id }
    if let data = try? JSONEncoder().encode(list) {
      UserDefaults.standard.set(data, forKey: allAccountsKey)
    }
    if let current = read(), current.id == id {
      clear()
    }
  }
}

actor NativeThumbnailDiskCache {
  static let shared = NativeThumbnailDiskCache()
  let directory: URL
  private var writesSincePrune = 0

  private init() {
    directory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("ImmichZThumbnails_v2", isDirectory: true)
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  }

  func diskUsage() -> (count: Int, bytes: Int64) {
    let files = (try? FileManager.default.contentsOfDirectory(
      at: directory,
      includingPropertiesForKeys: [.fileSizeKey],
      options: [.skipsHiddenFiles]
    )) ?? []
    var totalBytes: Int64 = 0
    for file in files {
      if let size = (try? file.resourceValues(forKeys: [.fileSizeKey]))?.fileSize {
        totalBytes += Int64(size)
      }
    }
    return (files.count, totalBytes)
  }

  func clearAll() {
    let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil, options: [])) ?? []
    for file in files {
      try? FileManager.default.removeItem(at: file)
    }
  }

  func data(for key: String) -> Data? {
    try? Data(contentsOf: fileURL(for: key), options: .mappedIfSafe)
  }

  func store(_ data: Data, for key: String) {
    let url = fileURL(for: key)
    try? data.write(to: url, options: .atomic)
    writesSincePrune += 1
    if writesSincePrune >= 128 {
      writesSincePrune = 0
      pruneIfNeeded()
    }
  }

  private func pruneIfNeeded() {
    let files = (try? FileManager.default.contentsOfDirectory(
      at: directory,
      includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey],
      options: [.skipsHiddenFiles]
    )) ?? []
    let entries = files.compactMap { url -> (URL, Int, Date)? in
      guard let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]),
            let size = values.fileSize else { return nil }
      return (url, size, values.contentModificationDate ?? .distantPast)
    }
    var total = entries.reduce(0) { $0 + $1.1 }
    guard total > 384 * 1024 * 1024 else { return }
    for (url, size, _) in entries.sorted(by: { $0.2 < $1.2 }) {
      try? FileManager.default.removeItem(at: url)
      total -= size
      if total <= 320 * 1024 * 1024 { break }
    }
  }

  private func fileURL(for key: String) -> URL {
    let digest = SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()
    return directory.appendingPathComponent(digest).appendingPathExtension("thumb")
  }
}

private enum NativeThumbnailPipeline {
  static let networkSession: URLSession = {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.urlCache = nil
    configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
    configuration.httpMaximumConnectionsPerHost = 5
    return URLSession(configuration: configuration)
  }()
}

private enum NativeAPIError: LocalizedError {
  case invalidServer
  case unauthorized
  case http(Int, String)
  case invalidResponse
  case invalidJSON(String)

  var errorDescription: String? {
    switch self {
    case .invalidServer: return "无法连接 Immich 服务器，请检查服务器地址。"
    case .unauthorized: return "认证失败。请检查服务器地址和凭据。"
    case let .http(code, message): return "服务器请求失败（\(code)）：\(message)"
    case .invalidResponse: return "服务器返回了无法识别的数据。"
    case let .invalidJSON(endpoint): return "服务器在 \(endpoint) 返回的数据不是有效 JSON。请检查服务器版本及反向代理的 /api 配置。"
    }
  }
}

struct NativeBackgroundDiagnostic: Identifiable, Codable {
  let id: UUID
  let date: Date
  let operation: String
  let category: String
}

// Only sanitized categories are persisted. Never store server responses,
// credentials, asset identifiers, or raw localized error descriptions.
@MainActor
final class NativeBackgroundDiagnostics: ObservableObject {
  static let shared = NativeBackgroundDiagnostics()
  @Published private(set) var entries: [NativeBackgroundDiagnostic] = []
  private var identity: String?

  private init() { configureForCurrentAccount() }

  func configureForCurrentAccount() {
    let current = NativeSyncCacheStore.shared.identity
    guard current != identity else { return }
    identity = current
    entries = NativePhotoSnapshotStore.shared.diagnostics(identity: current)
  }

  func record(_ operation: String, category: String) {
    configureForCurrentAccount()
    if entries.contains(where: {
      $0.operation == operation && $0.category == category &&
        Date().timeIntervalSince($0.date) < 60
    }) { return }
    entries.insert(NativeBackgroundDiagnostic(
      id: UUID(), date: Date(), operation: operation, category: category
    ), at: 0)
    if entries.count > 30 { entries = Array(entries.prefix(30)) }
    if identity != nil {
      NativePhotoSnapshotStore.shared.saveDiagnostics(
        entries, expectedIdentity: identity
      )
    }
  }

  func record(_ operation: String, error: Error) {
    let category: String
    if let api = error as? NativeAPIError {
      switch api {
      case .unauthorized: category = "身份认证失败"
      case let .http(code, _): category = "HTTP \(code)"
      case .invalidJSON: category = "服务器响应格式错误"
      case .invalidResponse: category = "服务器响应异常"
      case .invalidServer: category = "服务器地址无效"
      }
    } else if let urlError = error as? URLError {
      switch urlError.code {
      case .timedOut: category = "网络超时"
      case .notConnectedToInternet, .cannotConnectToHost,
           .cannotFindHost, .networkConnectionLost, .dnsLookupFailed:
        category = "网络连接失败"
      default: category = "网络错误 \(urlError.code.rawValue)"
      }
    } else {
      category = "后台请求失败"
    }
    record(operation, category: category)
  }

  func clear() {
    entries = []
    identity = nil
  }
}

// Session-scoped diagnostics for verified matches whose server DTO is not yet
// available in the timeline. Never expose asset IDs or raw server responses.
@MainActor
final class NativeMatchedAssetDiagnostics: ObservableObject {
  @Published private(set) var attempted = 0
  @Published private(set) var loaded = 0
  @Published private(set) var pending = 0
  @Published private(set) var lastAttempt: Date?
  @Published private(set) var lastFailure: Date?
  @Published private(set) var lastFailureCategory: String?
  @Published private(set) var failureCounts: [String: Int] = [:]
  private var failedAssets: [String: String] = [:]

  var unresolvedCount: Int { failedAssets.count }

  func started() {
    attempted += 1
    pending += 1
    lastAttempt = Date()
  }

  func succeeded(id: String) {
    pending = max(0, pending - 1)
    loaded += 1
    failedAssets.removeValue(forKey: id)
    refreshCounts()
  }

  func failed(id: String, error: Error?) {
    pending = max(0, pending - 1)
    let category: String
    if let error = error as? NativeAPIError {
      switch error {
      case .unauthorized: category = "认证失败 (401/403)"
      case let .http(code, _): category = "HTTP \(code)"
      case .invalidJSON: category = "响应 JSON 无效"
      case .invalidResponse: category = "响应格式异常"
      case .invalidServer: category = "服务器地址无效"
      }
    } else if let error = error as? URLError {
      switch error.code {
      case .timedOut: category = "请求超时"
      case .notConnectedToInternet, .networkConnectionLost, .cannotConnectToHost,
           .cannotFindHost, .dnsLookupFailed: category = "网络连接失败"
      default: category = "网络错误 (\(error.code.rawValue))"
      }
    } else {
      category = error == nil ? "响应缺少有效资产信息" : "其他请求错误"
    }
    failedAssets[id] = category
    lastFailure = Date()
    lastFailureCategory = category
    refreshCounts()
  }

  private func refreshCounts() {
    failureCounts = Dictionary(grouping: failedAssets.values, by: { $0 }).mapValues(\.count)
  }
}

@MainActor
final class NativeImmichClient {
  let config: NativeServerConfig
  private let session: URLSession

  init(config: NativeServerConfig, session: URLSession = .shared) {
    self.config = config
    self.session = session
  }

  nonisolated static func normalize(_ raw: String) -> String {
    var value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    if !value.hasPrefix("http://") && !value.hasPrefix("https://") { value = "https://" + value }
    while value.hasSuffix("/") { value.removeLast() }
    return value
  }

  static func discover(_ raw: String) async throws -> String {
    let base = normalize(raw)
    guard let url = URL(string: base), url.host != nil else { throw NativeAPIError.invalidServer }
    var candidates = [String]()
    if let wellKnown = URL(string: base + "/.well-known/immich"),
       let (data, response) = try? await nativeData(from: wellKnown),
       (response as? HTTPURLResponse)?.statusCode == 200,
       let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
       let api = object["api"] as? String, !api.isEmpty {
      candidates.append(api.hasPrefix("http") ? api : base + api)
    }
    candidates.append(contentsOf: [base + "/api", base])
    for candidate in candidates {
      guard let ping = URL(string: candidate + "/server/ping"),
            let (data, response) = try? await nativeData(from: ping),
            (response as? HTTPURLResponse)?.statusCode == 200,
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
      let pong = (object["res"] as? String) == "pong" || (object["res"] as? Bool) == true
      guard pong else { continue }
      return candidate
    }
    throw NativeAPIError.invalidServer
  }

  static func login(server: String, email: String, password: String) async throws -> NativeServerConfig {
    let endpoint = try await discover(server)
    let temporary = NativeImmichClient(config: NativeServerConfig(serverUrl: normalize(server), apiEndpoint: endpoint))
    let result = try await temporary.send(path: "auth/login", method: "POST", body: ["email": email, "password": password])
    guard let token = result["accessToken"] as? String, !token.isEmpty else { throw NativeAPIError.invalidResponse }
    var config = NativeServerConfig(serverUrl: normalize(server), apiEndpoint: endpoint, accessToken: token)
    config.userId = try await NativeImmichClient(config: config).verifiedUserID()
    return config
  }

  static func login(server: String, apiKey: String) async throws -> NativeServerConfig {
    let endpoint = try await discover(server)
    var config = NativeServerConfig(serverUrl: normalize(server), apiEndpoint: endpoint, apiKey: apiKey)
    config.userId = try await NativeImmichClient(config: config).verifiedUserID()
    return config
  }

  static func fetchOAuthConfig(server: String, redirectUri: String) async throws -> (enabled: Bool, url: String?, buttonText: String?) {
    let endpoint = try await discover(server)
    guard let url = URL(string: "\(endpoint)/oauth/config") else {
      throw NativeAPIError.invalidServer
    }
    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.httpBody = try JSONSerialization.data(withJSONObject: ["redirectUri": redirectUri])
    let (data, response) = try await nativeData(for: request)
    try Self.check(response: response, data: data)
    guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
      throw NativeAPIError.invalidJSON("/oauth/config")
    }
    let enabled = json["enabled"] as? Bool ?? false
    let authUrl = json["url"] as? String
    let buttonText = json["buttonText"] as? String
    return (enabled, authUrl, buttonText)
  }

  static func oauthCallback(server: String, callbackUrl: String) async throws -> NativeServerConfig {
    let endpoint = try await discover(server)
    guard let url = URL(string: "\(endpoint)/oauth/callback") else {
      throw NativeAPIError.invalidServer
    }
    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.httpBody = try JSONSerialization.data(withJSONObject: ["url": callbackUrl])
    let (data, response) = try await nativeData(for: request)
    try Self.check(response: response, data: data)
    guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
          let token = json["accessToken"] as? String else {
      throw NativeAPIError.invalidJSON("/oauth/callback")
    }
    let userId = json["userId"] as? String
    let userEmail = json["userEmail"] as? String
    let userName = json["name"] as? String
    var config = NativeServerConfig(
      serverUrl: normalize(server),
      apiEndpoint: endpoint,
      accessToken: token,
      apiKey: nil,
      deviceId: nil,
      userId: userId,
      userEmail: userEmail,
      userName: userName
    )
    if config.userId == nil {
      config.userId = try? await NativeImmichClient(config: config).verifiedUserID()
    }
    return config
  }

  func verifiedUserID() async throws -> String {
    let response = try await send(path: "users/me")
    guard let id = response["id"] as? String, !id.isEmpty else { throw NativeAPIError.invalidResponse }
    return id
  }

  func verifySession() async throws {
    _ = try await verifiedUserID()
  }

  func send(path: String, method: String = "GET", query: [URLQueryItem] = [], body: [String: Any]? = nil) async throws -> [String: Any] {
    let base = config.apiEndpoint ?? (Self.normalize(config.serverUrl) + "/api")
    guard var components = URLComponents(string: base + "/" + path) else { throw NativeAPIError.invalidServer }
    if !query.isEmpty { components.queryItems = query }
    guard let url = components.url else { throw NativeAPIError.invalidServer }
    var request = URLRequest(url: url)
    request.httpMethod = method
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    applyAuth(to: &request)
    if let body {
      request.setValue("application/json", forHTTPHeaderField: "Content-Type")
      request.httpBody = try JSONSerialization.data(withJSONObject: body)
    }
    let (data, response) = try await nativeData(for: request, using: session)
    guard let http = response as? HTTPURLResponse else { throw NativeAPIError.invalidResponse }
    guard (200..<300).contains(http.statusCode) else {
      if http.statusCode == 401 || http.statusCode == 403 { throw NativeAPIError.unauthorized }
      let message = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["message"] as? String ?? ""
      throw NativeAPIError.http(http.statusCode, message)
    }
    if data.isEmpty { return [:] } // DELETE endpoints may return HTTP 204 No Content.
    do {
      guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        throw NativeAPIError.invalidJSON(path)
      }
      return object
    } catch let error as NativeAPIError { throw error }
    catch { throw NativeAPIError.invalidJSON(path) }
  }

  func timelineBuckets() async throws -> [NativeBucket] {
    if ImmichCoreBridge.shared.isInitialized {
      do {
        let coreBuckets = try await ImmichCoreBridge.shared.syncAndGetBuckets()
        if !coreBuckets.isEmpty {
          return coreBuckets.map { NativeBucket(id: $0.timeBucket, count: Int($0.count)) }
        }
      } catch {
        if let cached = try? await ImmichCoreBridge.shared.getCachedBuckets(), !cached.isEmpty {
          return cached.map { NativeBucket(id: $0.timeBucket, count: Int($0.count)) }
        }
      }
    }
    let base = config.apiEndpoint ?? (Self.normalize(config.serverUrl) + "/api")
    guard var components = URLComponents(string: base + "/timeline/buckets") else { throw NativeAPIError.invalidServer }
    components.queryItems = [
      URLQueryItem(name: "order", value: "desc"),
      URLQueryItem(name: "orderBy", value: "takenAt"),
      URLQueryItem(name: "visibility", value: "timeline"),
    ]
    guard let url = components.url else { throw NativeAPIError.invalidServer }
    var request = URLRequest(url: url)
    applyAuth(to: &request)
    let (data, response) = try await nativeData(for: request, using: session)
    try check(response: response, data: data)
    let payload = try parseJSON(data, endpoint: "/timeline/buckets")
    guard let rows = payload as? [[String: Any]] else { throw NativeAPIError.invalidJSON("/timeline/buckets") }
    return rows.compactMap { row in
      guard let id = row["timeBucket"] as? String else { return nil }
      return NativeBucket(id: id, count: row["count"] as? Int ?? 0)
    }
  }

  func assets(in bucket: NativeBucket) async throws -> [NativeAsset] {
    if ImmichCoreBridge.shared.isInitialized {
      do {
        let coreAssets = try await ImmichCoreBridge.shared.fetchBucketAssets(timeBucket: bucket.id)
        if !coreAssets.isEmpty {
          return coreAssets.map { $0.toNativeAsset() }
        }
      } catch {
        if let cached = try? await ImmichCoreBridge.shared.getCachedBucketAssets(timeBucket: bucket.id), !cached.isEmpty {
          return cached.map { $0.toNativeAsset() }
        }
      }
    }
    let base = config.apiEndpoint ?? (Self.normalize(config.serverUrl) + "/api")
    guard var components = URLComponents(string: base + "/timeline/bucket") else { throw NativeAPIError.invalidServer }
    let bucketParam = bucket.id.count == 10 ? "\(bucket.id)T00:00:00.000Z" : bucket.id
    components.queryItems = [
      URLQueryItem(name: "timeBucket", value: bucketParam),
      URLQueryItem(name: "order", value: "desc"),
      URLQueryItem(name: "orderBy", value: "takenAt"),
      URLQueryItem(name: "visibility", value: "timeline"),
    ]
    guard let url = components.url else { throw NativeAPIError.invalidServer }
    var request = URLRequest(url: url)
    applyAuth(to: &request)
    let (data, response) = try await nativeData(for: request, using: session)
    try check(response: response, data: data)
    let payload = try parseJSON(data, endpoint: "/timeline/bucket")
    guard let object = payload as? [String: Any], let ids = object["id"] as? [Any] else {
      throw NativeAPIError.invalidJSON("/timeline/bucket")
    }
    func strings(_ key: String) -> [Any] { object[key] as? [Any] ?? [] }
    let dates = strings("fileCreatedAt")
    let created = strings("createdAt")
    let images = strings("isImage")
    let favorites = strings("isFavorite")
    let hashes = strings("thumbhash")
    let livePhotoIDs = strings("livePhotoVideoId")
    let fileNames = strings("originalFileName")
    let mimeTypes = strings("originalMimeType")
    let widths = strings("width")
    let heights = strings("height")
    let sizes = strings("fileSizeInByte")
    let latitudes = strings("latitude")
    let longitudes = strings("longitude")
    let visibility = strings("visibility")
    return ids.enumerated().compactMap { index, rawID in
      guard let id = rawID as? String else { return nil }
      let dateString = (dates[safe: index] as? String) ?? (created[safe: index] as? String) ?? bucket.id
      let date = Self.parseISODate(dateString) ?? Self.parseISODate(bucket.id) ?? .distantPast
      return NativeAsset(
        id: id,
        date: date,
        isImage: images[safe: index] as? Bool ?? true,
        isFavorite: favorites[safe: index] as? Bool ?? false,
        thumbhash: hashes[safe: index] as? String,
        livePhotoVideoId: livePhotoIDs[safe: index] as? String,
        originalFileName: fileNames[safe: index] as? String,
        originalMimeType: mimeTypes[safe: index] as? String,
        width: widths[safe: index] as? Int,
        height: heights[safe: index] as? Int,
        fileSizeInByte: (sizes[safe: index] as? NSNumber)?.int64Value,
        latitude: (latitudes[safe: index] as? NSNumber)?.doubleValue,
        longitude: (longitudes[safe: index] as? NSNumber)?.doubleValue,
        isArchived: (visibility[safe: index] as? String) == "archive" || (visibility[safe: index] as? String) == "ARCHIVE"
      )
    }
  }

  func deleteAsset(id: String) async throws {
    try await deleteAssets(ids: [id])
  }

  func deleteAssets(ids: [String]) async throws {
    guard !ids.isEmpty else { return }
    // Omit `force` so Immich applies its normal trash/recycle-bin semantics.
    _ = try await send(path: "assets", method: "DELETE", body: ["ids": ids])
  }

  func createAlbum(name: String) async throws -> [String: Any] {
    let payload: [String: Any] = [
      "albumName": name
    ]
    return try await send(path: "albums", method: "POST", body: payload)
  }

  func deleteAlbum(id: String) async throws {
    _ = try await send(path: "albums/\(id)", method: "DELETE")
  }

  func updateFavorite(id: String, isFavorite: Bool) async throws {
    try await updateFavorites(ids: [id], isFavorite: isFavorite)
  }

  func updateFavorites(ids: [String], isFavorite: Bool) async throws {
    guard !ids.isEmpty else { return }
    _ = try await send(path: "assets", method: "PUT", body: ["ids": ids, "isFavorite": isFavorite])
  }

  func updateVisibility(ids: [String], visibility: String) async throws {
    guard !ids.isEmpty else { return }
    _ = try await send(path: "assets", method: "PUT", body: ["ids": ids, "visibility": visibility])
  }


  func addAssetsToAlbum(ids: [String], albumID: String) async throws -> [[String: Any]] {
    guard !ids.isEmpty else { return [] }
    let base = config.apiEndpoint ?? (Self.normalize(config.serverUrl) + "/api")
    guard let url = URL(string: base + "/albums/\(albumID)/assets") else { throw NativeAPIError.invalidServer }
    var request = URLRequest(url: url)
    request.httpMethod = "PUT"
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.httpBody = try JSONSerialization.data(withJSONObject: ["ids": ids])
    applyAuth(to: &request)
    let (data, response) = try await nativeData(for: request, using: session)
    try check(response: response, data: data)
    guard let results = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
      throw NativeAPIError.invalidJSON("/albums/{id}/assets")
    }
    return results
  }

  func removeAssetsFromAlbum(ids: [String], albumID: String) async throws {
    guard !ids.isEmpty else { return }
    let base = config.apiEndpoint ?? (Self.normalize(config.serverUrl) + "/api")
    guard let url = URL(string: base + "/albums/\(albumID)/assets") else { throw NativeAPIError.invalidServer }
    var request = URLRequest(url: url)
    request.httpMethod = "DELETE"
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.httpBody = try JSONSerialization.data(withJSONObject: ["ids": ids])
    applyAuth(to: &request)
    let (data, response) = try await nativeData(for: request, using: session)
    try check(response: response, data: data)
  }

  func recentlyAddedPage(cursor: String? = nil) async throws -> NativeSearchPage {
    var payload: [String: Any] = [
      "size": 100,
      "orderBy": ["field": "createdAt", "direction": "desc"],
    ]
    if let cursor { payload["cursor"] = cursor }
    let result = try await send(path: "search/metadata", method: "POST", body: payload)
    guard let page = result["assets"] as? [String: Any], let items = page["items"] as? [[String: Any]] else {
      throw NativeAPIError.invalidResponse
    }
    return NativeSearchPage(assets: items.compactMap(Self.decodeAsset), next: page["nextCursor"] as? String)
  }

  func restoreTrash(ids: [String]) async throws {
    guard !ids.isEmpty else { return }
    do {
      _ = try await send(path: "trash/restore", method: "POST", body: ["ids": ids])
    } catch {
      _ = try await send(path: "trash/restore/assets", method: "POST", body: ["ids": ids])
    }
  }

  func emptyTrash() async throws {
    _ = try await send(path: "trash/empty", method: "POST")
  }

  func deletePermanently(ids: [String]) async throws {
    guard !ids.isEmpty else { return }
    _ = try await send(path: "assets", method: "DELETE", body: ["ids": ids, "force": true])
  }

  func assetInfo(id: String) async throws -> [String: Any] {
    try await send(path: "assets/\(id)", method: "GET")
  }

  func serverAsset(id: String) async throws -> NativeAsset? {
    NativeImmichClient.decodeAsset(try await assetInfo(id: id))
  }

  func originalFile(for asset: NativeAsset) async throws -> URL {
    guard let url = originalURL(for: asset),
          let endpoint = URL(string: config.apiEndpoint ?? (Self.normalize(config.serverUrl) + "/api")),
          url.scheme == endpoint.scheme, url.host == endpoint.host, url.port == endpoint.port,
          url.path.hasPrefix(endpoint.path + "/") else { throw NativeAPIError.invalidServer }
    var request = URLRequest(url: url)
    request.timeoutInterval = 300
    request.setValue("*/*", forHTTPHeaderField: "Accept")
    applyAuth(to: &request)
    let (downloadedURL, response) = try await session.download(for: request)
    try check(response: response, data: Data())
    let suggestedName = asset.originalFileName ?? "immich-\(asset.id).\(asset.isImage ? "jpg" : "mp4")"
    let fileName = URL(fileURLWithPath: suggestedName).lastPathComponent
    let target = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString)-\(fileName)")
    do { try FileManager.default.moveItem(at: downloadedURL, to: target) }
    catch { try? FileManager.default.removeItem(at: downloadedURL); throw error }
    return target
  }

  nonisolated func originalURL(for asset: NativeAsset) -> URL? {
    let base = config.apiEndpoint ?? (Self.normalize(config.serverUrl) + "/api")
    return URL(string: base + "/assets/\(asset.id)/original")
  }

  nonisolated func thumbnailURL(for asset: NativeAsset, size: String = "preview") -> URL? {
    let base = config.apiEndpoint ?? (Self.normalize(config.serverUrl) + "/api")
    var components = URLComponents(string: base + "/assets/\(asset.id)/thumbnail")
    components?.queryItems = [URLQueryItem(name: "size", value: size)]
    return components?.url
  }

  func imageData(for url: URL) async throws -> Data {
    try await imageData(for: url, using: session, cacheable: false)
  }

  func thumbnailData(for url: URL) async throws -> Data {
    try await imageData(for: url, using: NativeThumbnailPipeline.networkSession, cacheable: true)
  }

  private func imageData(for url: URL, using imageSession: URLSession, cacheable: Bool) async throws -> Data {
    guard let endpoint = URL(string: config.apiEndpoint ?? (Self.normalize(config.serverUrl) + "/api")),
          url.scheme == endpoint.scheme, url.host == endpoint.host, url.port == endpoint.port,
          url.path.hasPrefix(endpoint.path + "/") else { throw NativeAPIError.invalidServer }
    var request = URLRequest(url: url)
    request.cachePolicy = cacheable ? .returnCacheDataElseLoad : .useProtocolCachePolicy
    request.setValue("image/*", forHTTPHeaderField: "Accept")
    applyAuth(to: &request)
    let (data, response) = try await nativeData(for: request, using: imageSession)
    try check(response: response, data: data)
    return data
  }

  private func parseJSON(_ data: Data, endpoint: String) throws -> Any {
    do { return try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) }
    catch { throw NativeAPIError.invalidJSON(endpoint) }
  }

  private func applyAuth(to request: inout URLRequest) {
    request.setValue(config.deviceId ?? "immichz-ios", forHTTPHeaderField: "x-immich-device-id")
    if let token = config.accessToken { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
    if let key = config.apiKey { request.setValue(key, forHTTPHeaderField: "x-api-key") }
  }

  static func check(response: URLResponse, data: Data) throws {
    guard let http = response as? HTTPURLResponse else { throw NativeAPIError.invalidResponse }
    guard (200..<300).contains(http.statusCode) else {
      if http.statusCode == 401 || http.statusCode == 403 { throw NativeAPIError.unauthorized }
      throw NativeAPIError.http(http.statusCode, "")
    }
  }

  func check(response: URLResponse, data: Data) throws {
    try Self.check(response: response, data: data)
  }

  nonisolated static func parseISODate(_ value: String) -> Date? {
    // Immich metadata normally carries an explicit offset. Some compatible
    // servers send wall-clock timestamps without one; interpret those in the
    // current app/device timezone instead of silently treating them as UTC.
    let hasExplicitZone = value.range(of: #"(?:Z|[+-]\d{2}:?\d{2})$"#, options: .regularExpression) != nil
    if !hasExplicitZone { return parseDate(value) }
    let f1 = ISO8601DateFormatter()
    f1.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let d = f1.date(from: value) { return d }
    let f2 = ISO8601DateFormatter()
    f2.formatOptions = [.withInternetDateTime]
    if let d = f2.date(from: value) { return d }
    return parseDate(value)
  }

  nonisolated static func formatChineseDateTime(_ date: Date) -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "zh_CN")
    formatter.timeZone = .autoupdatingCurrent
    formatter.dateStyle = .long
    formatter.timeStyle = .short
    return formatter.string(from: date)
  }

  nonisolated static func formatChineseDate(_ date: Date, includeDay: Bool = true) -> String {
    var calendar = Calendar.autoupdatingCurrent
    calendar.timeZone = .autoupdatingCurrent
    let currentYear = calendar.component(.year, from: Date())
    let year = calendar.component(.year, from: date)
    let month = calendar.component(.month, from: date)
    let day = calendar.component(.day, from: date)
    if includeDay {
      if year == currentYear {
        return "\(month)月\(day)日"
      } else {
        return "\(year)年\(month)月\(day)日"
      }
    } else {
      if year == currentYear {
        return "\(month)月"
      } else {
        return "\(year)年\(month)月"
      }
    }
  }

  nonisolated static func formatViewerTopDateTitle(_ date: Date) -> (date: String, time: String) {
    var calendar = Calendar.autoupdatingCurrent
    calendar.timeZone = .autoupdatingCurrent
    let now = Date()

    let timeFormatter = DateFormatter()
    timeFormatter.locale = Locale(identifier: "zh_CN")
    timeFormatter.timeZone = .autoupdatingCurrent
    timeFormatter.dateFormat = "HH:mm"
    let timeStr = timeFormatter.string(from: date)

    let weekdayFormatter = DateFormatter()
    weekdayFormatter.locale = Locale(identifier: "zh_CN")
    weekdayFormatter.timeZone = .autoupdatingCurrent
    weekdayFormatter.dateFormat = "EEEE"
    let weekdayStr = weekdayFormatter.string(from: date)

    if calendar.isDateInToday(date) {
      return ("今天", timeStr)
    } else if calendar.isDateInYesterday(date) {
      return ("昨天", timeStr)
    }

    let dayDiff = abs(calendar.dateComponents([.day], from: date, to: now).day ?? 100)
    let isCurrentYear = calendar.isDate(date, equalTo: now, toGranularity: .year)
    if dayDiff < 7 {
      return (weekdayStr, timeStr)
    } else if isCurrentYear {
      let monthDayFormatter = DateFormatter()
      monthDayFormatter.locale = Locale(identifier: "zh_CN")
      monthDayFormatter.timeZone = .autoupdatingCurrent
      monthDayFormatter.dateFormat = "M月d日"
      return ("\(monthDayFormatter.string(from: date)) \(weekdayStr)", timeStr)
    } else {
      let fullFormatter = DateFormatter()
      fullFormatter.locale = Locale(identifier: "zh_CN")
      fullFormatter.timeZone = .autoupdatingCurrent
      fullFormatter.dateFormat = "yyyy年M月d日"
      return (fullFormatter.string(from: date), timeStr)
    }
  }

  nonisolated private static func parseDate(_ value: String) -> Date? {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    // Naive timestamps from compatible Immich servers represent wall-clock
    // time in the device/app timezone; explicit offsets remain authoritative.
    formatter.timeZone = .autoupdatingCurrent
    for format in [
      "yyyy-MM-dd'T'HH:mm:ss.SSSSSSXXXXX",
      "yyyy-MM-dd'T'HH:mm:ss.SSSSSS",
      "yyyy-MM-dd'T'HH:mm:ss.SSSXXXXX",
      "yyyy-MM-dd'T'HH:mm:ss.SSS",
      "yyyy-MM-dd'T'HH:mm:ssXXXXX",
      "yyyy-MM-dd'T'HH:mm:ss",
      "yyyy-MM-dd"
    ] {
      formatter.dateFormat = format
      if let date = formatter.date(from: value) { return date }
    }
    return nil
  }
}

private extension Array {
  subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}

struct NativeBucket: Identifiable, Codable {
  let id: String
  let count: Int
}

func nativeRefreshedBucketBoundary(old: [NativeBucket], next: Int, refreshed: [NativeBucket]) -> Int {
  guard next > 0 else { return 0 }
  let remainingID = next < old.count ? old[next].id : nil
  let lastLoadedID = next <= old.count ? old[next - 1].id : nil
  if let remainingID, let index = refreshed.firstIndex(where: { $0.id == remainingID }) { return index }
  if let lastLoadedID, let index = refreshed.firstIndex(where: { $0.id == lastLoadedID }) { return index + 1 }
  return min(next, refreshed.count)
}

func nativeBoundaryAfterFetchingHead(old: [NativeBucket], next: Int, refreshed: [NativeBucket], headSize: Int) -> Int {
  max(min(headSize, refreshed.count), nativeRefreshedBucketBoundary(old: old, next: next, refreshed: refreshed))
}

struct NativeAsset: Identifiable, Codable {
  let id: String
  let date: Date
  let isImage: Bool
  let isFavorite: Bool
  let thumbhash: String?
  var livePhotoVideoId: String? = nil
  var originalFileName: String? = nil
  var originalMimeType: String? = nil
  var width: Int? = nil
  var height: Int? = nil
  var fileSizeInByte: Int64? = nil
  var latitude: Double? = nil
  var longitude: Double? = nil
  var isArchived: Bool = false
}

// MARK: - SwiftUI app and login

@MainActor
struct NativeImmichRootView: View {
  @State private var config: NativeServerConfig?
  @State private var restoreError: String?

  init() {
    let saved = NativeSessionStore.read()
    if let saved, saved.credential != nil {
      NativeSyncCacheStore.shared.configure(server: saved.serverUrl, userId: saved.userId)
      NativeBackgroundDiagnostics.shared.configureForCurrentAccount()
      _config = State(initialValue: saved)
    } else {
      _config = State(initialValue: nil)
    }
  }

  var body: some View {
    Group {
      if let config {
        NativeTabShell(client: NativeImmichClient(config: config)) {
          NativeBackgroundDiagnostics.shared.clear()
          NativePhotoSnapshotStore.shared.clearCurrentAccount()
          NativeSyncCacheStore.shared.clear()
          NativeSessionStore.clear()
          self.config = nil
          restoreError = nil
        }
        .id("\(config.serverUrl)|\(config.userId ?? "unverified")")
      } else {
        NativeLoginView(error: restoreError) { config = $0 }
      }
    }
    .task {
      // Initialize cross-platform Rust core engine
      _ = try? await ImmichCoreBridge.shared.initializeCoreEngine()
      if let saved = config, let key = saved.apiKey ?? saved.accessToken {
        _ = try? await ImmichCoreBridge.shared.loginServer(serverUrl: saved.serverUrl, apiKey: key)
      }
      guard let saved = config, saved.credential != nil else { return }
      // Restore the verified cache before the first frame. Session validation
      // runs independently and never blocks the cached photo timeline.
      do {
        let userID = try await NativeImmichClient(config: saved).verifiedUserID()
        guard config?.credential == saved.credential else { return }
        if saved.userId != userID {
          NativeSyncCacheStore.shared.configure(server: saved.serverUrl, userId: userID)
          NativeBackgroundDiagnostics.shared.configureForCurrentAccount()
          var verified = saved
          verified.userId = userID
          try? NativeSessionStore.save(verified)
          config = verified
        }
      } catch {
        guard config?.credential == saved.credential else { return }
        NativeBackgroundDiagnostics.shared.record("验证登录状态", error: error)
        // Authentication and connectivity errors must not delete offline
        // metadata. Only an explicit Logout clears the account's cache.
        restoreError = error.localizedDescription
      }
    }
  }
}

private extension NativeSessionStore {
  static func clear() {
    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: account,
    ]
    SecItemDelete(query as CFDictionary)
    UserDefaults.standard.removeObject(forKey: fallbackKey)
  }
}

@MainActor
final class NativeOAuthSessionManager: NSObject, ASWebAuthenticationPresentationContextProviding {
  static let shared = NativeOAuthSessionManager()

  func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
    let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
    for scene in scenes {
      if let window = scene.windows.first(where: { $0.isKeyWindow }) {
        return window
      }
    }
    return ASPresentationAnchor()
  }

  @MainActor
  func authenticate(authURL: URL, callbackScheme: String) async throws -> URL {
    try await withCheckedThrowingContinuation { continuation in
      let session = ASWebAuthenticationSession(
        url: authURL,
        callbackURLScheme: callbackScheme
      ) { callbackURL, error in
        if let error = error {
          continuation.resume(throwing: error)
        } else if let callbackURL = callbackURL {
          continuation.resume(returning: callbackURL)
        } else {
          continuation.resume(throwing: NativeAPIError.invalidServer)
        }
      }
      session.presentationContextProvider = self
      session.prefersEphemeralWebBrowserSession = false
      if !session.start() {
        continuation.resume(throwing: NativeAPIError.invalidServer)
      }
    }
  }
}

private struct NativeLoginView: View {
  let error: String?
  let onLogin: (NativeServerConfig) -> Void
  @State private var server = ""
  @State private var email = ""
  @State private var password = ""
  @State private var apiKey = ""
  @State private var useAPIKey = false
  @State private var busy = false
  @State private var loginError: String?

  var body: some View {
    NavigationView {
      Form {
        let history = NativeSessionStore.savedAccounts()
        if !history.isEmpty {
          Section(header: Text("已保存的服务器与账号")) {
            ForEach(history) { item in
              Button {
                server = item.serverUrl
                if let key = item.apiKey {
                  useAPIKey = true
                  apiKey = key
                } else if let emailVal = item.userEmail {
                  useAPIKey = false
                  email = emailVal
                }
              } label: {
                VStack(alignment: .leading, spacing: 2) {
                  Text(item.userEmail ?? (item.apiKey != nil ? "API Key 授权" : item.serverUrl))
                    .font(.subheadline)
                    .foregroundColor(.primary)
                  Text(item.serverUrl)
                    .font(.caption2)
                    .foregroundColor(.secondary)
                }
              }
            }
          }
        }

        Section {
          TextField("https://immich.example.com", text: $server)
            .textInputAutocapitalization(.never)
            .keyboardType(.URL)
            .autocorrectionDisabled()
          Toggle("使用 API Key 登录", isOn: $useAPIKey)
        } header: { Text("Immich 服务器") }

        Section {
          if useAPIKey {
            SecureField("API Key", text: $apiKey)
              .textInputAutocapitalization(.never)
              .autocorrectionDisabled()
          } else {
            TextField("邮箱", text: $email)
              .textInputAutocapitalization(.never)
              .keyboardType(.emailAddress)
              .autocorrectionDisabled()
            SecureField("密码", text: $password)
          }
        } header: { Text("登录凭据") }

        if let message = loginError ?? error {
          Section { Text(message).foregroundColor(.red) }
        }

        Section {
          Button {
            Task { await login() }
          } label: {
            HStack {
              Spacer()
              if busy { ProgressView() } else { Text("登录") }
              Spacer()
            }
          }
          .disabled(busy || server.isEmpty || (useAPIKey ? apiKey.isEmpty : email.isEmpty || password.isEmpty))
        }

        Section(header: Text("单点登录")) {
          Button {
            Task { await loginWithOAuth() }
          } label: {
            HStack {
              Spacer()
              Image(systemName: "person.badge.key")
              Text("使用 OAuth / SSO 登录")
              Spacer()
            }
          }
          .disabled(busy || server.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
      }
      .navigationTitle("Immich")
    }
    .navigationViewStyle(.stack)
  }

  @MainActor private func login() async {
    busy = true
    loginError = nil
    defer { busy = false }
    do {
      let value = useAPIKey
        ? try await NativeImmichClient.login(server: server, apiKey: apiKey)
        : try await NativeImmichClient.login(server: server, email: email, password: password)
      try NativeSessionStore.save(value)
      NativeSyncCacheStore.shared.configure(server: value.serverUrl, userId: value.userId)
      NativeBackgroundDiagnostics.shared.configureForCurrentAccount()
      if let key = value.apiKey ?? value.accessToken {
        _ = try? await ImmichCoreBridge.shared.initializeCoreEngine()
        _ = try? await ImmichCoreBridge.shared.loginServer(serverUrl: value.serverUrl, apiKey: key)
      }
      onLogin(value)
    } catch {
      loginError = error.localizedDescription
    }
  }

  @MainActor private func loginWithOAuth() async {
    let trimmedServer = server.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmedServer.isEmpty else {
      loginError = "请先输入 Immich 服务器地址。"
      return
    }
    busy = true
    loginError = nil
    defer { busy = false }
    let redirectScheme = "immich"
    let redirectUri = "\(redirectScheme)://oauth-callback"
    do {
      let config = try await NativeImmichClient.fetchOAuthConfig(server: trimmedServer, redirectUri: redirectUri)
      guard config.enabled, let authUrlStr = config.url, let authUrl = URL(string: authUrlStr) else {
        loginError = "当前服务器未启用或未配置 OAuth 单点登录服务。"
        return
      }
      let callbackURL = try await NativeOAuthSessionManager.shared.authenticate(authURL: authUrl, callbackScheme: redirectScheme)
      let value = try await NativeImmichClient.oauthCallback(server: trimmedServer, callbackUrl: callbackURL.absoluteString)
      try NativeSessionStore.save(value)
      NativeSyncCacheStore.shared.configure(server: value.serverUrl, userId: value.userId)
      NativeBackgroundDiagnostics.shared.configureForCurrentAccount()
      if let key = value.accessToken {
        _ = try? await ImmichCoreBridge.shared.initializeCoreEngine()
        _ = try? await ImmichCoreBridge.shared.loginServer(serverUrl: value.serverUrl, apiKey: key)
      }
      onLogin(value)
    } catch {
      if (error as NSError).domain == ASWebAuthenticationSessionErrorDomain,
         (error as NSError).code == ASWebAuthenticationSessionError.canceledLogin.rawValue {
        loginError = nil
      } else {
        loginError = "OAuth 登录失败：\(error.localizedDescription)"
      }
    }
  }
}

// MARK: - Native Photos timeline

@MainActor
private final class NativeTimelineModel: ObservableObject {
  @Published private(set) var assets: [NativeAsset] = []
  @Published private(set) var isLoading = false
  @Published private(set) var hasOlder = true
  @Published private(set) var newlyAddedCount = 0
  @Published var error: String?
  private(set) var hasCachedSnapshot = false

  private let client: NativeImmichClient
  private let accountIdentity: String?
  private var buckets: [NativeBucket] = []
  private var nextBucket = 0
  private var searchFallbackEnabled = false
  private var searchCursor: String?
  private var pendingSnapshotSave: Task<Void, Never>?
  private let pageSize = 8

  init(client: NativeImmichClient) {
    self.client = client
    accountIdentity = NativeSyncCacheStore.shared.identity
    if let snapshot = NativePhotoSnapshotStore.shared.timeline(identity: accountIdentity) {
      hasCachedSnapshot = true
      assets = snapshot.assets.sorted { $0.date < $1.date }
      buckets = snapshot.buckets
      nextBucket = min(snapshot.nextBucket, snapshot.buckets.count)
      searchFallbackEnabled = snapshot.searchFallbackEnabled
      searchCursor = snapshot.searchCursor
      hasOlder = snapshot.hasOlder
    }
  }

  private func persistSnapshot() {
    NativePhotoSnapshotStore.shared.saveTimeline(NativeTimelineSnapshot(
      assets: assets, buckets: buckets, nextBucket: nextBucket,
      searchFallbackEnabled: searchFallbackEnabled,
      searchCursor: searchCursor, hasOlder: hasOlder
    ), expectedIdentity: accountIdentity)
  }

  private func scheduleSnapshotSave() {
    pendingSnapshotSave?.cancel()
    pendingSnapshotSave = Task { @MainActor [weak self] in
      try? await Task.sleep(nanoseconds: 500_000_000)
      guard !Task.isCancelled else { return }
      self?.persistSnapshot()
      self?.pendingSnapshotSave = nil
    }
  }

  func loadInitial() async {
    guard !isLoading else { return }
    isLoading = true
    error = nil
    defer { isLoading = false }
    let existingAssets = assets
    let existingIDs = Set(existingAssets.map(\.id))
    let existingBuckets = buckets
    let existingNextBucket = nextBucket
    let existingSearchFallback = searchFallbackEnabled
    let existingSearchCursor = searchCursor
    do {
      let refreshedBuckets = try await client.timelineBuckets()
      searchFallbackEnabled = false
      searchCursor = nil
      buckets = refreshedBuckets
      // Fetch the newest page while preserving the older pagination boundary.
      var incoming = [NativeAsset]()
      for bucket in buckets.prefix(pageSize) {
        incoming.append(contentsOf: try await client.assets(in: bucket))
      }
      assets = (assets + incoming).reduce(into: [String: NativeAsset]()) { $0[$1.id] = $1 }.values.sorted { $0.date < $1.date }
      newlyAddedCount = assets.filter { !existingIDs.contains($0.id) }.count
      nextBucket = nativeBoundaryAfterFetchingHead(
        old: existingBuckets, next: existingSearchFallback ? 0 : existingNextBucket,
        refreshed: buckets, headSize: pageSize
      )
      hasOlder = nextBucket < buckets.count
      persistSnapshot()
      // Older buckets load only after the user scrolls towards them.
    } catch {
      // Some compatible Immich servers or reverse proxies return a non-JSON
      // timeline response. Keep Photos usable via the standard metadata search.
      NativeBackgroundDiagnostics.shared.record("时间线接口", error: error)
      do {
        searchFallbackEnabled = true
        searchCursor = nil
        assets = existingAssets
        try await loadSearchFallbackPage()
      } catch {
        assets = existingAssets
        buckets = existingBuckets
        nextBucket = existingNextBucket
        searchFallbackEnabled = existingSearchFallback
        searchCursor = existingSearchCursor
        hasOlder = existingSearchFallback ? existingSearchCursor != nil : existingNextBucket < existingBuckets.count
        self.error = error.localizedDescription
        NativeBackgroundDiagnostics.shared.record("时间线初次加载", error: error)
      }
    }
  }

  func refreshLatest() async {
    guard !isLoading else { return }
    isLoading = true
    defer { isLoading = false }
    do {
      if searchFallbackEnabled {
        let page = try await client.searchPage(cursor: nil, filter: ["visibility": ["eq": "timeline"]])
        let existingIDs = Set(assets.map(\.id))
        newlyAddedCount = page.assets.filter { !existingIDs.contains($0.id) }.count
        var seen = Set<String>()
        assets = (page.assets + assets).filter { seen.insert($0.id).inserted }.sorted { $0.date < $1.date }
        // Keep the cursor for the oldest already loaded page. Replacing it
        // with the newest page cursor would replay pages after a refresh.
        if existingIDs.isEmpty { searchCursor = page.next }
        hasOlder = searchCursor != nil
      } else {
        let refreshedBuckets = try await client.timelineBuckets()
        var incoming = [NativeAsset]()
        for bucket in refreshedBuckets.prefix(pageSize) {
          incoming.append(contentsOf: try await client.assets(in: bucket))
        }
        let existingIDs = Set(assets.map(\.id))
        newlyAddedCount = incoming.filter { !existingIDs.contains($0.id) }.count
        var seen = Set<String>()
        assets = (incoming + assets).filter { seen.insert($0.id).inserted }.sorted { $0.date < $1.date }
        let oldBuckets = buckets
        let oldNextBucket = nextBucket
        buckets = refreshedBuckets
        nextBucket = nativeBoundaryAfterFetchingHead(
          old: oldBuckets, next: oldNextBucket, refreshed: buckets, headSize: pageSize
        )
        hasOlder = nextBucket < buckets.count
      }
      error = nil
      persistSnapshot()
    } catch {
      NativeBackgroundDiagnostics.shared.record("时间线接口", error: error)
      if !searchFallbackEnabled {
        let previousCursor = searchCursor
        let existingIDs = Set(assets.map(\.id))
        searchFallbackEnabled = true
        searchCursor = nil
        do {
          try await loadSearchFallbackPage()
          newlyAddedCount = assets.filter { !existingIDs.contains($0.id) }.count
          return
        } catch {
          searchFallbackEnabled = false
          searchCursor = previousCursor
          self.error = error.localizedDescription
          NativeBackgroundDiagnostics.shared.record("时间线后台刷新", error: error)
          return
        }
      }
      // Keep the cached timeline visible when both API paths are unavailable.
      self.error = error.localizedDescription
    }
  }


  func loadOlder() async {
    guard !isLoading, hasOlder else { return }
    isLoading = true
    defer { isLoading = false }
    do {
      error = nil
      if searchFallbackEnabled { try await loadSearchFallbackPage() }
      else { try await loadNextPage() }
    } catch {
      self.error = error.localizedDescription
      NativeBackgroundDiagnostics.shared.record("加载更早照片", error: error)
    }
  }

  func retry() async {
    if hasOlder { await loadOlder() }
    else if error != nil { await loadInitial() }
  }

  private func loadSearchFallbackPage() async throws {
    let page = try await client.searchPage(cursor: searchCursor, filter: ["visibility": ["eq": "timeline"]])
    var seen = Set(assets.map(\.id))
    assets = (assets + page.assets).filter { seen.insert($0.id).inserted }.sorted { $0.date < $1.date }
    searchCursor = page.next
    hasOlder = page.next != nil
    error = nil
    persistSnapshot()
  }

  private func loadNextPage() async throws {
    guard nextBucket < buckets.count else { hasOlder = false; return }
    let end = min(nextBucket + pageSize, buckets.count)
    let page = buckets[nextBucket..<end]
    var result: [NativeAsset] = []
    for bucket in page {
      let bucketAssets = try await client.assets(in: bucket)
      result.append(contentsOf: bucketAssets)
    }
    nextBucket = end
    hasOlder = nextBucket < buckets.count
    var seen = Set<String>()
    assets = (assets + result).filter { seen.insert($0.id).inserted }.sorted { $0.date < $1.date }
    persistSnapshot()
  }

  func removeAssets(ids: Set<String>) {
    assets.removeAll { ids.contains($0.id) }
    persistSnapshot()
  }

  func upsert(_ asset: NativeAsset) {
    assets.removeAll { $0.id == asset.id }
    assets.append(asset)
    assets.sort { $0.date < $1.date }
    scheduleSnapshotSave()
  }

  func acknowledgeNewAssets() { newlyAddedCount = 0 }
}

func nativeTimelineRefreshTTL(isCellular: Bool, isExpensive: Bool = false) -> TimeInterval {
  if isCellular || isExpensive {
    return 180.0 // 3 minutes on cellular or metered connections
  } else {
    return 30.0  // 30 seconds on Wi-Fi / unmetered connections
  }
}

func nativeShouldRefreshTimeline(
  lastRefreshTime: Date,
  now: Date,
  isCellular: Bool,
  isExpensive: Bool = false
) -> Bool {
  let ttl = nativeTimelineRefreshTTL(isCellular: isCellular, isExpensive: isExpensive)
  return now.timeIntervalSince(lastRefreshTime) >= ttl
}

final class NativeNetworkMonitor: ObservableObject {
  static let shared = NativeNetworkMonitor()
  private let monitor: NWPathMonitor
  private let queue = DispatchQueue(label: "com.immichz.networkmonitor", qos: .utility)

  @Published private(set) var isCellular: Bool = false
  @Published private(set) var isExpensive: Bool = false
  @Published private(set) var isConnected: Bool = true

  private init() {
    monitor = NWPathMonitor()
    monitor.pathUpdateHandler = { [weak self] path in
      let cellular = path.usesInterfaceType(.cellular)
      let expensive = path.isExpensive
      let connected = path.status == .satisfied
      DispatchQueue.main.async {
        self?.isCellular = cellular
        self?.isExpensive = expensive
        self?.isConnected = connected
      }
    }
    monitor.start(queue: queue)
  }
}

struct NativePhotosView: View {
  let client: NativeImmichClient
  @ObservedObject var device: NativeDeviceLibrary
  let onLogout: () -> Void
  let matchedAssetDiagnostics: NativeMatchedAssetDiagnostics
  private let accountIdentity: String?
  @StateObject private var model: NativeTimelineModel
  @StateObject private var cloud = NativeCloudStatus()
  @State private var columns: Int = 4
  @State private var gestureBaseColumns: Int? = nil
  @State private var gestureAnchorID: String?
  @State private var loadingMatchedServerIDs = Set<String>()
  @State private var sourceFilter: NativePhotosSource = .all
  @State private var cachedDayGroups: [NativeDayGroup] = []
  @State private var cachedTimelineSections: [String: [NativeTimelineSection]] = [:]
  @State private var launchPreviewItems: [NativeGridItem]?
  @State private var cachedExcludedLocalIDs = Set<String>()
  @State private var localExclusionsReady = true
  @State private var serverExclusionsReady = true
  @State private var excludedLocalRefreshTask: Task<Void, Never>?
  @State private var excludedServerRefreshTask: Task<Void, Never>?
  @State private var excludedServerRefreshGeneration = 0
  @AppStorage("immichz_photos_excluded_local_album_ids") private var excludedLocalAlbumIDsRaw = "[]"
  @AppStorage("immichz_photos_excluded_server_album_ids") private var excludedServerAlbumIDsRaw = "[]"
  @State private var excludedServerAssetIDs = Set<String>()
  @State private var activeViewerItem: NativeGridItem?
  @State private var viewerSourceFrame: CGRect?
  @AppStorage("immichz_photos_aspect_ratio_grid") private var isAspectRatioGrid = false
  @State private var selectedTimelineLevel: String = "所有照片"
  @State private var isSwitchingTimeline = false
  @State private var timelineSwitchTask: Task<Void, Never>?
  @State private var timelineSwitchGeneration = 0
  @State private var selectedIDs: Set<String> = []
  @State private var isSelecting = false
  @State private var isDragSelecting = false
  @State private var dragSelectionIntent: NativeDragSelectionIntent = .undecided
  @State private var isMagnifying = false
  @State private var dragInitialSelectedIDs: Set<String> = []
  @State private var dragSelectMode: Bool = true // true = selecting, false = deselecting
  @State private var dragStartLocation: CGPoint? = nil
  @State private var dragStartAssetID: String? = nil
  @State private var itemBounds: [String: CGRect] = [:]
  @State private var lastPublishedItemBounds: [String: CGRect] = [:]
  @State private var lastItemBoundsUpdate: Date = .distantPast
  @State private var timelineBottomAnchorFrame = CGRect.null
  @State private var timelineViewportFrame = CGRect.null
  @State private var bottomPullDistance: CGFloat = 0
  @State private var bottomPullHapticTriggered = false
  @State private var pendingSourceChangeScroll = false
  @State private var hasInitialScrolled = false
  @State private var isBootstrappingTimeline = true
  @State private var isInitialTimelineVisible = false
  @State private var needsInitialBackgroundRefresh = false
  @State private var initialRemoteLoaded = false
  @State private var lastForegroundRefreshTime: Date = .distantPast
  @State private var lastTimelineRefreshTime: Date = .distantPast
  @State private var needsForegroundRefresh = false
  @State private var didInitialPosition = false
  @State private var userMovedTimeline = false
  @State private var hydrationTask: Task<Void, Never>?
  @State private var cloudCheckTask: Task<Void, Never>?
  @State private var bottomPositionTask: Task<Void, Never>?
  @State private var bottomPositionRetryCount = 0
  @State private var bottomPositionRequest = 0
  @State private var loadingOlderAnchor: String?
  @State private var showServerSettings = false
  @State private var showSyncSettings = false
  @State private var showDeleteConfirmation = false
  @State private var deletionError: String?
  @State private var isDeleting = false
  @State private var batchShareItems: [Any]? = nil
  @State private var isPreparingBatchShare = false
  @State private var isRefreshing = false
  @State private var actionMessage: String?
  @State private var archivedServerIDs = Set<String>()
  @State private var showSaveConfirmation = false
  @State private var showAlbumTargetDialog = false
  @State private var showLocalAlbumPicker = false
  @State private var showServerAlbumPicker = false
  @State private var duplicateSaveCount = 0
  @State private var lastScrollToBottomTime: Date = .distantPast
  private let bottomAnchor = "timeline-bottom-anchor"

  init(client: NativeImmichClient, device: NativeDeviceLibrary, onLogout: @escaping () -> Void, matchedAssetDiagnostics: NativeMatchedAssetDiagnostics) {
    self.client = client
    self.device = device
    self.onLogout = onLogout
    self.matchedAssetDiagnostics = matchedAssetDiagnostics
    accountIdentity = NativeSyncCacheStore.shared.identity
    let snapshot = NativePhotoSnapshotStore.shared.exclusions(identity: accountIdentity)
    let localAlbums = nativePhotosExcludedAlbumIDs(from:
      UserDefaults.standard.string(forKey: "immichz_photos_excluded_local_album_ids") ?? "[]"
    )
    let serverAlbums = nativePhotosExcludedAlbumIDs(from:
      UserDefaults.standard.string(forKey: "immichz_photos_excluded_server_album_ids") ?? "[]"
    )
    let localReady = localAlbums.isEmpty || snapshot?.localAlbumIDs == localAlbums
    let serverReady = serverAlbums.isEmpty || snapshot?.serverAlbumIDs == serverAlbums
    _cachedExcludedLocalIDs = State(initialValue:
      localAlbums.isEmpty ? [] : (localReady ? snapshot?.localAssetIDs ?? [] : [])
    )
    _excludedServerAssetIDs = State(initialValue:
      serverAlbums.isEmpty ? [] : (serverReady ? snapshot?.serverAssetIDs ?? [] : [])
    )
    _localExclusionsReady = State(initialValue: localReady)
    _serverExclusionsReady = State(initialValue: serverReady)
    _model = StateObject(wrappedValue: NativeTimelineModel(client: client))
  }

  private var totalDisplayCount: Int {
    cachedDayGroups.reduce(0) { $0 + $1.assets.count }
  }



  private var filteredTimelineAssets: [NativeGridItem] {
    let matched = cloud.matchedServerIDs
    let serverByID = Dictionary(model.assets.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    let serverToLocal = Dictionary(matched.map { ($0.value, $0.key) }, uniquingKeysWith: { first, _ in first })
    let localByID = Dictionary(device.assets.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    let excludedLocalIDs = cachedExcludedLocalIDs
    var seenServer = Set<String>()
    var result = [NativeGridItem]()

    let unmatchedServers = model.assets.filter { serverToLocal[$0.id] == nil }
    let serverBySec = nativeIndexAssetsBySecond(unmatchedServers)

    for local in device.assets where localExclusionsReady {
      let item: NativeGridItem
      if let serverID = matched[local.id] {
        guard serverExclusionsReady else { continue }
        if let server = serverByID[serverID] {
          item = NativeGridItem(server: server, local: local)
        } else {
          // Verified cloud membership must remain visible in the cloud filter.
          // Without the DTO, server-side actions remain unavailable until hydration.
          item = NativeGridItem(server: nil, local: local)
        }
        seenServer.insert(serverID)
        if excludedServerAssetIDs.contains(serverID) { continue }
        if sourceFilter == .server && archivedServerIDs.contains(serverID) { continue }
      } else if let heuristicServer = nativeFindHeuristicServerMatch(local: local, serverBySecond: serverBySec, usedServerIDs: seenServer) {
        guard serverExclusionsReady else { continue }
        item = NativeGridItem(server: heuristicServer, local: local)
        seenServer.insert(heuristicServer.id)
        if excludedServerAssetIDs.contains(heuristicServer.id) { continue }
        if sourceFilter == .server && archivedServerIDs.contains(heuristicServer.id) { continue }
      } else { item = NativeGridItem(server: nil, local: local) }
      if nativePhotosSourceIncludes(sourceFilter, hasLocal: item.local != nil, hasServer: item.server != nil, hasVerifiedMatch: matched[local.id] != nil || item.server != nil),
         !excludedLocalIDs.contains(local.id) {
        result.append(item)
      }
    }
    if sourceFilter != .device && serverExclusionsReady {
      for server in model.assets where !seenServer.contains(server.id) && !archivedServerIDs.contains(server.id) {
        if excludedServerAssetIDs.contains(server.id) { continue }
        if !localExclusionsReady && serverToLocal[server.id] != nil { continue }
        if let localID = serverToLocal[server.id], excludedLocalIDs.contains(localID) { continue }
        let local = serverToLocal[server.id].flatMap { localByID[$0] }
        result.append(NativeGridItem(server: server, local: local))
      }
    }
    return result.sorted { lhs, rhs in
      if lhs.date == rhs.date { return lhs.id < rhs.id }
      return lhs.date < rhs.date
    }
  }

  private func saveExcludedSnapshotIfReady() {
    guard localExclusionsReady, serverExclusionsReady else { return }
    NativePhotoSnapshotStore.shared.saveExclusions(
      NativeTimelineExclusionsSnapshot(
        localAlbumIDs: nativePhotosExcludedAlbumIDs(from: excludedLocalAlbumIDsRaw),
        serverAlbumIDs: nativePhotosExcludedAlbumIDs(from: excludedServerAlbumIDsRaw),
        localAssetIDs: cachedExcludedLocalIDs,
        serverAssetIDs: excludedServerAssetIDs
      ), expectedIdentity: accountIdentity
    )
  }

  private func refreshExcludedLocalAssetIDs() {
    excludedLocalRefreshTask?.cancel()
    let albumIDs = nativePhotosExcludedAlbumIDs(from: excludedLocalAlbumIDsRaw)
    guard !albumIDs.isEmpty else {
      cachedExcludedLocalIDs = []
      localExclusionsReady = true
      saveExcludedSnapshotIfReady()
      rebuildDayGroups()
      return
    }
    let albums = device.albums.filter { albumIDs.contains($0.id) }
    guard !albums.isEmpty else {
      // Wait for the full album scan, then resolve deleted/inaccessible albums
      // as empty rather than hiding every local photo indefinitely.
      if device.hasCompletedLiveRefresh && !device.isLoading {
        cachedExcludedLocalIDs = []
        localExclusionsReady = true
        saveExcludedSnapshotIfReady()
        rebuildDayGroups()
      }
      return
    }
    excludedLocalRefreshTask = Task(priority: .utility) {
      let ids = await Task.detached(priority: .utility) {
        var result = Set<String>()
        for album in albums {
          guard !Task.isCancelled else { break }
          guard let collection = PHAssetCollection.fetchAssetCollections(withLocalIdentifiers: [album.id], options: nil).firstObject else { continue }
          let assets = PHAsset.fetchAssets(in: collection, options: nil)
          assets.enumerateObjects { asset, _, _ in
            result.insert(asset.localIdentifier)
          }
        }
        return result
      }.value
      guard !Task.isCancelled, accountIdentity == NativeSyncCacheStore.shared.identity,
            albumIDs == nativePhotosExcludedAlbumIDs(from: excludedLocalAlbumIDsRaw) else { return }
      cachedExcludedLocalIDs = ids
      localExclusionsReady = true
      saveExcludedSnapshotIfReady()
      rebuildDayGroups()
    }
  }

  private var connectionAndSyncBadge: some View {
    HStack(spacing: 4) {
      // 1. 服务器连接状态指示（使用柔和中性色 / secondary，风格协调）
      if model.error != nil {
        Image(systemName: "bolt.slash")
          .font(.system(size: 11, weight: .medium))
          .foregroundColor(.secondary.opacity(0.6))
      } else if model.isLoading {
        Image(systemName: "server.rack")
          .font(.system(size: 11, weight: .medium))
          .foregroundColor(.secondary)
          .overlay(alignment: .bottomTrailing) {
            Image(systemName: "arrow.triangle.2.circlepath")
              .font(.system(size: 7, weight: .bold))
              .offset(x: 4, y: 3)
          }
      } else {
        Image(systemName: "server.rack")
          .font(.system(size: 11, weight: .medium))
          .foregroundColor(.secondary)
      }

      // 2. 同步状态指示
      if cloud.isRunning {
        Image(systemName: "arrow.clockwise.icloud")
          .font(.system(size: 11, weight: .medium))
          .foregroundColor(.secondary)
      } else if unknownLocalCount > 0 {
        Image(systemName: "questionmark.icloud")
          .font(.system(size: 11, weight: .medium))
          .foregroundColor(.secondary)
      } else if unsyncedLocalCount > 0 {
        Image(systemName: "icloud.slash")
          .font(.system(size: 11, weight: .medium))
          .foregroundColor(.secondary.opacity(0.6))
      } else {
        Image(systemName: "checkmark.icloud")
          .font(.system(size: 11, weight: .medium))
          .foregroundColor(.secondary)
      }
    }
  }

  private var unsyncedLocalCount: Int {
    device.assets.filter { cloud.checkedIDs.contains($0.id) && !cloud.failedVerificationIDs.contains($0.id) && cloud.matchedServerIDs[$0.id] == nil }.count
  }

  private var unknownLocalCount: Int {
    device.assets.filter { (!cloud.checkedIDs.contains($0.id) || cloud.failedVerificationIDs.contains($0.id)) && cloud.matchedServerIDs[$0.id] == nil }.count
  }

  @ViewBuilder
  private var trailingToolbarContent: some View {
    HStack(spacing: 6) {
      if isSelecting {
        Button(selectedIDs.count >= allOrderedAssetIDs.count && !allOrderedAssetIDs.isEmpty ? "取消全选" : "全选") {
          toggleSelectAll()
        }
        .font(.system(size: 15, weight: .medium))
      } else {
        Button("选择") {
          isSelecting = true
          UIImpactFeedbackGenerator(style: .light).impactOccurred()
        }
        .font(.system(size: 15, weight: .medium))
        .disabled(!isInitialTimelineVisible || totalDisplayCount == 0)
      }

      // 服务器状态按钮
      Button {
        showServerSettings = true
      } label: {
        serverStatusIcon
          .frame(width: 20, height: 20)
          .frame(width: 36, height: 32)
          .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .accessibilityLabel("服务器状态")

      // 同步与备份状态按钮
      Button {
        showSyncSettings = true
      } label: {
        cloudSyncStatusIcon
          .frame(width: 20, height: 20)
          .frame(width: 36, height: 32)
          .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .accessibilityLabel("同步与备份状态")
    }
    .fixedSize(horizontal: true, vertical: false)
  }

  @ViewBuilder
  private var serverStatusIcon: some View {
    if model.error != nil {
      Image(systemName: "bolt.slash")
        .font(.system(size: 16, weight: .medium))
        .foregroundColor(.secondary.opacity(0.6))
    } else if model.isLoading {
      Image(systemName: "server.rack")
        .font(.system(size: 16, weight: .medium))
        .foregroundColor(.secondary)
        .overlay(alignment: .bottomTrailing) {
          Image(systemName: "arrow.triangle.2.circlepath")
            .font(.system(size: 9, weight: .bold))
            .padding(1)
            .background(Color(uiColor: .systemBackground), in: Circle())
            .offset(x: 6, y: 5)
        }
    } else {
      Image(systemName: "server.rack")
        .font(.system(size: 16, weight: .medium))
        .foregroundColor(.secondary)
    }
  }

  private var cloudSyncBadgeName: String {
    if model.error != nil || cloud.failedCount > 0 { return "xmark" }
    if cloud.isRunning { return "arrow.clockwise" }
    if unknownLocalCount > 0 { return "questionmark" }
    if unsyncedLocalCount > 0 { return "line.diagonal" }
    return "checkmark"
  }

  private var cloudSyncStatusIcon: some View {
    Image(systemName: "icloud")
      .font(.system(size: 16, weight: .medium))
      .foregroundColor(.secondary)
      .overlay(alignment: .bottomTrailing) {
        Image(systemName: cloudSyncBadgeName)
          .font(.system(size: 9, weight: .bold))
          .foregroundColor(.secondary)
          .padding(1)
          .background(Color(uiColor: .systemBackground), in: Circle())
          .offset(x: 5, y: 4)
      }
  }

  private var activeTimelineSections: [NativeTimelineSection] {
    cachedTimelineSections[selectedTimelineLevel] ?? []
  }

  private func timelineGridContent(proxy: ScrollViewProxy) -> some View {
          LazyVStack(spacing: selectedTimelineLevel == "年" || selectedTimelineLevel == "月" ? 0 : 4) {
            if sourceFilter != .device && model.hasOlder && !model.assets.isEmpty {
              Button {
                requestOlder()
              } label: {
                if loadingOlderAnchor != nil { ProgressView() }
                else { Text("加载更早照片") }
              }
              .frame(maxWidth: .infinity)
              .padding(.vertical, 16)
              .disabled(loadingOlderAnchor != nil || model.isLoading)
            }
            if cachedDayGroups.isEmpty {
              VStack(spacing: 8) {
                Image(systemName: "photo.on.rectangle.angled")
                  .font(.largeTitle).foregroundColor(.secondary)
                Text("暂无缓存照片").font(.headline)
                Text(sourceFilter == .device && !device.authorized ? "请授予照片访问权限，查看本机照片。" : "有照片后会自动显示在这里。")
                  .font(.caption).foregroundColor(.secondary)
              }
              .frame(maxWidth: .infinity, minHeight: 220)
            }
            ForEach(activeTimelineSections) { section in
              VStack(alignment: .leading, spacing: 2) {
                if let title = section.title,
                   selectedTimelineLevel == "年" || selectedTimelineLevel == "月" || columns > 6 {
                  Text(title)
                    .font(selectedTimelineLevel == "年" ? .title2.weight(.bold) : (selectedTimelineLevel == "月" ? .headline.weight(.bold) : .caption2.weight(.bold)))
                    .foregroundColor(.primary)
                    .padding(.horizontal, 6)
                    .padding(.top, selectedTimelineLevel == "年" ? 12 : 6)
                    .padding(.bottom, 2)
                }
                let gridSpacing: CGFloat = columns > 7 ? 1 : 2
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: gridSpacing), count: columns), spacing: gridSpacing) {
                  ForEach(section.assets) { entry in
                    Color.clear
                      .aspectRatio(1, contentMode: .fit)
                      .background(isAspectRatioGrid ? Color(uiColor: .secondarySystemBackground).opacity(0.35) : Color.clear)
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
                          .preference(
                            key: NativeItemFramePreferenceKey.self,
                            value: nativePhotoFramePreference(
                              id: entry.id,
                              frame: geo.frame(in: .named("photosScrollSpace")),
                              viewportHeight: UIScreen.main.bounds.height
                            )
                          )
                        }
                      )
                      .clipped()
                      .overlay(alignment: .topLeading) {
                        if selectedTimelineLevel != "年" && selectedTimelineLevel != "月" && columns <= 6 && entry.id == section.assets.first?.id {
                          Text(section.title ?? "")
                            .font(.system(size: max(9, 13 - CGFloat(columns)), weight: .bold))
                            .foregroundColor(.white)
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 2)
                            .background(.black.opacity(0.65))
                            .cornerRadius(3)
                            .allowsHitTesting(false)
                        }
                      }
                      .overlay(alignment: .bottomLeading) {
                        if entry.isVideo && columns <= 7 {
                          Image(systemName: "play.fill")
                            .font(.system(size: columns > 4 ? 7 : 11, weight: .bold))
                            .foregroundColor(.white).shadow(color: .black, radius: 2)
                            .padding(columns > 4 ? 1.5 : 3)
                            .allowsHitTesting(false)
                        }
                      }
                      .overlay(alignment: .bottomTrailing) {
                        if columns <= 7 {
                          Image(systemName: cloudSymbol(for: entry))
                            .font(.system(size: columns > 4 ? 7 : 13, weight: .semibold))
                            .foregroundColor(.white).shadow(color: .black, radius: 2)
                            .padding(columns > 4 ? 1.5 : 3)
                            .allowsHitTesting(false)
                        }
                      }
                      .overlay(alignment: .topTrailing) {
                        if selectedIDs.contains(entry.id) {
                          Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: columns > 7 ? 12 : (columns > 4 ? 16 : 20), weight: .semibold))
                            .foregroundStyle(.white, .blue)
                            .padding(columns > 7 ? 1 : 4)
                            .allowsHitTesting(false)
                        }
                      }
                      .contentShape(Rectangle())
                      .accessibilityLabel("\(entry.date.formatted()), \(cloudDescription(for: entry))")
                      .onLongPressGesture(minimumDuration: 0.28, maximumDistance: 15) {
                        guard !isMagnifying else { return }
                        if isSelecting {
                          startDragSelectionInSelectMode(startingWith: entry.id)
                        }
                      }
                      .contextMenu(isSelecting ? nil : ContextMenu {
                        Button {
                          shareSingleAsset(entry)
                        } label: {
                          Label("分享", systemImage: "square.and.arrow.up")
                        }

                        Button {
                          toggleSingleFavorite(entry)
                        } label: {
                          Label(entry.isFavorite ? "取消收藏" : "收藏", systemImage: entry.isFavorite ? "heart.fill" : "heart")
                        }

                        Button {
                          copySingleAsset(entry)
                        } label: {
                          Label("复制", systemImage: "doc.on.doc")
                        }

                        Button {
                          selectedIDs = [entry.id]
                          showAlbumTargetDialog = true
                        } label: {
                          Label("加入相册...", systemImage: "plus.rectangle.on.folder")
                        }

                        if entry.local == nil && entry.server != nil {
                          Button {
                            selectedIDs = [entry.id]
                            prepareSaveToDevice()
                          } label: {
                            Label("保存到本机", systemImage: "square.and.arrow.down")
                          }
                        }

                        Divider()

                        Button(role: .destructive) {
                          selectedIDs = [entry.id]
                          showDeleteConfirmation = true
                        } label: {
                          Label("删除", systemImage: "trash")
                        }
                      })
                      .id(entry.id)
                  }
                }
              }
            }
            GeometryReader { geometry in
              Color.clear.preference(
                key: NativeTimelineBottomAnchorFramePreferenceKey.self,
                value: geometry.frame(in: .named("photosScrollSpace"))
              )
            }
            .frame(height: 1)
            .id(bottomAnchor)
          }
  }

  private var launchViewerItems: [NativeGridItem] {
    let candidates = launchPreviewItems.flatMap { $0.isEmpty ? nil : $0 }
      ?? filteredTimelineAssets
    return candidates.filter { item in
        nativePhotosSourceIncludes(
          sourceFilter, hasLocal: item.local != nil,
          hasServer: item.server != nil,
          hasVerifiedMatch: item.local.flatMap {
            cloud.matchedServerIDs[$0.id]
          } != nil
        )
    }
  }

  private func timelineGestureContent<Content: View>(_ content: Content, proxy: ScrollViewProxy) -> some View {
    content
        .coordinateSpace(name: "photosScrollSpace")
        .nativeScrollDisabled(isDragSelecting)
        .onPreferenceChange(NativeTimelineBottomAnchorFramePreferenceKey.self) { frame in
          timelineBottomAnchorFrame = frame
        }
        .onPreferenceChange(NativeTimelineViewportFramePreferenceKey.self) { frame in
          timelineViewportFrame = frame
        }
        .onPreferenceChange(NativeItemFramePreferenceKey.self) { frames in
          let forceUpdate = isSelecting || isDragSelecting || isMagnifying
          let now = Date()
          // Geometry preferences are emitted continuously while scrolling. Publish
          // ordinary viewport changes at a lower rate to avoid invalidating the
          // whole timeline several times per second; selection/zoom stays live.
          guard forceUpdate || now.timeIntervalSince(lastItemBoundsUpdate) >= 0.25 else { return }
          guard nativeShouldRefreshPhotoFrames(
            previous: lastPublishedItemBounds,
            next: frames,
            force: forceUpdate
          ) else { return }
          lastItemBoundsUpdate = now
          lastPublishedItemBounds = frames
          itemBounds = frames
        }
        .simultaneousGesture(
          DragGesture(minimumDistance: 4, coordinateSpace: .named("photosScrollSpace"))
            .onChanged { drag in
              if !isSelecting {
                // The loading overlay is not a user scroll of the photo grid.
                guard isInitialTimelineVisible else { return }
                if abs(drag.translation.height) > 12 {
                  isBootstrappingTimeline = false
                  userMovedTimeline = true
                  bottomPositionTask?.cancel()
                  bottomPositionTask = nil
                  pendingSourceChangeScroll = false
                  if !didInitialPosition { didInitialPosition = true }
                }
                return
              }
              guard !isMagnifying else { return }
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
              if isSelecting {
                isDragSelecting = false
                dragSelectionIntent = .undecided
                finishDragSelection()
              }
            }
        )
        .background(Color(uiColor: .systemBackground))
        .simultaneousGesture(
          MagnificationGesture()
            .onChanged { value in
              guard !isSelecting, isInitialTimelineVisible else { return }
              isMagnifying = true
              let base = gestureBaseColumns ?? columns
              if gestureBaseColumns == nil {
                gestureBaseColumns = base
                gestureAnchorID = centerVisibleAssetID
              }
              let deadzone = 0.12
              let effectiveValue: CGFloat
              if value > 1 {
                guard value >= 1 + deadzone else { return }
                effectiveValue = value - deadzone
              } else {
                guard value <= 1 - deadzone else { return }
                effectiveValue = value + deadzone
              }
              let delta = effectiveValue >= 1
                ? -(effectiveValue - 1) * 4
                : (1 / max(0.08, effectiveValue) - 1) * 4
              let target = min(15, max(2, Int((CGFloat(base) + delta).rounded())))
              guard target != columns else { return }
              UIImpactFeedbackGenerator(style: .medium).impactOccurred()
              columns = target
              if let anchor = gestureAnchorID { withAnimation(.none) { proxy.scrollTo(anchor, anchor: .center) } }
            }
            .onEnded { _ in
              gestureBaseColumns = nil
              gestureAnchorID = nil
              DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { isMagnifying = false }
            }
        )
  }

  private func timelineLifecycleContent<Content: View>(_ content: Content, proxy: ScrollViewProxy) -> some View {
    content
        .onChange(of: cloud.matchedServerIDs) { _ in
          rebuildDayGroups()
          keepBottomUntilUserScrolls(proxy: proxy)
          scheduleMatchedHydration()
        }
        .onChange(of: sourceFilter) { _ in
          bottomPositionTask?.cancel()
          bottomPositionTask = nil
          isBootstrappingTimeline = false
          actionMessage = nil
          rebuildDayGroups()
          updateSelectionAfterTimelineChange()
          positionAtLatestAfterSourceChange(proxy: proxy)
        }
        .refreshable {
          guard isInitialTimelineVisible else { return }
          bottomPositionTask?.cancel()
          bottomPositionTask = nil
          isBootstrappingTimeline = false
          isInitialTimelineVisible = true
          lastTimelineRefreshTime = Date()
          device.refresh()
          await model.refreshLatest()
          if !serverExclusionsReady { refreshExcludedServerAssetIDs() }
          rebuildDayGroups()
          scheduleMatchedHydration()
          scheduleBackgroundCloudCheck()
        }
        .onChange(of: device.assets.count) { _ in
          rebuildDayGroups()
          if !hasInitialScrolled {
            positionInitiallyIfReady(proxy: proxy)
            keepBottomUntilUserScrolls(proxy: proxy)
          }
          scheduleBackgroundCloudCheck()
          NativeBackupEngine.shared.triggerBackupPass(assets: device.assets, client: client)
          if pendingSourceChangeScroll { positionAtLatestAfterSourceChange(proxy: proxy) }
        }
        .onChange(of: device.hasLoadedInitialSnapshot) { _ in
          rebuildDayGroups()
          positionInitiallyIfReady(proxy: proxy)
          keepBottomUntilUserScrolls(proxy: proxy)
        }
        .onChange(of: device.hasCompletedLiveRefresh) { completed in
          if completed && !localExclusionsReady {
            refreshExcludedLocalAssetIDs()
          }
        }
        .onChange(of: cachedExcludedLocalIDs) { _ in
          keepBottomUntilUserScrolls(proxy: proxy)
        }
        .onChange(of: excludedServerAssetIDs) { _ in
          keepBottomUntilUserScrolls(proxy: proxy)
        }
        .onChange(of: excludedLocalAlbumIDsRaw) { raw in
          localExclusionsReady = nativePhotosExcludedAlbumIDs(from: raw).isEmpty
          refreshExcludedLocalAssetIDs()
          updateSelectionAfterTimelineChange()
        }
        .onChange(of: excludedServerAlbumIDsRaw) { raw in
          serverExclusionsReady = nativePhotosExcludedAlbumIDs(from: raw).isEmpty
          refreshExcludedServerAssetIDs()
          updateSelectionAfterTimelineChange()
        }
        .onChange(of: localExclusionsReady) { _ in
          rebuildDayGroups()
          if !isInitialTimelineVisible {
            launchPreviewItems = Array(filteredTimelineAssets.suffix(120))
            if !cachedDayGroups.isEmpty && device.hasLoadedInitialSnapshot {
              initialRemoteLoaded = true
              needsInitialBackgroundRefresh = true
            }
            positionInitiallyIfReady(proxy: proxy)
          }
        }
        .onChange(of: serverExclusionsReady) { _ in
          rebuildDayGroups()
          if !isInitialTimelineVisible {
            launchPreviewItems = Array(filteredTimelineAssets.suffix(120))
            if !cachedDayGroups.isEmpty && model.hasCachedSnapshot {
              initialRemoteLoaded = true
              needsInitialBackgroundRefresh = true
            }
            positionInitiallyIfReady(proxy: proxy)
          }
        }
        .onChange(of: device.isLoading) { loading in
          guard !loading else { return }
          refreshExcludedLocalAssetIDs()
          rebuildDayGroups()
          if !hasInitialScrolled { positionInitiallyIfReady(proxy: proxy) }
          keepBottomUntilUserScrolls(proxy: proxy)
          if pendingSourceChangeScroll { positionAtLatestAfterSourceChange(proxy: proxy) }
        }
        .onAppear {
          if launchPreviewItems == nil {
            launchPreviewItems = Array(filteredTimelineAssets.suffix(120))
          }
          rebuildDayGroups()
          refreshExcludedLocalAssetIDs()
          if !serverExclusionsReady { refreshExcludedServerAssetIDs() }

          let now = Date()
          let isCellular = NativeNetworkMonitor.shared.isCellular
          let isExpensive = NativeNetworkMonitor.shared.isExpensive

          if isInitialTimelineVisible {
            if nativeShouldRefreshTimeline(lastRefreshTime: lastTimelineRefreshTime, now: now, isCellular: isCellular, isExpensive: isExpensive) {
              lastTimelineRefreshTime = now
              Task(priority: .utility) {
                await model.refreshLatest()
                rebuildDayGroups()
                scheduleMatchedHydration()
              }
            }
          } else if !cachedDayGroups.isEmpty &&
              (model.hasCachedSnapshot || device.hasLoadedInitialSnapshot) {
            // Show the cached timeline before network metadata can change its
            // layout. The refresh starts only after the first grid is visible.
            initialRemoteLoaded = true
            needsInitialBackgroundRefresh = true
            positionInitiallyIfReady(proxy: proxy)
          } else if !model.isLoading {
            lastTimelineRefreshTime = now
            Task {
              await model.loadInitial()
              initialRemoteLoaded = true
              rebuildDayGroups()
              positionInitiallyIfReady(proxy: proxy)
              keepBottomUntilUserScrolls(proxy: proxy)
              scheduleMatchedHydration()
            }
          } else {
            initialRemoteLoaded = true
            scheduleMatchedHydration()
            positionInitiallyIfReady(proxy: proxy)
            keepBottomUntilUserScrolls(proxy: proxy)
          }
        }
        .onChange(of: isInitialTimelineVisible) { visible in
          guard visible, needsInitialBackgroundRefresh else { return }
          needsInitialBackgroundRefresh = false
          scheduleBackgroundCloudCheck()
          lastTimelineRefreshTime = Date()
          Task(priority: .utility) {
            await model.refreshLatest()
            rebuildDayGroups()
            scheduleMatchedHydration()
          }
        }
        .onChange(of: model.assets.count) { _ in
          rebuildDayGroups()
          updateSelectionAfterTimelineChange()
          if !hasInitialScrolled { positionInitiallyIfReady(proxy: proxy) }
          keepBottomUntilUserScrolls(proxy: proxy)
          if pendingSourceChangeScroll { positionAtLatestAfterSourceChange(proxy: proxy) }
        }
        .onChange(of: model.isLoading) { loading in
          if !loading {
            if !serverExclusionsReady { refreshExcludedServerAssetIDs() }
            rebuildDayGroups()
            positionInitiallyIfReady(proxy: proxy)
            keepBottomUntilUserScrolls(proxy: proxy)
          }
          if pendingSourceChangeScroll { positionAtLatestAfterSourceChange(proxy: proxy) }
        }
        .onReceive(NotificationCenter.default.publisher(for: .immichScrollPhotosToBottom)) { _ in
          let now = Date()
          guard now.timeIntervalSince(lastScrollToBottomTime) > 0.25 else { return }
          lastScrollToBottomTime = now
          scrollToBottom(proxy: proxy, animated: true)
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didEnterBackgroundNotification)) { _ in
          needsForegroundRefresh = true
          hydrationTask?.cancel()
          hydrationTask = nil
        }
        .onDisappear {
          timelineSwitchTask?.cancel()
          timelineSwitchTask = nil
          isSwitchingTimeline = false
          bottomPositionTask?.cancel()
          bottomPositionTask = nil
          hydrationTask?.cancel()
          hydrationTask = nil
          cloudCheckTask?.cancel()
          cloudCheckTask = nil
          excludedLocalRefreshTask?.cancel()
          excludedLocalRefreshTask = nil
          excludedServerRefreshTask?.cancel()
          excludedServerRefreshTask = nil
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
          guard needsForegroundRefresh, !isSelecting else { return }
          needsForegroundRefresh = false
          if !isInitialTimelineVisible {
            bottomPositionTask?.cancel()
            bottomPositionTask = nil
            hasInitialScrolled = false
            positionInitiallyIfReady(proxy: proxy)
          } else {
            isBootstrappingTimeline = false
          }
          let now = Date()
          let isCellular = NativeNetworkMonitor.shared.isCellular
          let isExpensive = NativeNetworkMonitor.shared.isExpensive
          guard nativeShouldRefreshTimeline(lastRefreshTime: lastTimelineRefreshTime, now: now, isCellular: isCellular, isExpensive: isExpensive) else {
            device.refresh()
            rebuildDayGroups()
            return
          }
          lastTimelineRefreshTime = now
          scheduleBackgroundCloudCheck()
          Task(priority: .utility) {
            // The existing grid stays interactive while the metadata reloads.
            device.refresh()
            if !model.isLoading { await model.refreshLatest() }
            if !serverExclusionsReady { refreshExcludedServerAssetIDs() }
            rebuildDayGroups()
            updateSelectionAfterTimelineChange()
            scheduleMatchedHydration()
          }
        }
  }

  private func timelineChromeContent<Content: View>(_ content: Content, proxy: ScrollViewProxy) -> some View {
    content
        .safeAreaInset(edge: .bottom, spacing: 0) {
          // Keep both bars in the same layout footprint. Changing the inset's
          // height on selection would resize the scroll viewport and shift it,
          // especially at the latest/bottom edge. Do not scrollTo to compensate:
          // centering a nearby asset also loses the user's exact pixel offset.
          ZStack(alignment: .bottom) {
            HStack(spacing: 0) {
              batchActionButton("square.and.arrow.up", label: "分享", disabled: selectedIDs.isEmpty || isPreparingBatchShare) { triggerBatchShare() }
              batchActionButton("heart", label: "收藏", disabled: selectedIDs.isEmpty) { Task { await updateBatchFavorites() } }
              batchActionButton("archivebox", label: "归档", disabled: !selectedItems.contains(where: { $0.server != nil })) { Task { await archiveSelected() } }
              batchActionButton("plus.rectangle.on.folder", label: "加入相册", disabled: !selectedItems.contains(where: { $0.server != nil || $0.local != nil })) { showAlbumTargetDialog = true }
              batchActionButton("square.and.arrow.down", label: "保存", disabled: !selectedItems.contains(where: { $0.server != nil })) { prepareSaveToDevice() }
              batchActionButton("trash", label: "删除", disabled: selectedIDs.isEmpty || isDeleting, destructive: true) {
                showDeleteConfirmation = true
              }
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 10)
            .background(.ultraThinMaterial)
            .opacity(isSelecting ? 1 : 0)
            .allowsHitTesting(isSelecting)
            .accessibilityHidden(!isSelecting)

            VStack(spacing: 6) {
              if !device.authorized && sourceFilter != .server {
                Button("允许访问本机照片（可选）") { Task { await device.requestAccess() } }.padding(6)
              }
              if let message = actionMessage {
                HStack(spacing: 8) {
                  Text(message).font(.caption).lineLimit(3)
                  Spacer(minLength: 4)
                  Button { actionMessage = nil } label: {
                    Image(systemName: "xmark.circle.fill").foregroundColor(.secondary)
                  }
                  .buttonStyle(.plain)
                  .accessibilityLabel("关闭操作提示")
                }
                .padding(6)
              }

              HStack(spacing: 12) {
                HStack(spacing: 2) {
                  ForEach(["年", "月", "日", "所有照片"], id: \.self) { level in
                    Button {
                      switchTimeline(to: level, proxy: proxy)
                    } label: {
                      Text(level)
                        .font(.system(size: 13, weight: selectedTimelineLevel == level ? .bold : .medium))
                        .foregroundColor(selectedTimelineLevel == level ? .primary : .secondary)
                        .padding(.horizontal, level == "所有照片" ? 10 : 8)
                        .padding(.vertical, 5)
                        .background(
                          Group {
                            if selectedTimelineLevel == level {
                              Capsule()
                                .fill(Color(uiColor: .systemBackground))
                                .shadow(color: .black.opacity(0.12), radius: 3, y: 1)
                            }
                          }
                        )
                    }
                    .buttonStyle(.plain)
                  }
                }
                .padding(3)
                .background(.ultraThinMaterial)
                .clipShape(Capsule())
                .shadow(color: .black.opacity(0.08), radius: 6, y: 2)

                if userMovedTimeline {
                  Button {
                    scrollToBottom(proxy: proxy, animated: true)
                  } label: {
                    HStack(spacing: 3) {
                      Image(systemName: "arrow.down")
                        .font(.system(size: 11, weight: .bold))
                      Text("最新")
                        .font(.system(size: 12, weight: .semibold))
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(.ultraThinMaterial)
                    .clipShape(Capsule())
                    .shadow(color: .black.opacity(0.08), radius: 6, y: 2)
                  }
                  .buttonStyle(.plain)
                  .transition(.opacity.combined(with: .scale(scale: 0.85)))
                }
              }
              .padding(.bottom, 6)
              .animation(.spring(response: 0.35, dampingFraction: 0.8), value: userMovedTimeline)
            }
            .opacity(isSelecting ? 0 : 1)
            .allowsHitTesting(!isSelecting)
            .accessibilityHidden(isSelecting)
          }
        }
        .navigationTitle("照片")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
          ToolbarItem(placement: .navigationBarLeading) {
            if isSelecting {
              Button("取消") { clearSelection() }
            } else {
              HStack(spacing: 8) {
                Button {
                  triggerRefresh(proxy: proxy)
                } label: {
                  if isRefreshing || model.isLoading {
                    ProgressView()
                      .scaleEffect(0.7)
                      .frame(width: 36, height: 32)
                  } else {
                    Image(systemName: "arrow.clockwise")
                      .font(.system(size: 16, weight: .medium))
                      .foregroundColor(.secondary)
                      .frame(width: 20, height: 20)
                      .frame(width: 36, height: 32)
                      .contentShape(Rectangle())
                  }
                }
                .buttonStyle(.plain)
                .disabled(!isInitialTimelineVisible || isRefreshing || model.isLoading)
                .accessibilityLabel("刷新照片")

                Text("\(totalDisplayCount) 项")
                  .font(.caption)
                  .foregroundColor(.secondary)
              }
            }
          }
          ToolbarItem(placement: .principal) {
            if isSelecting {
              Text("已选 \(selectedIDs.count) 项").font(.headline)
            } else {
              Text("照片").font(.headline)
            }
          }
          ToolbarItem(placement: .navigationBarTrailing) {
            trailingToolbarContent
          }
        }
  }

  private func shareSingleAsset(_ item: NativeGridItem) {
    Task {
      let result = await nativePrepareBatchShare(items: [item], client: client)
      await MainActor.run {
        if !result.files.isEmpty {
          batchShareItems = result.files
        } else {
          actionMessage = "未能准备该照片原件"
        }
      }
    }
  }

  private func copySingleAsset(_ item: NativeGridItem) {
    Task {
      let result = await nativePrepareBatchShare(items: [item], client: client)
      await MainActor.run {
        if let fileURL = result.files.first as? URL,
           let data = try? Data(contentsOf: fileURL),
           let img = UIImage(data: data) {
          UIPasteboard.general.image = img
          actionMessage = "已复制原图到剪贴板"
        } else {
          actionMessage = "无法复制原图"
        }
      }
    }
  }

  private func toggleSingleFavorite(_ item: NativeGridItem) {
    Task {
      let target = !item.isFavorite
      if let server = item.server {
        try? await client.updateFavorite(id: server.id, isFavorite: target)
      }
      if let local = item.local {
        _ = await device.updateFavorite(ids: [local.id], isFavorite: target)
      }
      device.refresh()
      await model.refreshLatest()
      rebuildDayGroups()
    }
  }

  private func toggleSelectAll() {
    let allIDs = Set(cachedDayGroups.flatMap { $0.assets.map(\.id) })
    if selectedIDs.count >= allIDs.count && !allIDs.isEmpty {
      selectedIDs.removeAll()
    } else {
      selectedIDs = allIDs
    }
    UIImpactFeedbackGenerator(style: .light).impactOccurred()
  }

  private func timelineModalContent<Content: View>(_ content: Content, proxy: ScrollViewProxy) -> some View {
    content
        .confirmationDialog("选择相册来源", isPresented: $showAlbumTargetDialog, titleVisibility: .visible) {
          Button("加入本机相册") { showLocalAlbumPicker = true }
          Button("加入云端相册") { showServerAlbumPicker = true }
          Button("取消", role: .cancel) {}
        } message: { Text("本机资产和云端资产分别操作，不会自动上传。") }
        .confirmationDialog("删除选中的 \(selectedIDs.count) 项照片", isPresented: $showDeleteConfirmation, titleVisibility: .visible) {
          Button("从所有位置删除", role: .destructive) {
            Task { await deleteSelectedPhotos(scope: .all, proxy: proxy) }
          }
          if selectedItems.contains(where: { $0.local != nil && $0.server == nil }) {
            Button("仅删除本机未上传照片", role: .destructive) {
              Task { await deleteSelectedPhotos(scope: .localOnly, proxy: proxy) }
            }
          }
          Button("取消", role: .cancel) {}
        } message: {
          Text("将从云端服务器及本地设备相册中彻底删除所选照片。")
        }
        .alert("保存到本机照片", isPresented: $showSaveConfirmation) {
          Button("取消", role: .cancel) {}
          Button("继续保存") { Task { await saveSelectedToDevice() } }
        } message: {
          Text(duplicateSaveCount > 0 ? "所选内容中有 \(duplicateSaveCount) 项已存在本机副本，继续操作可能产生重复照片。" : "将下载云端原件并保存到系统照片。")
        }
        .alert("删除失败", isPresented: Binding(get: { deletionError != nil }, set: { if !$0 { deletionError = nil } })) {
          Button("确定", role: .cancel) { deletionError = nil }
        } message: { Text(deletionError ?? "未知错误") }
        .sheet(item: Binding<NativeSharePayload?>(
          get: { batchShareItems.map { NativeSharePayload(contents: $0) } },
          set: { if $0 == nil { batchShareItems = nil } }
        )) { payload in
          NativeActivityView(activityItems: payload.content)
        }
        .sheet(isPresented: $showServerSettings) {
          NativeServerSettingsSheet(client: client, onLogout: onLogout)
        }
        .sheet(isPresented: $showSyncSettings) {
          NativeSyncSettingsSheet(client: client, device: device, cloud: cloud)
        }
        .sheet(isPresented: $showLocalAlbumPicker) {
          NativePhotosLocalAlbumPicker(albums: device.albums) { albumID in Task { await addSelectedToLocalAlbum(albumID) } }
        }
        .sheet(isPresented: $showServerAlbumPicker) {
          NativePhotosServerAlbumPicker(client: client) { albumID in Task { await addSelectedToServerAlbum(albumID) } }
        }
        .fullScreenCover(item: $activeViewerItem) { item in
          NativeUnifiedGalleryViewer(
            client: client,
            device: device,
            items: isInitialTimelineVisible
              ? cachedDayGroups.flatMap(\.assets)
              : launchViewerItems,
            initialItem: item,
            sourceFrame: viewerSourceFrame,
            onDeleteItem: { deletedItem, scope in
              let previousAssetIDs = cachedDayGroups.flatMap(\.assets).map(\.id)
              let fallbackID = nativeViewerNextSelectionID(deletingID: deletedItem.id, orderedIDs: previousAssetIDs)
              if let sid = deletedItem.server?.id, scope != .localOnly {
                model.removeAssets(ids: [sid])
              }
              if let local = deletedItem.local {
                cloud.forgetMatches(localIDs: Set([local.id]))
              }
              userMovedTimeline = true
              device.refresh()
              rebuildDayGroups()
              if let fallbackID {
                withAnimation(.none) {
                  proxy.scrollTo(fallbackID, anchor: .center)
                }
              }
              var transaction = Transaction()
              transaction.disablesAnimations = true
              withTransaction(transaction) {
                activeViewerItem = nil
              }
            },
            onServerAssetUpdated: { model.upsert($0) },
            onServerAssetArchived: { model.removeAssets(ids: [$0]) },
            onDismissViewer: {
              var transaction = Transaction()
              transaction.disablesAnimations = true
              withTransaction(transaction) {
                activeViewerItem = nil
              }
            }
          )
        }
  }

  var body: some View {
    NavigationView {
      ScrollViewReader { proxy in
        timelineModalContent(
          timelineChromeContent(
            timelineLifecycleContent(
              timelineGestureContent(
                ZStack {
                  ScrollView { timelineGridContent(proxy: proxy) }
                    .background(
                      GeometryReader { geometry in
                        Color.clear.preference(
                          key: NativeTimelineViewportFramePreferenceKey.self,
                          value: geometry.frame(in: .named("photosScrollSpace"))
                        )
                      }
                    )
                    .opacity(isInitialTimelineVisible && !isSwitchingTimeline ? 1 : 0)
                    .allowsHitTesting(isInitialTimelineVisible && !isSwitchingTimeline)
                  if isSwitchingTimeline {
                    ProgressView()
                      .frame(maxWidth: .infinity, maxHeight: .infinity)
                      .background(Color(uiColor: .systemBackground))
                  }
                  if !isInitialTimelineVisible {
                    NativeCachedTimelinePreview(
                      client: client, items: launchViewerItems,
                      columns: columns,
                      onTap: { activeViewerItem = $0 }
                    )
                  }
                },
                proxy: proxy
              ),
              proxy: proxy
            ),
            proxy: proxy
          ),
          proxy: proxy
        )
      }
    }
    .navigationViewStyle(.stack)
    .ignoresSafeArea(edges: .bottom)
  }

  private var selectedItems: [NativeGridItem] {
    cachedDayGroups.flatMap(\.assets).filter { selectedIDs.contains($0.id) }
  }

  private var centerVisibleAssetID: String? {
    let viewport = UIScreen.main.bounds
    let center = CGPoint(x: viewport.midX, y: viewport.midY)
    return itemBounds.filter { $0.value.maxY > 0 && $0.value.minY < viewport.height }
      .min(by: { hypot($0.value.midX - center.x, $0.value.midY - center.y) < hypot($1.value.midX - center.x, $1.value.midY - center.y) })?.key
  }

  private func scheduleMatchedHydration() {
    hydrationTask?.cancel()
    hydrationTask = Task(priority: .utility) {
      try? await Task.sleep(nanoseconds: 1_500_000_000)
      guard !Task.isCancelled else { return }
      await loadKnownMatchedServerAssets()
    }
  }

  private func scheduleBackgroundCloudCheck() {
    cloudCheckTask?.cancel()
    cloudCheckTask = Task(priority: .utility) {
      try? await Task.sleep(nanoseconds: 1_000_000_000)
      guard !Task.isCancelled, !cloud.isRunning else { return }
      await cloud.check(device.assets, client: client)
    }
  }

  @MainActor private func loadKnownMatchedServerAssets() async {
    let loaded = Set(model.assets.map(\.id))
    let missing = Set(cloud.matchedServerIDs.values).filter { !loaded.contains($0) && !loadingMatchedServerIDs.contains($0) }
    guard !missing.isEmpty else { return }
    loadingMatchedServerIDs.formUnion(missing)
    for id in missing {
      guard !Task.isCancelled else { loadingMatchedServerIDs.subtract(missing); return }
      matchedAssetDiagnostics.started()
      do {
        if let asset = try await client.serverAsset(id: id) {
          guard !Task.isCancelled else { loadingMatchedServerIDs.remove(id); return }
          model.upsert(asset)
          matchedAssetDiagnostics.succeeded(id: id)
        } else {
          matchedAssetDiagnostics.failed(id: id, error: nil)
          NativeBackgroundDiagnostics.shared.record(
            "云端照片详情", category: "服务器未返回资产"
          )
        }
      } catch {
        if !Task.isCancelled {
          matchedAssetDiagnostics.failed(id: id, error: error)
          NativeBackgroundDiagnostics.shared.record("云端照片详情", error: error)
        }
      }
      loadingMatchedServerIDs.remove(id)
    }
  }

  private func batchActionButton(_ symbol: String, label: String, disabled: Bool, destructive: Bool = false, action: @escaping () -> Void) -> some View {
    Button(action: action) {
      VStack(spacing: 3) {
        Image(systemName: symbol).font(.system(size: 18, weight: .medium))
        Text(label).font(.system(size: 10, weight: .medium))
      }
      .foregroundColor(disabled ? .secondary : (destructive ? .red : .primary))
      .frame(maxWidth: .infinity, minHeight: 42)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .disabled(disabled)
    .accessibilityLabel(label)
  }

  private var selectionSpansBothSources: Bool {
    selectedItems.contains(where: { $0.local != nil }) && selectedItems.contains(where: { $0.server != nil })
  }

  private func deleteSelectedPhotos(scope: NativeDeleteTargetScope = .all, proxy: ScrollViewProxy? = nil) async {
    guard !isDeleting else { return }
    let items = selectedItems
    guard !items.isEmpty else { return }
    await performSelectedDeletion(items: items, scope: scope, proxy: proxy)
  }

  private func performSelectedDeletion(items: [NativeGridItem], scope: NativeDeleteTargetScope, proxy: ScrollViewProxy? = nil) async {
    guard !isDeleting else { return }
    isDeleting = true
    defer { isDeleting = false }

    let allAssets = cachedDayGroups.flatMap(\.assets)
    let deletingIDs = Set(items.map(\.id))
    let firstDeletedIdx = allAssets.firstIndex(where: { deletingIDs.contains($0.id) }) ?? 0
    let anchorCandidate = allAssets.enumerated()
      .filter { !deletingIDs.contains($0.element.id) }
      .min(by: { abs($0.offset - firstDeletedIdx) < abs($1.offset - firstDeletedIdx) })?.element.id

    do {
      try await nativeDeleteGridItems(items, scope: scope, client: client, device: device)
      let serverIDs = Set(items.compactMap { $0.server?.id })
      model.removeAssets(ids: serverIDs)
      var invalidatedLocalIDs = Set<String>()
      for item in items {
        guard let local = item.local else { continue }
        invalidatedLocalIDs.insert(local.id)
      }
      cloud.forgetMatches(localIDs: invalidatedLocalIDs)

      selectedIDs.removeAll()
      isSelecting = false
      userMovedTimeline = true
      device.refresh()
      rebuildDayGroups()
      if let anchorCandidate {
        withAnimation(.none) {
          proxy?.scrollTo(anchorCandidate, anchor: .center)
        }
      }
    } catch {
      if let partial = error as? NativeDeleteOperationError {
        let deletedIDs = partial.deletedServerIDs
        model.removeAssets(ids: deletedIDs)
        let invalidated = Set(items.compactMap { item -> String? in
          guard let local = item.local, let serverID = cloud.matchedServerIDs[local.id],
                deletedIDs.contains(serverID) else { return nil }
          return local.id
        })
        cloud.forgetMatches(localIDs: invalidated)
      }
      deletionError = "删除未全部成功；已确认的云端删除会更新本地状态，请刷新核对。\(error.localizedDescription)"
      userMovedTimeline = true
      device.refresh()
      await model.refreshLatest()
      rebuildDayGroups()
      if let anchorCandidate {
        withAnimation(.none) {
          proxy?.scrollTo(anchorCandidate, anchor: .center)
        }
      }
    }
  }

  private func updateBatchFavorites() async {
    let items = selectedItems
    guard !items.isEmpty else { return }
    let target = !items.allSatisfy(\.isFavorite)
    var succeeded = 0
    var failed = 0
    var partial = 0
    for item in items {
      var successfulCopies = 0
      var failedCopies = 0
      if let server = item.server {
        do { try await client.updateFavorite(id: server.id, isFavorite: target); successfulCopies += 1 }
        catch { failedCopies += 1 }
      }
      if let local = item.local {
        if await device.updateFavorite(ids: [local.id], isFavorite: target) { successfulCopies += 1 }
        else { failedCopies += 1 }
      }
      if failedCopies == 0 && successfulCopies > 0 { succeeded += 1 }
      else if successfulCopies > 0 { partial += 1 }
      else { failed += 1 }
    }
    actionMessage = "收藏\(target ? "已开启" : "已关闭")：全部成功 \(succeeded) 项，部分成功 \(partial) 项，失败 \(failed) 项。"
    device.refresh()
    await model.refreshLatest()
    rebuildDayGroups()
  }

  private func archiveSelected() async {
    let targets = selectedItems
    let missingServerInfo = targets.filter { $0.server == nil && $0.local.flatMap { cloud.matchedServerIDs[$0.id] } != nil }.count
    let candidates = targets.compactMap { item -> (NativeGridItem, String)? in
      guard let server = item.server else { return nil }
      return (item, server.id)
    }
    guard !candidates.isEmpty else { return }
    var succeeded = Set<String>()
    var failures = [String]()
    for (_, id) in candidates {
      do { try await client.updateVisibility(ids: [id], visibility: "archive"); succeeded.insert(id) }
      catch { failures.append(id) }
    }
    archivedServerIDs.formUnion(succeeded)
    model.removeAssets(ids: succeeded)
    selectedIDs.subtract(Set(candidates.filter { succeeded.contains($0.1) }.map { $0.0.id }))
    rebuildDayGroups()
    let localOnlySkipped = targets.filter { $0.server == nil && $0.local != nil }.count
    actionMessage = "归档成功 \(succeeded.count) 项，失败 \(failures.count) 项，跳过本机独有项 \(localOnlySkipped) 项，已匹配但云端信息缺失 \(missingServerInfo) 项。"
  }

  private func prepareSaveToDevice() {
    let targets = selectedItems.filter { $0.server != nil }
    guard !targets.isEmpty else { actionMessage = "没有可保存的云端原件。"; return }
    duplicateSaveCount = targets.filter { $0.local != nil }.count
    showSaveConfirmation = true
  }

  private func saveSelectedToDevice() async {
    if !device.authorized {
      await device.requestAccess()
      guard device.authorized else { actionMessage = "未获得本机照片写入权限。请在系统设置中允许访问后重试。"; return }
    }
    let targets = selectedItems.filter { $0.server != nil }
    var urls: [URL] = []
    var failed = 0
    for item in targets {
      guard let server = item.server else { continue }
      do { urls.append(try await client.originalFile(for: server)) }
      catch { failed += 1 }
    }
    let result = await device.saveFilesToPhotos(urls)
    urls.forEach { try? FileManager.default.removeItem(at: $0) }
    actionMessage = "保存到本机：成功 \(result.saved) 项，失败 \(result.failed + failed) 项。"
  }

  private func addSelectedToServerAlbum(_ albumID: String) async {
    let ids = selectedItems.compactMap { $0.server?.id }
    let skipped = selectedItems.count - ids.count
    guard !ids.isEmpty else { actionMessage = "没有可加入云端相册的资产。"; return }
    do {
      let results = try await client.addAssetsToAlbum(ids: ids, albumID: albumID)
      let summary = nativeBulkOperationSummary(requestedIDs: ids, responses: results)
      actionMessage = "加入云端相册：成功 \(summary.succeeded) 项，失败 \(summary.failed) 项，未确认 \(summary.unconfirmed) 项。\(skipped > 0 ? "跳过本机独有项 \(skipped) 项。" : "")"
    } catch { actionMessage = "加入云端相册失败：\(error.localizedDescription)" }
  }

  private func addSelectedToLocalAlbum(_ albumID: String) async {
    let ids = selectedItems.compactMap { $0.local?.id }
    let skipped = selectedItems.count - ids.count
    guard !ids.isEmpty else { actionMessage = "没有可加入本机相册的资产。"; return }
    if await device.addAssets(ids, toAlbum: albumID) {
      actionMessage = "已加入本机相册 \(ids.count) 项。\(skipped > 0 ? "跳过云端独有项 \(skipped) 项。" : "")"
    } else { actionMessage = "加入本机相册失败；请检查照片权限。" }
  }

  private func triggerBatchShare() {
    guard !isPreparingBatchShare else { return }
    let targets = selectedItems
    guard !targets.isEmpty else { return }
    isPreparingBatchShare = true
    UIImpactFeedbackGenerator(style: .light).impactOccurred()
    Task {
      let result = await nativePrepareBatchShare(items: targets, client: client)
      await MainActor.run {
        isPreparingBatchShare = false
        if !result.files.isEmpty {
          batchShareItems = result.files
          if result.failed > 0 { actionMessage = "已准备 \(result.files.count) 项原件；\(result.failed) 项原件暂不可用而跳过。" }
        } else {
          actionMessage = "没有可分享的原件；未以预览替代。"
        }
      }
    }
  }

  private func switchTimeline(to level: String, proxy: ScrollViewProxy) {
    guard selectedTimelineLevel != level else {
      withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(bottomAnchor, anchor: .bottom) }
      return
    }
    UISelectionFeedbackGenerator().selectionChanged()
    timelineSwitchTask?.cancel()
    timelineSwitchGeneration += 1
    let generation = timelineSwitchGeneration
    bottomPositionTask?.cancel()
    bottomPositionTask = nil
    bottomPositionRequest += 1
    pendingSourceChangeScroll = false
    isBootstrappingTimeline = false
    userMovedTimeline = false

    // Large libraries cannot animate a whole grid reflow. Keep the stable
    // day identity, relayout without animation, then reveal it at the bottom.
    isSwitchingTimeline = isInitialTimelineVisible
    var transaction = Transaction(animation: nil)
    transaction.disablesAnimations = true
    withTransaction(transaction) {
      selectedTimelineLevel = level
      switch level {
      case "年": columns = 7
      case "月": columns = 5
      case "日": columns = 4
      default: columns = 4
      }
    }
    guard isInitialTimelineVisible else { return } // Cold-start positioning owns its own scroll.
    timelineSwitchTask = Task { @MainActor in
      try? await Task.sleep(nanoseconds: 50_000_000)
      guard !Task.isCancelled, generation == timelineSwitchGeneration else { return }
      withAnimation(.none) { proxy.scrollTo(bottomAnchor, anchor: .bottom) }
      try? await Task.sleep(nanoseconds: 120_000_000)
      guard !Task.isCancelled, generation == timelineSwitchGeneration else { return }
      if !nativeTimelineBottomReached(anchorFrame: timelineBottomAnchorFrame,
                                      viewportFrame: timelineViewportFrame, tolerance: 8) {
        withAnimation(.none) { proxy.scrollTo(bottomAnchor, anchor: .bottom) }
      }
      isSwitchingTimeline = false
      timelineSwitchTask = nil
    }
  }

  private func triggerRefresh(proxy _: ScrollViewProxy) {
    guard isInitialTimelineVisible, !isRefreshing, !model.isLoading else { return }
    isBootstrappingTimeline = false
    isRefreshing = true
    lastTimelineRefreshTime = Date()
    UIImpactFeedbackGenerator(style: .light).impactOccurred()
    device.refresh()
    Task(priority: .utility) {
      await model.refreshLatest()
      if !serverExclusionsReady { refreshExcludedServerAssetIDs() }
      rebuildDayGroups()
      scheduleMatchedHydration()
      scheduleBackgroundCloudCheck()
      isRefreshing = false
    }
  }

  private func positionAtLatestAfterSourceChange(proxy: ScrollViewProxy) {
    pendingSourceChangeScroll = true
    userMovedTimeline = false
    if !hasInitialScrolled {
      // A new source explicitly asks for its newest asset, even if the old
      // source had not finished loading at the time of the switch.
      hasInitialScrolled = true
      didInitialPosition = true
    }
    let sourceIsLoading: Bool
    switch sourceFilter {
    case .device: sourceIsLoading = device.isLoading
    case .server: sourceIsLoading = model.isLoading
    case .all: sourceIsLoading = model.isLoading || device.isLoading
    }
    guard !sourceIsLoading else { return }
    let expectedSource = sourceFilter
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
      guard pendingSourceChangeScroll, !userMovedTimeline, sourceFilter == expectedSource else { return }
      pendingSourceChangeScroll = false
      if !isInitialTimelineVisible {
        // A source switch during cold start still needs the hidden layout
        // settling passes before the new timeline becomes visible.
        bottomPositionRetryCount = 0
        scrollToBottom(proxy: proxy, animated: false)
      } else {
        if let targetAssetID = cachedDayGroups.last?.assets.last?.id {
          withAnimation(.none) { proxy.scrollTo(targetAssetID, anchor: .bottom) }
        }
        withAnimation(.none) { proxy.scrollTo(bottomAnchor, anchor: .bottom) }
      }
    }
  }

  private func positionInitiallyIfReady(proxy: ScrollViewProxy) {
    guard !hasInitialScrolled, !userMovedTimeline,
          isBootstrappingTimeline else { return }
    guard nativeInitialTimelineReady(
      source: sourceFilter,
      remoteLoaded: initialRemoteLoaded,
      // A cached local or remote snapshot can be displayed while either
      // source refreshes in the background; only uncached scans gate layout.
      remoteLoading: model.isLoading &&
        !model.hasCachedSnapshot && !device.hasLoadedInitialSnapshot,
      localSnapshotLoaded: device.hasLoadedInitialSnapshot,
      localLoading: device.isLoading && !device.hasLoadedInitialSnapshot
    ) else { return }
    if cachedDayGroups.isEmpty ||
        (cachedDayGroups.count == 1 && totalDisplayCount <= columns) {
      // A single row cannot fill the viewport; there is no bottom offset.
      isInitialTimelineVisible = true
      isBootstrappingTimeline = false
      didInitialPosition = true
      return
    }
    bottomPositionRetryCount = 0
    scrollToBottom(proxy: proxy, animated: false, initial: true)
  }

  private func keepBottomUntilUserScrolls(proxy: ScrollViewProxy) {
    guard nativeShouldKeepTimelineAtBottom(
      isBootstrapping: isBootstrappingTimeline,
      userMovedTimeline: userMovedTimeline,
      pendingSourceChange: pendingSourceChangeScroll,
      hasAssets: !cachedDayGroups.isEmpty,
      positioningInProgress: bottomPositionTask != nil
    ) else { return }
    if !hasInitialScrolled {
      positionInitiallyIfReady(proxy: proxy)
      return
    }
    // Asset and match publications can arrive during layout. The running
    // task reads the latest target on each pass; do not restart it.
    scrollToBottom(proxy: proxy, animated: false, initial: true)
  }

  private func scrollToBottom(proxy: ScrollViewProxy, animated: Bool, initial: Bool = false) {
    if initial {
      guard isBootstrappingTimeline, !userMovedTimeline, !pendingSourceChangeScroll else { return }
    } else {
      // A double tap is an explicit request even if initial positioning failed.
      isBootstrappingTimeline = false
      pendingSourceChangeScroll = false
      userMovedTimeline = false
    }
    hasInitialScrolled = true
    bottomPositionTask?.cancel()
    bottomPositionRequest += 1
    let request = bottomPositionRequest
    // LazyVStack estimates heights for off-screen days. Revisit its bottom
    // after layout materializes them, rather than trusting a single scrollTo.
    bottomPositionTask = Task { @MainActor in
      var stableBottomPasses = 0
      for (index, delay) in [0, 50, 150, 350, 700].enumerated() {
        if delay > 0 { try? await Task.sleep(nanoseconds: UInt64(delay) * 1_000_000) }
        guard !Task.isCancelled, request == bottomPositionRequest, !userMovedTimeline,
              !initial || (isBootstrappingTimeline && !pendingSourceChangeScroll) else { return }
        if let targetAssetID = activeTimelineSections.last?.assets.last?.id ?? cachedDayGroups.last?.assets.last?.id {
          if animated && index == 0 {
            withAnimation(.easeInOut(duration: 0.25)) { proxy.scrollTo(targetAssetID, anchor: .bottom) }
          } else {
            withAnimation(.none) { proxy.scrollTo(targetAssetID, anchor: .bottom) }
          }
        }
        if animated && index == 0 {
          withAnimation(.easeInOut(duration: 0.25)) { proxy.scrollTo(bottomAnchor, anchor: .bottom) }
        } else {
          withAnimation(.none) { proxy.scrollTo(bottomAnchor, anchor: .bottom) }
        }
        didInitialPosition = true
        // Let the explicit return-to-latest animation finish before a lazy
        // layout correction; a 40ms correction would cut it off mid-flight.
        let settleDelay: UInt64 = animated && index == 0 ? 300_000_000 : 40_000_000
        try? await Task.sleep(nanoseconds: settleDelay)
        if nativeTimelineBottomReached(
          anchorFrame: timelineBottomAnchorFrame,
          viewportFrame: timelineViewportFrame
        ) {
          stableBottomPasses += 1
        } else {
          stableBottomPasses = 0
        }
        // LazyVStack's estimated height may change as day groups materialize.
        // Require multiple separated bottom measurements before revealing it.
        if stableBottomPasses >= 3 { break }
      }
      if request == bottomPositionRequest {
        let reachedBottom = nativeTimelineBottomReached(
          anchorFrame: timelineBottomAnchorFrame,
          viewportFrame: timelineViewportFrame
        )
        if reachedBottom && stableBottomPasses >= 3 {
          bottomPositionTask = nil
          bottomPositionRetryCount = 0
          isBootstrappingTimeline = false
          isInitialTimelineVisible = true
        } else if !Task.isCancelled && !userMovedTimeline &&
                    bottomPositionRetryCount < 1 {
          // Retry only after SwiftUI has published the latest lazy-stack
          // geometry; never expose the grid at the stale top offset.
          bottomPositionRetryCount += 1
          try? await Task.sleep(nanoseconds: 100_000_000)
          guard !Task.isCancelled, request == bottomPositionRequest,
                !userMovedTimeline else { return }
          bottomPositionTask = nil
          scrollToBottom(proxy: proxy, animated: false, initial: initial)
        } else {
          bottomPositionTask = nil
          bottomPositionRetryCount = 0
          // Bound the hidden wait if an OS/layout edge case prevents geometry
          // reporting; the final scroll request has still targeted the anchor.
          isBootstrappingTimeline = false
          isInitialTimelineVisible = true
        }
      }
    }
  }

  private func requestOlder() {
    guard loadingOlderAnchor == nil, model.hasOlder, !model.isLoading else { return }
    isBootstrappingTimeline = false
    loadingOlderAnchor = "pending"
    Task(priority: .utility) {
      await model.loadOlder()
      // Do not fight the user's ongoing drag with an explicit scrollTo.
      loadingOlderAnchor = nil
    }
  }

  private func updateSelectionAfterTimelineChange() {
    let visibleIDs = Set(cachedDayGroups.flatMap { $0.assets.map(\.id) })
    selectedIDs.formIntersection(visibleIDs)
    if selectedIDs.isEmpty { isSelecting = false }
  }

  private func refreshExcludedServerAssetIDs() {
    excludedServerRefreshTask?.cancel()
    excludedServerRefreshGeneration += 1
    let generation = excludedServerRefreshGeneration
    let albumIDs = nativePhotosExcludedAlbumIDs(from: excludedServerAlbumIDsRaw)
    guard !albumIDs.isEmpty else {
      excludedServerAssetIDs = []
      serverExclusionsReady = true
      saveExcludedSnapshotIfReady()
      rebuildDayGroups()
      updateSelectionAfterTimelineChange()
      return
    }
    excludedServerRefreshTask = Task {
      var excludedIDs = Set<String>()
      var didLoad = true
      do {
        for albumID in albumIDs {
          try Task.checkCancellation()
          excludedIDs.formUnion(try await client.assetIDs(inServerAlbum: albumID))
        }
      } catch {
        guard !Task.isCancelled else { return }
        // Keep known exclusions rather than showing albums after a transient API error.
        didLoad = false
        excludedIDs = excludedServerAssetIDs
        NativeBackgroundDiagnostics.shared.record("读取排除的云端相册", error: error)
      }
      guard !Task.isCancelled, generation == excludedServerRefreshGeneration,
            accountIdentity == NativeSyncCacheStore.shared.identity,
            albumIDs == nativePhotosExcludedAlbumIDs(from: excludedServerAlbumIDsRaw) else { return }
      await MainActor.run {
        excludedServerAssetIDs = excludedIDs
        if didLoad {
          serverExclusionsReady = true
          saveExcludedSnapshotIfReady()
        }
        rebuildDayGroups()
        updateSelectionAfterTimelineChange()
      }
    }
  }

  private func rebuildDayGroups() {
    var grouped: [Date: [NativeGridItem]] = [:]
    var calendar = Calendar.autoupdatingCurrent
    calendar.timeZone = .autoupdatingCurrent
    for item in filteredTimelineAssets {
      let date = calendar.startOfDay(for: item.date)
      grouped[date, default: []].append(item)
    }
    let groups = grouped.keys.sorted().map { date in
      NativeDayGroup(date: date, assets: grouped[date] ?? [])
    }
    cachedDayGroups = groups
    // Calculate only when assets change, never on a SwiftUI body/layout pass.
    let daySections = nativeTimelineSections(from: groups, level: "日", calendar: calendar)
    cachedTimelineSections = [
      "年": nativeTimelineSections(from: groups, level: "年", calendar: calendar),
      "月": nativeTimelineSections(from: groups, level: "月", calendar: calendar),
      "日": daySections,
      "所有照片": daySections
    ]
  }

  private var allOrderedAssetIDs: [String] {
    cachedDayGroups.flatMap { $0.assets.map(\.id) }
  }

  private func enterSelection(startingWith id: String, at location: CGPoint? = nil) {
    guard !isSelecting else { return }
    UIImpactFeedbackGenerator(style: .heavy).impactOccurred()
    isSelecting = true
    dragStartAssetID = id
    let startLoc = location ?? itemBounds[id].map { CGPoint(x: $0.midX, y: $0.midY) }
    dragStartLocation = startLoc
    dragInitialSelectedIDs = selectedIDs
    let alreadySelected = selectedIDs.contains(id)
    dragSelectMode = !alreadySelected
    if dragSelectMode {
      selectedIDs.insert(id)
    } else {
      selectedIDs.remove(id)
    }
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
    if dragSelectMode {
      selectedIDs.insert(id)
    } else {
      selectedIDs.remove(id)
    }
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
      selectedIDs = updated
    }
  }

  private func finishDragSelection() {
    dragStartLocation = nil
    dragStartAssetID = nil
    dragInitialSelectedIDs.removeAll()
  }

  private func toggleSelection(_ id: String) {
    UIImpactFeedbackGenerator(style: .light).impactOccurred()
    if selectedIDs.contains(id) { selectedIDs.remove(id) } else { selectedIDs.insert(id) }
  }

  private func clearSelection() {
    isSelecting = false
    isDragSelecting = false
    selectedIDs.removeAll()
    finishDragSelection()
  }

  private func cloudSymbol(for entry: NativeGridItem) -> String {
    guard let local = entry.local else { return "cloud" }
    if entry.server != nil || cloud.matchedServerIDs[local.id] != nil { return "checkmark.icloud" }
    if cloud.failedVerificationIDs.contains(local.id) { return "exclamationmark.icloud" }
    return cloud.checkedIDs.contains(local.id) ? "icloud.slash" : "questionmark.icloud"
  }

  private func cloudDescription(for entry: NativeGridItem) -> String {
    let typeName = entry.isVideo ? "视频" : "照片"
    if let local = entry.local {
      if entry.server != nil || cloud.matchedServerIDs[local.id] != nil { return "已核验云端副本的\(typeName)" }
      if cloud.failedVerificationIDs.contains(local.id) { return "核验失败、云端状态未知的本机\(typeName)" }
      return cloud.checkedIDs.contains(local.id) ? "仅本机\(typeName)" : "云端状态未知的本机\(typeName)"
    }
    return "仅云端\(typeName)"
  }
}

struct NativeTimelineSection: Identifiable {
  var id: Date { date }  // The day stays in place as the display granularity changes.
  let title: String?
  let date: Date
  let assets: [NativeGridItem]
}

func nativeTimelineSections(
  from groups: [NativeDayGroup], level: String, calendar: Calendar
) -> [NativeTimelineSection] {
  var lastYear: Int?
  var lastMonth: Int?
  return groups.map { group in
    let year = calendar.component(.year, from: group.date)
    let month = calendar.component(.month, from: group.date)
    let firstInMonth = lastYear != year || lastMonth != month
    let title: String?
    switch level {
    case "年": title = lastYear == year ? nil : "\(year) 年"
    case "月": title = firstInMonth ? "\(year)年\(month)月" : nil
    default: title = NativeImmichClient.formatChineseDate(group.date, includeDay: !firstInMonth)
    }
    lastYear = year
    lastMonth = month
    return NativeTimelineSection(title: title, date: group.date, assets: group.assets)
  }
}

struct NativeDayGroup {
  let date: Date
  let assets: [NativeGridItem]
}

private struct NativePhotosLocalAlbumPicker: View {
  let albums: [NativeDeviceAlbum]
  let onSelect: (String) -> Void
  @Environment(\.dismiss) private var dismiss

  var body: some View {
    NavigationView {
      List(albums) { album in
        Button {
          dismiss()
          onSelect(album.id)
        } label: {
          HStack {
            Text(album.name)
            Spacer()
            Text("\(album.count)").foregroundColor(.secondary)
          }
        }
      }
      .navigationTitle("选择本机相册")
      .toolbar { ToolbarItem(placement: .navigationBarTrailing) { Button("取消") { dismiss() } } }
    }
  }
}

private struct NativePhotosServerAlbumPicker: View {
  let client: NativeImmichClient
  let onSelect: (String) -> Void
  @Environment(\.dismiss) private var dismiss
  @State private var albums: [NativeServerAlbum] = []
  @State private var loading = true
  @State private var error: String?

  var body: some View {
    NavigationView {
      Group {
        if loading { ProgressView("正在加载云端相册…") }
        else if let error { VStack { Text(error); Button("重试") { Task { await load() } } } }
        else {
          List(albums) { album in
            Button {
              dismiss()
              onSelect(album.id)
            } label: {
              HStack {
                Text(album.name)
                Spacer()
                Text("\(album.count)").foregroundColor(.secondary)
              }
            }
          }
        }
      }
      .navigationTitle("选择云端相册")
      .toolbar { ToolbarItem(placement: .navigationBarTrailing) { Button("取消") { dismiss() } } }
      .task { await load() }
    }
  }

  @MainActor private func load() async {
    loading = true
    error = nil
    do { albums = try await client.serverAlbums() }
    catch { self.error = error.localizedDescription }
    loading = false
  }
}

struct NativeItemFramePreferenceKey: PreferenceKey {
  static var defaultValue: [String: CGRect] = [:]
  static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
    value.merge(nextValue(), uniquingKeysWith: { $1 })
  }
}

struct NativeTimelineBottomAnchorFramePreferenceKey: PreferenceKey {
  static var defaultValue = CGRect.null
  static func reduce(value: inout CGRect, nextValue: () -> CGRect) {
    let next = nextValue()
    if !next.isNull { value = next }
  }
}

struct NativeTimelineViewportFramePreferenceKey: PreferenceKey {
  static var defaultValue = CGRect.null
  static func reduce(value: inout CGRect, nextValue: () -> CGRect) {
    let next = nextValue()
    if !next.isNull { value = next }
  }
}

enum NativeThumbnailCache {
  static let images: NSCache<NSString, UIImage> = {
    let cache = NSCache<NSString, UIImage>()
    cache.countLimit = 1500
    cache.totalCostLimit = 200 * 1024 * 1024
    return cache
  }()

  static func downsampledImage(from data: Data, maxPixelSize: Int) -> UIImage? {
    let options: [CFString: Any] = [
      kCGImageSourceShouldCache: false
    ]
    guard let source = CGImageSourceCreateWithData(data as CFData, options as CFDictionary) else {
      return UIImage(data: data)
    }
    let thumbOptions: [CFString: Any] = [
      kCGImageSourceCreateThumbnailFromImageAlways: true,
      kCGImageSourceShouldCacheImmediately: true,
      kCGImageSourceCreateThumbnailWithTransform: true,
      kCGImageSourceThumbnailMaxPixelSize: maxPixelSize
    ]
    guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbOptions as CFDictionary) else {
      return UIImage(data: data)
    }
    return UIImage(cgImage: cgImage)
  }
}

@MainActor
private final class NativeThumbnailRequestLimiter {
  static let shared = NativeThumbnailRequestLimiter()
  private let maximumActive = 6
  private var active = 0
  private var waiters: [(UUID, CheckedContinuation<Bool, Never>)] = []

  func acquire() async -> Bool {
    if Task.isCancelled { return false }
    if active < maximumActive {
      active += 1
      return true
    }
    let token = UUID()
    return await withTaskCancellationHandler {
      await withCheckedContinuation { continuation in
        if Task.isCancelled { continuation.resume(returning: false) }
        else { waiters.append((token, continuation)) }
      }
    } onCancel: {
      Task { @MainActor in
        if let index = self.waiters.firstIndex(where: { $0.0 == token }) {
          let (_, continuation) = self.waiters.remove(at: index)
          continuation.resume(returning: false)
        }
      }
    }
  }

  func release() {
    if waiters.isEmpty {
      active = max(0, active - 1)
    } else {
      let (_, continuation) = waiters.removeFirst()
      continuation.resume(returning: true)
    }
  }
}

struct NativeThumbhashBackground: View {
  let thumbhash: String?

  var body: some View {
    if let gradientColors, !gradientColors.isEmpty {
      LinearGradient(
        colors: gradientColors,
        startPoint: .topLeading,
        endPoint: .bottomTrailing
      )
    } else {
      Rectangle().fill(Color(uiColor: .secondarySystemBackground))
    }
  }

  private var gradientColors: [Color]? {
    guard let hash = thumbhash, !hash.isEmpty,
          let data = Data(base64Encoded: hash), data.count >= 5 else {
      return nil
    }
    func dc(_ byte: UInt8) -> Double {
      let v = Double((byte & 0x3F) * 2)
      return min(1.0, max(0.0, (v * 255.0 / 126.0) / 255.0))
    }
    let r = dc(data[1])
    let g = dc(data[2])
    let b = dc(data[3])
    let c1 = Color(red: r, green: g, blue: b)
    let c2 = Color(red: max(0.0, r * 0.55), green: max(0.0, g * 0.55), blue: max(0.0, b * 0.55))
    return [c1, c2]
  }
}

func nativeThumbnailCacheAccountKey(
  server: String, userId: String?, credential: String
) -> String {
  if let userId, !userId.isEmpty {
    let canonicalServer = server.trimmingCharacters(in: .whitespacesAndNewlines)
      .lowercased().replacingOccurrences(
        of: "/+$", with: "", options: .regularExpression
      )
    return "\(canonicalServer)|\(userId)"
  }
  return "\(server):\(credential)"
}

struct NativeThumbnail: View {
  let client: NativeImmichClient
  let asset: NativeAsset
  var columns: Int = 3
  @State private var image: UIImage?

  var body: some View {
    Group {
      if let image {
        Image(uiImage: image)
          .resizable()
          .scaledToFill()
      } else {
        NativeThumbhashBackground(thumbhash: asset.thumbhash)
      }
    }
    .task(id: "\(client.config.serverUrl):\(asset.id):\(isLowDensity ? "p" : "t")") {
      image = nil
      let credential = client.config.accessToken ?? client.config.apiKey ?? ""
      let legacyIdentity = "\(client.config.serverUrl):\(credential)"
      let stableIdentity = nativeThumbnailCacheAccountKey(
        server: client.config.serverUrl, userId: client.config.userId,
        credential: credential
      )
      let accountDigest = SHA256.hash(data: Data(stableIdentity.utf8))
        .map { String(format: "%02x", $0) }.joined()
      let legacyDigest = SHA256.hash(data: Data(legacyIdentity.utf8))
        .map { String(format: "%02x", $0) }.joined()
      let sizeTag = isLowDensity ? "preview" : "thumbnail"
      let cacheKey = "\(accountDigest):\(asset.id):\(sizeTag)"
      let legacyKey = "\(legacyDigest):\(asset.id):\(sizeTag)"
      let key = NSString(string: cacheKey)
      if let cached = NativeThumbnailCache.images.object(forKey: key) {
        image = cached
        return
      }
      let maxDim = maxPixelDimension
      guard await NativeThumbnailRequestLimiter.shared.acquire() else { return }
      defer { NativeThumbnailRequestLimiter.shared.release() }
      guard !Task.isCancelled else { return }
      var cachedData = await NativeThumbnailDiskCache.shared.data(for: cacheKey)
      if cachedData == nil, cacheKey != legacyKey {
        cachedData = await NativeThumbnailDiskCache.shared.data(for: legacyKey)
        if let cachedData, !Task.isCancelled {
          await NativeThumbnailDiskCache.shared.store(cachedData, for: cacheKey)
        }
      }
      if let cachedData {
        guard !Task.isCancelled else { return }
        let decoded = await Task.detached(priority: .utility) {
          NativeThumbnailCache.downsampledImage(from: cachedData, maxPixelSize: maxDim)
        }.value
        if !Task.isCancelled, let decoded {
          NativeThumbnailCache.images.setObject(
            decoded,
            forKey: key,
            cost: Int(decoded.size.width * decoded.size.height * 4)
          )
          image = decoded
          return
        }
      }

      // If columns > 3, request lightweight 250px thumbnail directly (10x faster)
      // Only request high-res preview when zooming into 1~3 large columns
      let preferredURL = isLowDensity ? client.thumbnailURL(for: asset, size: "preview") : client.thumbnailURL(for: asset, size: "thumbnail")
      let fallbackURL = isLowDensity ? client.thumbnailURL(for: asset, size: "thumbnail") : client.thumbnailURL(for: asset, size: "preview")
      guard let url = preferredURL ?? fallbackURL else { return }

      guard !Task.isCancelled else { return }
      do {
        let data = try await client.thumbnailData(for: url)
        guard !Task.isCancelled else { return }
        let decoded = await Task.detached(priority: .utility) {
          NativeThumbnailCache.downsampledImage(from: data, maxPixelSize: maxDim)
        }.value
        guard !Task.isCancelled, let decoded else { return }
        await NativeThumbnailDiskCache.shared.store(data, for: cacheKey)
        NativeThumbnailCache.images.setObject(
          decoded,
          forKey: key,
          cost: Int(decoded.size.width * decoded.size.height * 4)
        )
        image = decoded
      } catch {
        if let fallbackURL, fallbackURL != url {
          do {
            let data = try await client.thumbnailData(for: fallbackURL)
            guard !Task.isCancelled else { return }
            let decoded = await Task.detached(priority: .utility) {
              NativeThumbnailCache.downsampledImage(from: data, maxPixelSize: maxDim)
            }.value
            guard !Task.isCancelled, let decoded else { return }
            await NativeThumbnailDiskCache.shared.store(data, for: cacheKey)
            NativeThumbnailCache.images.setObject(
              decoded,
              forKey: key,
              cost: Int(decoded.size.width * decoded.size.height * 4)
            )
            image = decoded
          } catch {
            image = nil
            if !Task.isCancelled {
              NativeBackgroundDiagnostics.shared.record("云端缩略图", error: error)
            }
          }
        } else {
          image = nil
          if !Task.isCancelled {
            NativeBackgroundDiagnostics.shared.record("云端缩略图", error: error)
          }
        }
      }
    }
  }

  private var isLowDensity: Bool {
    columns <= 3
  }

  private var maxPixelDimension: Int {
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

// MARK: - Native Unified Gallery Viewer (Full-featured Asset Viewer)

import AVKit

private final class NativeWeakControllerBox {
  weak var value: UIViewController?
}

private struct NativeClearBackgroundView: UIViewRepresentable {
  let onControllerReady: (UIViewController) -> Void

  func makeUIView(context: Context) -> UIView {
    let view = UIView()
    view.backgroundColor = .clear
    DispatchQueue.main.async {
      view.superview?.superview?.backgroundColor = .clear
      if let controller = view.findViewController() {
        controller.view.backgroundColor = .clear
        onControllerReady(controller)
      }
    }
    return view
  }

  func updateUIView(_ uiView: UIView, context: Context) {}
}

private extension UIView {
  func findViewController() -> UIViewController? {
    if let nextResponder = self.next as? UIViewController {
      return nextResponder
    } else if let nextResponder = self.next as? UIView {
      return nextResponder.findViewController()
    } else {
      return nil
    }
  }
}

// Keep per-frame gesture updates out of the gallery's asset/page state.
// Only scale the pager for the final thumbnail dismissal animation.
private final class NativeViewerDismissFinderView: UIView {
  var onSetup: ((UIView) -> Void)?

  override func didMoveToWindow() {
    super.didMoveToWindow()
    if window != nil {
      onSetup?(self)
    }
  }
}

private struct NativeViewerDismissHelper: UIViewRepresentable {
  let isZoomed: Bool
  let isFinishing: Bool
  let onDragChanged: (CGFloat, CGFloat) -> Void
  let onDragEnded: (CGFloat, CGFloat, CGFloat, CGFloat) -> Void

  func makeCoordinator() -> Coordinator {
    Coordinator(
      isZoomed: isZoomed,
      isFinishing: isFinishing,
      onDragChanged: onDragChanged,
      onDragEnded: onDragEnded
    )
  }

  func makeUIView(context: Context) -> NativeViewerDismissFinderView {
    let view = NativeViewerDismissFinderView()
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

  func updateUIView(_ uiView: NativeViewerDismissFinderView, context: Context) {
    context.coordinator.isZoomed = isZoomed
    context.coordinator.isFinishing = isFinishing
    context.coordinator.onDragChanged = onDragChanged
    context.coordinator.onDragEnded = onDragEnded
    context.coordinator.setup(from: uiView)
  }

  static func dismantleUIView(_ uiView: NativeViewerDismissFinderView, coordinator: Coordinator) {
    uiView.onSetup = nil
    coordinator.detach()
  }

  final class Coordinator: NSObject, UIGestureRecognizerDelegate {
    var isZoomed: Bool
    var isFinishing: Bool
    var onDragChanged: (CGFloat, CGFloat) -> Void
    var onDragEnded: (CGFloat, CGFloat, CGFloat, CGFloat) -> Void

    private weak var panGesture: UIPanGestureRecognizer?
    private weak var pagingScrollView: UIScrollView?
    private weak var targetView: UIView?

    init(
      isZoomed: Bool,
      isFinishing: Bool,
      onDragChanged: @escaping (CGFloat, CGFloat) -> Void,
      onDragEnded: @escaping (CGFloat, CGFloat, CGFloat, CGFloat) -> Void
    ) {
      self.isZoomed = isZoomed
      self.isFinishing = isFinishing
      self.onDragChanged = onDragChanged
      self.onDragEnded = onDragEnded
    }

    func setup(from view: UIView) {
      guard let paging = findPagingScrollView(from: view) else {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self, weak view] in
          guard let self = self, let view = view else { return }
          self.setup(from: view)
        }
        return
      }
      let target = paging.superview ?? paging
      if self.pagingScrollView === paging && self.targetView === target && self.panGesture != nil {
        return
      }
      detach()

      self.pagingScrollView = paging
      self.targetView = target

      let pan = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
      pan.maximumNumberOfTouches = 1
      pan.delegate = self
      pan.cancelsTouchesInView = true
      target.addGestureRecognizer(pan)
      paging.panGestureRecognizer.require(toFail: pan)
      self.panGesture = pan
    }

    func detach() {
      if let pan = panGesture, let view = pan.view {
        view.removeGestureRecognizer(pan)
      }
      panGesture = nil
      pagingScrollView = nil
      targetView = nil
    }

    private func findPagingScrollView(from view: UIView) -> UIScrollView? {
      var responder: UIResponder? = view
      while let r = responder {
        if let pvc = r as? UIPageViewController {
          if let sv = findPagingScrollViewIn(view: pvc.view) { return sv }
        }
        if let vc = r as? UIViewController {
          for child in vc.children {
            if let pvc = child as? UIPageViewController {
              if let sv = findPagingScrollViewIn(view: pvc.view) { return sv }
            }
          }
        }
        responder = r.next
      }

      var root: UIView = view
      while let p = root.superview { root = p }
      return findPagingScrollViewIn(view: root)
    }

    private func findPagingScrollViewIn(view: UIView) -> UIScrollView? {
      if let sv = view as? UIScrollView {
        let isZoomScrollView = sv.tag == 100 || sv.maximumZoomScale > 1.0
        let isPaging = sv.isPagingEnabled || String(describing: type(of: sv)).contains("Queuing")
        if !isZoomScrollView && isPaging {
          return sv
        }
      }
      for sub in view.subviews {
        if let found = findPagingScrollViewIn(view: sub) { return found }
      }
      return nil
    }

    @objc private func handlePan(_ gesture: UIPanGestureRecognizer) {
      guard let view = gesture.view else { return }
      // The pager moves and scales during dismissal. Measure in the stable
      // window coordinate space, not in the animated gesture host's space.
      let coordinateView: UIView = view.window ?? view
      let translation = gesture.translation(in: coordinateView)
      let velocity = gesture.velocity(in: coordinateView)

      switch gesture.state {
      case .began:
        // Cancel in-flight horizontal paging and lock offset to the current page boundary
        if let sv = pagingScrollView {
          sv.panGestureRecognizer.isEnabled = false
          sv.panGestureRecognizer.isEnabled = true
          let width = sv.bounds.width
          if width > 0 {
            let currentX = sv.contentOffset.x
            let targetX = round(currentX / width) * width
            if abs(currentX - targetX) > 0.5 {
              sv.setContentOffset(CGPoint(x: targetX, y: sv.contentOffset.y), animated: false)
            }
          }
        }
        if translation.y > 0 {
          onDragChanged(translation.x, translation.y)
        }
      case .changed:
        if translation.y > 0 {
          onDragChanged(translation.x, translation.y)
        } else {
          onDragChanged(0, 0)
        }
      case .ended:
        onDragEnded(translation.x, translation.y, velocity.x, velocity.y)
      case .cancelled, .failed:
        // A system interruption must restore the viewer, not commit dismissal.
        onDragEnded(0, 0, 0, 0)
      default:
        break
      }
    }

    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
      guard gestureRecognizer === panGesture else { return true }
      guard !isZoomed, !isFinishing else { return false }
      guard let pan = gestureRecognizer as? UIPanGestureRecognizer else { return false }
      guard let view = pan.view else { return false }

      let velocity = pan.velocity(in: view)
      // Must be predominantly vertical (height component > width component * 1.3)
      let isVertical = abs(velocity.y) > abs(velocity.x) * 1.3
      guard isVertical else { return false }

      return true
    }

    func gestureRecognizer(
      _ gestureRecognizer: UIGestureRecognizer,
      shouldBeRequiredToFailBy otherGestureRecognizer: UIGestureRecognizer
    ) -> Bool {
      if otherGestureRecognizer === pagingScrollView?.panGestureRecognizer {
        return true
      }
      return false
    }

    func gestureRecognizer(
      _ gestureRecognizer: UIGestureRecognizer,
      shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
    ) -> Bool {
      if otherGestureRecognizer === pagingScrollView?.panGestureRecognizer {
        return false
      }
      return false
    }
  }
}

// iOS 15-compatible completion observation. A wall-clock timer can remove the
// fullScreenCover before its final rendered frame, especially under load.
private struct NativeViewerDismissCompletion: AnimatableModifier {
  var progress: Double
  let onCompleted: () -> Void

  var animatableData: Double {
    get { progress }
    set {
      progress = newValue
      if newValue == 1 {
        // Never mutate SwiftUI state during an animation/layout update.
        let completion = onCompleted
        DispatchQueue.main.async(execute: completion)
      }
    }
  }

  func body(content: Content) -> some View { content }
}

private struct NativeViewerDismissSurface<Pager: View, Chrome: View>: View {
  let pager: Pager
  let chrome: Chrome
  let showsChrome: Bool
  let isZoomed: Bool
  let sourceFrame: CGRect?
  @Binding var dismissRequested: Bool
  var onSwipeUp: (() -> Void)? = nil
  let onDismiss: () -> Void

  @State private var dragX: CGFloat = 0
  @State private var dragY: CGFloat = 0
  @State private var dismissScale: CGFloat = 1
  @State private var dismissX: CGFloat = 0
  @State private var dismissY: CGFloat = 0
  @State private var dismissCornerRadius: CGFloat = 0
  @State private var backdropOpacity: Double = 1
  @State private var pagerOpacity: Double = 1
  @State private var finishing = false
  @State private var didCompleteDismiss = false

  private var dragProgress: CGFloat {
    min(1.0, max(0.0, dragY / 320.0))
  }

  private var interactiveScale: CGFloat {
    1.0 - dragProgress * 0.28
  }

  private var interactiveCornerRadius: CGFloat {
    dragProgress * 36.0
  }

  private var interactiveShadowOpacity: Double {
    min(0.28, Double(dragProgress) * 0.28)
  }

  var body: some View {
    ZStack {
      (showsChrome ? Color(uiColor: .systemBackground) : Color.black)
        .opacity(backdropOpacity * max(0, 1 - Double(dragY / 350)))
        .ignoresSafeArea()

      pager
        .opacity(pagerOpacity)
        .clipShape(RoundedRectangle(cornerRadius: finishing ? dismissCornerRadius : interactiveCornerRadius, style: .continuous))
        .shadow(color: Color.black.opacity(finishing ? 0 : interactiveShadowOpacity), radius: 18, y: 8)
        .scaleEffect(finishing ? dismissScale : interactiveScale)
        .offset(x: finishing ? dismissX : (dragX * 0.35), y: finishing ? dismissY : dragY)
        .background(
          NativeViewerDismissHelper(
            isZoomed: isZoomed,
            isFinishing: finishing,
            onDragChanged: { x, y in
              dragX = x
              dragY = max(0, y)
            },
            onDragEnded: { translationX, translationY, velocityX, velocityY in
              handleDragEnded(translationX: translationX, translationY: translationY, velocityX: velocityX, velocityY: velocityY)
            }
          )
        )

      if showsChrome && !finishing {
        chrome
          .opacity(backdropOpacity * max(0, 1 - Double(dragY / 45)))
          .allowsHitTesting(dragY < 10)
          .transition(.opacity)
      }
    }
    .modifier(NativeViewerDismissCompletion(progress: finishing ? 1 : 0) {
      guard finishing, !didCompleteDismiss else { return }
      didCompleteDismiss = true
      onDismiss()
    })
    .animation(.easeInOut(duration: 0.2), value: showsChrome)
    .onChange(of: dismissRequested) { requested in
      if requested { finishDismiss(swipingDown: false) }
    }
  }

  private func handleDragEnded(translationX: CGFloat, translationY: CGFloat, velocityX: CGFloat, velocityY: CGFloat) {
    guard !finishing else { return }
    if isZoomed {
      withAnimation(.interactiveSpring(response: 0.32, dampingFraction: 0.85)) {
        dragX = 0; dragY = 0
      }
      return
    }
    let predictedEnd = CGSize(width: translationX + velocityX * 0.2, height: translationY + velocityY * 0.2)
    let action = nativeClassifyViewerVerticalSwipe(
      translation: CGSize(width: translationX, height: translationY),
      predictedEnd: predictedEnd
    )
    if action == .showDetails {
      onSwipeUp?()
      withAnimation(.interactiveSpring(response: 0.32, dampingFraction: 0.85)) {
        dragX = 0; dragY = 0
      }
      return
    }
    if action == .dismiss {
      finishDismiss(swipingDown: true)
    } else {
      withAnimation(.interactiveSpring(response: 0.32, dampingFraction: 0.85)) {
        dragX = 0
        dragY = 0
      }
    }
  }

  private func finishDismiss(swipingDown: Bool) {
    guard !finishing else { return }
    dismissScale = interactiveScale
    dismissX = dragX * 0.35
    dismissY = dragY
    dismissCornerRadius = interactiveCornerRadius
    UIImpactFeedbackGenerator(style: .light).impactOccurred()
    let screen = UIScreen.main.bounds
    let target = nativeViewerVisibleSourceFrame(sourceFrame, in: screen)

    // Use a finite, non-overshooting settle curve. The previous spring still
    // had a visible tail when a separate 0.28 s timer tore down the cover.
    // Animate the completion observer in this SAME transaction as the card.
    withAnimation(.timingCurve(0.2, 0.7, 0.25, 1, duration: 0.32)) {
      finishing = true
      backdropOpacity = 0
      if let target {
        let scale = min(target.width / screen.width, target.height / screen.height)
        dismissScale = scale
        dismissX = target.midX - screen.midX
        dismissY = target.midY - screen.midY
        dismissCornerRadius = 4
      } else if swipingDown {
        dismissY = screen.height + 80
        dismissScale = 0.65
        dismissCornerRadius = 36
      } else {
        pagerOpacity = 0
      }
    }
  }
}

func nativeViewerVisibleSourceFrame(_ source: CGRect?, in screen: CGRect) -> CGRect? {
  guard let source, source.width > 0, source.height > 0,
        screen.intersects(source) else { return nil }
  return source
}

func nativeFilmstripTargetIndex(start: Int, translation: CGFloat, count: Int) -> Int {
  guard count > 0, translation.isFinite else { return 0 }
  let limitedSteps = max(-CGFloat(count), min(CGFloat(count), (translation / 30).rounded()))
  return min(count - 1, max(0, start - Int(limitedSteps)))
}

private struct NativeViewerFilmstrip: View {
  let client: NativeImmichClient
  let device: NativeDeviceLibrary
  let items: [NativeGridItem]
  @Binding var currentAssetID: String
  @State private var dragStartIndex: Int?

  var body: some View {
    GeometryReader { geometry in
      ScrollViewReader { proxy in
        ScrollView(.horizontal, showsIndicators: false) {
          LazyHStack(spacing: 2) {
            ForEach(items) { item in
              let isCurrent = item.id == currentAssetID
              Group {
                if let server = item.server {
                  NativeThumbnail(client: client, asset: server, columns: 8)
                } else if let local = item.local {
                  NativeDeviceThumbnail(asset: local, columns: 8)
                } else {
                  Color.gray.opacity(0.3)
                }
              }
              .frame(width: 28, height: isCurrent ? 36 : 30)
              .clipped()
              .clipShape(RoundedRectangle(cornerRadius: isCurrent ? 5 : 3))
              .overlay(
                RoundedRectangle(cornerRadius: isCurrent ? 5 : 3)
                  .stroke(isCurrent ? Color.white : Color.clear, lineWidth: 2)
                  .shadow(color: isCurrent ? Color.black.opacity(0.25) : Color.clear, radius: 2)
              )
              .id(item.id)
              .contentShape(Rectangle())
              .onTapGesture {
                if item.id != currentAssetID {
                  UISelectionFeedbackGenerator().selectionChanged()
                  currentAssetID = item.id
                }
              }
            }
          }
          .padding(.horizontal, max(0, geometry.size.width / 2 - 30))
        }
        .frame(height: 40)
        .highPriorityGesture(
          DragGesture(minimumDistance: 4)
            .onChanged { value in
              guard !items.isEmpty else { return }
              let start = dragStartIndex ?? items.firstIndex(where: { $0.id == currentAssetID }) ?? 0
              if dragStartIndex == nil { dragStartIndex = start }
              let index = nativeFilmstripTargetIndex(start: start, translation: value.translation.width, count: items.count)
              if currentAssetID != items[index].id {
                UISelectionFeedbackGenerator().selectionChanged()
                currentAssetID = items[index].id
              }
            }
            .onEnded { _ in dragStartIndex = nil }
        )
        .padding(.horizontal, 8)
        .onChange(of: currentAssetID) { newID in
          if dragStartIndex != nil {
            proxy.scrollTo(newID, anchor: .center)
          } else {
            withAnimation(.easeOut(duration: 0.15)) {
              proxy.scrollTo(newID, anchor: .center)
            }
          }
        }
        .onAppear {
          proxy.scrollTo(currentAssetID, anchor: .center)
        }
      }
    }
    .frame(height: 36)
  }
}

private struct NativeAlertButtonStyle: ButtonStyle {
  let isDestructive: Bool
  let isCancel: Bool

  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .font(.system(size: 17, weight: isCancel ? .semibold : .regular))
      .foregroundColor(isDestructive ? Color(uiColor: .systemRed) : Color.accentColor)
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .background(configuration.isPressed ? Color(uiColor: .systemFill) : Color.clear)
      .contentShape(Rectangle())
  }
}

struct NativeUnifiedGalleryViewer: View {
  let client: NativeImmichClient
  let device: NativeDeviceLibrary
  @State private var items: [NativeGridItem]
  let initialItem: NativeGridItem
  var sourceFrame: CGRect? = nil
  var onDeleteItem: ((NativeGridItem, NativeDeleteTargetScope) -> Void)? = nil
  var onServerAssetUpdated: ((NativeAsset) -> Void)? = nil
  var onServerAssetArchived: ((String) -> Void)? = nil
  var onDismissViewer: (() -> Void)? = nil

  @Environment(\.dismiss) private var dismiss
  @State private var isLivePhotoEnabled = true
  @State private var isLivePhotoMuted = true
  @State private var currentAssetID: String
  @State private var showChrome = true
  @State private var dismissRequested = false
  @State private var isCurrentImageZoomed = false
  @State private var showInfoSheet = false
  @State private var isFavorite = false
  @State private var isProcessingFavorite = false
  @State private var isPreparingShare = false
  @State private var shareTask: Task<Void, Never>?
  @State private var sharePreparationID: UUID?
  @State private var viewerMessage: String?
  @State private var presentedController = NativeWeakControllerBox()
  @State private var shareItem: Any? = nil
  @State private var showBothDeleteDialog = false
  @State private var showLocalOnlyDeleteDialog = false
  @State private var showCloudTrashDialog = false
  @State private var dontRemindTrashSelected = false
  @State private var isDeletingItem = false
  @State private var deleteErrorMessage: String? = nil
  @AppStorage("immichz_share_include_gps") private var shareIncludeGPS = true
  @State private var isSavingToDevice = false
  @State private var showAlbumTargetDialog = false
  @State private var showLocalAlbumPicker = false
  @State private var showServerAlbumPicker = false

  private var isRemoteOnly: Bool {
    currentItem?.server != nil && currentItem?.local == nil
  }

  private var isBoth: Bool {
    currentItem?.server != nil && currentItem?.local != nil
  }

  private var isLocalOnly: Bool {
    currentItem?.local != nil && currentItem?.server == nil
  }

  private var dontRemindTrashKey: String {
    let identity = NativeSyncCacheStore.shared.identity ?? client.config.serverUrl
    return "immich_dont_remind_cloud_trash_\(identity)"
  }

  private var isSkipTrashReminderEnabled: Bool {
    UserDefaults.standard.bool(forKey: dontRemindTrashKey)
  }

  private func handleDeleteOrTrashTap() {
    guard currentItem != nil else { return }
    if isRemoteOnly {
      if isSkipTrashReminderEnabled {
        performDeleteItem(scope: .all)
      } else {
        dontRemindTrashSelected = false
        showCloudTrashDialog = true
      }
    } else if isBoth {
      showBothDeleteDialog = true
    } else {
      showLocalOnlyDeleteDialog = true
    }
  }

  init(
    client: NativeImmichClient,
    device: NativeDeviceLibrary,
    items: [NativeGridItem],
    initialItem: NativeGridItem,
    sourceFrame: CGRect? = nil,
    onDeleteItem: ((NativeGridItem, NativeDeleteTargetScope) -> Void)? = nil,
    onServerAssetUpdated: ((NativeAsset) -> Void)? = nil,
    onServerAssetArchived: ((String) -> Void)? = nil,
    onDismissViewer: (() -> Void)? = nil
  ) {
    self.client = client
    self.device = device
    _items = State(initialValue: items)
    self.initialItem = initialItem
    self.sourceFrame = sourceFrame
    self.onDeleteItem = onDeleteItem
    self.onServerAssetUpdated = onServerAssetUpdated
    self.onServerAssetArchived = onServerAssetArchived
    self.onDismissViewer = onDismissViewer
    _currentAssetID = State(initialValue: initialItem.id)
    _isFavorite = State(initialValue: initialItem.isFavorite)
  }

  private var currentIndex: Int {
    items.firstIndex(where: { $0.id == currentAssetID }) ?? 0
  }

  private var currentItem: NativeGridItem? {
    items.first(where: { $0.id == currentAssetID })
  }

  var body: some View {
    ZStack {
      NativeClearBackgroundView { controller in
        presentedController.value = controller
      }

      if items.isEmpty {
        Color.black.ignoresSafeArea()
        Text("当前照片已删除").foregroundColor(.white)
      } else {
        NativeViewerDismissSurface(
          pager: TabView(selection: $currentAssetID) {
            ForEach(items) { item in
              NativeSingleAssetPage(
                client: client,
                device: device,
                item: item,
                isActive: item.id == currentAssetID,
                isLivePhotoEnabled: isLivePhotoEnabled,
                isLivePhotoMuted: isLivePhotoMuted,
                showsControls: showChrome,
                onZoomChanged: { zoomed in
                  if item.id == currentAssetID { isCurrentImageZoomed = zoomed }
                },
                onTap: {
                  withAnimation(.easeInOut(duration: 0.25)) {
                    showChrome.toggle()
                  }
                }
              )
              .tag(item.id)
              .ignoresSafeArea()
            }
          }
          .tabViewStyle(.page(indexDisplayMode: .never))
          .nativeScrollDisabled(isCurrentImageZoomed)
          .ignoresSafeArea(),
          chrome: viewerChrome,
          showsChrome: showChrome,
          isZoomed: isCurrentImageZoomed,
          sourceFrame: currentAssetID == initialItem.id ? sourceFrame : nil,
          dismissRequested: $dismissRequested,
          onSwipeUp: {
            showInfoSheet = true
          },
          onDismiss: {
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) {
              if let onDismissViewer { onDismissViewer() }
              else { dismiss() }
            }
          }
        )
      }

      if showCloudTrashDialog {
        Color.black.opacity(0.4)
          .ignoresSafeArea()
          .contentShape(Rectangle())
          .onTapGesture {
            showCloudTrashDialog = false
          }

        VStack(spacing: 0) {
          VStack(spacing: 4) {
            Text("移入云端回收站")
              .font(.system(size: 17, weight: .semibold))
              .foregroundColor(.primary)
              .multilineTextAlignment(.center)
              .padding(.top, 20)
              .padding(.horizontal, 16)

            Text("确定将该照片移入云端回收站吗？稍后可在资料库回收站中查看或恢复。")
              .font(.system(size: 13, weight: .regular))
              .foregroundColor(Color(uiColor: .secondaryLabel))
              .multilineTextAlignment(.center)
              .lineSpacing(2)
              .padding(.top, 4)
              .padding(.horizontal, 16)

            Button {
              dontRemindTrashSelected.toggle()
            } label: {
              HStack(spacing: 6) {
                Image(systemName: dontRemindTrashSelected ? "checkmark.square.fill" : "square")
                  .font(.system(size: 15, weight: .medium))
                  .foregroundColor(dontRemindTrashSelected ? Color.accentColor : Color(uiColor: .tertiaryLabel))
                Text("不再提醒")
                  .font(.system(size: 13))
                  .foregroundColor(Color(uiColor: .secondaryLabel))
              }
              .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.top, 10)
            .padding(.bottom, 16)
          }

          Rectangle()
            .fill(Color(uiColor: .separator))
            .frame(height: 0.5)

          HStack(spacing: 0) {
            Button("取消") {
              showCloudTrashDialog = false
            }
            .buttonStyle(NativeAlertButtonStyle(isDestructive: false, isCancel: true))

            Rectangle()
              .fill(Color(uiColor: .separator))
              .frame(width: 0.5, height: 44)

            Button("放入回收站") {
              if dontRemindTrashSelected {
                UserDefaults.standard.set(true, forKey: dontRemindTrashKey)
              }
              showCloudTrashDialog = false
              performDeleteItem(scope: .all)
            }
            .buttonStyle(NativeAlertButtonStyle(isDestructive: true, isCancel: false))
          }
          .frame(height: 44)
        }
        .frame(width: 270)
        .background(
          RoundedRectangle(cornerRadius: 14, style: .continuous)
            .fill(.ultraThickMaterial)
        )
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .shadow(color: Color.black.opacity(0.18), radius: 24, y: 8)
        .transition(.scale(scale: 0.95).combined(with: .opacity))
        .zIndex(100)
      }
    }
    .animation(.easeInOut(duration: 0.2), value: showCloudTrashDialog)
    .onAppear {
      presentedController.value?.setNeedsStatusBarAppearanceUpdate()
    }
    .onChange(of: showChrome) { _ in
      presentedController.value?.setNeedsStatusBarAppearanceUpdate()
    }
    .confirmationDialog("删除照片", isPresented: $showBothDeleteDialog, titleVisibility: .visible) {
      Button("仅删除本地照片", role: .destructive) {
        performDeleteItem(scope: .localOnly)
      }
      Button("全部删除（本地和云端彻底删除）", role: .destructive) {
        performDeleteItem(scope: .all)
      }
      Button("取消", role: .cancel) {}
    } message: {
      Text("该照片在本地相册与云端均存在，请选择删除范围：")
    }
    .confirmationDialog("删除本地照片", isPresented: $showLocalOnlyDeleteDialog, titleVisibility: .visible) {
      Button("删除本地照片", role: .destructive) {
        performDeleteItem(scope: .localOnly)
      }
      Button("取消", role: .cancel) {}
    } message: {
      Text("该照片尚未同步到云端，删除后仅从本地设备相册中移除。")
    }
    .alert("删除失败", isPresented: Binding(get: { deleteErrorMessage != nil }, set: { if !$0 { deleteErrorMessage = nil } })) {
      Button("确定", role: .cancel) { deleteErrorMessage = nil }
    } message: {
      Text(deleteErrorMessage ?? "未知错误")
    }
    .onChange(of: currentAssetID) { newID in
      isCurrentImageZoomed = false
      isLivePhotoEnabled = true
      isLivePhotoMuted = true
      if let item = items.first(where: { $0.id == newID }) { isFavorite = item.isFavorite }
    }
    .onDisappear {
      sharePreparationID = nil
      shareTask?.cancel()
      shareTask = nil
      if let url = shareItem as? URL { try? FileManager.default.removeItem(at: url) }
      shareItem = nil
    }
    .alert("操作结果", isPresented: Binding(get: { viewerMessage != nil }, set: { if !$0 { viewerMessage = nil } })) {
      Button("好", role: .cancel) { viewerMessage = nil }
    } message: { Text(viewerMessage ?? "") }
    .sheet(isPresented: $showInfoSheet) {
      if let item = currentItem {
        NativeAssetInfoSheet(client: client, device: device, item: item)
          .modifier(NativeInfoSheetDetentsModifier())
      }
    }
    .sheet(item: Binding<NativeSharePayload?>(
      get: { shareItem.map { NativeSharePayload(content: $0) } },
      set: { if $0 == nil { shareItem = nil } }
    )) { payload in
      NativeActivityView(activityItems: payload.content)
    }
    .confirmationDialog("选择相册来源", isPresented: $showAlbumTargetDialog, titleVisibility: .visible) {
      if currentItem?.local != nil {
        Button("加入本机相册") { showLocalAlbumPicker = true }
      }
      if currentItem?.server != nil {
        Button("加入云端相册") { showServerAlbumPicker = true }
      }
      Button("取消", role: .cancel) {}
    } message: { Text("本机资产和云端资产分别操作，不会自动上传。") }
    .sheet(isPresented: $showLocalAlbumPicker) {
      NativePhotosLocalAlbumPicker(albums: device.albums) { albumID in
        Task { await addCurrentItemToLocalAlbum(albumID) }
      }
    }
    .sheet(isPresented: $showServerAlbumPicker) {
      NativePhotosServerAlbumPicker(client: client) { albumID in
        Task { await addCurrentItemToServerAlbum(albumID) }
      }
    }
    .statusBarHidden(!showChrome)
  }

  private var viewerChrome: some View {
    VStack {
      // Top Bar (参考 iOS 原生相册：左圆返回 + 中胶囊日期时间 + 右圆更多)
      HStack(alignment: .center, spacing: 12) {
        Button {
          dismissRequested = true
        } label: {
          Image(systemName: "chevron.left")
            .font(.system(size: 18, weight: .semibold))
            .foregroundColor(.primary)
            .frame(width: 44, height: 44)
            .background(.ultraThinMaterial)
            .clipShape(Circle())
            .shadow(color: Color.black.opacity(0.06), radius: 8, y: 2)
        }
        .accessibilityLabel("返回")

        if let item = currentItem, (item.local?.isLivePhoto == true || item.server?.livePhotoVideoId != nil) {
          Menu {
            Button {
              isLivePhotoEnabled.toggle()
            } label: {
              Label(isLivePhotoEnabled ? "关闭实况" : "开启实况", systemImage: isLivePhotoEnabled ? "livephoto.slash" : "livephoto")
            }
            Button {
              isLivePhotoMuted.toggle()
            } label: {
              Label(isLivePhotoMuted ? "开启声音" : "静音", systemImage: isLivePhotoMuted ? "speaker.wave.2" : "speaker.slash")
            }
          } label: {
            HStack(spacing: 4) {
              Image(systemName: "livephoto")
              Text("实况")
                .font(.caption2.weight(.semibold))
              Image(systemName: "chevron.down")
                .font(.system(size: 8, weight: .bold))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(.ultraThinMaterial)
            .clipShape(Capsule())
            .foregroundColor(.primary)
            .shadow(color: Color.black.opacity(0.06), radius: 8, y: 2)
          }
        }

        Spacer()

        if let item = currentItem {
          let dateInfo = NativeImmichClient.formatViewerTopDateTitle(item.date)
          Button {
            showInfoSheet = true
          } label: {
            VStack(spacing: 2) {
              Text(dateInfo.date)
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(.primary)
              Text(dateInfo.time)
                .font(.system(size: 11, weight: .regular))
                .foregroundColor(.secondary)
            }
            .padding(.horizontal, 20)
            .frame(height: 44)
            .background(.ultraThinMaterial)
            .clipShape(Capsule())
            .shadow(color: Color.black.opacity(0.06), radius: 8, y: 2)
          }
          .buttonStyle(.plain)
          .accessibilityLabel("\(dateInfo.date) \(dateInfo.time)")
        }

        Spacer()

        // 保持对称占位，使日期时间胶囊居中
        Color.clear
          .frame(width: 44, height: 44)
      }
      .padding(.horizontal, 16)
      .padding(.top, 4)

      Spacer()

      // Filmstrip Scrubber (无黑胶囊底框，通透悬浮)
      if items.count > 1 {
        NativeViewerFilmstrip(
          client: client,
          device: device,
          items: items,
          currentAssetID: $currentAssetID
        )
        .padding(.bottom, 8)
      }

      // Bottom Bar (所有操作按钮完整展开排布在磨砂胶囊中，均分排布，无“更多”折叠)
      HStack(spacing: 0) {
        // 分享 (直接调用，按设置自动决定是否保留 GPS)
        viewerBottomActionButton(
          systemName: "square.and.arrow.up",
          title: isPreparingShare ? "准备中" : "分享",
          disabled: isPreparingShare,
          showSpinner: isPreparingShare,
          action: { executeShare(removeGPS: !shareIncludeGPS) }
        )

        // 存到相册 (仅云端存在且本地无时)
        if currentItem?.server != nil && currentItem?.local == nil {
          viewerBottomActionButton(
            systemName: "arrow.down.to.line",
            title: isSavingToDevice ? "保存中" : "存到相册",
            disabled: isSavingToDevice,
            showSpinner: isSavingToDevice,
            action: { Task { await saveCurrentServerAssetToDevice() } }
          )
        }

        // 收藏
        viewerBottomActionButton(
          systemName: isFavorite ? "heart.fill" : "heart",
          title: isFavorite ? "已收藏" : "收藏",
          tintColor: isFavorite ? .red : .primary,
          disabled: isProcessingFavorite || currentItem == nil,
          action: toggleFavorite
        )

        // 详情
        viewerBottomActionButton(
          systemName: "info.circle",
          title: "详情",
          action: { showInfoSheet = true }
        )

        // 加入相册
        viewerBottomActionButton(
          systemName: "plus.rectangle.on.folder",
          title: "加入相册",
          disabled: currentItem == nil,
          action: { showAlbumTargetDialog = true }
        )

        // 归档 (仅云端存在时可操作)
        if currentItem?.server != nil {
          viewerBottomActionButton(
            systemName: "archivebox",
            title: "归档",
            disabled: isDeletingItem || currentItem?.server == nil,
            action: { Task { await archiveCurrentServerCopy() } }
          )
        }

        // 删除 / 回收站
        viewerBottomActionButton(
          systemName: "trash",
          title: isRemoteOnly ? "回收站" : "删除",
          disabled: isDeletingItem || currentItem == nil,
          action: handleDeleteOrTrashTap
        )
      }
      .padding(.horizontal, 6)
      .frame(height: 48)
      .background(.ultraThinMaterial)
      .clipShape(Capsule())
      .shadow(color: Color.black.opacity(0.06), radius: 8, y: 2)
      .padding(.horizontal, 16)
      .padding(.bottom, 6)
    }
    .padding(.horizontal, 4)
  }

  @ViewBuilder
  private func viewerBottomActionButton(
    systemName: String,
    title: String,
    tintColor: Color = .primary,
    disabled: Bool = false,
    showSpinner: Bool = false,
    action: @escaping () -> Void
  ) -> some View {
    Button(action: action) {
      Group {
        if showSpinner {
          ProgressView()
            .scaleEffect(0.8)
        } else {
          Image(systemName: systemName)
            .font(.system(size: 18, weight: .regular))
            .foregroundColor(tintColor)
        }
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .contentShape(Rectangle())
    }
    .disabled(disabled)
    .accessibilityLabel(title)
  }

  private func performDeleteItem(scope: NativeDeleteTargetScope, item requestedItem: NativeGridItem? = nil) {
    guard let item = requestedItem ?? currentItem, !isDeletingItem else { return }
    isDeletingItem = true
    UIImpactFeedbackGenerator(style: .heavy).impactOccurred()
    Task {
      do {
        try await nativeDeleteGridItems([item], scope: scope, client: client, device: device)
        if let local = item.local {
          NativeSyncCacheStore.shared.removeMatches(localIDs: Set([local.id]))
        }
        isDeletingItem = false
        onDeleteItem?(item, scope)
        removeCurrentViewerItem(deletingID: item.id)
      } catch {
        await MainActor.run {
          isDeletingItem = false
          deleteErrorMessage = "删除失败：\(error.localizedDescription)"
        }
      }
    }
  }

  private func removeCurrentViewerItem(deletingID: String? = nil) {
    let targetID = deletingID ?? currentAssetID
    guard let idx = items.firstIndex(where: { $0.id == targetID }) else {
      if items.isEmpty { dismiss() }
      return
    }
    let allIDs = items.map(\.id)
    let nextID = nativeViewerNextSelectionID(deletingID: targetID, orderedIDs: allIDs)
    items.remove(at: idx)
    if nativeShouldDismissViewerOnDeletion(itemsCountAfterDeletion: items.count) {
      dismiss()
      return
    }
    if let nextID, items.contains(where: { $0.id == nextID }) {
      currentAssetID = nextID
    } else if let first = items.first {
      currentAssetID = first.id
    }
    if let current = currentItem {
      isFavorite = current.isFavorite
    }
  }

  private func archiveCurrentServerCopy() async {
    guard let item = currentItem, let server = item.server else { return }
    do {
      try await client.updateVisibility(ids: [server.id], visibility: "archive")
      onServerAssetArchived?(server.id)
      if let local = item.local, let idx = items.firstIndex(where: { $0.id == item.id }) {
        let updated = NativeGridItem(server: nil, local: local)
        items[idx] = updated
        currentAssetID = updated.id
        isFavorite = updated.isFavorite
      } else {
        removeCurrentViewerItem(deletingID: item.id)
      }
      viewerMessage = "已归档云端副本；本机副本保留。"
    } catch { viewerMessage = "归档失败：\(error.localizedDescription)" }
  }

  private func toggleFavorite() {
    guard let item = currentItem, !isProcessingFavorite else { return }
    let newFav = !isFavorite
    isProcessingFavorite = true
    UIImpactFeedbackGenerator(style: .medium).impactOccurred()
    Task {
      var succeeded = 0
      var failed = 0
      var serverSucceeded = false
      var localSucceeded = false
      if let server = item.server {
        do { try await client.updateFavorite(id: server.id, isFavorite: newFav); succeeded += 1; serverSucceeded = true }
        catch { failed += 1 }
      }
      if let local = item.local {
        if await device.updateFavorite(ids: [local.id], isFavorite: newFav) { succeeded += 1; localSucceeded = true }
        else { failed += 1 }
      }
      // A paired asset can succeed on just one side. Never synthesize a
      // successful server favorite when its request actually failed.
      let serverUpdated = serverSucceeded && item.server != nil
      let localUpdated = localSucceeded && item.local != nil
      let updatedServer: NativeAsset? = item.server.map { server in
        guard serverUpdated else { return server }
        return NativeAsset(
          id: server.id, date: server.date, isImage: server.isImage, isFavorite: newFav,
          thumbhash: server.thumbhash, livePhotoVideoId: server.livePhotoVideoId,
          originalFileName: server.originalFileName, originalMimeType: server.originalMimeType,
          width: server.width, height: server.height, fileSizeInByte: server.fileSizeInByte,
          latitude: server.latitude, longitude: server.longitude, isArchived: server.isArchived
        )
      }
      let updatedLocal: NativeDeviceAsset? = item.local.map { local in
        guard localUpdated else { return local }
        return NativeDeviceAsset(
          id: local.id, date: local.date, isVideo: local.isVideo,
          isLivePhoto: local.isLivePhoto, contentVersion: local.contentVersion,
          isFavorite: newFav
        )
      }
      if serverUpdated, let updatedServer { onServerAssetUpdated?(updatedServer) }
      if let index = items.firstIndex(where: { $0.id == item.id }) {
        let updated = NativeGridItem(server: updatedServer, local: updatedLocal)
        items[index] = updated
        if updated.id == currentAssetID {
          isFavorite = updatedServer?.isFavorite == true || updatedLocal?.isFavorite == true
        }
      }
      isProcessingFavorite = false
      viewerMessage = "收藏更新：云端\(item.server == nil ? "无副本" : (serverSucceeded ? "成功" : "失败"))；本机\(item.local == nil ? "无副本" : (localSucceeded ? "成功" : "失败"))。成功 \(succeeded) 份，失败 \(failed) 份。"
    }
  }

  private func executeShare(removeGPS: Bool) {
    guard let item = currentItem, !isPreparingShare else { return }

    isPreparingShare = true
    let preparationID = UUID()
    sharePreparationID = preparationID
    UIImpactFeedbackGenerator(style: .light).impactOccurred()
    shareTask = Task {
      var preparedURL: URL?
      defer {
        if Task.isCancelled || sharePreparationID != preparationID {
          if let preparedURL { try? FileManager.default.removeItem(at: preparedURL) }
        }
        if sharePreparationID == preparationID {
          sharePreparationID = nil
          isPreparingShare = false
          shareTask = nil
        }
      }
      do {
        var fileURL: URL
        if let local = item.local {
          guard let source = PHAsset.fetchAssets(withLocalIdentifiers: [local.id], options: nil).firstObject else {
            throw NativeShareError.originalUnavailable
          }
          fileURL = try await nativeOriginalFile(for: source)
        } else if let server = item.server {
          fileURL = try await client.originalFile(for: server)
        } else {
          throw NativeShareError.originalUnavailable
        }

        if removeGPS {
          fileURL = (try? nativeStripGPSFromImageFile(at: fileURL)) ?? fileURL
        }

        preparedURL = fileURL
        guard !Task.isCancelled, sharePreparationID == preparationID else { return }
        shareItem = fileURL
      } catch {
        guard !Task.isCancelled, sharePreparationID == preparationID else { return }
        viewerMessage = "原件暂不可分享。请检查网络、照片权限或 iCloud 原件状态后重试。\n\(error.localizedDescription)"
      }
    }
  }

  private func saveCurrentServerAssetToDevice() async {
    guard let item = currentItem, let server = item.server, !isSavingToDevice else { return }
    if !device.authorized {
      await device.requestAccess()
      guard device.authorized else {
        viewerMessage = "未获得系统照片写入权限，请在系统设置中允许访问。"
        return
      }
    }

    isSavingToDevice = true
    UIImpactFeedbackGenerator(style: .light).impactOccurred()
    defer { isSavingToDevice = false }

    do {
      let fileURL = try await client.originalFile(for: server)
      let saveRes = await device.saveFilesToPhotos([fileURL])
      try? FileManager.default.removeItem(at: fileURL)

      if saveRes.saved > 0 {
        viewerMessage = "原图已成功保存到系统照片！"
        // Refresh device and update match in cache
        device.refresh()
      } else {
        viewerMessage = "保存到系统照片失败，请检查手机存储空间。"
      }
    } catch {
      viewerMessage = "下载原件失败：\(error.localizedDescription)"
    }
  }

  private func addCurrentItemToServerAlbum(_ albumID: String) async {
    guard let server = currentItem?.server else {
      viewerMessage = "当前照片无云端副本，无法加入云端相册。"
      return
    }
    do {
      _ = try await client.addAssetsToAlbum(ids: [server.id], albumID: albumID)
      viewerMessage = "已加入云端相册！"
    } catch {
      viewerMessage = "加入云端相册失败：\(error.localizedDescription)"
    }
  }

  private func addCurrentItemToLocalAlbum(_ albumID: String) async {
    guard let local = currentItem?.local else {
      viewerMessage = "当前照片无本机副本，无法加入本机相册。"
      return
    }
    if await device.addAssets([local.id], toAlbum: albumID) {
      viewerMessage = "已加入本机相册！"
    } else {
      viewerMessage = "加入本机相册失败；请检查照片权限。"
    }
  }
}

private enum NativeShareError: LocalizedError {
  case originalUnavailable
  var errorDescription: String? { "无法读取原件。" }
}

@MainActor
private func nativeOriginalFile(for asset: PHAsset) async throws -> URL {
  guard let resource = asset.getResource() else { throw NativeShareError.originalUnavailable }
  let ext = URL(fileURLWithPath: resource.originalFilename).pathExtension
  let fileName = ext.isEmpty ? UUID().uuidString : "\(UUID().uuidString).\(ext)"
  let target = FileManager.default.temporaryDirectory.appendingPathComponent(fileName)
  let options = PHAssetResourceRequestOptions()
  options.isNetworkAccessAllowed = true
  do {
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
      PHAssetResourceManager.default().writeData(for: resource, toFile: target, options: options) { error in
        if let error { continuation.resume(throwing: error) }
        else { continuation.resume(returning: ()) }
      }
    }
  } catch {
    try? FileManager.default.removeItem(at: target)
    throw error
  }
  return target
}

struct NativeSharePayload: Identifiable {
  let id = UUID()
  let content: [Any]

  init(content: Any) {
    if let array = content as? [Any] {
      self.content = array
    } else {
      self.content = [content]
    }
  }

  init(contents: [Any]) {
    self.content = contents
  }
}

struct NativeActivityView: UIViewControllerRepresentable {
  let activityItems: [Any]

  func makeUIViewController(context: Context) -> UIActivityViewController {
    let controller = UIActivityViewController(activityItems: activityItems, applicationActivities: nil)
    let temporaryURLs = activityItems.compactMap { $0 as? URL }.filter { $0.path.hasPrefix(FileManager.default.temporaryDirectory.path) }
    controller.completionWithItemsHandler = { _, _, _, _ in
      temporaryURLs.forEach { try? FileManager.default.removeItem(at: $0) }
    }
    return controller
  }

  func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

struct NativeBatchShareResult {
  let files: [Any]
  let failed: Int
}

/// Helper function to strip GPS coordinates from an image file (JPEG/HEIC/PNG)
/// Creates a sanitized copy in temporaryDirectory without GPS metadata
enum NativeShareFormatMode {
  case original
  case compatible
  case cloudLink
}

func nativeCompatibleCopy(for sourceURL: URL, removeGPS: Bool) throws -> URL {
  guard let source = CGImageSourceCreateWithURL(sourceURL as CFURL, nil) else {
    return sourceURL
  }
  let destinationURL = FileManager.default.temporaryDirectory
    .appendingPathComponent("\(UUID().uuidString)_compat.\(removeGPS ? "nogps.jpg" : "jpg")")
  guard let destination = CGImageDestinationCreateWithURL(destinationURL as CFURL, "public.jpeg" as CFString, 1, nil) else {
    return sourceURL
  }
  let count = CGImageSourceGetCount(source)
  if count > 0 {
    if let metadata = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] {
      var sanitized = metadata
      if removeGPS {
        sanitized.removeValue(forKey: kCGImagePropertyGPSDictionary)
      }
      CGImageDestinationAddImageFromSource(destination, source, 0, sanitized as CFDictionary)
    } else {
      CGImageDestinationAddImageFromSource(destination, source, 0, nil)
    }
  }
  if CGImageDestinationFinalize(destination) {
    return destinationURL
  } else {
    try? FileManager.default.removeItem(at: destinationURL)
    return sourceURL
  }
}

func nativeStripGPSFromImageFile(at sourceURL: URL) throws -> URL {
  guard let source = CGImageSourceCreateWithURL(sourceURL as CFURL, nil) else {
    return sourceURL
  }
  guard let uti = CGImageSourceGetType(source) else {
    return sourceURL
  }

  let ext = sourceURL.pathExtension
  let sanitizedFilename = "\(UUID().uuidString)_nogps.\(ext)"
  let destinationURL = FileManager.default.temporaryDirectory.appendingPathComponent(sanitizedFilename)

  guard let destination = CGImageDestinationCreateWithURL(destinationURL as CFURL, uti, 1, nil) else {
    return sourceURL
  }

  // Read metadata dict
  let count = CGImageSourceGetCount(source)
  if count > 0 {
    if let metadata = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] {
      var sanitized = metadata
      // Remove GPS Dictionary
      sanitized.removeValue(forKey: kCGImagePropertyGPSDictionary)
      CGImageDestinationAddImageFromSource(destination, source, 0, sanitized as CFDictionary)
    } else {
      CGImageDestinationAddImageFromSource(destination, source, 0, nil)
    }
  }

  if CGImageDestinationFinalize(destination) {
    return destinationURL
  } else {
    try? FileManager.default.removeItem(at: destinationURL)
    return sourceURL
  }
}

@MainActor
func nativePrepareBatchShare(items: [NativeGridItem], client: NativeImmichClient) async -> NativeBatchShareResult {
  var results: [Any] = []
  var failed = 0
  for item in items {
    do {
      if let local = item.local,
         let asset = PHAsset.fetchAssets(withLocalIdentifiers: [local.id], options: nil).firstObject {
        results.append(try await nativeOriginalFile(for: asset))
      } else if let server = item.server {
        results.append(try await client.originalFile(for: server))
      } else {
        failed += 1
      }
    } catch {
      failed += 1
    }
  }
  return NativeBatchShareResult(files: results, failed: failed)
}

private final class NativeVideoPlayerView: UIView {
  override static var layerClass: AnyClass { AVPlayerLayer.self }
  var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
}

private struct NativeVideoSurface: UIViewRepresentable {
  let player: AVPlayer

  func makeUIView(context: Context) -> NativeVideoPlayerView {
    let view = NativeVideoPlayerView()
    view.backgroundColor = .clear
    view.playerLayer.videoGravity = .resizeAspect
    return view
  }

  func updateUIView(_ view: NativeVideoPlayerView, context: Context) {
    view.playerLayer.player = player
  }
}

private struct NativeSingleAssetPage: View {
  let client: NativeImmichClient
  let device: NativeDeviceLibrary
  let item: NativeGridItem
  let isActive: Bool
  let isLivePhotoEnabled: Bool
  let isLivePhotoMuted: Bool
  var showsControls: Bool = true
  let onZoomChanged: (Bool) -> Void
  let onTap: () -> Void

  @State private var image: UIImage?
  @State private var isLoading = true
  @State private var loadError: String?
  @State private var player: AVPlayer?
  @State private var livePhoto: PHLivePhoto?
  @State private var livePlayer: AVPlayer?
  @State private var isLivePlaying = false
  @State private var liveResourceMissing = false

  // 视频播放与进度控制
  @State private var isVideoPlaying = false
  @State private var videoCurrentTime: Double = 0
  @State private var videoDuration: Double = 0
  @State private var isScrubbing = false
  @State private var resumeAfterScrub = false
  @State private var isVideoMuted = false
  @State private var timeObserverToken: Any?

  private var isLive: Bool {
    item.local?.isLivePhoto == true || item.server?.livePhotoVideoId != nil
  }

  var body: some View {
    GeometryReader { proxy in
      let topPadding: CGFloat = showsControls ? 88 : 0
      let bottomPadding: CGFloat = showsControls ? 120 : 0
      let effectiveHeight = max(100, proxy.size.height - topPadding - bottomPadding)
      let contentSize = CGSize(width: proxy.size.width, height: effectiveHeight)

      ZStack {
        (showsControls ? Color(uiColor: .systemBackground) : Color.black)
          .ignoresSafeArea()
          .contentShape(Rectangle())
          .onTapGesture(perform: onTap)

        Group {
          if item.isVideo {
            if let player {
              ZStack(alignment: .bottom) {
                NativeVideoSurface(player: player)
                  .frame(width: contentSize.width, height: contentSize.height)
                  .contentShape(Rectangle())
                  .onTapGesture(perform: onTap)
                  .onAppear {
                    setupVideoObserver(for: player)
                    if isActive {
                      player.play()
                      isVideoPlaying = true
                    }
                  }
                  .onDisappear {
                    player.pause()
                    isVideoPlaying = false
                    removeVideoObserver()
                  }

                // Spec §3.4: paused videos show a visible play affordance over
                // the first frame instead of auto-playing.
                if !isVideoPlaying, !isLoading {
                  Button {
                    if videoCurrentTime >= videoDuration && videoDuration > 0 {
                      player.seek(to: .zero)
                    }
                    player.play()
                    isVideoPlaying = true
                  } label: {
                    Image(systemName: "play.fill")
                      .font(.system(size: 34, weight: .bold))
                      .foregroundColor(.white.opacity(0.95))
                      .frame(width: 76, height: 76)
                      .background(.ultraThinMaterial, in: Circle())
                      .shadow(radius: 8)
                  }
                  .accessibilityLabel("播放视频")
                  .contentShape(Circle())
                }

                if showsControls {
                  videoControlsOverlay
                }
              }
            } else {
              VStack(spacing: 12) {
                if isLoading { ProgressView().tint(.primary) }
                else {
                  Text(loadError ?? "视频暂不可用").font(.caption).foregroundColor(.secondary).multilineTextAlignment(.center)
                  Button("重试") { Task { await loadAssetContent() } }.buttonStyle(.bordered)
                }
              }
            }
          } else {
            if isLivePlaying && isActive && isLivePhotoEnabled, let livePlayer, livePhoto == nil {
              VideoPlayer(player: livePlayer)
                .frame(width: contentSize.width, height: contentSize.height)
                .allowsHitTesting(false)
            } else if let livePhoto {
              NativeZoomableLivePhotoView(
                livePhoto: livePhoto,
                isPlaying: isLivePlaying && isActive && isLivePhotoEnabled,
                isEnabled: isLivePhotoEnabled,
                isMuted: isLivePhotoMuted,
                isActive: isActive,
                size: contentSize,
                onTap: onTap,
                onZoomChanged: onZoomChanged
              )
              .frame(width: contentSize.width, height: contentSize.height)
            } else if let image {
              NativeZoomableImageView(
                image: image,
                isActive: isActive,
                size: contentSize,
                onTap: onTap,
                onZoomChanged: onZoomChanged
              )
              .frame(width: contentSize.width, height: contentSize.height)
            } else {
              VStack(spacing: 10) {
                if isLoading { ProgressView().tint(.primary) }
                else {
                  Image(systemName: "photo").font(.system(size: 42)).foregroundColor(.secondary.opacity(0.5))
                  Text(loadError ?? "无法加载原件").font(.caption).foregroundColor(.secondary).multilineTextAlignment(.center)
                  Button("重试") { Task { await loadAssetContent() } }.buttonStyle(.bordered)
                }
              }
              .padding()
            }
          }
        }
        .padding(.top, topPadding)
        .padding(.bottom, bottomPadding)
        .animation(.easeInOut(duration: 0.25), value: showsControls)

        if liveResourceMissing && isLive {
          VStack {
            HStack(spacing: 6) {
              Image(systemName: "exclamationmark.triangle.fill")
              Text("实况动态资源暂不可用或缺失")
                .font(.caption.weight(.medium))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(Color.black.opacity(0.75))
            .foregroundColor(.white)
            .clipShape(Capsule())
            .padding(.top, 64)
            Spacer()
          }
          .allowsHitTesting(false)
        }
      }
      .onLongPressGesture(minimumDuration: 0.35, maximumDistance: 15, pressing: { pressing in
        if !pressing { stopLivePlayback() }
      }, perform: {
        startLivePlayback()
      })
    }
    .ignoresSafeArea()
    .onChange(of: isActive) { active in
      if !active {
        player?.pause()
        isVideoPlaying = false
        stopLivePlayback()
      } else if item.isVideo, let player {
        player.play()
        isVideoPlaying = true
      }
    }
    .onChange(of: isLivePhotoEnabled) { enabled in
      if !enabled { stopLivePlayback() }
    }
    .onChange(of: isLivePhotoMuted) { muted in livePlayer?.isMuted = muted }
    .task(id: "\(item.local?.id ?? "remote"):\(item.server?.id ?? "none")") {
      image = nil
      livePhoto = nil
      liveResourceMissing = false
      removeVideoObserver()
      player?.pause()
      player = nil
      livePlayer = nil
      isVideoPlaying = false
      await loadAssetContent()
      if isActive && item.isVideo, let player {
        player.play()
        isVideoPlaying = true
      }
    }
    .onDisappear {
      removeVideoObserver()
      player?.pause()
      player = nil
      stopLivePlayback()
      livePlayer = nil
    }
  }

  private func setupVideoObserver(for avPlayer: AVPlayer) {
    removeVideoObserver()
    avPlayer.isMuted = isVideoMuted
    let interval = CMTime(seconds: 0.1, preferredTimescale: 600)
    timeObserverToken = avPlayer.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak avPlayer] time in
      guard !isScrubbing else { return }
      if time.seconds.isFinite { videoCurrentTime = time.seconds }
      if let item = avPlayer?.currentItem, item.duration.isValid,
         !item.duration.isIndefinite, item.duration.seconds.isFinite {
        videoDuration = item.duration.seconds
      }
      isVideoPlaying = (avPlayer?.timeControlStatus == .playing)
    }
  }

  private func removeVideoObserver() {
    if let timeObserverToken, let player {
      player.removeTimeObserver(timeObserverToken)
    }
    timeObserverToken = nil
  }

  @ViewBuilder
  private var videoControlsOverlay: some View {
    VStack(spacing: 0) {
      Spacer()

      HStack(spacing: 10) {
        Button {
          guard let player else { return }
          if isVideoPlaying {
            player.pause()
            isVideoPlaying = false
          } else {
            if videoCurrentTime >= videoDuration && videoDuration > 0 {
              player.seek(to: .zero)
            }
            player.play()
            isVideoPlaying = true
          }
        } label: {
          Image(systemName: isVideoPlaying ? "pause.fill" : "play.fill")
            .font(.system(size: 15, weight: .bold))
            .foregroundColor(.white)
            .frame(width: 28, height: 28)
        }
        .buttonStyle(.plain)

        Text(formatTime(videoCurrentTime))
          .font(.system(size: 11, weight: .medium, design: .monospaced))
          .foregroundColor(.white.opacity(0.9))

        Slider(
          value: Binding(
            get: { videoCurrentTime },
            set: { newValue in
              videoCurrentTime = newValue
              player?.seek(to: CMTime(seconds: newValue, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
            }
          ),
          in: 0...max(videoDuration, 0.1),
          onEditingChanged: { editing in
            if editing {
              resumeAfterScrub = isVideoPlaying
              isScrubbing = true
              player?.pause()
            } else {
              isScrubbing = false
              if resumeAfterScrub && isActive {
                player?.play()
              }
              resumeAfterScrub = false
            }
          }
        )
        .tint(.white)

        Text(formatTime(videoDuration))
          .font(.system(size: 11, weight: .medium, design: .monospaced))
          .foregroundColor(.white.opacity(0.9))

        Button {
          guard let player else { return }
          isVideoMuted.toggle()
          player.isMuted = isVideoMuted
        } label: {
          Image(systemName: isVideoMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
            .font(.system(size: 13, weight: .medium))
            .foregroundColor(.white)
            .frame(width: 24, height: 24)
        }
        .buttonStyle(.plain)
      }
      .padding(.horizontal, 14)
      .padding(.vertical, 6)
      .background(Color.black.opacity(0.65))
      .clipShape(Capsule())
      .padding(.horizontal, 16)
      .padding(.bottom, 160)
    }
    .allowsHitTesting(true)
  }

  private func formatTime(_ seconds: Double) -> String {
    guard seconds.isFinite && !seconds.isNaN else { return "0:00" }
    let totalSeconds = Int(seconds)
    let mins = totalSeconds / 60
    let secs = totalSeconds % 60
    return String(format: "%d:%02d", mins, secs)
  }

  private func startLivePlayback() {
    guard isActive, isLivePhotoEnabled, isLive, !item.isVideo else { return }
    if livePhoto == nil && livePlayer == nil {
      liveResourceMissing = true
      UINotificationFeedbackGenerator().notificationOccurred(.warning)
      return
    }
    isLivePlaying = true
    livePlayer?.isMuted = isLivePhotoMuted
    livePlayer?.seek(to: .zero)
    livePlayer?.play()
  }

  private func stopLivePlayback() {
    isLivePlaying = false
    livePlayer?.pause()
  }

  private func loadAssetContent() async {
    isLoading = true
    loadError = nil
    defer { isLoading = false }

    if item.isVideo {
      if let local = item.local {
        guard let phAsset = PHAsset.fetchAssets(withLocalIdentifiers: [local.id], options: nil).firstObject else {
          loadError = "照片权限不足或本机视频已不存在。"
          return
        }
        let options = PHVideoRequestOptions()
        options.isNetworkAccessAllowed = true
        options.deliveryMode = .highQualityFormat
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
          PHImageManager.default().requestPlayerItem(forVideo: phAsset, options: options) { playerItem, info in
            Task { @MainActor in
              if let playerItem {
                let avPlayer = AVPlayer(playerItem: playerItem)
                avPlayer.actionAtItemEnd = .pause
                player = avPlayer
              } else {
                loadError = Self.photoKitErrorMessage(info)
              }
              continuation.resume()
            }
          }
        }
      } else if let server = item.server {
        let base = client.config.apiEndpoint ?? (NativeImmichClient.normalize(client.config.serverUrl) + "/api")
        if let videoURL = URL(string: base + "/assets/\(server.id)/video/playback") {
          var req = URLRequest(url: videoURL)
          if let token = client.config.accessToken {
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
          }
          if let key = client.config.apiKey {
            req.setValue(key, forHTTPHeaderField: "x-api-key")
          }
          let asset = AVURLAsset(url: videoURL, options: ["AVURLAssetHTTPHeaderFieldsKey": req.allHTTPHeaderFields ?? [:]])
          let item = AVPlayerItem(asset: asset)
          let avPlayer = AVPlayer(playerItem: item)
          avPlayer.actionAtItemEnd = .pause
          player = avPlayer
        } else { loadError = "服务器视频播放地址无效" }
      } else { loadError = "视频资产来源不可用" }
      if player == nil { loadError = "视频暂不可用；请检查网络或访问权限后重试。" }
      return
    }

    // Load Image
    if let local = item.local {
      guard let source = PHAsset.fetchAssets(withLocalIdentifiers: [local.id], options: nil).firstObject else {
        loadError = "照片权限不足或本机原件已不存在。"
        return
      }
      let options = PHImageRequestOptions()
      options.isNetworkAccessAllowed = true
      options.deliveryMode = .highQualityFormat
      await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
        PHImageManager.default().requestImage(for: source, targetSize: PHImageManagerMaximumSize, contentMode: .aspectFit, options: options) { result, info in
          guard info?[PHImageResultIsDegradedKey] as? Bool != true else { return }
          Task { @MainActor in
            if let result { image = result }
            else { loadError = Self.photoKitErrorMessage(info) }
            continuation.resume()
          }
        }
      }
      if local.isLivePhoto {
        let liveOptions = PHLivePhotoRequestOptions()
        liveOptions.isNetworkAccessAllowed = true
        PHImageManager.default().requestLivePhoto(for: source, targetSize: PHImageManagerMaximumSize, contentMode: .aspectFit, options: liveOptions) { result, info in
          guard info?[PHImageResultIsDegradedKey] as? Bool != true else { return }
          DispatchQueue.main.async {
            livePhoto = result
            if result == nil { liveResourceMissing = true }
          }
        }
      }
    } else if let server = item.server {
      if let videoID = server.livePhotoVideoId {
        let base = client.config.apiEndpoint ?? (NativeImmichClient.normalize(client.config.serverUrl) + "/api")
        if let url = URL(string: base + "/assets/\(videoID)/video/playback") {
          var request = URLRequest(url: url)
          if let token = client.config.accessToken {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
          }
          if let key = client.config.apiKey {
            request.setValue(key, forHTTPHeaderField: "x-api-key")
          }
          let videoAsset = AVURLAsset(url: url, options: ["AVURLAssetHTTPHeaderFieldsKey": request.allHTTPHeaderFields ?? [:]])
          livePlayer = AVPlayer(playerItem: AVPlayerItem(asset: videoAsset))
        } else {
          liveResourceMissing = true
        }
      }
      if let url = client.originalURL(for: server) {
        do {
          let data = try await client.imageData(for: url)
          if let decoded = UIImage(data: data) { image = decoded }
          else { loadError = "服务器返回的原件格式无法显示" }
        } catch {
          loadError = Self.networkErrorMessage(error)
        }
      } else { loadError = "云端原件地址无效" }
    }
  }

  private static func photoKitErrorMessage(_ info: [AnyHashable: Any]?) -> String {
    if info?[PHImageCancelledKey] as? Bool == true { return "加载已取消" }
    if info?[PHImageResultIsInCloudKey] as? Bool == true { return "iCloud 原件尚未下载；请检查网络后重试" }
    if let error = info?[PHImageErrorKey] as? Error { return "照片权限或原件读取失败：\(error.localizedDescription)" }
    return "本机原件暂不可用；检查照片权限或 iCloud 状态后重试"
  }

  private static func networkErrorMessage(_ error: Error) -> String {
    if let urlError = error as? URLError, urlError.code == .notConnectedToInternet || urlError.code == .networkConnectionLost {
      return "当前离线；云端原件无法加载"
    }
    return "云端原件加载失败：\(error.localizedDescription)"
  }
}

// MARK: - Native Centering Scroll View for Single Assets

final class NativeCenteringScrollView: UIScrollView {
  var contentTag: Int = 100
  var assetSize: CGSize = .zero
  private var lastBoundsSize: CGSize = .zero

  override func layoutSubviews() {
    super.layoutSubviews()
    updateContentSizeAndFrameIfNeeded()
    centerContent()
  }

  func updateContentSizeAndFrameIfNeeded() {
    guard assetSize.width > 0, assetSize.height > 0 else { return }
    let boundsSize = bounds.size
    guard boundsSize.width > 0, boundsSize.height > 0 else { return }
    guard let contentView = viewWithTag(contentTag) else { return }

    if boundsSize != lastBoundsSize && zoomScale <= minimumZoomScale + 0.01 {
      lastBoundsSize = boundsSize
      let fitted = nativeAspectFitImageSize(imageSize: assetSize, viewportSize: boundsSize)
      if fitted != .zero {
        setZoomScale(minimumZoomScale, animated: false)
        contentView.bounds = CGRect(origin: .zero, size: fitted)
        contentSize = fitted
      }
    }
  }

  func centerContent() {
    guard let contentView = viewWithTag(contentTag) else { return }
    let boundsSize = bounds.size
    guard boundsSize.width > 0, boundsSize.height > 0 else { return }

    let offsetX = max((boundsSize.width - contentSize.width) * 0.5, 0)
    let offsetY = max((boundsSize.height - contentSize.height) * 0.5, 0)
    contentView.center = CGPoint(
      x: contentSize.width * 0.5 + offsetX,
      y: contentSize.height * 0.5 + offsetY
    )
  }
}

enum NativeViewerGestureAction: Equatable {
  case none
  case dismiss
  case showDetails
}

func nativeClassifyViewerVerticalSwipe(
  translation: CGSize,
  predictedEnd: CGSize
) -> NativeViewerGestureAction {
  let isVertical = abs(translation.height) > abs(translation.width) * 1.25
  guard isVertical else { return .none }
  if translation.height < -20 || (translation.height < -15 && predictedEnd.height < -80) {
    return .showDetails
  }
  if translation.height > 120 || (translation.height > 40 && predictedEnd.height > 300) {
    return .dismiss
  }
  return .none
}

func nativeViewerZoomRect(
  for location: CGPoint,
  in viewSize: CGSize,
  viewportSize: CGSize,
  targetScale: CGFloat = 3.0
) -> CGRect {
  guard viewSize.width > 0, viewSize.height > 0,
        viewportSize.width > 0, viewportSize.height > 0,
        targetScale > 0 else { return .zero }
  let zoomWidth = viewportSize.width / targetScale
  let zoomHeight = viewportSize.height / targetScale
  let clampedX = max(0, min(viewSize.width, location.x))
  let clampedY = max(0, min(viewSize.height, location.y))
  return CGRect(
    x: clampedX - zoomWidth / 2,
    y: clampedY - zoomHeight / 2,
    width: zoomWidth,
    height: zoomHeight
  )
}

// Fit the full image inside the viewer; this is the minimum zoom size.
func nativeAspectFitImageSize(imageSize: CGSize, viewportSize: CGSize) -> CGSize {
  guard imageSize.width > 0, imageSize.height > 0,
        viewportSize.width > 0, viewportSize.height > 0 else { return .zero }
  let widthRatio = viewportSize.width / imageSize.width
  let heightRatio = viewportSize.height / imageSize.height
  let scale = min(widthRatio, heightRatio)
  return CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
}

// PhotoKit owns the local Live Photo playback and zooming.
private struct NativeZoomableLivePhotoView: UIViewRepresentable {
  let livePhoto: PHLivePhoto
  let isPlaying: Bool
  let isEnabled: Bool
  let isMuted: Bool
  let isActive: Bool
  let size: CGSize
  let onTap: () -> Void
  let onZoomChanged: (Bool) -> Void

  func makeUIView(context: Context) -> NativeCenteringScrollView {
    let scrollView = NativeCenteringScrollView()
    scrollView.contentTag = 101
    scrollView.assetSize = livePhoto.size
    scrollView.delegate = context.coordinator
    scrollView.maximumZoomScale = 5.0
    scrollView.minimumZoomScale = 1.0
    scrollView.bouncesZoom = true
    scrollView.isScrollEnabled = false
    scrollView.showsVerticalScrollIndicator = false
    scrollView.showsHorizontalScrollIndicator = false
    scrollView.contentInsetAdjustmentBehavior = .never
    scrollView.automaticallyAdjustsScrollIndicatorInsets = false
    scrollView.backgroundColor = .clear

    let photoView = PHLivePhotoView()
    photoView.contentMode = .scaleAspectFit
    photoView.isMuted = isMuted
    photoView.isUserInteractionEnabled = isEnabled
    photoView.tag = 101
    scrollView.addSubview(photoView)

    let tapGesture = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleTap))
    tapGesture.numberOfTapsRequired = 1
    tapGesture.cancelsTouchesInView = false
    tapGesture.delegate = context.coordinator
    scrollView.addGestureRecognizer(tapGesture)

    let doubleTapGesture = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleDoubleTap(_:)))
    doubleTapGesture.numberOfTapsRequired = 2
    scrollView.addGestureRecognizer(doubleTapGesture)
    tapGesture.require(toFail: doubleTapGesture)

    return scrollView
  }

  func updateUIView(_ uiView: NativeCenteringScrollView, context: Context) {
    context.coordinator.onTap = onTap
    context.coordinator.onZoomChanged = onZoomChanged
    if !isActive && uiView.zoomScale > uiView.minimumZoomScale + 0.01 {
      uiView.setZoomScale(uiView.minimumZoomScale, animated: false)
      uiView.isScrollEnabled = false
    }
    uiView.contentTag = 101
    uiView.assetSize = livePhoto.size
    guard let photoView = uiView.viewWithTag(101) as? PHLivePhotoView else { return }
    if photoView.livePhoto !== livePhoto { photoView.livePhoto = livePhoto }
    photoView.isMuted = isMuted
    photoView.isUserInteractionEnabled = isEnabled
    if isPlaying && !context.coordinator.wasPlaying {
      photoView.startPlayback(with: .full)
    } else if !isPlaying && context.coordinator.wasPlaying {
      photoView.stopPlayback()
    }
    context.coordinator.wasPlaying = isPlaying

    let viewportSize = uiView.bounds.size == .zero ? size : uiView.bounds.size
    let fittedSize = nativeAspectFitImageSize(imageSize: livePhoto.size, viewportSize: viewportSize)
    if fittedSize != .zero && photoView.bounds.size != fittedSize {
      uiView.setZoomScale(uiView.minimumZoomScale, animated: false)
      photoView.bounds = CGRect(origin: .zero, size: fittedSize)
      uiView.contentSize = fittedSize
      uiView.isScrollEnabled = false
      onZoomChanged(false)
    }
    uiView.centerContent()
  }

  func makeCoordinator() -> Coordinator {
    Coordinator(onTap: onTap, onZoomChanged: onZoomChanged)
  }

  class Coordinator: NSObject, UIScrollViewDelegate, UIGestureRecognizerDelegate {
    var onTap: () -> Void
    var onZoomChanged: (Bool) -> Void
    var wasPlaying = false
    private var pendingSingleTapWorkItem: DispatchWorkItem?

    init(onTap: @escaping () -> Void, onZoomChanged: @escaping (Bool) -> Void) {
      self.onTap = onTap
      self.onZoomChanged = onZoomChanged
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
      if gestureRecognizer is UITapGestureRecognizer, otherGestureRecognizer is UITapGestureRecognizer {
        return false
      }
      return true
    }

    func viewForZooming(in scrollView: UIScrollView) -> UIView? {
      scrollView.viewWithTag(101)
    }

    func scrollViewDidZoom(_ scrollView: UIScrollView) {
      (scrollView as? NativeCenteringScrollView)?.centerContent()
      let zoomed = scrollView.zoomScale > scrollView.minimumZoomScale + 0.01
      scrollView.isScrollEnabled = zoomed
      onZoomChanged(zoomed)
    }

    func scrollViewDidEndZooming(_ scrollView: UIScrollView, with view: UIView?, atScale scale: CGFloat) {
      (scrollView as? NativeCenteringScrollView)?.centerContent()
      let zoomed = scale > scrollView.minimumZoomScale + 0.01
      scrollView.isScrollEnabled = zoomed
      onZoomChanged(zoomed)
    }

    @objc func handleTap() {
      pendingSingleTapWorkItem?.cancel()
      let workItem = DispatchWorkItem { [weak self] in
        self?.onTap()
      }
      pendingSingleTapWorkItem = workItem
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: workItem)
    }

    @objc func handleDoubleTap(_ gesture: UITapGestureRecognizer) {
      pendingSingleTapWorkItem?.cancel()
      pendingSingleTapWorkItem = nil
      guard let scrollView = gesture.view as? UIScrollView else { return }
      if scrollView.zoomScale > scrollView.minimumZoomScale + 0.01 {
        scrollView.setZoomScale(scrollView.minimumZoomScale, animated: true)
        scrollView.isScrollEnabled = false
        onZoomChanged(false)
      } else if let view = scrollView.viewWithTag(101) {
        let location = gesture.location(in: view)
        let rect = nativeViewerZoomRect(for: location, in: view.bounds.size, viewportSize: scrollView.bounds.size, targetScale: min(3.0, scrollView.maximumZoomScale))
        if rect != .zero {
          scrollView.zoom(to: rect, animated: true)
          scrollView.isScrollEnabled = true
          onZoomChanged(true)
        }
      }
    }
  }
}

// Pinch to zoom and double tap zoomable container
private struct NativeZoomableImageView: UIViewRepresentable {
  let image: UIImage
  let isActive: Bool
  let size: CGSize
  let onTap: () -> Void
  let onZoomChanged: (Bool) -> Void

  func makeUIView(context: Context) -> NativeCenteringScrollView {
    let scrollView = NativeCenteringScrollView()
    scrollView.contentTag = 100
    scrollView.assetSize = image.size
    scrollView.delegate = context.coordinator
    scrollView.maximumZoomScale = 5.0
    scrollView.minimumZoomScale = 1.0
    scrollView.bouncesZoom = true
    scrollView.isScrollEnabled = false
    scrollView.showsVerticalScrollIndicator = false
    scrollView.showsHorizontalScrollIndicator = false
    scrollView.contentInsetAdjustmentBehavior = .never
    scrollView.automaticallyAdjustsScrollIndicatorInsets = false
    scrollView.backgroundColor = .clear

    let imageView = UIImageView(image: image)
    imageView.contentMode = .scaleAspectFit
    imageView.tag = 100
    scrollView.addSubview(imageView)

    let tapGesture = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleTap))
    tapGesture.numberOfTapsRequired = 1
    tapGesture.cancelsTouchesInView = false
    tapGesture.delegate = context.coordinator
    scrollView.addGestureRecognizer(tapGesture)

    let doubleTapGesture = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleDoubleTap(_:)))
    doubleTapGesture.numberOfTapsRequired = 2
    scrollView.addGestureRecognizer(doubleTapGesture)
    tapGesture.require(toFail: doubleTapGesture)

    return scrollView
  }

  func updateUIView(_ uiView: NativeCenteringScrollView, context: Context) {
    context.coordinator.onTap = onTap
    context.coordinator.onZoomChanged = onZoomChanged
    if !isActive && uiView.zoomScale > uiView.minimumZoomScale + 0.01 {
      uiView.setZoomScale(uiView.minimumZoomScale, animated: false)
      uiView.isScrollEnabled = false
    }
    uiView.contentTag = 100
    uiView.assetSize = image.size

    guard let imageView = uiView.viewWithTag(100) as? UIImageView else { return }
    let imageChanged = imageView.image !== image
    if imageChanged {
      imageView.image = image
    }

    let viewportSize = uiView.bounds.size == .zero ? size : uiView.bounds.size
    let fittedSize = nativeAspectFitImageSize(imageSize: image.size, viewportSize: viewportSize)
    if fittedSize != .zero && (imageChanged || imageView.bounds.size != fittedSize) {
      uiView.setZoomScale(uiView.minimumZoomScale, animated: false)
      imageView.bounds = CGRect(origin: .zero, size: fittedSize)
      uiView.contentSize = fittedSize
      uiView.isScrollEnabled = false
      onZoomChanged(false)
    }
    uiView.centerContent()
  }

  func makeCoordinator() -> Coordinator {
    Coordinator(onTap: onTap, onZoomChanged: onZoomChanged)
  }

  class Coordinator: NSObject, UIScrollViewDelegate, UIGestureRecognizerDelegate {
    var onTap: () -> Void
    var onZoomChanged: (Bool) -> Void
    private var pendingSingleTapWorkItem: DispatchWorkItem?

    init(onTap: @escaping () -> Void, onZoomChanged: @escaping (Bool) -> Void) {
      self.onTap = onTap
      self.onZoomChanged = onZoomChanged
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
      if gestureRecognizer is UITapGestureRecognizer, otherGestureRecognizer is UITapGestureRecognizer {
        return false
      }
      return true
    }

    func viewForZooming(in scrollView: UIScrollView) -> UIView? {
      scrollView.viewWithTag(100)
    }

    func scrollViewDidZoom(_ scrollView: UIScrollView) {
      (scrollView as? NativeCenteringScrollView)?.centerContent()
      let zoomed = scrollView.zoomScale > scrollView.minimumZoomScale + 0.01
      scrollView.isScrollEnabled = zoomed
      onZoomChanged(zoomed)
    }

    func scrollViewDidEndZooming(_ scrollView: UIScrollView, with view: UIView?, atScale scale: CGFloat) {
      (scrollView as? NativeCenteringScrollView)?.centerContent()
      let zoomed = scale > scrollView.minimumZoomScale + 0.01
      scrollView.isScrollEnabled = zoomed
      onZoomChanged(zoomed)
    }

    @objc func handleTap() {
      pendingSingleTapWorkItem?.cancel()
      let workItem = DispatchWorkItem { [weak self] in
        self?.onTap()
      }
      pendingSingleTapWorkItem = workItem
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: workItem)
    }

    @objc func handleDoubleTap(_ gesture: UITapGestureRecognizer) {
      pendingSingleTapWorkItem?.cancel()
      pendingSingleTapWorkItem = nil
      guard let scrollView = gesture.view as? UIScrollView else { return }
      if scrollView.zoomScale > scrollView.minimumZoomScale + 0.01 {
        scrollView.setZoomScale(scrollView.minimumZoomScale, animated: true)
        scrollView.isScrollEnabled = false
        onZoomChanged(false)
      } else if let imageView = scrollView.viewWithTag(100) as? UIImageView {
        let location = gesture.location(in: imageView)
        let rect = nativeViewerZoomRect(for: location, in: imageView.bounds.size, viewportSize: scrollView.bounds.size, targetScale: min(3.0, scrollView.maximumZoomScale))
        if rect != .zero {
          scrollView.zoom(to: rect, animated: true)
          scrollView.isScrollEnabled = true
          onZoomChanged(true)
        }
      }
    }
  }
}

private struct NativeInfoSheetDetentsModifier: ViewModifier {
  @ViewBuilder
  func body(content: Content) -> some View {
    if #available(iOS 16.0, *) {
      content
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    } else {
      content
    }
  }
}

// Info & EXIF Sheet
private struct NativeAssetInfoSheet: View {
  let client: NativeImmichClient
  let device: NativeDeviceLibrary
  let item: NativeGridItem

  @State private var remoteInfo: [String: Any]?
  @State private var loadingInfo = false
  @State private var infoError: String?
  @Environment(\.dismiss) private var dismiss

  private var infoAsset: [String: Any] { remoteInfo ?? [:] }
  private var exif: [String: Any] { infoAsset["exifInfo"] as? [String: Any] ?? [:] }
  private var localAsset: PHAsset? {
    guard let id = item.local?.id else { return nil }
    return PHAsset.fetchAssets(withLocalIdentifiers: [id], options: nil).firstObject
  }
  private var localResource: PHAssetResource? { localAsset?.getResource() }
  private var resolvedName: String? {
    (infoAsset["originalFileName"] as? String) ?? item.server?.originalFileName ?? localResource?.originalFilename
  }
  private var sizeText: String? {
    let width = (infoAsset["width"] as? NSNumber)?.intValue ?? item.server?.width ?? localAsset?.pixelWidth
    let height = (infoAsset["height"] as? NSNumber)?.intValue ?? item.server?.height ?? localAsset?.pixelHeight
    guard let width, let height, width > 0, height > 0 else { return nil }
    return "\(width) × \(height)"
  }
  private var fileSize: Int64? {
    (exif["fileSizeInByte"] as? NSNumber)?.int64Value ?? item.server?.fileSizeInByte
  }

  var body: some View {
    NavigationView {
      List {
        Section("基本信息") {
          InfoRow(label: "拍摄时间", value: NativeImmichClient.formatChineseDateTime(item.date))
          InfoRow(label: "类型", value: item.isVideo ? "视频" : "照片")
          InfoRow(label: "来源", value: item.server != nil && item.local != nil ? "本机与云端" : (item.local != nil ? "本机" : "云端"))
          InfoRow(label: "副本状态", value: item.server != nil && item.local != nil ? "双端已确认" : (item.server != nil ? "仅云端" : (NativeSyncCacheStore.shared.isMatched(localId: item.local?.id) ? "已匹配，云端信息待载入" : "本机；核验状态按下方显示")))
          if let local = item.local {
            InfoRow(label: "云端核验", value: NativeSyncCacheStore.shared.isMatched(localId: local.id) ? "已确认匹配" : "尚未确认；不能据此判断未上传")
          }
          if let resolvedName { InfoRow(label: "文件名", value: resolvedName) }
          if let sizeText { InfoRow(label: "尺寸", value: sizeText) }
          if let mime = (infoAsset["originalMimeType"] as? String) ?? item.server?.originalMimeType ?? localResource?.uniformTypeIdentifier { InfoRow(label: "格式", value: mime) }
          if let fileSize { InfoRow(label: "文件大小", value: ByteCountFormatter.string(fromByteCount: fileSize, countStyle: .file)) }
          if let location = locationText { InfoRow(label: "地点", value: location) }
        }

        if let infoError {
          Section("云端详情") { Text(infoError).foregroundColor(.secondary); Button("重试") { Task { await loadInfo() } } }
        } else if loadingInfo {
          Section("云端详情") { ProgressView("正在加载详情…") }
        }

        if !exif.isEmpty {
          Section("拍摄与硬件参数") {
            if let make = exif["make"] as? String { InfoRow(label: "设备品牌", value: make) }
            if let model = exif["model"] as? String { InfoRow(label: "设备型号", value: model) }
            if let lens = exif["lensModel"] as? String { InfoRow(label: "镜头", value: lens) }
            if let fNumber = exif["fNumber"] { InfoRow(label: "光圈", value: "f/\(fNumber)") }
            if let focal = exif["focalLength"] { InfoRow(label: "焦距", value: "\(focal)mm") }
            if let iso = exif["iso"] { InfoRow(label: "ISO", value: "\(iso)") }
            if let exp = exif["exposureTime"] { InfoRow(label: "曝光时间", value: "\(exp)s") }
          }
        }
      }
      .navigationTitle("详细信息")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar { ToolbarItem(placement: .navigationBarTrailing) { Button("完成") { dismiss() } } }
      .task { await loadInfo() }
    }
  }

  private var locationText: String? {
    let latitude = (exif["latitude"] as? NSNumber)?.doubleValue ?? item.server?.latitude ?? localAsset?.location?.coordinate.latitude
    let longitude = (exif["longitude"] as? NSNumber)?.doubleValue ?? item.server?.longitude ?? localAsset?.location?.coordinate.longitude
    guard let latitude, let longitude else { return nil }
    return String(format: "%.5f, %.5f", latitude, longitude)
  }

  @MainActor private func loadInfo() async {
    guard let server = item.server else { return }
    loadingInfo = true
    infoError = nil
    do { remoteInfo = try await client.assetInfo(id: server.id) }
    catch { infoError = error.localizedDescription }
    loadingInfo = false
  }
}

private struct InfoRow: View {
  let label: String
  let value: String

  var body: some View {
    HStack(alignment: .top) {
      Text(label)
        .font(.subheadline)
        .foregroundColor(.secondary)
        .frame(width: 90, alignment: .leading)
      Spacer()
      Text(value)
        .font(.subheadline)
        .foregroundColor(.primary)
        .multilineTextAlignment(.trailing)
    }
  }
}

// MARK: - Server and Sync Settings Sheets

struct NativeServerSettingsSheet: View {
  let client: NativeImmichClient
  let onLogout: () -> Void
  @Environment(\.dismiss) private var dismiss

  @State private var currentUserEmail: String = "正在获取…"
  @State private var currentUserName: String = ""
  @State private var isTestingConnection = false
  @State private var testResult: String? = nil
  @State private var testSuccess: Bool? = nil

  var body: some View {
    NavigationView {
      Form {
        Section(header: Text("当前登录账号")) {
          HStack {
            Text("账号邮箱")
            Spacer()
            Text(currentUserEmail)
              .foregroundColor(.secondary)
          }
          if !currentUserName.isEmpty {
            HStack {
              Text("用户昵称")
              Spacer()
              Text(currentUserName)
                .foregroundColor(.secondary)
            }
          }
        }

        Section(header: Text("服务器配置")) {
          HStack {
            Text("服务器地址")
            Spacer()
            Text(client.config.serverUrl)
              .foregroundColor(.secondary)
              .lineLimit(1)
              .truncationMode(.middle)
          }
          if let deviceId = client.config.deviceId {
            HStack {
              Text("设备标识")
              Spacer()
              Text(deviceId)
                .foregroundColor(.secondary)
            }
          }
          HStack {
            Text("认证方式")
            Spacer()
            Text(client.config.apiKey != nil ? "API Key" : "账号凭据")
              .foregroundColor(.secondary)
          }
        }

        Section(header: Text("连接性测试"), footer: testResult.map { Text($0).foregroundColor(testSuccess == true ? .green : .red) }) {
          Button {
            testServerConnection()
          } label: {
            HStack {
              if isTestingConnection {
                ProgressView().scaleEffect(0.8)
                Text("正在测试连接…")
              } else {
                Text("测试服务器连接性")
              }
            }
          }
          .disabled(isTestingConnection)
        }

        Section(header: Text("多账号管理与切换")) {
          let accounts = NativeSessionStore.savedAccounts()
          ForEach(accounts) { acc in
            HStack {
              VStack(alignment: .leading, spacing: 2) {
                Text(acc.userEmail ?? (acc.apiKey != nil ? "API Key 账号" : acc.serverUrl))
                  .font(.subheadline)
                  .fontWeight(acc.id == client.config.id ? .semibold : .regular)
                Text(acc.serverUrl)
                  .font(.caption2)
                  .foregroundColor(.secondary)
              }
              Spacer()
              if acc.id == client.config.id {
                Text("当前活跃")
                  .font(.caption2)
                  .padding(.horizontal, 6)
                  .padding(.vertical, 2)
                  .background(Color.green.opacity(0.15))
                  .foregroundColor(.green)
                  .cornerRadius(4)
              } else {
                Button("切换") {
                  Task {
                    dismiss()
                    try? NativeSessionStore.save(acc)
                    onLogout() // triggers reload with new session
                  }
                }
                .font(.caption)
                .buttonStyle(.bordered)
              }
            }
          }
        }

        Section(header: Text("缓存空间与隔离")) {
          let identity = NativeSyncCacheStore.shared.identity ?? "default"
          HStack {
            Text("当前账号独立缓存")
            Spacer()
            Text(identity)
              .font(.caption.monospaced())
              .foregroundColor(.secondary)
          }

          Button(role: .destructive) {
            NativePhotoSnapshotStore.shared.clearCurrentAccount()
            NativeSyncCacheStore.shared.clear()
            Task {
              await NativeThumbnailDiskCache.shared.clearAll()
            }
          } label: {
            Text("清理当前账号缩略图与元数据缓存")
          }
        }

        Section(header: Text("账号操作")) {
          Button(role: .destructive) {
            dismiss()
            onLogout()
          } label: {
            HStack {
              Spacer()
              Text("退出当前账号")
              Spacer()
            }
          }
        }
      }
      .navigationTitle("服务器设置")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .navigationBarTrailing) {
          Button("完成") { dismiss() }
        }
      }
      .task {
        await loadUserInfo()
      }
    }
  }

  private func loadUserInfo() async {
    do {
      let info = try await client.send(path: "users/me")
      let email = info["email"] as? String ?? "已登录"
      let name = info["name"] as? String ?? ""
      await MainActor.run {
        currentUserEmail = email
        currentUserName = name
      }
    } catch {
      await MainActor.run {
        currentUserEmail = client.config.apiKey != nil ? "API Key 授权" : "无法获取用户信息"
      }
    }
  }

  private func testServerConnection() {
    isTestingConnection = true
    testResult = nil
    testSuccess = nil
    UIImpactFeedbackGenerator(style: .light).impactOccurred()
    Task {
      let start = Date()
      do {
        _ = try await client.send(path: "server/ping")
        let latency = Int(Date().timeIntervalSince(start) * 1000)
        await MainActor.run {
          isTestingConnection = false
          testSuccess = true
          testResult = "连接正常：服务器响应成功，延迟约为 \(latency)ms"
          UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        }
      } catch {
        await MainActor.run {
          isTestingConnection = false
          testSuccess = false
          testResult = "连接失败：\(error.localizedDescription)"
          UINotificationFeedbackGenerator().notificationOccurred(.error)
        }
      }
    }
  }
}

struct NativeSyncSettingsSheet: View {
  let client: NativeImmichClient
  @ObservedObject var device: NativeDeviceLibrary
  @ObservedObject var cloud: NativeCloudStatus
  @ObservedObject private var backupEngine = NativeBackupEngine.shared
  @Environment(\.dismiss) private var dismiss

  @AppStorage("backup_enabled") private var legacySyncEnabled = false
  @AppStorage("immichz_sync_enabled") private var syncEnabled = true
  @AppStorage("immichz_sync_wifi_only") private var wifiOnlySync = true
  @AppStorage("immichz_sync_wifi_only_video") private var wifiOnlySyncVideo = true
  @State private var showNoAlbumAlert = false

  private var verifiedLocalOnlyCount: Int {
    device.assets.filter { cloud.checkedIDs.contains($0.id) && !cloud.failedVerificationIDs.contains($0.id) && cloud.matchedServerIDs[$0.id] == nil }.count
  }

  private var unknownCount: Int {
    device.assets.filter { (!cloud.checkedIDs.contains($0.id) || cloud.failedVerificationIDs.contains($0.id)) && cloud.matchedServerIDs[$0.id] == nil }.count
  }

  var body: some View {
    NavigationView {
      Form {
        Section(header: Text("自动备份引擎"), footer: Text("支持原图与实况照片 (Live Photo) 双轨原子上传；开启后所选相册的新照片将自动备份到 Immich 服务器。")) {
          Toggle("开启自动备份", isOn: Binding(
            get: { backupEngine.isBackupEnabled },
            set: { enabled in
              if enabled && backupEngine.selectedAlbumIDs.isEmpty {
                showNoAlbumAlert = true
              } else {
                backupEngine.isBackupEnabled = enabled
              }
            }
          ))

          Toggle("仅在 Wi-Fi 下备份", isOn: Binding(
            get: { backupEngine.requireWifi },
            set: { backupEngine.requireWifi = $0 }
          ))
          .disabled(!backupEngine.isBackupEnabled)

          if backupEngine.isRunning {
            VStack(alignment: .leading, spacing: 6) {
              HStack {
                Text(backupEngine.statusMessage ?? "正在备份...")
                  .font(.subheadline)
                Spacer()
                ProgressView()
                  .scaleEffect(0.8)
              }
              ProgressView(value: backupEngine.currentProgress)
            }
            .padding(.vertical, 4)

            Button("暂停备份", role: .destructive) {
              backupEngine.cancel()
            }
          } else {
            Button("立即执行备份") {
              if backupEngine.selectedAlbumIDs.isEmpty {
                showNoAlbumAlert = true
              } else {
                backupEngine.triggerBackupPass(assets: device.assets, client: client, force: true)
              }
            }
            .disabled(!backupEngine.isBackupEnabled)

            if let msg = backupEngine.statusMessage {
              Text(msg)
                .font(.caption)
                .foregroundColor(.secondary)
            }
          }
        }

        Section(header: Text("备份相册选择"), footer: Text("请先勾选需要自动备份的本机相册。只有选中的相册内容才会自动备份到 Immich。")) {
          if device.albums.isEmpty {
            Text("未检测到本机相册或暂未获得相册权限")
              .font(.caption)
              .foregroundColor(.secondary)
          } else {
            ForEach(device.albums) { album in
              HStack {
                Text(album.name)
                Spacer()
                if backupEngine.selectedAlbumIDs.contains(album.id) {
                  Image(systemName: "checkmark")
                    .foregroundColor(.accentColor)
                    .font(.subheadline.bold())
                }
              }
              .contentShape(Rectangle())
              .onTapGesture {
                var current = backupEngine.selectedAlbumIDs
                if current.contains(album.id) {
                  current.remove(album.id)
                } else {
                  current.insert(album.id)
                }
                backupEngine.selectedAlbumIDs = current
              }
            }
          }
        }

        Section(header: Text("同步开关与网络偏好"), footer: Text("关闭同步开关将暂停自动核验与同步任务。“仅 WiFi 同步”可节省蜂窝流量；开启后视频亦仅在连接 Wi-Fi 时同步。")) {
          Toggle("同步开关", isOn: Binding(
            get: { syncEnabled },
            set: { newValue in
              syncEnabled = newValue
              legacySyncEnabled = newValue
            }
          ))

          Toggle("仅 WiFi 同步", isOn: $wifiOnlySync)
            .disabled(!syncEnabled)

          Toggle("仅 WiFi 同步视频", isOn: $wifiOnlySyncVideo)
            .disabled(!syncEnabled || wifiOnlySync)
        }

        Section(header: Text("相册与同步状态")) {
          HStack {
            Text("设备已授权照片")
            Spacer()
            Text("\(device.assets.count) 项").foregroundColor(.secondary)
          }
          HStack {
            Text("已匹配云端照片")
            Spacer()
            Text("\(cloud.matchedServerIDs.count) 项").foregroundColor(.secondary)
          }
          HStack {
            Text("已核验但云端无匹配")
            Spacer()
            Text("\(verifiedLocalOnlyCount) 项").foregroundColor(verifiedLocalOnlyCount > 0 ? .orange : .secondary)
          }
          HStack {
            Text("状态未知")
            Spacer()
            Text("\(unknownCount) 项").foregroundColor(unknownCount > 0 ? .secondary : .secondary)
          }
        }

        Section(header: Text("核验")) {
          Button {
            Task {
              await cloud.retry(device.assets, client: client)
            }
          } label: {
            HStack {
              if cloud.isRunning {
                ProgressView().scaleEffect(0.8)
                Text("正在核验中…")
              } else {
                Text("重新核验本地照片")
              }
            }
          }
          .disabled(cloud.isRunning || !syncEnabled)
        }
      }
      .navigationTitle("同步设置")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .navigationBarTrailing) {
          Button("完成") { dismiss() }
        }
      }
      .alert("请先选择备份相册", isPresented: $showNoAlbumAlert) {
        Button("好", role: .cancel) {}
      } message: {
        Text("请在“备份相册选择”中勾选至少一个手机相册，再开启自动备份。")
      }
    }
  }
}

extension Notification.Name {
  static let immichScrollPhotosToBottom = Notification.Name("ImmichScrollPhotosToBottom")
}

extension View {
  @ViewBuilder
  func nativeScrollDisabled(_ disabled: Bool) -> some View {
    if #available(iOS 16.0, *) {
      self.scrollDisabled(disabled)
    } else {
      self
    }
  }
}
