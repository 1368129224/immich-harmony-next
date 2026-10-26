"""Source-level UI regression guards; these do not replace iOS interaction tests."""

import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]


class PhotoScrollContractTests(unittest.TestCase):
    def test_selection_bars_share_a_stable_layout_footprint(self):
        source = (ROOT / "ios-app/Runner/NativeImmichApp.swift").read_text()
        chrome = source.split("private func timelineChromeContent", 1)[1].split(
            '.navigationTitle("照片")', 1
        )[0]
        self.assertIn("ZStack(alignment: .bottom)", chrome)
        self.assertNotIn("if isSelecting {", chrome)
        self.assertIn(".opacity(isSelecting ? 1 : 0)", chrome)
        self.assertIn(".opacity(isSelecting ? 0 : 1)", chrome)
        self.assertIn(".allowsHitTesting(isSelecting)", chrome)
        self.assertIn(".allowsHitTesting(!isSelecting)", chrome)
        self.assertIn(".accessibilityHidden(!isSelecting)", chrome)
        self.assertIn(".accessibilityHidden(isSelecting)", chrome)

    def test_tab_interception_preserves_swiftui_delegate(self):
        source = (ROOT / "ios-app/Runner/NativeFeatures.swift").read_text()
        helper = source.split("private struct TabBarDoubleTapHelper", 1)[1].split(
            "struct NativeTabShell", 1
        )[0]
        self.assertIn("UITabBarControllerDelegate", helper)
        self.assertIn("tabBarController.selectedViewController === viewController", helper)
        self.assertIn("vcs.first === viewController", helper)
        self.assertIn("return false", helper)
        self.assertIn("previousDelegate?.tabBarController?", helper)
        self.assertIn("override func forwardingTarget", helper)
        self.assertIn("controller.delegate = previousDelegate", helper)
        self.assertIn("doubleTap.numberOfTapsRequired = 2", helper)
        self.assertIn("doubleTap.cancelsTouchesInView = false", helper)

    def test_bottom_correction_waits_for_animation(self):
        source = (ROOT / "ios-app/Runner/NativeImmichApp.swift").read_text()
        self.assertIn("animated && index == 0 ? 300_000_000 : 40_000_000", source)
        self.assertIn(".easeInOut(duration: 0.25)", source)

    def test_viewer_dismiss_gesture_prevents_horizontal_paging_conflict(self):
        source = (ROOT / "ios-app/Runner/NativeImmichApp.swift").read_text()
        surface = source.split("private struct NativeViewerDismissHelper", 1)[1].split(
            "func nativeViewerVisibleSourceFrame", 1
        )[0]
        # Must require the horizontal paging pan gesture to fail when dismiss pan begins
        self.assertIn("paging.panGestureRecognizer.require(toFail: pan)", surface)
        self.assertIn("shouldBeRequiredToFailBy", surface)
        self.assertIn("shouldRecognizeSimultaneouslyWith", surface)
        # Must reset in-flight offset to page boundary
        self.assertIn("sv.setContentOffset", surface)
        self.assertIn("round(currentX / width) * width", surface)
        # Must not use simultaneous DragGesture on the pager
        self.assertNotIn("simultaneousGesture(\n          DragGesture", surface)

    def test_viewer_deletion_scenarios_contract(self):
        source = (ROOT / "ios-app/Runner/NativeImmichApp.swift").read_text()
        viewer = source.split("struct NativeUnifiedGalleryViewer", 1)[1]

        # 1. Remote only: displays "回收站", has "不再提醒" checkbox for trash
        self.assertIn('title: isRemoteOnly ? "回收站" : "删除"', viewer)
        self.assertIn("showCloudTrashDialog", viewer)
        self.assertIn("不再提醒", viewer)
        self.assertIn("isSkipTrashReminderEnabled", viewer)

        # 2. Both exist: confirms localOnly vs all
        self.assertIn("showBothDeleteDialog", viewer)
        self.assertIn("仅删除本地照片", viewer)
        self.assertIn("全部删除", viewer)

        # 3. Local only: warns not synced yet and deletes local
        self.assertIn("showLocalOnlyDeleteDialog", viewer)
        self.assertIn("尚未同步", viewer)
        self.assertIn("删除本地照片", viewer)



if __name__ == "__main__":
    unittest.main()
