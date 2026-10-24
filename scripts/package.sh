#!/bin/bash
set -euo pipefail
project_dir="$(cd "$(dirname "$0")/.." && pwd)"
version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$project_dir/Info.plist")"
expected_tag="${1:-}"
if [[ ! "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  printf 'Invalid app version: %s\n' "$version" >&2
  exit 1
fi
if [[ -n "$expected_tag" && "$expected_tag" != "v$version" ]]; then
  printf 'Release tag %s must match Info.plist version v%s\n' "$expected_tag" "$version" >&2
  exit 1
fi
architecture="$(uname -m)"
case "$architecture" in
  arm64|x86_64) ;;
  *) printf 'Unsupported architecture: %s\n' "$architecture" >&2; exit 1 ;;
esac

mkdir -p "$project_dir/.work" "$project_dir/release"
staging_dir="$(mktemp -d "$project_dir/.work/package.XXXXXX")"
trap 'rm -rf "$staging_dir"' EXIT
app="$staging_dir/WinKeyForMac.app"
archive_name="WinKeyForMac-$version-macOS-$architecture.zip"
archive="$project_dir/release/$archive_name"
bash "$project_dir/scripts/build.sh" "$app"
actual_architecture="$(lipo -archs "$app/Contents/MacOS/WinKeyForMac")"
if [[ "$actual_architecture" != "$architecture" ]]; then
  printf 'Expected %s binary, got %s\n' "$architecture" "$actual_architecture" >&2
  exit 1
fi
# ditto preserves the app bundle's metadata and executable permissions.
ditto -c -k --sequesterRsrc --keepParent "$app" "$staging_dir/$archive_name"
mv "$staging_dir/$archive_name" "$archive"
(
  cd "$project_dir/release"
  shasum -a 256 "$archive_name" > "$archive_name.sha256"
)
printf 'Packaged: %s\nChecksum: %s.sha256\n' "$archive" "$archive"
