import Photos
import SwiftUI
import UIKit

// Show real cached thumbnails while the full, lazy timeline settles at its
// initial bottom anchor. Keep day boundaries identical to the main grid.
struct NativeCachedTimelinePreview: View {
  let client: NativeImmichClient
  let items: [NativeGridItem]
  let columns: Int
  let onTap: (NativeGridItem) -> Void

  var body: some View {
    GeometryReader { viewport in
      let cellWidth = viewport.size.width / CGFloat(max(columns, 1))
      let rows = Int(ceil(viewport.size.height / max(cellWidth, 1))) + 1
      let recent = Array(items.suffix(rows * columns))
      previewContent(groups: dayGroups(for: recent), viewport: viewport.size)
    }
  }

  @ViewBuilder
  private func previewContent(
    groups: [NativeDayGroup], viewport: CGSize
  ) -> some View {
    if groups.isEmpty {
      ProgressView("正在读取照片…")
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    } else {
      let alignment: Alignment = estimatedHeight(
        groups: groups, width: viewport.width
      ) > viewport.height ? .bottom : .top
      VStack(spacing: 4) {
        ForEach(groups, id: \.date) { group in
          dayGrid(group)
        }
      }
      .fixedSize(horizontal: false, vertical: true)
      .frame(height: viewport.height, alignment: alignment)
      .clipped()
    }
  }

  private func dayGrid(_ group: NativeDayGroup) -> some View {
    let spacing: CGFloat = columns > 7 ? 1 : 2
    return VStack(alignment: .leading, spacing: 2) {
      if columns > 6 {
        Text(NativeImmichClient.formatChineseDate(group.date))
          .font(.caption2.weight(.bold))
          .padding(.horizontal, 4)
      }
      LazyVGrid(
        columns: Array(repeating: GridItem(.flexible(), spacing: spacing),
                       count: columns),
        spacing: spacing
      ) {
        ForEach(group.assets) { item in
          cell(item, date: group.date,
               isFirst: item.id == group.assets.first?.id)
        }
      }
    }
  }

  private func cell(
    _ item: NativeGridItem, date: Date, isFirst: Bool
  ) -> some View {
    Color(uiColor: .secondarySystemBackground)
      .aspectRatio(1, contentMode: .fit)
      .overlay {
        if let asset = item.server {
          NativeThumbnail(client: client, asset: asset, columns: columns)
        } else if let asset = item.local {
          NativeDeviceThumbnail(asset: asset, columns: columns)
        }
      }
      .clipped()
      .overlay(alignment: .topLeading) {
        if columns <= 6 && isFirst {
          Text(NativeImmichClient.formatChineseDate(date))
            .font(.system(size: max(9, 13 - CGFloat(columns)), weight: .bold))
            .foregroundColor(.white)
            .padding(2)
            .background(.black.opacity(0.65))
            .cornerRadius(3)
        }
      }
      .contentShape(Rectangle())
      .onTapGesture { onTap(item) }
  }

  private func dayGroups(for items: [NativeGridItem]) -> [NativeDayGroup] {
    var calendar = Calendar.autoupdatingCurrent
    calendar.timeZone = .autoupdatingCurrent
    let grouped = Dictionary(grouping: items) {
      calendar.startOfDay(for: $0.date)
    }
    return grouped.keys.sorted().map { date in
      NativeDayGroup(date: date, assets: grouped[date] ?? [])
    }
  }

  private func estimatedHeight(
    groups: [NativeDayGroup], width: CGFloat
  ) -> CGFloat {
    let spacing: CGFloat = columns > 7 ? 1 : 2
    let cellHeight = (width - CGFloat(columns - 1) * spacing)
      / CGFloat(columns)
    let rowCounts = groups.map {
      Int(ceil(Double($0.assets.count) / Double(columns)))
    }
    return CGFloat(rowCounts.reduce(0, +)) * cellHeight
      + CGFloat(rowCounts.reduce(0) { $0 + max(0, $1 - 1) }) * spacing
      + CGFloat(max(0, groups.count - 1)) * 4
      + (columns > 6 ? CGFloat(groups.count) * 20 : 0)
  }
}
