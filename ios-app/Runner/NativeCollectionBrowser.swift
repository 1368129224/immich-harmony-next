import Photos
import SwiftUI

/// Shared selection actions for Photos, album contents and memory contents.
struct NativePhotoBatchToolbar: View {
  let count: Int
  let hasServer: Bool
  let busy: Bool
  let share: () -> Void
  let favorite: () -> Void
  let archive: () -> Void
  let addToAlbum: () -> Void
  let save: () -> Void
  let delete: () -> Void
  var removeFromAlbum: (() -> Void)? = nil

  var body: some View {
    HStack(spacing: 0) {
      action("square.and.arrow.up", "分享", disabled: count == 0, run: share)
      action("heart", "收藏", disabled: count == 0, run: favorite)
      action("archivebox", "归档", disabled: !hasServer, run: archive)
      action("plus.rectangle.on.folder", "加入相册", disabled: count == 0, run: addToAlbum)
      action("square.and.arrow.down", "保存", disabled: !hasServer, run: save)
      if let removeFromAlbum {
        action("folder.badge.minus", "移出相册", disabled: count == 0, run: removeFromAlbum)
      }
      action("trash", "删除", disabled: count == 0, destructive: true, run: delete)
    }
    .padding(.horizontal, 16)
    .padding(.vertical, 10)
    .background(.ultraThinMaterial)
  }

  private func action(_ symbol: String, _ title: String, disabled: Bool, destructive: Bool = false, run: @escaping () -> Void) -> some View {
    Button(action: run) {
      VStack(spacing: 3) {
        Image(systemName: symbol).font(.system(size: 18, weight: .medium))
        Text(title).font(.system(size: 10, weight: .medium)).lineLimit(1).minimumScaleFactor(0.8)
      }
      .foregroundColor(disabled || busy ? .secondary : (destructive ? .red : .primary))
      .frame(maxWidth: .infinity, minHeight: 42)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .disabled(disabled || busy)
    .accessibilityLabel(title)
  }
}

/// The same browser is used by memory details and album contents. Selection and
/// action targets both come from nativeCollectionGridItems, never separate merges.
struct NativeCollectionBrowser: View {
  let client: NativeImmichClient
  @ObservedObject var device: NativeDeviceLibrary
  let title: String
  var subtitle = ""
  var emptyMessage = "暂无照片"
  let assets: [NativeAsset]
  var localAssets: [NativeDeviceAsset] = []
  var hasOlder = false
  var initialPositionReady = true
  var loading = false
  var loadError: String? = nil
  var serverAlbumID: String? = nil
  var localAlbumID: String? = nil
  var loadMore: () -> Void = {}
  var refresh: () async -> Void = {}

  @State private var isSelecting = false
  @State private var selectedIDs = Set<String>()
  @State private var latestRequest = 0
  @State private var busy = false
  @State private var message: String?
  @State private var sharePayload: NativeSharePayload?
  @State private var showDelete = false
  @State private var showRemove = false
  @State private var showSave = false
  @State private var showAlbumTarget = false
  @State private var showLocalAlbumPicker = false
  @State private var showServerAlbumPicker = false
  @State private var pendingTargets: [NativeGridItem] = []
  @State private var hiddenServerIDs = Set<String>()
  @State private var hiddenLocalIDs = Set<String>()
  @State private var serverOverrides: [String: NativeAsset] = [:]
  @State private var localFavoriteOverrides: [String: Bool] = [:]

  private var visibleServers: [NativeAsset] {
    assets.filter { !hiddenServerIDs.contains($0.id) }.map { serverOverrides[$0.id] ?? $0 }
  }

  private var visibleLocals: [NativeDeviceAsset] {
    localAssets.filter { !hiddenLocalIDs.contains($0.id) }.map { source in
      var local = source
      if let favorite = localFavoriteOverrides[local.id] { local.isFavorite = favorite }
      return local
    }
  }

  private var items: [NativeGridItem] {
    nativeCollectionGridItems(assets: visibleServers, localAssets: visibleLocals,
      matchedServerIDs: NativeSyncCacheStore.shared.matchedServerIDs)
  }

  private var selectedTargets: [NativeGridItem] { items.filter { selectedIDs.contains($0.id) } }
  private var canRemove: Bool { serverAlbumID != nil || localAlbumID != nil }

