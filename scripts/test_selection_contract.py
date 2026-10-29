"""Continuous collection selection guards and Foundation-only Swift behavior tests."""

import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def block(path, start, end):
    return (ROOT / path).read_text().split(start, 1)[1].split(end, 1)[0]


class SelectionSourceContractTests(unittest.TestCase):
    def test_both_grids_use_continuous_range_not_rectangle(self):
        for path, anchor in [
            ("ios-app/Runner/NativeImmichApp.swift", "struct NativePhotosView"),
            ("ios-app/Runner/NativeFeatures.swift", "struct NativeResultGrid"),
        ]:
            source = (ROOT / path).read_text().split(anchor, 1)[1]
            handler = source.split("private func handle2DDragSelection", 1)[1].split("private func finishDragSelection", 1)[0]
            self.assertIn("nativeContinuousSelection", handler)
            self.assertIn("nativeSelectionHitID", handler)
            self.assertNotIn("frame.intersects(selectionRect)", handler)

    def test_grid_drag_lifecycle_and_display_order(self):
        grid = block("ios-app/Runner/NativeFeatures.swift", "struct NativeResultGrid", "private func positionAtLatest")
        self.assertIn("visualOrderedAssetIDs", grid)
        self.assertIn(".updating($selectionDragActive)", grid)
        self.assertIn(".updating($selectionPressActive)", grid)
        self.assertIn(".onChange(of: selectionDragActive)", grid)
        self.assertIn(".onChange(of: selectionPressActive)", grid)
        self.assertIn("!longPressSelectionActive", grid)
        self.assertIn("guard !isSelecting else { return }", grid)
        self.assertIn("min(15, max(2,", grid)
        self.assertNotIn(".onLongPressGesture", grid)
        self.assertIn(".exclusively(before: TapGesture()", grid)
        self.assertNotIn(".onTapGesture", grid)
        self.assertIn(".onChange(of: latestRequest)", grid)
        self.assertIn("nativeCollectionGridItems", grid)
        self.assertNotIn("nativeFindHeuristicServerMatch", grid)
        # Recently-added server order stays intact.
        self.assertIn("if preservesServerOrder", grid)
        self.assertIn("return assets.map { NativeGridItem(server: $0, local: nil) }", grid)


@unittest.skipUnless(shutil.which("swift"), "Swift unavailable locally; behavior tests run on macOS CI")
class SelectionSwiftBehaviorTests(unittest.TestCase):
    def run_swift(self, helpers, checks):
        with tempfile.TemporaryDirectory(prefix="immich-selection-tests-") as directory:
            source = Path(directory) / "main.swift"
            source.write_text("import Foundation\nimport CoreGraphics\n" + helpers + "\n" + checks)
            result = subprocess.run([shutil.which("swift"), str(source)], capture_output=True, text=True, timeout=120)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_contiguous_ranges_backtracking_deselection_and_hits(self):
        helpers = block("ios-app/Runner/NativeFeatures.swift", "// MARK: - Collection selection helpers (Foundation-only)", "// MARK: - Gesture direction")
        self.run_swift(helpers, r'''
let order = ["a", "b", "c", "d", "e", "f", "g", "h"]
let baseline: Set<String> = ["a", "h"]
precondition(nativeContinuousSelection(orderedIDs: order, baseline: baseline, startID: "b", endID: "f", selecting: true) == ["a", "b", "c", "d", "e", "f", "h"])
// Moving back retracts only this drag's contribution, keeping pre-existing h.
precondition(nativeContinuousSelection(orderedIDs: order, baseline: baseline, startID: "b", endID: "c", selecting: true) == ["a", "b", "c", "h"])
precondition(nativeContinuousSelection(orderedIDs: order, baseline: [], startID: "f", endID: "b", selecting: true) == ["b", "c", "d", "e", "f"])
precondition(nativeContinuousSelection(orderedIDs: order, baseline: Set(order), startID: "b", endID: "f", selecting: false) == ["a", "g", "h"])
precondition(nativeContinuousSelection(orderedIDs: order, baseline: Set(order), startID: "b", endID: "c", selecting: false) == ["a", "d", "e", "f", "g", "h"])
precondition(nativeContinuousSelection(orderedIDs: order, baseline: baseline, startID: "gone", endID: "f", selecting: true) == baseline)
precondition(nativeContinuousSelection(orderedIDs: [], baseline: baseline, startID: "b", endID: "f", selecting: true) == baseline)
// The visual order is authoritative, not lexical ID order or just visible rows.
precondition(nativeContinuousSelection(orderedIDs: ["z", "m", "a", "x"], baseline: [], startID: "z", endID: "a", selecting: true) == ["z", "m", "a"])
var frames: [String: CGRect] = [:]
for (i, id) in order.enumerated() {
  frames[id] = CGRect(x: CGFloat((i % 4) * 12), y: CGFloat((i / 4) * 12), width: 10, height: 10)
}
precondition(nativeSelectionHitID(at: CGPoint(x: 25, y: 13), orderedIDs: order, frames: frames) == "g")
// Diagonal start b -> g includes c/d/e/f, unlike rectangle intersection.
let end = nativeSelectionHitID(at: CGPoint(x: 25, y: 13), orderedIDs: order, frames: frames)!
precondition(nativeContinuousSelection(orderedIDs: order, baseline: [], startID: "b", endID: end, selecting: true) == ["b", "c", "d", "e", "f", "g"])
precondition(nativeSelectionHitID(at: CGPoint(x: 11, y: 5), orderedIDs: order, frames: frames) == "a")
precondition(nativeSelectionHitID(at: CGPoint(x: 1, y: 1), orderedIDs: [], frames: frames) == nil)
precondition(nativeSelectionHitID(at: CGPoint(x: CGFloat.nan, y: 1), orderedIDs: order, frames: frames) == nil)
''')

    def test_collection_merge_requires_verified_match(self):
        helper = "func nativeCollectionGridItems" + block("ios-app/Runner/NativeFeatures.swift", "func nativeCollectionGridItems", "struct NativeResultGrid")
        stubs = r'''
struct NativeAsset { let id: String; let date: Date }
struct NativeDeviceAsset { let id: String; let date: Date }
struct NativeGridItem {
  let server: NativeAsset?
  let local: NativeDeviceAsset?
  var id: String { local.map { "local:\($0.id)" } ?? "server:\(server!.id)" }
  var date: Date { local?.date ?? server!.date }
}
'''
        self.run_swift(stubs + helper, r'''
let date = Date(timeIntervalSince1970: 100)
let server = NativeAsset(id: "s", date: date)
let local = NativeDeviceAsset(id: "l", date: date)
let unmatched = nativeCollectionGridItems(assets: [server], localAssets: [local], matchedServerIDs: [:])
precondition(unmatched.count == 2) // Same timestamp is NOT a verified identity.
let matched = nativeCollectionGridItems(assets: [server], localAssets: [local], matchedServerIDs: ["l": "s"])
precondition(matched.count == 1 && matched[0].local?.id == "l" && matched[0].server?.id == "s")
let outside = nativeCollectionGridItems(assets: [server], localAssets: [local], matchedServerIDs: ["l": "not-in-this-album"])
precondition(outside.count == 2 && outside.first(where: { $0.local != nil })?.server?.id == nil)
precondition(nativeCollectionGridItems(assets: [server, server], localAssets: [local, local], matchedServerIDs: ["l": "s"]).count == 1)
''')


if __name__ == "__main__":
    unittest.main()
