#!/bin/bash
set -euo pipefail

TARGET=dtb_selector
GO="${GO:-go}"
# Note: Separate FLAGS arguments with spaces, not "=".
VERSION="$(TZ=Asia/Shanghai date +%Y.%m.%d)"
FLAGS=(-ldflags "-s -w -X main.Version=${VERSION}")
echo "Version     = $VERSION"

# --- Locate script and project root directories ---
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

if [[ -d "$SCRIPT_DIR/dtbTools" && -d "$SCRIPT_DIR/boot" ]]; then
  ROOT_DIR="$SCRIPT_DIR"
elif [[ -d "$SCRIPT_DIR/../dtbTools" && -d "$SCRIPT_DIR/../boot" ]]; then
  ROOT_DIR="$(cd -- "$SCRIPT_DIR/.." && pwd)"
else
  echo "[ERROR] Could not locate the project root (both dtbTools/ and boot/ must exist)" >&2
  exit 1
fi

MODULE_DIR="$ROOT_DIR/dtbTools"
OUT_DIR="$ROOT_DIR/boot/dArkOS"

# Copy the source to a local disk before building (Go source scans are very slow on drvfs/9p, e.g. /mnt/d; measured 12.7s -> 0.7s).
BUILD_DIR="$(mktemp -d -t dtbsrc.XXXXXXX)"
cp -r "$MODULE_DIR"/. "$BUILD_DIR"/
trap 'rm -rf "$BUILD_DIR"' EXIT
MODULE_DIR="$BUILD_DIR"

echo "ROOT_DIR   = $ROOT_DIR"
echo "MODULE_DIR = $MODULE_DIR"
echo "OUT_DIR    = $OUT_DIR"
echo

# --- Platform build functions ---
# Use filenames relative to OUT_DIR for all executables.
build_win32() {
  local exe="${TARGET}_win32.exe"
  echo "Building: Windows 32-bit"
  (cd "$MODULE_DIR" && GOOS=windows GOARCH=386 "$GO" build "${FLAGS[@]}" -o "$OUT_DIR/$exe" .)
  echo "Generated: boot/dArkOS/$exe"
}

build_win64() {
  local exe="${TARGET}_win64.exe"
  echo "Building: Windows 64-bit"
  (cd "$MODULE_DIR" && GOOS=windows GOARCH=amd64 "$GO" build "${FLAGS[@]}" -o "$OUT_DIR/$exe" .)
  echo "Generated: boot/dArkOS/$exe"
}

build_macos_intel() {
  local exe="${TARGET}_macos_intel"
  echo "Building: macOS Intel"
  (cd "$MODULE_DIR" && GOOS=darwin GOARCH=amd64 "$GO" build "${FLAGS[@]}" -o "$OUT_DIR/$exe" .)
  echo "Generated: boot/dArkOS/$exe"
}

build_macos_apple_silicon() {
  local exe="${TARGET}_macos_apple"
  echo "Building: macOS Apple Silicon"
  (cd "$MODULE_DIR" && GOOS=darwin GOARCH=arm64 "$GO" build "${FLAGS[@]}" -o "$OUT_DIR/$exe" .)
  echo "Generated: boot/dArkOS/$exe"
}

build_macos() {
  local lipo
  lipo="$(go env GOPATH)/bin/lipo"
  if [[ ! -x "$lipo" ]]; then
    echo "Installing: lipo"
    "$GO" install github.com/konoui/lipo@v0.10.0
    lipo="$(go env GOPATH)/bin/lipo"
  fi

  local exe="${TARGET}_macos"
  echo "Building: macOS Universal"

  (cd "$MODULE_DIR" && GOOS=darwin GOARCH=amd64 "$GO" build "${FLAGS[@]}" -o "$OUT_DIR/${exe}_amd64" .)
  (cd "$MODULE_DIR" && GOOS=darwin GOARCH=arm64 "$GO" build "${FLAGS[@]}" -o "$OUT_DIR/${exe}_arm64" .)

  "$lipo" -output "$OUT_DIR/$exe" -create "$OUT_DIR/${exe}_arm64" "$OUT_DIR/${exe}_amd64"
  rm -f "$OUT_DIR/${exe}_amd64" "$OUT_DIR/${exe}_arm64"

  echo "Generated: boot/dArkOS/$exe"
}

build_linux32() {
  local exe="${TARGET}_linux32"
  echo "Building: Linux 32-Bit"
  (cd "$MODULE_DIR" && GOOS=linux GOARCH=386 "$GO" build "${FLAGS[@]}" -o "$OUT_DIR/$exe" .)
  echo "Generated: boot/dArkOS/$exe"
}

build_linux64() {
  local exe="${TARGET}_linux64"
  echo "Building: Linux 64-Bit"
  (cd "$MODULE_DIR" && GOOS=linux GOARCH=amd64 "$GO" build "${FLAGS[@]}" -o "$OUT_DIR/$exe" .)
  echo "Generated: boot/dArkOS/$exe"
}

build_linux_arm64() {
  local exe="${TARGET}_linuxarm64"
  echo "Building: Linux ARM64"
  (cd "$MODULE_DIR" && GOOS=linux GOARCH=arm64 "$GO" build "${FLAGS[@]}" -o "$OUT_DIR/$exe" .)
  echo "Generated: boot/dArkOS/$exe"
}

build_linux_arm() {
  local exe="${TARGET}_linuxarm"
  echo "Building: Linux ARM 32-Bit"
  (cd "$MODULE_DIR" && GOOS=linux GOARCH=arm GOARM=7 "$GO" build "${FLAGS[@]}" -o "$OUT_DIR/$exe" .)
  echo "Generated: boot/dArkOS/$exe"
}

# --- --clean ---
clean_all() {
  echo "Cleaning outputs in $OUT_DIR"
  rm -f \
    "$OUT_DIR/${TARGET}_win32.exe" \
    "$OUT_DIR/${TARGET}_win64.exe" \
    "$OUT_DIR/${TARGET}_macos_intel" \
    "$OUT_DIR/${TARGET}_macos_apple" \
    "$OUT_DIR/${TARGET}_macos" \
    "$OUT_DIR/${TARGET}_linux32" \
    "$OUT_DIR/${TARGET}_linux64" \
    "$OUT_DIR/${TARGET}_linuxarm64" \
    "$OUT_DIR/${TARGET}_linuxarm"
}

# --- --help ---
usage() {
  cat <<EOF
Usage: $(basename "$0") [--clean] [--all] [--help]

Options:
  (no arg)    Build default platforms: win32, macos, linux32, linuxarm
  --all       Build all platforms
  --clean     Remove all build artifacts
  --help      Show this help
EOF
}

# --- Parse arguments ---
case "${1:-}" in
  --clean)
    clean_all
    exit 0
    ;;
  --help|-h)
    usage
    exit 0
    ;;
  --all)
    PLATFORMS=(
      build_win32
      build_win64
      build_macos_intel
      build_macos_apple_silicon
      build_macos
      build_linux32
      build_linux64
      build_linux_arm64
      build_linux_arm
    )
    ;;
  "")
    PLATFORMS=(
      build_win32
      build_macos
      build_linux32
      build_linux_arm
    )
    ;;
  *)
    echo "[ERROR] Unknown argument: $1" >&2
    usage
    exit 1
    ;;
esac

for platform in "${PLATFORMS[@]}"; do
  "$platform"
  echo
done