  var body: some View {
    VStack(spacing: 0) {
      if let loadError {
        HStack {
          Text(loadError).font(.caption).foregroundColor(.red)
          Button("重试") { Task { await refresh() } }.disabled(busy || loading)
        }.padding(6)
      }
      if !subtitle.isEmpty { Text(subtitle).font(.footnote).foregroundColor(.secondary).padding(6) }
      if initialPositionReady && !loading && loadError == nil && items.isEmpty {
        Text(emptyMessage).foregroundColor(.secondary).padding()
      }
      NativeResultGrid(
        client: client, assets: visibleServers, localAssets: visibleLocals,
        hasOlder: hasOlder, startsAtLatest: true, initialPositionReady: initialPositionReady,
        latestRequest: latestRequest, device: device,
        onDeleteItem: { item, scope in applyDeletion([item], scope: scope) },
        onServerAssetUpdated: { serverOverrides[$0.id] = $0 },
        onServerAssetArchived: { id in hiddenServerIDs.insert(id) },
        isSelecting: $isSelecting, selectedIDs: $selectedIDs, loadMore: loadMore
      )
      if loading { ProgressView().padding(6) }
    }
    .navigationTitle(title)
    .navigationBarTitleDisplayMode(.inline)
    .toolbar {
      ToolbarItem(placement: .navigationBarLeading) {
        if isSelecting { Button("取消") { clearSelection() }.disabled(busy) }
      }
      ToolbarItem(placement: .principal) {
        if isSelecting { Text("已选 \(selectedIDs.count) 项").font(.headline) }
      }
      ToolbarItem(placement: .navigationBarTrailing) {
        Button(isSelecting ? (selectedIDs.count == items.count && !items.isEmpty ? "取消全选" : "全选") : "选择") {
          if isSelecting {
            let all = Set(items.map(\.id))
            selectedIDs = selectedIDs == all ? [] : all
          } else { isSelecting = true }
        }
        .disabled(busy || items.isEmpty)
        .accessibilityHint(isSelecting ? "仅选择当前已加载的照片" : "进入多选")
      }
    }
    .safeAreaInset(edge: .bottom, spacing: 0) {
      // Both layers reserve one footprint: entering/cancelling selection must
      // not resize the scroll viewport and shift the current photo position.
      ZStack(alignment: .bottom) {
        NativePhotoBatchToolbar(
          count: selectedIDs.count, hasServer: selectedTargets.contains { $0.server != nil }, busy: busy,
          share: { Task { await shareSelected() } },
          favorite: { Task { await favoriteSelected() } },
          archive: { Task { await archiveSelected() } },
          addToAlbum: { pendingTargets = selectedTargets; showAlbumTarget = true },
          save: { pendingTargets = selectedTargets; showSave = true },
          delete: { pendingTargets = selectedTargets; showDelete = true },
          removeFromAlbum: canRemove ? { pendingTargets = selectedTargets; showRemove = true } : nil
        )
        .opacity(isSelecting ? 1 : 0)
        .allowsHitTesting(isSelecting && !busy)
        .accessibilityHidden(!isSelecting)
        HStack {
          if busy { ProgressView() }
          Text(message ?? "\(items.count) 项").font(.caption).lineLimit(2)
          Spacer(minLength: 4)
          if message != nil { Button("关闭提示") { message = nil }.font(.caption) }
          Button("最新") { latestRequest += 1 }
        }
        .padding(.horizontal, 16).frame(minHeight: 62)
        .background(.ultraThinMaterial)
        .opacity(isSelecting ? 0 : 1)
        .allowsHitTesting(!isSelecting)
        .accessibilityHidden(isSelecting)
      }
    }
    .refreshable { if !busy { await refresh() } }
    .onChange(of: items.map(\.id)) { ids in selectedIDs.formIntersection(ids) }
    .sheet(item: $sharePayload) { NativeActivityView(activityItems: $0.content) }
    .sheet(isPresented: $showLocalAlbumPicker) {
      NativePhotosLocalAlbumPicker(albums: device.albums) { id in Task { await addToLocalAlbum(id) } }
    }
    .sheet(isPresented: $showServerAlbumPicker) {
      NativePhotosServerAlbumPicker(client: client) { id in Task { await addToServerAlbum(id) } }
    }
    .confirmationDialog("选择相册来源", isPresented: $showAlbumTarget, titleVisibility: .visible) {
      if pendingTargets.contains(where: { $0.local != nil }) { Button("加入本机相册") { showLocalAlbumPicker = true } }
      if pendingTargets.contains(where: { $0.server != nil }) { Button("加入云端相册") { showServerAlbumPicker = true } }
      Button("取消", role: .cancel) {}
    } message: { Text("只操作已有副本，不会自动上传或补齐另一端。") }
    .confirmationDialog("删除选中的照片", isPresented: $showDelete, titleVisibility: .visible) {
      if pendingTargets.contains(where: { $0.server != nil }) {
        Button("删除所选副本（云端移入回收站）", role: .destructive) { Task { await deleteSelected(scope: .all) } }
      }
      if pendingTargets.contains(where: { $0.local != nil }) {
        Button("仅删除本机照片", role: .destructive) { Task { await deleteSelected(scope: .localOnly) } }
      }
      Button("取消", role: .cancel) {}
    } message: {
      Text("这不是移出相册。本机未同步原件删除后可能丢失；系统图库删除可能影响 iCloud。云端可否恢复由服务器配置决定。")
    }
    .confirmationDialog("移出当前相册", isPresented: $showRemove, titleVisibility: .visible) {
      Button("仅从当前相册移出", role: .destructive) { Task { await removeSelectedFromAlbum() } }
      Button("取消", role: .cancel) {}
    } message: { Text("只解除当前相册的成员关系，不删除照片原件。合并相册会分别操作所选的本机和云端成员。") }
    .alert("保存到系统照片", isPresented: $showSave) {
      Button("取消", role: .cancel) {}
      Button("继续保存") { Task { await saveSelected() } }
    } message: { Text("下载云端原件并写入系统照片；已有本机副本的项目可能产生重复照片。") }
    .alert("操作结果", isPresented: Binding(get: { message != nil && isSelecting && sharePayload == nil }, set: { if !$0 { message = nil } })) {
      Button("好", role: .cancel) { message = nil }
    } message: { Text(message ?? "") }
  }

