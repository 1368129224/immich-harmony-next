#!/usr/bin/env bash
# Download the newest successful main-branch iOS build, then refresh the local IPA source for LiveContainer.
set -euo pipefail

repo="${REPO:-1368129224/immich-next}"
workflow="${WORKFLOW:-build-ios.yml}"
artifact="${ARTIFACT:-immich-ios-ipa-unsigned}"
ipa_name="${IPA_NAME:-Immich-unsigned.ipa}"
legacy_ipa_name="ImmichZ-unsigned.ipa"
ipa_dir="${IPA_DIR:-/mnt/ssd/temp/ipa}"
updater="${UPDATER:-/home/zooter/docker-config/livecontainer-ipa-source/update-source.py}"

for tool in gh python3; do
  command -v "$tool" >/dev/null || { echo "Missing command: $tool" >&2; exit 1; }
done
[[ -f "$updater" ]] || { echo "Missing updater: $updater" >&2; exit 1; }

branch="${1:-$(git branch --show-current 2>/dev/null || echo "main")}"
[[ -n "$branch" ]] || branch="main"

# Pick the newest *successful* run for the specified branch.
run_id="$(gh run list -R "$repo" -w "$workflow" -b "$branch" -s success -L 1 --json databaseId \
  --jq '.[0].databaseId // empty')"
[[ -n "$run_id" ]] || { echo "No successful $branch-branch run found for $workflow" >&2; exit 1; }

mkdir -p "$ipa_dir"
staging="$(mktemp -d "$ipa_dir/.download.XXXXXXXX")"
trap 'rm -rf -- "$staging"' EXIT

echo "Downloading run $run_id ($artifact)..."
if ! gh run download "$run_id" -R "$repo" -n "$artifact" -D "$staging" 2>/dev/null; then
  echo "Artifact download failed (possibly hit storage quota), falling back to release $ipa_name..."
  python3 - "$repo" "latest-build" "$ipa_name" "$staging/$ipa_name" <<'PY'
import sys, json, os, time, subprocess, urllib.request

repo, tag, asset_name, dest = sys.argv[1:5]
token = subprocess.check_output("gh auth token", shell=True).decode().strip()
release_info = subprocess.check_output(f"gh api repos/{repo}/releases/tags/{tag}", shell=True).decode()
assets = json.loads(release_info).get('assets', [])
asset = next((a for a in assets if a['name'] == asset_name), None)
if not asset:
    sys.exit(f"Asset {asset_name} not found in release {tag}")

asset_url = asset['url']
target_size = asset['size']
current_size = os.path.getsize(dest) if os.path.exists(dest) else 0

for attempt in range(1, 40):
    if current_size >= target_size:
        break
    req = urllib.request.Request(asset_url)
    req.add_header("Authorization", f"token {token}")
    req.add_header("Accept", "application/octet-stream")
    if current_size > 0:
        req.add_header("Range", f"bytes={current_size}-")
    try:
        with urllib.request.urlopen(req, timeout=20) as resp:
            with open(dest, "ab" if current_size > 0 else "wb") as f:
                while True:
                    chunk = resp.read(128 * 1024)
                    if not chunk:
                        break
                    f.write(chunk)
                    current_size += len(chunk)
    except Exception as e:
        time.sleep(1)
        if os.path.exists(dest):
            current_size = os.path.getsize(dest)

if not os.path.exists(dest) or os.path.getsize(dest) != target_size:
    sys.exit(f"Failed to fully download {asset_name}: {current_size}/{target_size} bytes")
PY
fi
ipa="$staging/$ipa_name"
if [[ ! -s "$ipa" ]]; then
  found="$(find "$staging" -maxdepth 2 -type f -name "*.ipa" | head -n 1)"
  if [[ -n "$found" && -s "$found" ]]; then
    ipa="$found"
  else
    echo "Could not obtain $ipa_name from artifact or release" >&2
    exit 1
  fi
fi

# An Actions artifact is an outer ZIP; gh extracts it. Never rename that ZIP to .ipa.
python3 - "$ipa" <<'PY'
import sys
import zipfile

with zipfile.ZipFile(sys.argv[1]) as archive:
    if archive.testzip() is not None or not any(
        name.startswith('Payload/') and name.endswith('.app/Info.plist')
        for name in archive.namelist()
    ):
        raise SystemExit('Downloaded file is not a valid Device IPA')
PY

# Staging is on the same filesystem, so replacement is atomic. Preserve other IPA files.
cp -f -- "$ipa" "$ipa_dir/$legacy_ipa_name"
mv -f -- "$ipa" "$ipa_dir/$ipa_name"
python3 "$updater" --ipa-dir "$ipa_dir"
echo "Updated $ipa_dir/$ipa_name and $ipa_dir/$legacy_ipa_name from Actions run $run_id"
