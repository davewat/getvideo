#!/bin/sh
# Builds the Go version of GetVideo: one self-contained file per platform.
# The web UI (web/) is embedded by go:embed, so Go is the only requirement.
#
#   ./build.sh            every platform:
#                           dist/getvideo                 macOS, universal (Apple Silicon + Intel)
#                           dist/windows/getvideo.exe     Windows, 64-bit Intel/AMD
#                           dist/ubuntu/getvideo          Ubuntu Linux, 64-bit Intel/AMD
#   ./build.sh native     this machine only (faster): dist/getvideo
set -eu
cd "$(dirname "$0")"

VERSION=$(git describe --tags --always --dirty 2>/dev/null || echo dev)
LDFLAGS="-s -w -X main.version=$VERSION"
OUT=dist/getvideo
mkdir -p dist
rm -f "$OUT" # go build refuses to overwrite a universal binary

echo "==> checks"
test -z "$(gofmt -l .)" || { echo "gofmt needed:"; gofmt -l .; exit 1; }
for os in darwin windows linux; do GOOS=$os go vet ./...; done
go test ./...

build() { # build <os> <arch> <output>
	CGO_ENABLED=0 GOOS="$1" GOARCH="$2" go build -trimpath -ldflags "$LDFLAGS" -o "$3" .
}

report() { echo "==> $1 ($VERSION, $(du -h "$1" | cut -f1 | tr -d ' '))"; }

if [ "${1:-all}" = native ]; then
	echo "==> building $(go env GOOS)/$(go env GOARCH)"
	build "$(go env GOOS)" "$(go env GOARCH)" "$OUT"
	report "$OUT"
	exit 0
fi

echo "==> building macOS arm64 + amd64"
build darwin arm64 dist/getvideo-arm64
build darwin amd64 dist/getvideo-amd64
lipo -create -output "$OUT" dist/getvideo-arm64 dist/getvideo-amd64
rm dist/getvideo-arm64 dist/getvideo-amd64
report "$OUT"

echo "==> building Windows amd64"
build windows amd64 dist/windows/getvideo.exe
report dist/windows/getvideo.exe

echo "==> building Ubuntu Linux amd64"
build linux amd64 dist/ubuntu/getvideo
report dist/ubuntu/getvideo
