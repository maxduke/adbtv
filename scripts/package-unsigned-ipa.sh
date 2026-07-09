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

PAYLOAD_DIR="$OUTPUT_DIR/Payload"
rm -rf "$PAYLOAD_DIR"
mkdir -p "$PAYLOAD_DIR"
ditto "$APP_PATH" "$PAYLOAD_DIR/$(basename "$APP_PATH")"

(
  cd "$OUTPUT_DIR"
  rm -f "$IPA_NAME"
  zip -qry "$IPA_NAME" Payload
)

echo "$OUTPUT_DIR/$IPA_NAME"
