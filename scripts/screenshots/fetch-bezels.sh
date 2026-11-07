#!/bin/bash
# Downloads Apple's official Product Bezels (https://developer.apple.com/design/resources/#product-bezels)
# into build/bezels. They are covered by the Apple Design Resources License and must not be committed.
set -euo pipefail
cd "$(dirname "$0")/../.."
OUT=build/bezels
mkdir -p "$OUT"
TMP=$(mktemp -d)
trap 'for m in "$TMP"/m-*; do hdiutil detach -quiet "$m" 2>/dev/null || true; done; rm -rf "$TMP"' EXIT

fetch() { # <dmg name> <png path inside dmg> <output name>
    [[ -f "$OUT/$3" ]] && return
    echo "==> $3"
    curl -sLf -o "$TMP/$1.dmg" "https://devimages-cdn.apple.com/design/resources/download/Bezel-$1.dmg"
    # The DMG shows a license prompt; the license is at the root of the image for you to read.
    printf 'Y\n' | hdiutil attach -nobrowse -mountpoint "$TMP/m-$1" "$TMP/$1.dmg" > /dev/null
    cp "$TMP/m-$1/PNG/$2" "$OUT/$3"
}

fetch "iPhone-18" "iPhone 18 Pro Max/iPhone 18 Pro Max - Black - Portrait.png" iphone-6.9.png
fetch "iPhone-18" "iPhone 18 Pro Max/iPhone 18 Pro Max - Black - Landscape.png" iphone-6.9-land.png
fetch "iPad-Pro-(M5)" 'iPad Pro (M5) 13" - Space Black - Portrait.png' ipad-13.png
fetch "iPhone-Duo" "iPhone Duo - Star White - Outer Closed Portrait.png" duo-folded.png
fetch "iPhone-Duo" "iPhone Duo - Star White - Inner Open Landscape.png" duo-unfolded.png
fetch "MacBook-Pro-M5" "MacBook Pro M5 14-inch Space Black.png" mac-14.png
echo "Bezels in $OUT"
