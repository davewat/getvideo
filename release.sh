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

ZIP="dist/getvideo-$VERSION-macos-universal.zip"
rm -f "$ZIP"
ditto -c -k --keepParent dist/getvideo "$ZIP"

APPZIP="dist/GetVideo-$VERSION-macos.zip"
rm -f "$APPZIP"
ditto -c -k --sequesterRsrc --keepParent dist/GetVideo.app "$APPZIP"

echo "==> publishing"
git push origin "$VERSION"
gh release create "$VERSION" "$ZIP" "$APPZIP" --title "GetVideo $VERSION" --generate-notes
