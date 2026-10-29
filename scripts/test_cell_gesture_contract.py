"""Guard mutually exclusive cell tap/long-press wiring, not a UIKit gesture simulation."""

import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


class CellGestureContractTests(unittest.TestCase):
    def test_collection_cell_has_one_exclusive_tap_and_long_press_owner(self):
        source = (ROOT / "ios-app/Runner/NativeFeatures.swift").read_text()
        grid = source.split("struct NativeResultGrid: View", 1)[1].split("enum NativeAssetState", 1)[0]
        cells = grid.split("private func collectionCellGesture", 1)[0]
        gesture = grid.split("private func collectionCellGesture", 1)[1].split("private func positionAtLatest", 1)[0]
        self.assertIn("collectionCellGesture(for: entry, sourceFrame: geo.frame(in: .global))", cells)
        self.assertNotIn(".onTapGesture", cells)
        self.assertNotIn(".onLongPressGesture", cells)
        self.assertNotIn(".highPriorityGesture", cells)
        self.assertIn(".sequenced(before: DragGesture", gesture)
        self.assertIn(".exclusively(before: TapGesture().onEnded", gesture)
        self.assertIn("resetSelectionDrag()", gesture)
        self.assertIn("toggleSelection(entry.id)", gesture)
        self.assertIn("bottomPositionTask?.cancel()", gesture)
        # onChanged belongs to the sequence, not ExclusiveGesture<Value, Void>.
        self.assertLess(gesture.index(".onChanged"), gesture.index(".exclusively"))


if __name__ == "__main__":
    unittest.main()
