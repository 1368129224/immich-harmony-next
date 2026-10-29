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

    def test_tab_bar_order_contract(self):
        source = (ROOT / "ios-app/Runner/NativeFeatures.swift").read_text()
        shell = source.split("struct NativeTabShell", 1)[1].split("var body: some View", 1)[1].split(".background(", 1)[0]
        # Document Section 2: 照片 · 相册 · 搜索 · 资源库
        photos_idx = shell.find('Label("照片"')
        albums_idx = shell.find('Label("相册"')
        search_idx = shell.find('Label("搜索"')
        library_idx = shell.find('Label("资源库"')
        self.assertTrue(0 <= photos_idx < albums_idx < search_idx < library_idx)

    def test_default_grid_columns_and_viewer_features(self):
        source = (ROOT / "ios-app/Runner/NativeImmichApp.swift").read_text()
        # Default columns must be 4
        self.assertIn("@State private var columns: Int = 4", source)
        # Viewer Add to Album
        viewer = source.split("struct NativeUnifiedGalleryViewer", 1)[1]
        self.assertIn('title: "加入相册"', viewer)
        self.assertIn("showAlbumTargetDialog", viewer)
        # Video autoplay and controls overlay
        single_page = source.split("private struct NativeSingleAssetPage", 1)[1]
        self.assertIn("player.play()", single_page)
        self.assertIn("videoControlsOverlay", single_page)
        # Live Photo missing resource truthful indication
        self.assertIn("liveResourceMissing", single_page)
        self.assertIn("实况动态资源暂不可用或缺失", single_page)
        # Share options: Original, Compatible, Cloud Link, GPS options
        self.assertIn("原件（保留 GPS 位置）", viewer)
        self.assertIn("原件（去除 GPS 位置）", viewer)
        self.assertIn("兼容副本 JPEG", viewer)
        self.assertIn("复制云端访问链接", viewer)

    def test_album_and_backup_contracts(self):
        features_source = (ROOT / "ios-app/Runner/NativeFeatures.swift").read_text()
        backup_source = (ROOT / "ios-app/Runner/NativeBackupEngine.swift").read_text()
        # Album 2-4 zoom
        self.assertIn("albumColumns = target", features_source)
        # Remove from album vs delete photos
        album_detail = features_source.split("private struct NativeAlbumDetail", 1)[1]
        self.assertIn("移出相册", album_detail)
        self.assertIn("删除照片", album_detail)
        self.assertIn("removeSelectedFromAlbum", album_detail)
        # Backup default disabled and album selection required
        self.assertIn('UserDefaults.standard.object(forKey: "backup_enabled") as? Bool ?? false', backup_source)
        self.assertIn("请先选择需要备份的手机相册", backup_source)

    def test_library_recently_added_and_trash_management(self):
        features_source = (ROOT / "ios-app/Runner/NativeFeatures.swift").read_text()
        library_view = features_source.split("private struct NativeLibraryView", 1)[1]
        self.assertIn("NativeRecentlyAddedView", library_view)
        self.assertIn("NativeTrashManagementView", library_view)
        # Trash management actions
        trash_view = features_source.split("struct NativeTrashManagementView", 1)[1]
        self.assertIn("restoreSelected", trash_view)
        self.assertIn("performPermanentDelete", trash_view)
        self.assertIn("performEmptyTrash", trash_view)

    def test_native_viewer_default_non_fullscreen_style(self):
        source = (ROOT / "ios-app/Runner/NativeImmichApp.swift").read_text()
        viewer = source.split("struct NativeUnifiedGalleryViewer", 1)[1]
        # Native iOS viewer top & bottom bar design matching screenshot
        self.assertIn("formatViewerTopDateTitle", viewer)
        self.assertIn("viewerBottomActionButton", viewer)
        # Non-fullscreen viewport padding toggles on showsControls
        single_page = source.split("private struct NativeSingleAssetPage", 1)[1]
        self.assertIn("showsControls ? Color(uiColor: .systemBackground) : Color.black", single_page)
        self.assertIn("showsControls ? 88 : 0", single_page)
        self.assertIn("showsControls ? 120 : 0", single_page)


if __name__ == "__main__":
    unittest.main()
