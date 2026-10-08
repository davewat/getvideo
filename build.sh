#!/bin/sh
# Builds GetVideo into one self-contained macOS binary: dist/getvideo.
# The web UI (web/) is embedded by go:embed, so Go is the only requirement.
#
#   ./build.sh            universal binary (Apple Silicon + Intel)
#   ./build.sh native     this machine's architecture only (faster)
set -eu
cd "$(dirname "$0")"

VERSION=$(git describe --tags --always --dirty 2>/dev/null || echo dev)
LDFLAGS="-s -w -X main.version=$VERSION"
OUT=dist/getvideo
mkdir -p dist
rm -f "$OUT" # go build refuses to overwrite a universal binary

echo "==> checks"
test -z "$(gofmt -l .)" || { echo "gofmt needed:"; gofmt -l .; exit 1; }
go vet ./...
go test ./...

build() { # build <arch> <output>
	CGO_ENABLED=0 GOOS=darwin GOARCH="$1" go build -trimpath -ldflags "$LDFLAGS" -o "$2" .
}

if [ "${1:-universal}" = native ]; then
	echo "==> building $(go env GOARCH)"
	build "$(go env GOARCH)" "$OUT"
else
	echo "==> building arm64 + amd64"
	build arm64 dist/getvideo-arm64
	build amd64 dist/getvideo-amd64
	lipo -create -output "$OUT" dist/getvideo-arm64 dist/getvideo-amd64
	rm dist/getvideo-arm64 dist/getvideo-amd64
fi

echo "==> $OUT ($VERSION, $(du -h "$OUT" | cut -f1 | tr -d ' '))"
file "$OUT" | sed 's/^/    /'
