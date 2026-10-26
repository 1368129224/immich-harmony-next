import CryptoKit
import Foundation
import MapKit
import Photos
import SwiftUI
import UIKit

struct LibraryRow: Identifiable {
  let id: String
  let title: String
  let detail: String
  let assetID: String?
}

extension NativeImmichClient {
  func libraryRows(_ path: String, query: [URLQueryItem] = []) async throws -> [[String: Any]] {
    let base = config.apiEndpoint ?? (Self.normalize(config.serverUrl) + "/api")
    guard var components = URLComponents(string: base + "/" + path) else { throw NativeLibraryError.invalidResponse }
    components.queryItems = query.isEmpty ? nil : query
    guard let url = components.url else { throw NativeLibraryError.invalidResponse }
    var request = URLRequest(url: url)
    if let token = config.accessToken { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
    if let key = config.apiKey { request.setValue(key, forHTTPHeaderField: "x-api-key") }
    let (data, response) = try await URLSession.shared.data(for: request)
    guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
          let rows = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { throw NativeLibraryError.invalidResponse }
    return rows
  }
}

private enum NativeLibraryError: LocalizedError {
  case invalidResponse
  var errorDescription: String? { "服务器暂时无法提供该集合。" }
}

struct NativeLibrarySection: View {
  let client: NativeImmichClient
  let title: String
  let path: String
  let query: [URLQueryItem]
  let transform: ([String: Any]) -> LibraryRow?
  @State private var rows: [LibraryRow] = []
  @State private var error: String?
  @State private var loading = false

  var body: some View {
    List {
      if loading { ProgressView() }
      if let error { Text(error).foregroundColor(.red); Button("重试") { Task { await reload() } } }
      if !loading && error == nil && rows.isEmpty { Text("暂无内容").foregroundColor(.secondary) }
      ForEach(rows) { row in
        if let tag = row.assetID {
          NavigationLink {
            NativeFilteredView(client: client, title: row.title, filter: ["tagIds": ["any": [tag]]])
          } label: { rowLabel(row) }
        } else { rowLabel(row) }
      }
    }
    .navigationTitle(title)
    .refreshable { await reload() }
    .task { await reload() }
  }

  private func rowLabel(_ row: LibraryRow) -> some View {
    VStack(alignment: .leading, spacing: 4) {
      Text(row.title)
      if !row.detail.isEmpty { Text(row.detail).font(.caption).foregroundColor(.secondary) }
    }
  }

  private func reload() async {
    guard !loading else { return }
    loading = true
    defer { loading = false }
    do { let response = try await client.libraryRows(path, query: query); rows = response.compactMap(transform); error = nil }
    catch { self.error = error.localizedDescription }
  }
}

struct NativePeopleView: View {
  let client: NativeImmichClient
  @State private var people: [[String: Any]] = []
  @State private var page = 1
  @State private var hasMore = true
  @State private var loading = false
  @State private var error: String?

