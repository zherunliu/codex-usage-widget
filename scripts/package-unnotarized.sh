#!/bin/bash
set -euo pipefail

project_root="$(cd "$(dirname "$0")/.." && pwd)"
build_root="$project_root/build"
derived_data="$build_root/UnnotarizedDerivedData"
output_dir="$build_root/releases"
mkdir -p "$output_dir"

# Use the checked-in project. Regenerate it with XcodeGen after project.yml changes.
# Clear the local team and use ad-hoc signing, without debugger entitlements.
xcodebuild \
  -project "$project_root/CodexUsage.xcodeproj" \
  -scheme CodexUsage \
  -configuration Release \
  -destination 'generic/platform=macOS' \
  -derivedDataPath "$derived_data" \
  build \
  CODE_SIGN_IDENTITY=- \
  CODE_SIGN_STYLE=Manual \
  DEVELOPMENT_TEAM= \
  CODE_SIGNING_ALLOWED=YES \
  CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO \
  'ARCHS=arm64 x86_64' \
  ONLY_ACTIVE_ARCH=NO

app="$derived_data/Build/Products/Release/CodexUsage.app"
widget="$app/Contents/PlugIns/CodexUsageWidget.appex"
version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app/Contents/Info.plist")"
package_name="CodexUsage-$version-unnotarized-universal"
staging="$(mktemp -d "$build_root/UnnotarizedPackage.XXXXXX")"
trap 'rm -rf "$staging"' EXIT

codesign --verify --deep --strict --verbose=2 "$app"
for architecture in arm64 x86_64; do
  lipo "$app/Contents/MacOS/CodexUsage" -verify_arch "$architecture"
  lipo "$widget/Contents/MacOS/CodexUsageWidget" -verify_arch "$architecture"
done

app_group="$(/usr/libexec/PlistBuddy -c 'Print :AppGroupIdentifier' "$app/Contents/Info.plist")"
widget_group="$(/usr/libexec/PlistBuddy -c 'Print :AppGroupIdentifier' "$widget/Contents/Info.plist")"
test "$app_group" = "$widget_group"

for bundle in "$app" "$widget"; do
  codesign -d --entitlements - --xml "$bundle" > "$staging/entitlements.plist" 2>/dev/null
  signed_group="$(/usr/libexec/PlistBuddy -c 'Print :com.apple.security.application-groups:0' "$staging/entitlements.plist")"
  test "$signed_group" = "$app_group"
  debugger_allowed="$(/usr/libexec/PlistBuddy -c 'Print :com.apple.security.get-task-allow' "$staging/entitlements.plist" 2>/dev/null || true)"
  if test "$debugger_allowed" = true; then
    echo 'Unexpected debugger entitlement in the release bundle.' >&2
    exit 1
  fi
done
test "$(/usr/libexec/PlistBuddy -c 'Print :com.apple.security.app-sandbox' "$staging/entitlements.plist")" = true

mkdir -p "$staging/$package_name"
ditto "$app" "$staging/$package_name/CodexUsage.app"
cp "$project_root/LICENSE" "$staging/$package_name/LICENSE"
cp "$project_root/docs/unnotarized-release.md" "$staging/$package_name/INSTALL.md"
{
  echo "Version: $version"
  echo "Build: $(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$app/Contents/Info.plist")"
  echo "Commit: $(git -C "$project_root" rev-parse HEAD)"
  if test -n "$(git -C "$project_root" status --porcelain --untracked-files=normal)"; then
    echo 'Working tree: includes local changes'
  else
    echo 'Working tree: clean'
  fi
  echo 'Architectures: arm64, x86_64'
  echo 'Signing: ad-hoc; not notarized by Apple'
  echo "Shared container: $app_group"
} > "$staging/$package_name/BUILD.txt"

ditto -c -k --sequesterRsrc --keepParent "$staging/$package_name" "$staging/$package_name.zip"
mv -f "$staging/$package_name.zip" "$output_dir/$package_name.zip"
(
  cd "$output_dir"
  shasum -a 256 "$package_name.zip" > "$package_name.zip.sha256"
)
echo "App: $app"
echo "Package: $output_dir/$package_name.zip"
echo "Checksum: $output_dir/$package_name.zip.sha256"
