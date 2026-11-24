#!/usr/bin/env bash
set -euo pipefail
ROOT="${ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
DERIVED="$ROOT/app/DerivedData"
DIST="$ROOT/dist"
# Debug is the configuration that runs games (docs/BUILDING.md); Release builds
# have crashed the guest.
CONFIGURATION="${CONFIGURATION:-Debug}"
APP="$DERIVED/Build/Products/$CONFIGURATION-iphoneos/Madeira.app"

required=(
  "$ROOT/FEX/build-ios/FEXCore/Source/libFEXCore.a"
  "$ROOT/FEX/build-ios/FEXCore/Source/libFEXCore_Base.a"
  "$ROOT/FEX/build-ios/External/fmt/libfmt.a"
  "$ROOT/FEX/build-ios/External/cephes/libcephes_128bit.a"
  "$ROOT/app/Madeira/libwineserver.a"
  "$ROOT/app/Madeira/libntdll_unix.a"
  "$ROOT/app/Madeira/libwin32u_unix.a"
  "$ROOT/app/Madeira/libdxmt_combined.a"
  "$ROOT/app/Madeira/libmadeira_rppairing.a"
)
for path in "${required[@]}"; do
  [[ -f "$path" ]] || { echo "ERROR: required build artifact missing: $path" >&2; exit 1; }
done

python3 "$ROOT/tools/build/runtime-components.py" verify all

rm -rf "$DERIVED" "$DIST/Payload"
mkdir -p "$DIST"

xcodebuild \
  -project "$ROOT/app/Madeira.xcodeproj" \
  -scheme Madeira \
  -configuration "$CONFIGURATION" \
  -sdk iphoneos \
  -destination 'generic/platform=iOS' \
  -derivedDataPath "$DERIVED" \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO \
  CODE_SIGN_IDENTITY='' \
  build

[[ -d "$APP" ]] || { echo "ERROR: xcodebuild succeeded but Madeira.app is missing" >&2; exit 1; }

# Keep the app and the iOS 26 helper at their respective project targets.
minimum_os=$(/usr/libexec/PlistBuddy -c 'Print MinimumOSVersion' "$APP/Info.plist")
[[ "$minimum_os" == 17.0 ]] || { echo "ERROR: Madeira minimum OS is $minimum_os, expected 17.0" >&2; exit 1; }
verify_app_binary() {
  xcrun otool -l "$1" | awk -v binary="${1##*/}" '
  $1 == "cmd" { command = $2 }
  $1 == "minos" && command == "LC_BUILD_VERSION" && ($2 == "17.0" || $2 == "17.0.0") { target = 1 }
  $1 == "name" && $2 ~ /\/_GameController_SwiftUI\.framework\// && command != "LC_LOAD_WEAK_DYLIB" { required_overlay = 1 }
  END {
    if (!target) print "ERROR: " binary " does not target iOS 17.0" > "/dev/stderr"
    if (required_overlay) print "ERROR: " binary " requires _GameController_SwiftUI at launch" > "/dev/stderr"
    exit (!target || required_overlay)
  }
'
}
verify_app_binary "$APP/Madeira"
if [[ -f "$APP/Madeira.debug.dylib" ]]; then
  verify_app_binary "$APP/Madeira.debug.dylib"
fi

python3 "$ROOT/tools/build/runtime-components.py" bundle "$APP"

# Preserve Madeira's requested JIT/debug entitlements in the IPA. SideStore will
# replace this ad-hoc signature with the user's development signature while
# retaining the supported entitlements.
codesign --force --sign - \
  --entitlements "$ROOT/app/Madeira/Madeira.entitlements" \
  "$APP"

bundle_required=(
  "$APP/Madeira"
  "$APP/prefix-template.tar.gz"
  "$APP/arm64ec-windows/xtajit64.dll"
  "$APP/x86_64-vcruntime/vcruntime140.dll"
)
for path in "${bundle_required[@]}"; do
  [[ -e "$path" ]] || { echo "ERROR: required bundle resource missing: $path" >&2; exit 1; }
done
codesign -d --entitlements :- "$APP" 2>/dev/null | grep -q 'com.apple.security.cs.allow-jit' || {
  echo "ERROR: packaged app is missing the allow-jit entitlement" >&2
  exit 1
}

mkdir -p "$DIST/Payload"
ditto "$APP" "$DIST/Payload/Madeira.app"
rm -f "$DIST/Madeira.ipa"
(
  cd "$DIST"
  /usr/bin/zip -qry Madeira.ipa Payload
)
rm -rf "$DIST/Payload"
[[ -s "$DIST/Madeira.ipa" ]] || { echo "ERROR: failed to create IPA" >&2; exit 1; }
unzip -tq "$DIST/Madeira.ipa" >/dev/null
python3 "$ROOT/tools/build/runtime-components.py" ipa "$DIST/Madeira.ipa"