  var body: some View {
    List {
      if let error { Text(error).foregroundColor(.red); Button("重试") { Task { await load() } } }
      if !loading && people.isEmpty && error == nil { Text("暂无人物").foregroundColor(.secondary) }
      ForEach(people.indices, id: \.self) { index in
        if let id = people[index]["id"] as? String {
          NavigationLink {
            NativeFilteredView(client: client, title: people[index]["name"] as? String ?? "人物", filter: ["personIds": ["any": [id]]])
          } label: {
            HStack(spacing: 12) {
              Image(systemName: "person.crop.circle.fill")
                .font(.system(size: 32))
                .foregroundColor(.secondary)
              Text((people[index]["name"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "未命名")
                .font(.body)
            }
            .padding(.vertical, 2)
          }
        }
      }
      if hasMore {
        Button(loading ? "加载中…" : "加载更多") { Task { await load() } }.disabled(loading)
      }
    }
    .navigationTitle("人物")
    .task { if people.isEmpty { await load() } }
  }

  private func load() async {
    guard !loading && hasMore else { return }
    loading = true
    defer { loading = false }
    do {
      let response = try await client.send(path: "people", query: [URLQueryItem(name: "page", value: String(page)), URLQueryItem(name: "size", value: "100")])
      guard let rows = response["people"] as? [[String: Any]] else { throw NativeLibraryError.invalidResponse }
      people += rows
      hasMore = response["hasNextPage"] as? Bool ?? false
      page += 1
      error = nil
    } catch { self.error = error.localizedDescription }
  }
}

struct NativePlacesView: View {
  let client: NativeImmichClient
  @State private var places: [String: (count: Int, sampleId: String?)] = [:]
  @State private var markers: [NativeMapPin] = []
  @State private var error: String?
  @State private var region = MKCoordinateRegion(center: CLLocationCoordinate2D(latitude: 0, longitude: 0), span: MKCoordinateSpan(latitudeDelta: 150, longitudeDelta: 150))

  var body: some View {
    VStack(spacing: 0) {
      Map(coordinateRegion: $region, annotationItems: markers) { pin in
        MapMarker(coordinate: pin.coordinate)
      }.frame(height: 240)
      List {
        if let error { Text(error).foregroundColor(.red); Button("重试") { Task { await load() } } }
        if places.isEmpty && error == nil { Text("暂无带位置的照片").foregroundColor(.secondary) }
        ForEach(places.keys.sorted(), id: \.self) { place in
          if let info = places[place] {
            NavigationLink {
              NativeFilteredView(client: client, title: place, filter: ["city": ["eq": place]])
            } label: {
              HStack {
                VStack(alignment: .leading, spacing: 2) {
                  Text(place)
                    .font(.body)
                  Text("\(info.count) 张照片")
                    .font(.caption)
                    .foregroundColor(.secondary)
                }
                Spacer()
              }
            }
          }
        }
      }
    }
    .navigationTitle("地点")
    .task { await load() }
  }

  private func load() async {
    do {
      let rows = try await client.libraryRows("map/markers")
      var totals: [String: (count: Int, sampleId: String?)] = [:]
      markers = rows.compactMap { row in
        let place = [row["city"], row["state"], row["country"]].compactMap { $0 as? String }.first(where: { !$0.isEmpty }) ?? "未知地点"
        let id = row["id"] as? String
        let current = totals[place] ?? (count: 0, sampleId: id)
        totals[place] = (count: current.count + 1, sampleId: current.sampleId ?? id)
        guard let lat = row["lat"] as? Double, let lon = row["lon"] as? Double,
              (-90...90).contains(lat), (-180...180).contains(lon), let pinId = id else { return nil }
        return NativeMapPin(id: pinId, coordinate: CLLocationCoordinate2D(latitude: lat, longitude: lon))
      }
      places = totals
      if let first = markers.first { region.center = first.coordinate; region.span = MKCoordinateSpan(latitudeDelta: 20, longitudeDelta: 20) }
      error = nil
    } catch { self.error = error.localizedDescription }
  }
}

private struct NativeMapPin: Identifiable {
  let id: String
  let coordinate: CLLocationCoordinate2D
}

struct NativeFoldersView: View {
  let client: NativeImmichClient
  @State private var paths: [String] = []
  @State private var error: String?
  var body: some View {
    List {
      if let error { Text(error).foregroundColor(.red) }
      if paths.isEmpty && error == nil { Text("暂无服务器文件夹").foregroundColor(.secondary) }
      ForEach(paths, id: \.self) { path in
        NavigationLink(path) { NativeFolderAssets(client: client, path: path) }
      }
    }
    .navigationTitle("服务器文件夹")
    .task {
      do { paths = try await client.libraryStrings("view/folder/unique-paths"); error = nil }
      catch { self.error = error.localizedDescription }
    }
  }
}

private struct NativeFolderAssets: View {
  let client: NativeImmichClient
  let path: String
  @State private var assets: [NativeAsset] = []
  @State private var error: String?
  var body: some View {
    VStack {
      if let error { Text(error).foregroundColor(.red) }
      NativeResultGrid(client: client, assets: assets, hasOlder: false, loadMore: {})
    }
    .navigationTitle((path as NSString).lastPathComponent)
    .task {
      do {
        let rows = try await client.libraryRows("view/folder", query: [URLQueryItem(name: "path", value: path)])
        assets = rows.compactMap { row in
          guard let id = row["id"] as? String else { return nil }
          let text = row["fileCreatedAt"] as? String ?? ""
          return NativeAsset(id: id, date: ISO8601DateFormatter().date(from: text) ?? .distantPast, isImage: row["type"] as? String != "VIDEO", isFavorite: row["isFavorite"] as? Bool ?? false, thumbhash: row["thumbhash"] as? String, livePhotoVideoId: row["livePhotoVideoId"] as? String)
        }
        error = nil
      } catch { self.error = error.localizedDescription }
    }
  }
}

extension NativeImmichClient {
  func libraryStrings(_ path: String) async throws -> [String] {
    let base = config.apiEndpoint ?? (Self.normalize(config.serverUrl) + "/api")
    guard let url = URL(string: base + "/" + path) else { throw NativeLibraryError.invalidResponse }
    var request = URLRequest(url: url)
    if let token = config.accessToken { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
    if let key = config.apiKey { request.setValue(key, forHTTPHeaderField: "x-api-key") }
    let (data, response) = try await URLSession.shared.data(for: request)
    guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
          let strings = try JSONSerialization.jsonObject(with: data) as? [String] else { throw NativeLibraryError.invalidResponse }
    return strings
  }
}

// The main branch publishes this manifest together with its unsigned IPA.
// The app downloads the IPA to a temporary file, verifies its SHA-256 against
// this manifest, and presents the standard iOS Share Sheet with LiveContainer
// targeted, avoiding the LiveContainer guest app URL scheme block.
struct NativeReleaseUpdate: Decodable {
  let bundleIdentifier: String
  let channel: String
  let buildNumber: Int
  let version: String
  let commit: String
  let sha256: String
  let downloadURL: URL

  static let manifestURL = URL(string:
    "https://github.com/1368129224/immich-next/releases/download/latest-build/immichz-update.json"
  )!
  static let ipaURL = URL(string:
    "https://github.com/1368129224/immich-next/releases/download/latest-build/ImmichZ-unsigned.ipa"
  )!

  func isNewer(than currentBuild: Int, bundleID: String) throws -> Bool {
    guard bundleIdentifier == bundleID, channel == "main", buildNumber > 0,
          !version.isEmpty, !commit.isEmpty,
          sha256.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil,
          downloadURL == Self.ipaURL else {
      throw NativeUpdateError.invalidManifest
    }
    return buildNumber > currentBuild
  }

  var liveContainerURL: URL? {
    var components = URLComponents()
    components.scheme = "livecontainer"
    components.host = "install"
    components.queryItems = [URLQueryItem(name: "url", value: downloadURL.absoluteString)]
    return components.url
  }
}

func nativeComputeFileSHA256(at url: URL) throws -> String {
  let handle = try FileHandle(forReadingFrom: url)
  defer { try? handle.close() }
  var hasher = SHA256()
  while true {
    let chunk = handle.readData(ofLength: 65_536)
    if chunk.isEmpty { break }
    hasher.update(data: chunk)
  }
  let digest = hasher.finalize()
  return digest.map { String(format: "%02x", $0) }.joined()
}

func nativeVerifyDownloadedIPA(at fileURL: URL, expectedSHA256: String) throws {
  let computed = try nativeComputeFileSHA256(at: fileURL)
  guard computed.lowercased() == expectedSHA256.lowercased() else {
    throw NativeUpdateError.checksumMismatch
  }
}

private enum NativeUpdateError: LocalizedError {
  case invalidManifest
  case unavailable
  case unknownBuild
  case checksumMismatch
  case downloadFailed

  var errorDescription: String? {
    switch self {
    case .invalidManifest: return "更新信息无效，已停止安装。请稍后重试。"
    case .unavailable: return "暂时无法读取 GitHub Release，请检查网络后重试。"
    case .unknownBuild: return "无法读取当前构建号，暂不能安全比较版本。"
    case .checksumMismatch: return "安装包哈希校验失败（可能下载损坏或被篡改），已取消导入。"
    case .downloadFailed: return "安装包下载失败，请检查网络连接后重试。"
    }
  }
}

private final class NativeUpdateDownloadDelegate: NSObject, URLSessionDownloadDelegate {
  var onProgress: ((Double) -> Void)?
  var onCompletion: ((Result<URL, Error>) -> Void)?

  func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
    guard totalBytesExpectedToWrite > 0 else { return }
    let progress = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
    DispatchQueue.main.async { self.onProgress?(progress) }
  }

  func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
    let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("immichz_update_\(UUID().uuidString)")
    let target = tempDir.appendingPathComponent("ImmichZ-unsigned.ipa")
    do {
      try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
      if FileManager.default.fileExists(atPath: target.path) {
        try FileManager.default.removeItem(at: target)
      }
      try FileManager.default.moveItem(at: location, to: target)
      DispatchQueue.main.async { self.onCompletion?(.success(target)) }
    } catch {
      DispatchQueue.main.async { self.onCompletion?(.failure(error)) }
    }
  }

  func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
    if let error {
      DispatchQueue.main.async { self.onCompletion?(.failure(error)) }
    }
  }
}

struct NativeAppUpdateView: View {
  @State private var latest: NativeReleaseUpdate?
  @State private var isChecking = false
  @State private var isDownloading = false
  @State private var downloadProgress: Double = 0.0
  @State private var downloadStatusText: String?
  @State private var currentDownloadTask: URLSessionDownloadTask?
  @State private var status: String?
  @State private var sharePayload: NativeSharePayload?

