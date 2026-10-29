"""Shared collection browser guards; interaction acceptance still needs an iPhone."""

import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


class CollectionBrowserContractTests(unittest.TestCase):
    def test_album_and_memories_share_browser_and_photo_toolbar(self):
        features = (ROOT / 'ios-app/Runner/NativeFeatures.swift').read_text()
        library = (ROOT / 'ios-app/Runner/NativeLibrary.swift').read_text()
        photos = (ROOT / 'ios-app/Runner/NativeImmichApp.swift').read_text()
        browser = (ROOT / 'ios-app/Runner/NativeCollectionBrowser.swift').read_text()
        album = features.split('private struct NativeAlbumDetail', 1)[1].split('private struct NativePhotosPageSettingsView', 1)[0]
        memory = library.split('struct NativeMemoryDetailView', 1)[1].split('struct NativeSharedLinksView', 1)[0]
        self.assertIn('NativeCollectionBrowser(', album)
        self.assertIn('NativeCollectionBrowser(', memory)
        memories = library.split('struct NativeMemoriesView', 1)[1].split('struct NativeMemoryDetailView', 1)[0]
        self.assertIn('NativeCollectionBrowser(', memories)
        self.assertNotIn('NavigationLink', memories)
        self.assertIn('localAssets: matchingLocals', memories)
        self.assertIn('NativePhotoBatchToolbar(', photos)
        self.assertIn('NativePhotoBatchToolbar(', browser)
        for title in ['分享', '收藏', '归档', '加入相册', '保存', '删除']:
            self.assertIn('"' + title + '"', browser)
        self.assertIn('hasOlder: hasOlder, startsAtLatest: true', browser)
        self.assertIn('latestRequest: latestRequest, device: device', browser)
        self.assertIn('nativeCollectionGridItems(assets: visibleServers', browser)
        self.assertIn('nativeCollectionGridItems(', features)
        self.assertNotIn('selectedTargets:', album)

    def test_selection_chrome_keeps_layout_and_operations_respect_scope(self):
        browser = (ROOT / 'ios-app/Runner/NativeCollectionBrowser.swift').read_text()
        self.assertIn('ZStack(alignment: .bottom)', browser)
        self.assertIn('.opacity(isSelecting ? 1 : 0)', browser)
        self.assertIn('.opacity(isSelecting ? 0 : 1)', browser)
        self.assertIn('.accessibilityHidden(!isSelecting)', browser)
        self.assertIn('.accessibilityHidden(isSelecting)', browser)
        self.assertIn('serverAlbumID != nil || localAlbumID != nil', browser)
        self.assertIn('removeFromAlbum: canRemove ?', browser)
        remove = browser.split('private func removeSelectedFromAlbum()', 1)[1]
        self.assertIn('removeAssetsFromAlbum', remove)
        self.assertIn('device.removeAssets', remove)
        self.assertNotIn('deleteAssets', remove)
        self.assertIn('scope == .all', browser)
        self.assertIn('partial.deletedServerIDs', browser)
        self.assertIn('nativeBulkOperationSummary', browser)

    def test_new_source_is_registered_in_xcode(self):
        project = (ROOT / 'ios-app/Runner.xcodeproj/project.pbxproj').read_text()
        self.assertIn('NativeCollectionBrowser.swift in Sources', project)
        self.assertEqual(project.count('/* NativeCollectionBrowser.swift in Sources */'), 2)

    @unittest.skipUnless(shutil.which('swift'), 'Swift behavior tests run on macOS CI')
    def test_collection_merge_only_uses_verified_matches(self):
        features = (ROOT / 'ios-app/Runner/NativeFeatures.swift').read_text()
        helper = 'func nativeCollectionGridItems(' + features.split('func nativeCollectionGridItems(', 1)[1].split('struct NativeResultGrid', 1)[0]
        stubs = '''import Foundation
struct NativeAsset { let id: String; let date: Date }
struct NativeDeviceAsset { let id: String; let date: Date }
struct NativeGridItem {
  let server: NativeAsset?
  let local: NativeDeviceAsset?
  var id: String { local.map { "local:" + $0.id } ?? "server:" + server!.id }
  var date: Date { server?.date ?? local!.date }
}
'''
        checks = '''
let now = Date(timeIntervalSince1970: 100)
let remote = NativeAsset(id: "cloud", date: now)
let local = NativeDeviceAsset(id: "device", date: now)
let unverified = nativeCollectionGridItems(assets: [remote], localAssets: [local], matchedServerIDs: [:])
precondition(unverified.count == 2, "Same timestamp is not proof of a match")
let verified = nativeCollectionGridItems(assets: [remote, remote], localAssets: [local, local], matchedServerIDs: ["device": "cloud"])
precondition(verified.count == 1)
precondition(verified[0].local?.id == "device" && verified[0].server?.id == "cloud")
let missing = nativeCollectionGridItems(assets: [], localAssets: [local], matchedServerIDs: ["device": "other-account-or-missing"])
precondition(missing.count == 1 && missing[0].server == nil)
'''
        with tempfile.TemporaryDirectory(prefix='collection-merge-tests-') as directory:
            source = Path(directory) / 'main.swift'
            source.write_text(stubs + helper + checks)
            result = subprocess.run([shutil.which('swift'), str(source)], capture_output=True, text=True, timeout=120)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)


if __name__ == '__main__':
    unittest.main()
