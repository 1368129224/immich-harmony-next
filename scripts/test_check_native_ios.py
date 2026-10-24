"""Regression tests for the native-only source and bundle guard."""

import plistlib
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

from check_native_ios import check_app, check_paths, check_sources


class NativeIOSCheckTests(unittest.TestCase):
    def test_accepts_native_project(self):
        self.assertEqual(check_paths([Path("ios-app/Runner/AppDelegate.swift")]), [])

    def test_rejects_old_source_and_build_artifacts(self):
        for name in ("mobile/lib/main.dart", "mobile/pubspec.yaml", "mobile/.dart_tool/package_config.json",
                     "Frameworks/Flutter.framework/Flutter", "Runner.app/flutter_assets/AssetManifest.bin"):
            with self.subTest(name=name):
                self.assertEqual(check_paths([Path(name)]), [name])

    def test_rejects_runtime_references_in_native_source(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source = Path("ios-app/Runner/AppDelegate.swift")
            (root / source).parent.mkdir(parents=True)
            (root / source).write_text("import Flutter\n")
            self.assertTrue(check_sources(root, [source]))
            (root / source).write_text("import SwiftUI\n")
            self.assertEqual(check_sources(root, [source]), [])

    def test_bundle_contents_and_linked_libraries(self):
        with tempfile.TemporaryDirectory() as directory:
            app = Path(directory) / "Runner.app"
            app.mkdir()
            (app / "Info.plist").write_bytes(plistlib.dumps({"CFBundleExecutable": "Runner"}))
            with patch("check_native_ios.subprocess.check_output", return_value="/System/Library/Frameworks/UIKit.framework/UIKit"):
                self.assertEqual(check_app(app), [])
                (app / "flutter_assets").mkdir()
                self.assertTrue(check_app(app))
                (app / "flutter_assets").rmdir()
            with patch("check_native_ios.subprocess.check_output", return_value="@rpath/Flutter.framework/Flutter"):
                self.assertTrue(check_app(app))

    def test_missing_bundle_fails(self):
        with tempfile.TemporaryDirectory() as directory, self.assertRaises(ValueError):
            check_app(Path(directory) / "missing.app")


if __name__ == "__main__":
    unittest.main()
