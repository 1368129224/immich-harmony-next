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

extension NativeImmichClient {
  nonisolated func personThumbnailURL(for personId: String) -> URL? {
    let base = config.apiEndpoint ?? (Self.normalize(config.serverUrl) + "/api")
    return URL(string: base + "/people/\(personId)/thumbnail")
  }

  func updatePerson(id: String, name: String) async throws -> [String: Any] {
    try await send(path: "people/\(id)", method: "PUT", body: ["name": name])
  }

  nonisolated func sharedLinkURL(key: String, slug: String?) -> String {
    let base = Self.normalize(config.serverUrl)
    if let slug = slug?.trimmingCharacters(in: .whitespacesAndNewlines), !slug.isEmpty {
      return "\(base)/s/\(slug)"
    }
    return "\(base)/share/\(key)"
  }
}

private final class NativePersonAvatarCache {
  static let shared = NSCache<NSString, UIImage>()
}

struct NativePersonAvatarView: View {
  let client: NativeImmichClient
  let personId: String
  var size: CGFloat = 44
  @State private var image: UIImage?

  var body: some View {
    Group {
      if let image {
        Image(uiImage: image)
          .resizable()
          .scaledToFill()
          .frame(width: size, height: size)
          .clipShape(Circle())
      } else {
        ZStack {
          Circle()
            .fill(Color(UIColor.secondarySystemBackground))
            .frame(width: size, height: size)
          Image(systemName: "person.fill")
            .font(.system(size: size * 0.45))
            .foregroundColor(.secondary)
        }
      }
    }
    .task(id: personId) {
      let key = personId as NSString
      if let cached = NativePersonAvatarCache.shared.object(forKey: key) {
        self.image = cached
        return
      }
      guard let url = client.personThumbnailURL(for: personId) else { return }
      do {
        let data = try await client.thumbnailData(for: url)
        if let decoded = UIImage(data: data) {
          NativePersonAvatarCache.shared.setObject(decoded, forKey: key)
          self.image = decoded
        }
      } catch {
        // Fallback to placeholder on error
      }
    }
  }
}

enum PeopleFilterMode: String, CaseIterable, Identifiable {
  case all = "全部"
  case named = "已命名"
  case unnamed = "未命名"
  var id: String { rawValue }
}

struct NativePeopleView: View {
  let client: NativeImmichClient
  @State private var people: [[String: Any]] = []
  @State private var page = 1
  @State private var hasMore = true
  @State private var loading = false
  @State private var error: String?
  @State private var filterMode: PeopleFilterMode = .all
  @State private var searchText = ""

  @State private var renamingPersonId: String?
  @State private var renamingName: String = ""
  @State private var showRenameAlert = false