  private func clearSelection() { isSelecting = false; selectedIDs = [] }

  private func applyDeletion(_ targets: [NativeGridItem], scope: NativeDeleteTargetScope) {
    if scope == .all { hiddenServerIDs.formUnion(targets.compactMap { $0.server?.id }) }
    let locals = Set(targets.compactMap { $0.local?.id })
    hiddenLocalIDs.formUnion(locals)
    NativeSyncCacheStore.shared.removeMatches(localIDs: locals)
    clearSelection()
    device.refresh()
  }

  private func deleteSelected(scope: NativeDeleteTargetScope) async {
    guard !busy else { return }
    busy = true
    defer { busy = false }
    let targets = pendingTargets
    do {
      try await nativeDeleteGridItems(targets, scope: scope, client: client, device: device)
      applyDeletion(targets, scope: scope)
      message = "删除成功；仅删除本机时云端原件保留。"
    } catch {
      if let partial = error as? NativeDeleteOperationError {
        hiddenServerIDs.formUnion(partial.deletedServerIDs)
        NativeSyncCacheStore.shared.removeMatches(localIDs: Set(targets.compactMap { item in
          guard let server = item.server, partial.deletedServerIDs.contains(server.id) else { return nil }
          return item.local?.id
        }))
      }
      message = "删除未全部成功：\(error.localizedDescription)"
    }
  }

  private func shareSelected() async {
    guard !busy else { return }
    let targets = selectedTargets
    busy = true
    defer { busy = false }
    let result = await nativePrepareBatchShare(items: targets, client: client)
    if !result.files.isEmpty { sharePayload = NativeSharePayload(contents: result.files) }
    if result.failed > 0 || result.files.isEmpty { message = "已准备 \(result.files.count) 项，失败 \(result.failed) 项；未用预览替代原件。" }
  }

