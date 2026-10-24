#!/usr/bin/env python3
"""Reject cross-platform runtime leftovers in the source tree and built iOS app."""

import argparse
import plistlib
import re
import subprocess
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
FORBIDDEN_NAMES = {
    "flutter", ".dart_tool", ".flutter-plugins", ".flutter-plugins-dependencies",
    "pubspec.yaml", "pubspec.lock", ".metadata", "flutter.framework",
    "flutter_assets", "vm_snapshot_data", "isolate_snapshot_data",
}
SOURCE_SUFFIXES = {".swift", ".h", ".m", ".mm", ".pbxproj", ".xcconfig", ".plist", ".storyboard"}
RUNTIME_REFERENCE = re.compile(r"flutter|xcode_backend\.sh|dart:|DART_DEFINES", re.IGNORECASE)


def check_paths(paths):
    return [str(path) for path in paths if path.suffix.lower() == ".dart"
            or any(part.lower() in FORBIDDEN_NAMES for part in path.parts)]


def check_sources(root, paths):
    errors = []
    for path in paths:
        is_ios = path.parts[:1] == ("ios-app",) or path.parts[:2] == ("mobile", "ios")
        if not is_ios or path.suffix not in SOURCE_SUFFIXES:
            continue
        text = (root / path).read_text(encoding="utf-8", errors="ignore")
        if RUNTIME_REFERENCE.search(text):
            errors.append(f"Runtime reference in {path}")
    return errors


def check_app(app):
    if not app.is_dir():
        raise ValueError(f"App bundle does not exist: {app}")
    errors = check_paths(path.relative_to(app) for path in app.rglob("*"))
    with (app / "Info.plist").open("rb") as file:
        info = plistlib.load(file)
    executable = app / info["CFBundleExecutable"]
    linked = subprocess.check_output(["otool", "-L", str(executable)], text=True)
    if "flutter" in linked.lower():
        errors.append("Executable links the removed runtime")
    return errors


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--app", type=Path, help="Also inspect an Xcode-built .app (macOS only)")
    args = parser.parse_args()
    try:
        tracked = subprocess.check_output(["git", "ls-files", "-z"], cwd=ROOT)
        paths = [Path(name) for name in tracked.decode().split("\0") if name]
        errors = check_paths(paths) + check_sources(ROOT, paths)
        if args.app:
            errors.extend(check_app(args.app))
    except (OSError, ValueError, KeyError, subprocess.CalledProcessError) as error:
        raise SystemExit(f"Native iOS check failed: {error}") from error
    if errors:
        raise SystemExit("Native iOS check failed:\n" + "\n".join(errors))
    print("Native iOS source" + (" and app bundle" if args.app else "") + " checks passed.")


if __name__ == "__main__":
    main()