  private var sortedAndFilteredPeople: [[String: Any]] {
    let filtered = people.filter { person in
      let name = ((person["name"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
      switch filterMode {
      case .all: break
      case .named: guard !name.isEmpty else { return false }
      case .unnamed: guard name.isEmpty else { return false }
      }
      if searchText.isEmpty { return true }
      return name.localizedCaseInsensitiveContains(searchText)
    }
    return filtered.sorted { a, b in
      let nameA = ((a["name"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
      let nameB = ((b["name"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
      if !nameA.isEmpty && !nameB.isEmpty {
        return nameA.localizedStandardCompare(nameB) == .orderedAscending
      }
      if !nameA.isEmpty && nameB.isEmpty { return true }
      if nameA.isEmpty && !nameB.isEmpty { return false }
      return false
    }
  }

  var body: some View {
    VStack(spacing: 0) {
      Picker("筛选", selection: $filterMode) {
        ForEach(PeopleFilterMode.allCases) { mode in
          Text(mode.rawValue).tag(mode)
        }
      }
      .pickerStyle(.segmented)
      .padding(.horizontal)
      .padding(.vertical, 8)

      List {
        if let error {
          Text(error).foregroundColor(.red)
          Button("重试") { Task { await load() } }
        }
        if !loading && sortedAndFilteredPeople.isEmpty && error == nil {
          Text(emptyMessage).foregroundColor(.secondary)
        }
        ForEach(sortedAndFilteredPeople.indices, id: \.self) { idx in
          let person = sortedAndFilteredPeople[idx]
          if let id = person["id"] as? String {
            let name = ((person["name"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            NavigationLink {
              NativePersonDetailView(
                client: client,
                personId: id,
                initialName: name,
                onNameUpdated: { newName in
                  updateLocalName(id: id, name: newName)
                }
              )
            } label: {
              HStack(spacing: 12) {
                NativePersonAvatarView(client: client, personId: id, size: 48)
                VStack(alignment: .leading, spacing: 3) {
                  if !name.isEmpty {
                    Text(name)
                      .font(.body)
                      .fontWeight(.medium)
                  } else {
                    HStack(spacing: 4) {
                      Text("未命名")
                        .font(.body)
                        .foregroundColor(.secondary)
                      Text("· 添加姓名")
                        .font(.caption)
                        .foregroundColor(.accentColor)
                    }
                  }
                }
                Spacer()
                Button {
                  renamingPersonId = id
                  renamingName = name
                  showRenameAlert = true
                } label: {
                  Image(systemName: name.isEmpty ? "plus.circle" : "pencil")
                    .font(.system(size: 16))
                    .foregroundColor(.secondary)
                    .padding(6)
                }
                .buttonStyle(BorderlessButtonStyle())
              }
              .padding(.vertical, 2)
            }
          }
        }
        if hasMore {
          Button(loading ? "加载中…" : "加载更多") { Task { await load() } }
            .disabled(loading)
        }
      }
      .searchable(text: $searchText, prompt: "搜索姓名")
    }
    .navigationTitle("人物")
    .alert("设置姓名", isPresented: $showRenameAlert) {
      TextField("姓名", text: $renamingName)
      Button("保存") {
        if let id = renamingPersonId {
          let trimmed = renamingName.trimmingCharacters(in: .whitespacesAndNewlines)
          Task { await savePersonName(id: id, name: trimmed) }
        }
      }
      Button("取消", role: .cancel) {}
    } message: {
      Text("请输入此人物的姓名：")
    }
    .task { if people.isEmpty { await load() } }
  }

  private var emptyMessage: String {
    switch filterMode {
    case .all: return "暂无人物"
    case .named: return "暂无已命名人物"
    case .unnamed: return "暂无未命名人物"
    }
  }

  private func updateLocalName(id: String, name: String) {
    if let idx = people.firstIndex(where: { ($0["id"] as? String) == id }) {
      people[idx]["name"] = name
    }
  }

  private func savePersonName(id: String, name: String) async {
    do {
      _ = try await client.updatePerson(id: id, name: name)
      updateLocalName(id: id, name: name)
    } catch {
      self.error = "更新姓名失败：\(error.localizedDescription)"
    }
  }

  private func load() async {
    guard !loading && hasMore else { return }
    loading = true
    defer { loading = false }
    do {
      let response = try await client.send(
        path: "people",
        query: [URLQueryItem(name: "page", value: String(page)), URLQueryItem(name: "size", value: "200")]
      )
      guard let rows = response["people"] as? [[String: Any]] else { throw NativeLibraryError.invalidResponse }
      people += rows
      hasMore = response["hasNextPage"] as? Bool ?? false
      page += 1
      error = nil
    } catch {
      self.error = error.localizedDescription
    }
  }
}

struct NativePersonDetailView: View {
  let client: NativeImmichClient
  let personId: String
  @State var name: String
  let onNameUpdated: (String) -> Void

  @State private var showRenameAlert = false
  @State private var newName = ""

  init(client: NativeImmichClient, personId: String, initialName: String, onNameUpdated: @escaping (String) -> Void) {
    self.client = client
    self.personId = personId
    self._name = State(initialValue: initialName)
    self.onNameUpdated = onNameUpdated
  }

  var body: some View {
    VStack(spacing: 0) {
      HStack(spacing: 16) {
        NativePersonAvatarView(client: client, personId: personId, size: 60)
        VStack(alignment: .leading, spacing: 4) {
          Text(name.isEmpty ? "未命名人物" : name)
            .font(.title3)
            .fontWeight(.bold)
          Button {
            newName = name
            showRenameAlert = true
          } label: {
            Label(name.isEmpty ? "添加姓名" : "编辑姓名", systemImage: "pencil")
              .font(.footnote)
          }
        }
        Spacer()
      }
      .padding()
      .background(Color(UIColor.secondarySystemBackground))

      NativeFilteredView(
        client: client,
        title: name.isEmpty ? "人物照片" : name,
        filter: ["personIds": ["any": [personId]]]
      )
    }
    .navigationTitle(name.isEmpty ? "人物" : name)
    .navigationBarTitleDisplayMode(.inline)
    .alert("编辑姓名", isPresented: $showRenameAlert) {
      TextField("姓名", text: $newName)
      Button("保存") {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        Task {
          do {
            _ = try await client.updatePerson(id: personId, name: trimmed)
            self.name = trimmed
            onNameUpdated(trimmed)
          } catch {
            // Error handling
          }
        }
      }
      Button("取消", role: .cancel) {}
    }
  }
}

final class NativePlacesCache {
  static let shared = NativePlacesCache()
  var places: [String: (count: Int, sampleId: String?)]?
  var markers: [NativeMapPin]?
  var center: CLLocationCoordinate2D?
  var span: MKCoordinateSpan?
  var lastUpdated: Date?
}

struct NativePlacesView: View {
  let client: NativeImmichClient
  @State private var places: [String: (count: Int, sampleId: String?)] = NativePlacesCache.shared.places ?? [:]
  @State private var markers: [NativeMapPin] = NativePlacesCache.shared.markers ?? []
  @State private var error: String?
  @State private var loading = false
  @State private var region: MKCoordinateRegion

  init(client: NativeImmichClient) {
    self.client = client
    if let c = NativePlacesCache.shared.center, let s = NativePlacesCache.shared.span {
      _region = State(initialValue: MKCoordinateRegion(center: c, span: s))
    } else {
      _region = State(initialValue: MKCoordinateRegion(
        center: CLLocationCoordinate2D(latitude: 35.0, longitude: 105.0),
        span: MKCoordinateSpan(latitudeDelta: 60, longitudeDelta: 60)
      ))
    }
  }

  var body: some View {
    VStack(spacing: 0) {
      Map(coordinateRegion: $region, annotationItems: markers) { pin in
        MapMarker(coordinate: pin.coordinate)
      }
      .frame(height: 240)

      List {
        if loading && places.isEmpty {
          ProgressView("正在加载地点…")
        }
        if let error {
          Text(error).foregroundColor(.red)
          Button("重试") { Task { await load() } }
        }
        if places.isEmpty && !loading && error == nil {
          Text("暂无带位置的照片").foregroundColor(.secondary)
        }
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
    .task {
      if places.isEmpty {
        await load()
      } else {
        Task.detached { await self.loadSilently() }
      }
    }
  }

  private func load() async {
    loading = true
    defer { loading = false }
    await loadSilently()
  }

  private func loadSilently() async {
    do {
      let rows = try await client.libraryRows("map/markers")
      let processed = await Task.detached(priority: .userInitiated) { () -> (totals: [String: (count: Int, sampleId: String?)], pins: [NativeMapPin], center: CLLocationCoordinate2D?, span: MKCoordinateSpan?) in
        var totals: [String: (count: Int, sampleId: String?)] = [:]
        var placeCoords: [String: CLLocationCoordinate2D] = [:]
        var minLat = 90.0, maxLat = -90.0, minLon = 180.0, maxLon = -180.0
        var hasValid = false

        for row in rows {
          let place = [row["city"], row["state"], row["country"]].compactMap { $0 as? String }.first(where: { !$0.isEmpty }) ?? "未知地点"
          let id = row["id"] as? String
          let current = totals[place] ?? (count: 0, sampleId: id)
          totals[place] = (count: current.count + 1, sampleId: current.sampleId ?? id)

          if let lat = row["lat"] as? Double, let lon = row["lon"] as? Double,
             (-90...90).contains(lat), (-180...180).contains(lon) {
            if placeCoords[place] == nil {
              placeCoords[place] = CLLocationCoordinate2D(latitude: lat, longitude: lon)
            }
            minLat = min(minLat, lat)
            maxLat = max(maxLat, lat)
            minLon = min(minLon, lon)
            maxLon = max(maxLon, lon)
            hasValid = true
          }
        }

        var pins: [NativeMapPin] = []
        for (place, coord) in placeCoords.prefix(100) {
          let pinId = totals[place]?.sampleId ?? UUID().uuidString
          pins.append(NativeMapPin(id: pinId, coordinate: coord))
        }

        var center: CLLocationCoordinate2D?
        var span: MKCoordinateSpan?
        if hasValid {
          let cLat = (minLat + maxLat) / 2
          let cLon = (minLon + maxLon) / 2
          let dLat = max(abs(maxLat - minLat) * 1.3, 2.0)
          let dLon = max(abs(maxLon - minLon) * 1.3, 2.0)
          center = CLLocationCoordinate2D(latitude: cLat, longitude: cLon)
          span = MKCoordinateSpan(latitudeDelta: min(dLat, 150), longitudeDelta: min(dLon, 150))
        }
        return (totals, pins, center, span)
      }.value

      await MainActor.run {
        self.places = processed.totals
        self.markers = processed.pins
        if let c = processed.center, let s = processed.span {
          self.region = MKCoordinateRegion(center: c, span: s)
          NativePlacesCache.shared.center = c
          NativePlacesCache.shared.span = s
        }
        NativePlacesCache.shared.places = processed.totals
        NativePlacesCache.shared.markers = processed.pins
        NativePlacesCache.shared.lastUpdated = Date()
        self.error = nil
      }
    } catch {
      await MainActor.run { self.error = error.localizedDescription }
    }
  }
}

private struct NativeMapPin: Identifiable {
  let id: String
  let coordinate: CLLocationCoordinate2D
}

struct NativeMemoryCoverThumb: View {
  let client: NativeImmichClient
  let url: URL
  @State private var image: UIImage?

  var body: some View {
    Group {
      if let image {
        Image(uiImage: image)
          .resizable()
          .scaledToFill()
          .frame(width: 56, height: 56)
          .clipShape(RoundedRectangle(cornerRadius: 8))
      } else {
        RoundedRectangle(cornerRadius: 8)
          .fill(Color(UIColor.secondarySystemBackground))
          .frame(width: 56, height: 56)
          .overlay(Image(systemName: "photo").foregroundColor(.secondary))
      }
    }
    .task(id: url) {
      if let data = try? await client.thumbnailData(for: url),
         let decoded = UIImage(data: data) {
        self.image = decoded
      }
    }
  }
}

struct NativeMemoriesView: View {
  let client: NativeImmichClient
  @State private var memories: [[String: Any]] = []
  @State private var loading = false
  @State private var error: String?

  var body: some View {
    List {
      if loading && memories.isEmpty { ProgressView() }
      if let error {
        Text(error).foregroundColor(.red)
        Button("重试") { Task { await load() } }
      }
      if !loading && error == nil && memories.isEmpty {
        Text("暂无回忆").foregroundColor(.secondary)
      }
      ForEach(memories.indices, id: \.self) { index in
        let memory = memories[index]
        let title = memoryTitle(for: memory)
        let detail = memoryDetail(for: memory)
        let assets = (memory["assets"] as? [[String: Any]])?.compactMap(NativeImmichClient.decodeAsset) ?? []

        NavigationLink {
          NativeMemoryDetailView(client: client, title: title, detail: detail, assets: assets)
        } label: {
          HStack(spacing: 14) {
            if let firstAsset = assets.first, let url = client.thumbnailURL(for: firstAsset) {
              NativeMemoryCoverThumb(client: client, url: url)
            } else {
              RoundedRectangle(cornerRadius: 8)
                .fill(Color(UIColor.secondarySystemBackground))
                .frame(width: 56, height: 56)
                .overlay(Image(systemName: "sparkles").foregroundColor(.secondary))
            }

            VStack(alignment: .leading, spacing: 4) {
              Text(title)
                .font(.headline)
              if !detail.isEmpty {
                Text(detail)
                  .font(.subheadline)
                  .foregroundColor(.secondary)
              }
            }
            Spacer()
          }
          .padding(.vertical, 4)
        }
      }
    }
    .navigationTitle("回忆")
    .refreshable { await load() }
    .task { if memories.isEmpty { await load() } }
  }

  private func load() async {
    guard !loading else { return }
    loading = true
    defer { loading = false }
    do {
      memories = try await client.libraryRows("memories")
      error = nil
    } catch {
      self.error = error.localizedDescription
    }
  }

  private func memoryTitle(for row: [String: Any]) -> String {
    let year = (row["data"] as? [String: Any])?["year"] as? Int
    if let year {
      let currentYear = Calendar.current.component(.year, from: Date())
      let diff = currentYear - year
      if diff > 0 {
        return "\(diff) 年前的今天 (\(year)年)"
      } else {
        return "那年今日 (\(year)年)"
      }
    }
    if let memoryAtStr = row["memoryAt"] as? String,
       let date = NativeImmichClient.parseISODate(memoryAtStr) {
      let fmt = DateFormatter()
      fmt.dateFormat = "M月d日的回忆"
      return fmt.string(from: date)
    }
    return "那年今日"
  }

  private func memoryDetail(for row: [String: Any]) -> String {
    var parts: [String] = []
    if let memoryAtStr = row["memoryAt"] as? String,
       let date = NativeImmichClient.parseISODate(memoryAtStr) {
      let fmt = DateFormatter()
      fmt.dateFormat = "yyyy年M月d日"
      parts.append(fmt.string(from: date))
    }
    if let assets = row["assets"] as? [Any] {
      parts.append("\(assets.count) 张照片")
    }
    return parts.joined(separator: " · ")
  }
}

struct NativeMemoryDetailView: View {
  let client: NativeImmichClient
  let title: String
  let detail: String
  let assets: [NativeAsset]

  var body: some View {
    VStack(spacing: 0) {
      if !detail.isEmpty {
        HStack {
          Text(detail)
            .font(.footnote)
            .foregroundColor(.secondary)
          Spacer()
        }
        .padding(.horizontal)
        .padding(.vertical, 6)
      }
      NativeResultGrid(client: client, assets: assets, hasOlder: false, loadMore: {})
    }
    .navigationTitle(title)
  }
}

struct NativeSharedLinksView: View {
  let client: NativeImmichClient
  @State private var links: [[String: Any]] = []
  @State private var loading = false
  @State private var error: String?
  @State private var showCopiedAlert = false

  var body: some View {
    List {
      if loading && links.isEmpty { ProgressView() }
      if let error {
        Text(error).foregroundColor(.red)
        Button("重试") { Task { await load() } }
      }
      if !loading && error == nil && links.isEmpty {
        Text("暂无共享链接").foregroundColor(.secondary)
      }
      ForEach(links.indices, id: \.self) { index in
        let link = links[index]
        let id = link["id"] as? String ?? "\(index)"
        NavigationLink {
          NativeSharedLinkEditView(
            client: client,
            link: link,
            onUpdated: { updated in
              if index < links.count { links[index] = updated }
            },
            onDeleted: {
              if index < links.count { links.remove(at: index) }
            }
          )
        } label: {
          SharedLinkRowView(client: client, link: link, onCopy: { url in
            UIPasteboard.general.string = url
            showCopiedAlert = true
          })
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
          Button(role: .destructive) {
            Task { await deleteLink(id: id, at: index) }
          } label: {
            Label("删除", systemImage: "trash")
          }
        }
      }
    }
    .navigationTitle("共享链接")
    .alert("已复制", isPresented: $showCopiedAlert) {
      Button("确定", role: .cancel) {}
    } message: {
      Text("共享链接已复制到剪贴板。")
    }
    .refreshable { await load() }
    .task { if links.isEmpty { await load() } }
  }

  private func load() async {
    guard !loading else { return }
    loading = true
    defer { loading = false }
    do {
      links = try await client.libraryRows("shared-links")
      error = nil
    } catch {
      self.error = error.localizedDescription
    }
  }

  private func deleteLink(id: String, at index: Int) async {
    do {
      _ = try await client.send(path: "shared-links/\(id)", method: "DELETE")
      if index < links.count { links.remove(at: index) }
    } catch {
      self.error = "删除共享链接失败：\(error.localizedDescription)"
    }
  }
}

struct SharedLinkRowView: View {
  let client: NativeImmichClient
  let link: [String: Any]
  let onCopy: (String) -> Void

  private var title: String {
    if let desc = link["description"] as? String, !desc.isEmpty { return desc }
    if let album = link["album"] as? [String: Any], let name = album["albumName"] as? String, !name.isEmpty {
      return name
    }
    if let slug = link["slug"] as? String, !slug.isEmpty { return "/s/\(slug)" }
    return "共享链接"
  }

  private var shareURL: String {
    let key = link["key"] as? String ?? ""
    let slug = link["slug"] as? String
    return client.sharedLinkURL(key: key, slug: slug)
  }

  private var expirationText: String {
    if let expiresAtStr = link["expiresAt"] as? String,
       let date = NativeImmichClient.parseISODate(expiresAtStr) {
      let isPast = date < Date()
      let fmt = DateFormatter()
      fmt.dateFormat = "yyyy-MM-dd HH:mm"
      let dateString = fmt.string(from: date)
      return isPast ? "已过期 (\(dateString))" : "到期: \(dateString)"
    }
    return "永不过期"
  }

  private var isExpired: Bool {
    if let expiresAtStr = link["expiresAt"] as? String,
       let date = NativeImmichClient.parseISODate(expiresAtStr) {
      return date < Date()
    }
    return false
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      HStack {
        Text(title)
          .font(.headline)
          .foregroundColor(isExpired ? .secondary : .primary)
        Spacer()
        Button {
          onCopy(shareURL)
        } label: {
          Image(systemName: "doc.on.doc")
            .font(.footnote)
            .foregroundColor(.secondary)
        }
        .buttonStyle(BorderlessButtonStyle())
      }

      HStack(spacing: 8) {
        Text(expirationText)
          .font(.caption)
          .foregroundColor(isExpired ? .red : .secondary)

        let isAlbum = (link["album"] != nil) || ((link["type"] as? String) == "ALBUM")
        Text(isAlbum ? "相册共享" : "散选照片")
          .font(.caption2)
          .padding(.horizontal, 6)
          .padding(.vertical, 2)
          .background(Color(UIColor.tertiarySystemFill))
          .cornerRadius(4)
      }

      HStack(spacing: 6) {
        if link["allowDownload"] as? Bool == true {
          tagView("允许下载", color: .blue)
        }
        if link["allowUpload"] as? Bool == true {
          tagView("允许上传", color: .green)
        }
        if link["showMetadata"] as? Bool == true {
          tagView("显示信息", color: .purple)
        }
        if link["password"] != nil && !(link["password"] is NSNull) {
          tagView("密码保护", color: .orange)
        }
      }
    }
    .padding(.vertical, 4)
  }

  private func tagView(_ text: String, color: Color) -> some View {
    Text(text)
      .font(.system(size: 10, weight: .medium))
      .padding(.horizontal, 5)
      .padding(.vertical, 2)
      .background(color.opacity(0.15))
      .foregroundColor(color)
      .cornerRadius(4)
  }
}

struct NativeSharedLinkEditView: View {
  let client: NativeImmichClient
  let link: [String: Any]
  let onUpdated: ([String: Any]) -> Void
  let onDeleted: () -> Void

  @Environment(\.dismiss) private var dismiss

  @State private var description: String
  @State private var slug: String
  @State private var password: String
  @State private var hasPassword: Bool
  @State private var allowDownload: Bool
  @State private var allowUpload: Bool
  @State private var showMetadata: Bool
  @State private var hasExpiration: Bool
  @State private var expiresAt: Date

  @State private var isSaving = false
  @State private var errorMessage: String?
  @State private var showDeleteConfirm = false
  @State private var showCopiedAlert = false

  init(client: NativeImmichClient, link: [String: Any], onUpdated: @escaping ([String: Any]) -> Void, onDeleted: @escaping () -> Void) {
    self.client = client
    self.link = link
    self.onUpdated = onUpdated
    self.onDeleted = onDeleted

    _description = State(initialValue: link["description"] as? String ?? "")
    _slug = State(initialValue: link["slug"] as? String ?? "")
    let hadPw = link["password"] != nil && !(link["password"] is NSNull)
    _password = State(initialValue: "")
    _hasPassword = State(initialValue: hadPw)
    _allowDownload = State(initialValue: link["allowDownload"] as? Bool ?? true)
    _allowUpload = State(initialValue: link["allowUpload"] as? Bool ?? false)
    _showMetadata = State(initialValue: link["showMetadata"] as? Bool ?? true)

    if let expStr = link["expiresAt"] as? String,
       let expDate = NativeImmichClient.parseISODate(expStr) {
      _hasExpiration = State(initialValue: true)
      _expiresAt = State(initialValue: expDate)
    } else {
      _hasExpiration = State(initialValue: false)
      _expiresAt = State(initialValue: Date().addingTimeInterval(86400 * 30))
    }
  }

  private var linkId: String {
    link["id"] as? String ?? ""
  }

  private var shareURL: String {
    let key = link["key"] as? String ?? ""
    return client.sharedLinkURL(key: key, slug: slug)
  }

  private var assets: [NativeAsset] {
    (link["assets"] as? [[String: Any]])?.compactMap(NativeImmichClient.decodeAsset) ?? []
  }

  var body: some View {
    Form {
      Section("链接地址") {
        VStack(alignment: .leading, spacing: 8) {
          Text(shareURL)
            .font(.footnote.monospaced())
            .foregroundColor(.secondary)
            .lineLimit(2)
          Button {
            UIPasteboard.general.string = shareURL
            showCopiedAlert = true
          } label: {
            Label("复制共享链接", systemImage: "doc.on.doc")
          }
        }
      }

      Section("基本信息") {
        HStack {
          Text("描述")
          TextField("如：家庭聚会照片", text: $description)
            .multilineTextAlignment(.trailing)
        }
        HStack {
          Text("自定义后缀")
          TextField("如：family-trip", text: $slug)
            .multilineTextAlignment(.trailing)
            .autocapitalization(.none)
            .disableAutocorrection(true)
        }
      }

      Section("访问保护") {
        HStack {
          Text("密码")
          SecureField(hasPassword ? "已设置 (输入新密码修改)" : "未设置密码", text: $password)
            .multilineTextAlignment(.trailing)
        }
        if hasPassword && password.isEmpty {
          Button("清除现有密码", role: .destructive) {
            hasPassword = false
            password = ""
          }
          .font(.footnote)
        }

        Toggle("设置到期时间", isOn: $hasExpiration)
        if hasExpiration {
          DatePicker("到期时间", selection: $expiresAt, in: Date()...)
        }
      }

      Section("权限与功能开关") {
        Toggle("显示详细信息 (EXIF/元数据)", isOn: $showMetadata)
          .onChange(of: showMetadata) { newValue in
            if !newValue { allowDownload = false }
          }
        Toggle("允许公开用户下载", isOn: $allowDownload)
          .disabled(!showMetadata)
        Toggle("允许公开用户上传", isOn: $allowUpload)
      }

      if !assets.isEmpty {
        Section("共享照片") {
          NavigationLink("查看共享的照片 (\(assets.count) 张)") {
            NativeResultGrid(client: client, assets: assets, hasOlder: false, loadMore: {})
              .navigationTitle("共享照片")
          }
        }
      }

      if let errorMessage {
        Section {
          Text(errorMessage).foregroundColor(.red).font(.footnote)
        }
      }

      Section {
        Button {
          Task { await saveChanges() }
        } label: {
          HStack {
            Spacer()
            if isSaving {
              ProgressView()
            } else {
              Text("保存修改").fontWeight(.semibold)
            }
            Spacer()
          }
        }
        .disabled(isSaving)

        Button("删除共享链接", role: .destructive) {
          showDeleteConfirm = true
        }
      }
    }
    .navigationTitle("编辑共享链接")
    .alert("已复制", isPresented: $showCopiedAlert) {
      Button("确定", role: .cancel) {}
    } message: {
      Text("共享链接已复制到剪贴板。")
    }
    .alert("确定删除？", isPresented: $showDeleteConfirm) {
      Button("删除", role: .destructive) {
        Task { await deleteLink() }
      }
      Button("取消", role: .cancel) {}
    } message: {
      Text("删除后，该共享链接将永久失效，已分享的用户将无法再访问。")
    }
  }

  private func saveChanges() async {
    guard !isSaving else { return }
    isSaving = true
    errorMessage = nil
    defer { isSaving = false }

    var body: [String: Any] = [
      "description": description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? NSNull() : description.trimmingCharacters(in: .whitespacesAndNewlines),
      "slug": slug.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? NSNull() : slug.trimmingCharacters(in: .whitespacesAndNewlines),
      "allowDownload": showMetadata ? allowDownload : false,
      "allowUpload": allowUpload,
      "showMetadata": showMetadata,
    ]

    if hasExpiration {
      let iso = ISO8601DateFormatter()
      iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
      body["expiresAt"] = iso.string(from: expiresAt)
    } else {
      body["expiresAt"] = NSNull()
    }

    if !password.isEmpty {
      body["password"] = password
    } else if !hasPassword {
      body["password"] = NSNull()
    }

    do {
      let updated = try await client.send(path: "shared-links/\(linkId)", method: "PATCH", body: body)
      onUpdated(updated.isEmpty ? link : updated)
      dismiss()
    } catch {
      errorMessage = "保存失败：\(error.localizedDescription)"
    }
  }

  private func deleteLink() async {
    do {
      _ = try await client.send(path: "shared-links/\(linkId)", method: "DELETE")
      onDeleted()
      dismiss()
    } catch {
      errorMessage = "删除失败：\(error.localizedDescription)"
    }
  }
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