  private var currentBuild: Int? {
    guard let string = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String else { return nil }
    return Int(string)
  }

  private var currentVersion: String {
    Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "未知版本"
  }

  var body: some View {
    Form {
      Section("当前版本") {
        HStack { Text("版本"); Spacer(); Text(currentVersion).foregroundColor(.secondary) }
        HStack { Text("构建号"); Spacer(); Text(currentBuild.map { String($0) } ?? "未知").foregroundColor(.secondary) }
      }

      Section {
        Button {
          Task { await checkForUpdate() }
        } label: {
          HStack {
            Text("检查更新")
            if isChecking { Spacer(); ProgressView() }
          }
        }
        .disabled(isChecking || isDownloading)

        if let latest {
          HStack {
            Text("主分支新版本")
            Spacer()
            Text(latest.version).foregroundColor(.secondary)
          }

          if isDownloading {
            VStack(alignment: .leading, spacing: 6) {
              HStack {
                Text(downloadStatusText ?? "正在下载安装包…")
                  .font(.subheadline)
                Spacer()
                Text("\(Int(downloadProgress * 100))%")
                  .font(.subheadline.monospacedDigit())
                  .foregroundColor(.secondary)
              }
              ProgressView(value: downloadProgress)
              Button("取消下载", role: .destructive) {
                cancelDownload()
              }
              .font(.footnote)
              .padding(.top, 4)
            }
            .padding(.vertical, 4)
          } else {
            Button("下载并导入 LiveContainer") {
              startDownloadAndShare(release: latest)
            }
            .disabled(isChecking)

            Link("在浏览器中手动下载 IPA", destination: latest.downloadURL)
          }
        }

        if let status { Text(status).font(.footnote).foregroundColor(.secondary) }
      } header: {
        Text("GitHub Release · main")
      } footer: {
        Text("下载完成后会自动调出系统共享面板。请在面板中选择「LiveContainer」，并在 LiveContainer 弹出的确认框中选择「覆盖 (Replace)」完成安装。")
      }
    }
    .navigationTitle("应用更新")
    .sheet(item: $sharePayload) { payload in
      NativeActivityView(activityItems: payload.content)
    }
    .task { await checkForUpdate() }
  }

