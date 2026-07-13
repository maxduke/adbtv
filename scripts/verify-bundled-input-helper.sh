#!/usr/bin/env bash

set -euo pipefail

if [[ $# -ne 2 ]]; then
  echo "usage: $0 <source-built.apk> <bundled.apk>" >&2
  exit 64
fi

built_apk="$1"
bundled_apk="$2"

for apk in "$built_apk" "$bundled_apk"; do
  if [[ ! -f "$apk" ]]; then
    echo "APK not found: $apk" >&2
    exit 66
  fi
done

payload_entries() {
  unzip -Z1 "$1" \
    | LC_ALL=C sort \
    | sed -e '/\/$/d' -e '/^META-INF\//d'
}

if ! diff -u <(payload_entries "$built_apk") <(payload_entries "$bundled_apk"); then
  echo "Bundled input helper entries differ from the source build." >&2
  exit 1
fi

while IFS= read -r entry; do
  if ! cmp -s \
    <(unzip -p "$built_apk" "$entry") \
    <(unzip -p "$bundled_apk" "$entry"); then
    echo "Bundled input helper payload differs at: $entry" >&2
    exit 1
  fi
done < <(payload_entries "$built_apk")

echo "Bundled input helper payload matches the source build."
