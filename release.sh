#!/bin/sh
# Cuts a release: tags the current commit, builds the universal binary and
# the Mac app (mac/build.sh), and publishes both as a GitHub release.
#
#   ./release.sh v0.1.0
set -eu
cd "$(dirname "$0")"

VERSION=${1:-}
case "$VERSION" in
v[0-9]*.[0-9]*.[0-9]*) ;;
*) echo "usage: ./release.sh vMAJOR.MINOR.PATCH" >&2; exit 2 ;;
esac

test -z "$(git status --porcelain)" || { echo "working tree is not clean; commit first" >&2; exit 1; }
if git rev-parse -q --verify "refs/tags/$VERSION" >/dev/null; then
	echo "tag $VERSION already exists" >&2
	exit 1
fi

echo "==> pushing $(git rev-parse --abbrev-ref HEAD)"
git push origin HEAD

# Tag before building: both build scripts stamp from git describe.
echo "==> tagging $VERSION"
git tag -a "$VERSION" -m "GetVideo $VERSION"
./build.sh
./mac/build.sh

# No version in the file names: the site and README link to releases/latest/download/<name>.
ZIP="dist/getvideo-mac-go.zip"
rm -f "$ZIP"
ditto -c -k --keepParent dist/getvideo "$ZIP"

WINZIP="dist/getvideo-windows-go.zip"
rm -f "$WINZIP"
(cd dist/windows && zip -q -X "../getvideo-windows-go.zip" getvideo.exe)

# tar.gz keeps the executable bit; COPYFILE_DISABLE keeps macOS metadata out of it.
LINUXTAR="dist/getvideo-ubuntu-go.tar.gz"
rm -f "$LINUXTAR"
COPYFILE_DISABLE=1 tar -czf "$LINUXTAR" -C dist/ubuntu getvideo

APPZIP="dist/GetVideo-mac-native.zip"
rm -f "$APPZIP"
ditto -c -k --sequesterRsrc --keepParent dist/GetVideo.app "$APPZIP"

echo "==> publishing"
git push origin "$VERSION"
# The text after # is the name shown on the release page.
gh release create "$VERSION" "$APPZIP#Mac Native (preferred)" "$ZIP#Mac Go version" \
	"$WINZIP#Windows Go version (untested)" "$LINUXTAR#Ubuntu Go version (untested)" --title "GetVideo $VERSION" --generate-notes