  @MainActor private func checkForUpdate() async {
    guard !isChecking, !isDownloading else { return }
    isChecking = true
    latest = nil
    status = nil
    defer { isChecking = false }

    do {
      guard let currentBuild, let bundleID = Bundle.main.bundleIdentifier else {
        throw NativeUpdateError.unknownBuild
      }
      var request = URLRequest(url: NativeReleaseUpdate.manifestURL)
      request.cachePolicy = .reloadIgnoringLocalCacheData
      request.timeoutInterval = 20
      let (data, response) = try await URLSession.shared.data(for: request)
      guard let http = response as? HTTPURLResponse,
            (200..<300).contains(http.statusCode), data.count < 64_000 else {
        throw NativeUpdateError.unavailable
      }
      let release = try JSONDecoder().decode(NativeReleaseUpdate.self, from: data)
      if try release.isNewer(than: currentBuild, bundleID: bundleID) {
        latest = release
        status = "发现新构建 \(release.buildNumber)，点击上方按钮下载并导入 LiveContainer。"
      } else {
        status = "当前已是 main 渠道的最新版本。"
      }
    } catch is DecodingError {
      status = NativeUpdateError.invalidManifest.localizedDescription
    } catch {
      status = error.localizedDescription
    }
  }

  private func cancelDownload() {
    currentDownloadTask?.cancel()
    currentDownloadTask = nil
    isDownloading = false
    downloadProgress = 0
    downloadStatusText = nil
    status = "下载已取消。"
  }

  private func startDownloadAndShare(release: NativeReleaseUpdate) {
    guard !isDownloading else { return }
    isDownloading = true
    downloadProgress = 0.0
    downloadStatusText = "正在连接 GitHub…"
    status = nil

    let delegate = NativeUpdateDownloadDelegate()
    let session = URLSession(configuration: .default, delegate: delegate, delegateQueue: nil)
    let task = session.downloadTask(with: release.downloadURL)
    currentDownloadTask = task

    delegate.onProgress = { progress in
      self.downloadProgress = progress
      self.downloadStatusText = "正在下载 IPA (\(Int(progress * 100))%)…"
    }

    delegate.onCompletion = { result in
      self.isDownloading = false
      self.currentDownloadTask = nil
      switch result {
      case .success(let downloadedURL):
        self.downloadStatusText = "正在校验安装包…"
        do {
          try nativeVerifyDownloadedIPA(at: downloadedURL, expectedSHA256: release.sha256)
          self.status = "安装包哈希校验通过，请在弹出的面板中选择 LiveContainer 覆盖安装。"
          self.sharePayload = NativeSharePayload(content: downloadedURL)
        } catch {
          try? FileManager.default.removeItem(at: downloadedURL)
          self.status = error.localizedDescription
        }
      case .failure(let error):
        if (error as NSError).code == NSURLErrorCancelled {
          self.status = "下载已取消。"
        } else {
          self.status = "下载失败：\(error.localizedDescription)"
        }
      }
    }

    task.resume()
  }
}


