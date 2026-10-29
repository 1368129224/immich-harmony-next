"""Library request/date regression tests; Swift behavior tests run on macOS CI."""

import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def swift_block(path, start, end):
    return (ROOT / path).read_text().split(start, 1)[1].split(end, 1)[0]


class LibrarySourceContractTests(unittest.TestCase):
    def test_recently_added_uses_created_at_timeline_not_search(self):
        client = (ROOT / "ios-app/Runner/NativeImmichApp.swift").read_text()
        self.assertNotIn('"field": "createdAt"', client)
        self.assertNotIn("func recentlyAddedPage", client)
        # Do not let the Rust takenAt cache silently override date-added order.
        self.assertEqual(client.count("if orderBy == .takenAt && ImmichCoreBridge.shared.isInitialized"), 2)
        self.assertIn("nativeTimelineQuery(orderBy: orderBy)", client)
        self.assertIn("nativeTimelineQuery(orderBy: orderBy, bucketID: bucket.id)", client)
        view = swift_block("ios-app/Runner/NativeFeatures.swift", "struct NativeRecentlyAddedView", "struct NativeTrashManagementView")
        self.assertIn("timelineBuckets(orderBy: .createdAt)", view)
        self.assertIn("assets(in: buckets[nextBucket], orderBy: .createdAt)", view)
        self.assertIn("preservesServerOrder: true", view)
        self.assertNotIn("localAssets", view)
        self.assertLess(view.index("let page = try await client.assets"), view.index("nextBucket += 1"))
        grid = swift_block("ios-app/Runner/NativeFeatures.swift", "struct NativeResultGrid", "private func positionAtLatest")
        self.assertIn("if preservesServerOrder", grid)
        self.assertIn("if !preservesServerOrder", grid)

    def test_memories_enforce_today_on_server_and_client(self):
        view = swift_block("ios-app/Runner/NativeLibrary.swift", "struct NativeMemoriesView", "struct NativeMemoryDetailView")
        self.assertIn('URLQueryItem(name: "for", value: nativeMemoryDayKey(for: today))', view)
        self.assertIn('URLQueryItem(name: "type", value: "on_this_day")', view)
        self.assertIn("nativeMemoriesOnThisDay(rows, now: today)", view)
        self.assertIn("暂无往年今天的回忆", view)


@unittest.skipUnless(shutil.which("swift"), "Swift toolchain unavailable; behavior tests run on macOS CI")
class LibrarySwiftBehaviorTests(unittest.TestCase):
    def run_swift(self, helpers, checks):
        with tempfile.TemporaryDirectory(prefix="immich-library-tests-") as directory:
            source = Path(directory) / "main.swift"
            source.write_text("import Foundation\n" + helpers + "\n" + checks)
            result = subprocess.run([shutil.which("swift"), str(source)], capture_output=True, text=True, timeout=120)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_timeline_query_contract(self):
        helpers = swift_block("ios-app/Runner/NativeFeatures.swift", "// MARK: - Timeline request contract (Foundation-only)", "// MARK: - Result grids")
        self.run_swift(helpers, r'''
func values(_ query: [URLQueryItem]) -> [String: String] {
  Dictionary(uniqueKeysWithValues: query.map { ($0.name, $0.value ?? "") })
}
let added = values(nativeTimelineQuery(orderBy: .createdAt))
precondition(added["orderBy"] == "createdAt" && added["order"] == "desc")
precondition(added["visibility"] == "timeline" && added["timeBucket"] == nil)
let bucket = values(nativeTimelineQuery(orderBy: .createdAt, bucketID: "2026-10-29"))
precondition(bucket["timeBucket"] == "2026-10-29")
precondition(bucket["orderBy"] == added["orderBy"])
let taken = values(nativeTimelineQuery(orderBy: .takenAt, bucketID: "2026-10-29"))
precondition(taken["orderBy"] == "takenAt" && taken["timeBucket"] == "2026-10-29T00:00:00.000Z")
''')

    def test_memories_dates_years_timezones_and_members(self):
        helpers = swift_block("ios-app/Runner/NativeLibrary.swift", "// MARK: - On-this-day filtering (Foundation-only)", "// MARK: - Memories UI")
        self.run_swift(helpers, r'''
var calendar = Calendar(identifier: .gregorian)
calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
func date(_ text: String) -> Date { ISO8601DateFormatter().date(from: text)! }
let now = date("2026-10-29T04:00:00Z")
func asset(_ id: String, _ taken: String) -> [String: Any] {
  ["id": id, "localDateTime": taken]
}
func memory(_ id: String, _ day: String, _ year: Int, _ assets: [[String: Any]]) -> [String: Any] {
  ["id": id, "type": "on_this_day", "memoryAt": day, "data": ["year": year], "assets": assets]
}
let rows = [
  memory("today", "2026-10-29T00:00:00Z", 2024, [
    asset("valid", "2024-10-29T12:00:00"), asset("yesterday", "2024-10-28T12:00:00"),
    asset("this-year", "2026-10-29T12:00:00"), asset("future", "2027-10-29T12:00:00")]),
  memory("yesterday", "2026-10-28T00:00:00Z", 2024, [asset("old", "2024-10-28T12:00:00")]),
  memory("day-before", "2026-10-27T00:00:00Z", 2024, [asset("old", "2024-10-27T12:00:00")]),
  memory("past-date", "2023-10-29", 2023, [asset("old", "2023-10-29T12:00:00")]),
  memory("this-year", "2026-10-29", 2026, [asset("new", "2026-10-29T12:00:00")]),
  memory("bad-date", "invalid", 2024, [asset("old", "2024-10-29T12:00:00")])
]
let filtered = nativeMemoriesOnThisDay(rows, now: now, calendar: calendar)
precondition(filtered.compactMap { $0["id"] as? String } == ["today", "past-date"])
let members = filtered[0]["assets"] as! [[String: Any]]
precondition(members.compactMap { $0["id"] as? String } == ["valid"])
// Oct 28 UTC is Oct 29 in Shanghai. Do not query or match yesterday at midnight.
let midnight = date("2026-10-28T16:30:00Z")
precondition(nativeMemoryDayKey(for: midnight, calendar: calendar) == "2026-10-29")
let utcMember = memory("offset", "2026-10-28T16:00:00Z", 2024,
  [["id": "utc", "fileCreatedAt": "2024-10-28T17:00:00.000Z"]])
precondition(nativeMemoriesOnThisDay([utcMember], now: midnight, calendar: calendar).count == 1)
// Prefer photographer's localDateTime over UTC capture timestamp when supplied.
let localMember = memory("local", "2026-10-29", 2024,
  [["id": "local", "localDateTime": "2024-10-29T01:00:00.000Z", "fileCreatedAt": "2024-10-28T12:00:00Z"]])
precondition(nativeMemoriesOnThisDay([localMember], now: now, calendar: calendar).count == 1)
let leapNow = date("2028-02-29T04:00:00Z")
let leap = memory("leap", "2024-02-29", 2024, [asset("leap", "2024-02-29T12:00:00")])
let invalid = memory("invalid", "2023-02-29", 2023, [asset("bad", "2023-02-29T12:00:00")])
precondition(nativeMemoriesOnThisDay([leap, invalid], now: leapNow, calendar: calendar).count == 1)
precondition(nativeMemoriesOnThisDay([leap], now: now, calendar: calendar).isEmpty)
''')


if __name__ == "__main__":
    unittest.main()
