#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_DIR="${BUILD_DIR:-"$ROOT_DIR/build/unsigned-ipa"}"
DERIVED_DATA_DIR="$BUILD_DIR/DerivedData"
OUTPUT_DIR="${OUTPUT_DIR:-"$BUILD_DIR/output"}"
PROJECT_PATH="${PROJECT_PATH:-"$ROOT_DIR/ADBTV.xcodeproj"}"
SCHEME="${SCHEME:-ADBTV}"
CONFIGURATION="${CONFIGURATION:-Release}"
IPA_NAME="${IPA_NAME:-ADBTV-unsigned.ipa}"
CHECKSUM_NAME="${CHECKSUM_NAME:-${IPA_NAME}.sha256}"
EXPECTED_MARKETING_VERSION="${EXPECTED_MARKETING_VERSION:-}"

rm -rf "$BUILD_DIR"
mkdir -p "$DERIVED_DATA_DIR" "$OUTPUT_DIR"

xcodebuild \
  -project "$PROJECT_PATH" \
  -scheme "$SCHEME" \
  -configuration "$CONFIGURATION" \
  -destination 'generic/platform=iOS' \
  -derivedDataPath "$DERIVED_DATA_DIR" \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO \
  CODE_SIGN_IDENTITY="" \
  build

PRODUCTS_DIR="$DERIVED_DATA_DIR/Build/Products/${CONFIGURATION}-iphoneos"
APP_PATH=""
for candidate in "$PRODUCTS_DIR"/*.app; do
  if [[ -d "$candidate" ]]; then
    APP_PATH="$candidate"
    break
  fi
done

if [[ -z "$APP_PATH" ]]; then
  echo "No .app product found in $PRODUCTS_DIR" >&2
  exit 1
fi

INFO_PLIST_PATH="$APP_PATH/Info.plist"
PAIRING_SERVICE="$(/usr/libexec/PlistBuddy -c 'Print :NSBonjourServices:0' "$INFO_PLIST_PATH")"
CONNECT_SERVICE="$(/usr/libexec/PlistBuddy -c 'Print :NSBonjourServices:1' "$INFO_PLIST_PATH")"
LOCAL_NETWORK_DESCRIPTION="$(/usr/libexec/PlistBuddy -c 'Print :NSLocalNetworkUsageDescription' "$INFO_PLIST_PATH")"
BONJOUR_DISCOVERY_ENABLED="$(/usr/libexec/PlistBuddy -c 'Print :ADBTVBonjourDiscoveryEnabled' "$INFO_PLIST_PATH")"
CAMERA_DESCRIPTION="$(/usr/libexec/PlistBuddy -c 'Print :NSCameraUsageDescription' "$INFO_PLIST_PATH")"
ALLOWS_HTTP="$(/usr/libexec/PlistBuddy -c 'Print :NSAppTransportSecurity:NSAllowsArbitraryLoads' "$INFO_PLIST_PATH")"
APP_ICON_NAME="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIcons:CFBundlePrimaryIcon:CFBundleIconName' "$INFO_PLIST_PATH")"
MARKETING_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$INFO_PLIST_PATH")"
BUILD_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$INFO_PLIST_PATH")"
INPUT_HELPER_APK="$APP_PATH/ADBTVInput.apk"
APK_TYPE_IDENTIFIER="$(/usr/libexec/PlistBuddy -c 'Print :UTImportedTypeDeclarations:0:UTTypeIdentifier' "$INFO_PLIST_PATH")"
APK_TYPE_EXTENSION="$(/usr/libexec/PlistBuddy -c 'Print :UTImportedTypeDeclarations:0:UTTypeTagSpecification:public.filename-extension:0' "$INFO_PLIST_PATH")"
if ! /usr/libexec/PlistBuddy -c 'Print :UILaunchScreen' "$INFO_PLIST_PATH" >/dev/null; then
  echo "Built app is missing its launch-screen configuration" >&2
  exit 1
fi
if [[ "$PAIRING_SERVICE" != '_adb-tls-pairing._tcp' \
    || "$CONNECT_SERVICE" != '_adb-tls-connect._tcp' \
    || -z "$LOCAL_NETWORK_DESCRIPTION" \
    || "$BONJOUR_DISCOVERY_ENABLED" != 'NO' \
    || -z "$CAMERA_DESCRIPTION" \
    || "$ALLOWS_HTTP" != 'true' \
    || "$APP_ICON_NAME" != 'AppIcon' \
    || "$APK_TYPE_IDENTIFIER" != 'com.android.package-archive' \
    || "$APK_TYPE_EXTENSION" != 'apk' \
    || -z "$MARKETING_VERSION" \
    || -z "$BUILD_VERSION" \
    || ! -f "$INPUT_HELPER_APK" \
    || ! -f "$APP_PATH/Assets.car" ]]; then
  echo "Built app has invalid discovery, permission, APK/input-helper, HTTP, or app icon metadata" >&2
  exit 1
fi
if [[ -n "$EXPECTED_MARKETING_VERSION" \
    && "$MARKETING_VERSION" != "$EXPECTED_MARKETING_VERSION" ]]; then
  echo "Built app version $MARKETING_VERSION does not match expected version $EXPECTED_MARKETING_VERSION" >&2
  exit 1
fi

PAYLOAD_DIR="$OUTPUT_DIR/Payload"
rm -rf "$PAYLOAD_DIR"
mkdir -p "$PAYLOAD_DIR"
ditto "$APP_PATH" "$PAYLOAD_DIR/$(basename "$APP_PATH")"

(
  cd "$OUTPUT_DIR"
  rm -f "$IPA_NAME" "$CHECKSUM_NAME"
  zip -qry "$IPA_NAME" Payload
  shasum -a 256 "$IPA_NAME" >"$CHECKSUM_NAME"
)

echo "$OUTPUT_DIR/$IPA_NAME"
echo "$OUTPUT_DIR/$CHECKSUM_NAME"