  private func favoriteSelected() async {
    guard !busy else { return }
    let targets = selectedTargets
    let favorite = !targets.allSatisfy(\.isFavorite)
    busy = true
    defer { busy = false }
    var succeeded = 0
    var failed = 0
    for item in targets {
      if let server = item.server {
        do {
          try await client.updateFavorite(id: server.id, isFavorite: favorite)
          let updated = NativeAsset(id: server.id, date: server.date, isImage: server.isImage, isFavorite: favorite,
            thumbhash: server.thumbhash, livePhotoVideoId: server.livePhotoVideoId,
            originalFileName: server.originalFileName, originalMimeType: server.originalMimeType,
            width: server.width, height: server.height, fileSizeInByte: server.fileSizeInByte,
            latitude: server.latitude, longitude: server.longitude, isArchived: server.isArchived)
          serverOverrides[server.id] = updated
          succeeded += 1
        } catch { failed += 1 }
      }
      if let local = item.local {
        if await device.updateFavorite(ids: [local.id], isFavorite: favorite) {
          localFavoriteOverrides[local.id] = favorite; succeeded += 1
        } else { failed += 1 }
      }
    }
    message = "收藏更新：成功 \(succeeded) 份副本，失败 \(failed) 份。"
  }

  private func archiveSelected() async {
    guard !busy else { return }
    let targets = selectedTargets
    busy = true
    defer { busy = false }
    var succeeded = 0
    var failed = 0
    for item in targets {
      guard var server = item.server else { continue }
      do {
        try await client.updateVisibility(ids: [server.id], visibility: "archive")
        server.isArchived = true
        serverOverrides[server.id] = server
        succeeded += 1
      } catch { failed += 1 }
    }
    message = "归档成功 \(succeeded) 项，失败 \(failed) 项；跳过本机独有项。"
  }

  private func saveSelected() async {
    guard !busy else { return }
    busy = true
    defer { busy = false }
    let targets = pendingTargets
    if !device.authorized { await device.requestAccess() }
    guard device.authorized else { message = "未获系统照片权限，无法保存。"; return }
    var urls: [URL] = []
    var failed = 0
    for item in targets {
      guard let server = item.server else { continue }
      do { urls.append(try await client.originalFile(for: server)) }
      catch { failed += 1 }
    }
    let result = await device.saveFilesToPhotos(urls)
    // These are temporary downloads returned for this operation, never originals.
    urls.forEach { try? FileManager.default.removeItem(at: $0) }
    message = "保存成功 \(result.saved) 项，失败 \(failed + result.failed) 项。"
  }

  private func addToServerAlbum(_ id: String) async {
    guard !busy else { return }
    busy = true
    defer { busy = false }
    let ids = pendingTargets.compactMap { $0.server?.id }
    do {
      let rows = try await client.addAssetsToAlbum(ids: ids, albumID: id)
      let summary = nativeBulkOperationSummary(requestedIDs: ids, responses: rows)
      message = "加入云端相册：成功 \(summary.succeeded)，失败 \(summary.failed)，未确认 \(summary.unconfirmed)；本机独有项跳过。"
    } catch { message = "加入相册失败：\(error.localizedDescription)" }
  }

  private func addToLocalAlbum(_ id: String) async {
    guard !busy else { return }
    busy = true
    defer { busy = false }
    let ids = pendingTargets.compactMap { $0.local?.id }
    let success = await device.addAssets(ids, toAlbum: id)
    message = success ? "已加入本机相册 \(ids.count) 项；云端独有项跳过。" : "加入本机相册失败，请检查权限。"
  }

  private func removeSelectedFromAlbum() async {
    guard !busy else { return }
    busy = true
    defer { busy = false }
    var succeeded = 0
    var failed = 0
    for item in pendingTargets {
      if let albumID = serverAlbumID, let server = item.server {
        do {
          try await client.removeAssetsFromAlbum(ids: [server.id], albumID: albumID)
          hiddenServerIDs.insert(server.id); succeeded += 1
        } catch { failed += 1 }
      }
      if let albumID = localAlbumID, let local = item.local {
        if await device.removeAssets([local.id], fromAlbum: albumID) {
          hiddenLocalIDs.insert(local.id); succeeded += 1
        } else { failed += 1 }
      }
    }
    clearSelection()
    message = "移出相册：成功 \(succeeded) 份成员关系，失败 \(failed) 份；原件保留。"
  }
}
