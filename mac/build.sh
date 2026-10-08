#!/bin/sh
# Builds the native macOS app into one bundle: dist/GetVideo.app.
# It is a Swift package (no Xcode project); this script assembles the bundle
# around the built executable and ad-hoc signs it.
#
#   ./mac/build.sh            universal app (Apple Silicon + Intel)
#   ./mac/build.sh native     this machine's architecture only (faster)
#
# SKIP_TESTS=1 skips swift test.
set -eu
cd "$(dirname "$0")/.."

DESCRIBE=$(git describe --tags --always --dirty 2>/dev/null || echo dev)
# The plist needs a plain dotted version: v0.2.1-3-gabc1234-dirty -> 0.2.1.
VERSION=$(printf '%s\n' "$DESCRIBE" | sed -n 's/^v\{0,1\}\([0-9][0-9]*\(\.[0-9][0-9]*\)\{1,2\}\).*/\1/p')
VERSION=${VERSION:-0.0.0}
APP=dist/GetVideo.app

if [ "${SKIP_TESTS:-}" = 1 ]; then
	echo "==> checks skipped (SKIP_TESTS=1)"
else
	echo "==> checks"
	swift test --package-path mac
fi

if [ "${1:-universal}" = native ]; then
	echo "==> building $(uname -m)"
	swift build -c release --package-path mac
	BIN=$(swift build -c release --package-path mac --show-bin-path)/GetVideo
else
	echo "==> building arm64 + x86_64"
	swift build -c release --arch arm64 --arch x86_64 --package-path mac
	BIN=mac/.build/apple/Products/Release/GetVideo
fi
test -x "$BIN" || { echo "no executable at $BIN" >&2; exit 1; }

echo "==> assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/GetVideo"
cp mac/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
sed "s/__VERSION__/$VERSION/g" mac/Info.plist >"$APP/Contents/Info.plist"
plutil -lint "$APP/Contents/Info.plist" >/dev/null

echo "==> signing (ad hoc)"
codesign --force --deep --sign - "$APP"
codesign --verify --deep --strict "$APP"

echo "==> $APP ($VERSION from $DESCRIBE, $(du -sh "$APP" | cut -f1 | tr -d ' '))"
echo "    $(lipo -archs "$APP/Contents/MacOS/GetVideo")"
