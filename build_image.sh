#!/usr/bin/env bash
set -euo pipefail

# ArkOS4Clone one-click build script
# Usage: sudo ./build_image.sh <image-path> [working-directory]
#        sudo ./build_image.sh --download [working-directory] [--ci]
# The working directory stores the image copy and temporary files. An ext4 filesystem is recommended for best performance.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Timestamp format (matches scripts/clone_support.sh)
BUILD_DATE="$(TZ=Asia/Shanghai date +%Y%m%d)"
OUTPUT_NAME="ArkOS4Clone-${BUILD_DATE}"
ARKOS_SOURCE_NAME="ArkOS_R35S-R36S_v2.0_11072025_MultiPanel.img"

# Colored output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

log_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
log_ok() { echo -e "${GREEN}[OK]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

need_root() {
  if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
    log_error "Please run this script with sudo"
    exit 1
  fi
}

check_image() {
  local img="$1"
  if [[ ! -f "$img" ]]; then
    log_error "Image file does not exist: $img"
    exit 1
  fi
  if [[ ! -r "$img" ]]; then
    log_error "Cannot read image file: $img"
    exit 1
  fi
  log_ok "Source image: $img"
}

check_tools() {
  local tools=(losetup mount umount parted rsync dd xz mkfs.exfat)
  for t in "${tools[@]}"; do
    if ! command -v "$t" >/dev/null 2>&1; then
      log_error "Required tool is missing: $t"
      exit 1
    fi
  done
  log_ok "All required tools are available"
}

download_arkos_image() (
  local cache_dir="$1"
  local image="$cache_dir/$ARKOS_SOURCE_NAME"
  local base_url="https://github.com/lcdyk0517/baidupan2release/releases/download/backup-r3xs/${ARKOS_SOURCE_NAME}.xz.7z"
  local t part staging
  local wget_opts=()
  read -r -a wget_opts <<< "$WGET_OPTS"

  if [[ -s "$image" ]]; then
    log_ok "Using cached source image: $image"
    return 0
  fi

  for t in wget 7z; do
    if ! command -v "$t" >/dev/null 2>&1; then
      log_error "Required download tool is missing: $t"
      exit 1
    fi
  done

  mkdir -p "$cache_dir"
  staging=$(mktemp -d "$cache_dir/.download.XXXXXX")
  trap 'rm -rf -- "$staging"' EXIT

  log_info "Downloading the ArkOS R35S/R36S MultiPanel source image..."
  for part in 001 002; do
    local expected_sha256 actual_sha256
    case "$part" in
      001) expected_sha256="76dda3708348d837c37e458cfe798d746de700f1ab9327af2989170d8792acc2" ;;
      002) expected_sha256="fb7e962f5685d9ae46be9807ee317d6bc27a43f71fc321161501519a20ae1661" ;;
    esac
    if ! wget "${wget_opts[@]}" -O "$staging/source.7z.$part" "${base_url}.$part"; then
      log_error "ArkOS source download failed (part $part)"
      exit 1
    fi
    actual_sha256="$(sha256sum "$staging/source.7z.$part" | cut -d' ' -f1)"
    if [[ "$actual_sha256" != "$expected_sha256" ]]; then
      log_error "ArkOS source checksum mismatch (part $part)"
      exit 1
    fi
  done

  # Stream only the expected member, never archive paths, into the staging directory.
  log_info "Extracting the ArkOS source image..."
  if ! 7z e -so "$staging/source.7z.001" "${ARKOS_SOURCE_NAME}.xz" > "$staging/source.img.xz" \
      || [[ ! -s "$staging/source.img.xz" ]]; then
    log_error "ArkOS source archive extraction failed"
    exit 1
  fi
  if ! xz -dc "$staging/source.img.xz" > "$staging/source.img" \
      || [[ ! -s "$staging/source.img" ]]; then
    log_error "ArkOS source xz decompression failed"
    exit 1
  fi
  mv -- "$staging/source.img" "$image"
  log_ok "Source image downloaded: $image"
)

check_uboot_files() {
  local uboot_dir="$SCRIPT_DIR/uboot"
  local files=("idbloader.img" "uboot.img" "trust.img" "flash_uboot.sh")
  for f in "${files[@]}"; do
    if [[ ! -f "$uboot_dir/$f" ]]; then
      log_error "U-Boot file is missing: $uboot_dir/$f"
      exit 1
    fi
  done
  log_ok "U-Boot files are available"
}

check_jdk_file() {
  local jdk_dir="$SCRIPT_DIR/roms/j2me/jdk"
  local jdk_file="$SCRIPT_DIR/zulu11.48.21-ca-jdk11.0.11-linux_aarch64.tar.gz"
  local jdk_url="https://cdn.azul.com/zulu-embedded/bin/zulu11.48.21-ca-jdk11.0.11-linux_aarch64.tar.gz"

  if [[ -d "$jdk_dir" ]]; then
    log_ok "JDK already exists: roms/j2me/jdk"
    return
  fi

  if [[ ! -f "$jdk_file" ]]; then
    log_info "Downloading JDK..."
    # Download as the original user to avoid permission issues.
    if [[ -n "${SUDO_USER:-}" ]]; then
      if sudo -u "$SUDO_USER" wget $WGET_OPTS -O "$jdk_file" "$jdk_url"; then
        log_ok "JDK download complete"
      else
        log_error "JDK download failed"
        sudo -u "$SUDO_USER" rm -f "$jdk_file" 2>/dev/null || true
        exit 1
      fi
    else
      if wget $WGET_OPTS -O "$jdk_file" "$jdk_url"; then
        log_ok "JDK download complete"
      else
        log_error "JDK download failed"
        rm -f "$jdk_file" 2>/dev/null || true
        exit 1
      fi
    fi
  else
    log_ok "Using cached JDK: $(basename "$jdk_file")"
  fi

  log_info "Extracting JDK to roms/j2me/jdk..."
  mkdir -p "$SCRIPT_DIR/roms/j2me"
  tar -xf "$jdk_file" -C "$SCRIPT_DIR/roms/j2me"
  mv "$SCRIPT_DIR/roms/j2me/zulu11.48.21-ca-jdk11.0.11-linux_aarch64" "$jdk_dir"
  rm -f "$jdk_file"
  if [[ -n "${SUDO_USER:-}" ]]; then
    chown -R "$SUDO_USER" "$SCRIPT_DIR/roms/j2me"
  fi
  log_ok "JDK ready: roms/j2me/jdk"
}

check_pm_libs() {
  local pm_libs_dir="$SCRIPT_DIR/roms/tools/PortMaster/libs"
  local runtimes_url="https://github.com/PortsMaster/PortMaster-New/releases/download/2026-09-02_1031/runtimes.all.aarch64.zip"

  # Required files
  local required_files=(
    "ags_3.6.squashfs"
    "dotnet-8.0.12.squashfs"
    "frt_2.1.6.squashfs"
    "frt_3.0.6_v1.squashfs"
    "frt_3.1.2.squashfs"
    "frt_3.2.3.squashfs"
    "frt_3.3.4.squashfs"
    "frt_3.4.5.squashfs"
    "frt_3.5.2.squashfs"
    "frt_3.5.3.squashfs"
    "frt_3.6.squashfs"
    "frt_4.0.4.squashfs"
    "frt_4.1.3.squashfs"
    "gmtoolkit.squashfs"
    "godot_4.2.2.mono.squashfs"
    "godot_4.2.2.squashfs"
    "godot_4.3.mono.squashfs"
    "godot_4.3.squashfs"
    "godot_4.4.1.mono.squashfs"
    "godot_4.4.1.squashfs"
    "godot_4.4.mono.squashfs"
    "godot_4.4.squashfs"
    "godot_4.5.mono.squashfs"
    "godot_4.5.squashfs"
    "godot_4.6.3.mono.squashfs"
    "godot_4.6.3.squashfs"
    "godot_4.7.1.mono.squashfs"
    "godot_4.7.1.squashfs"
    "mesa_pkg_0.1.squashfs"
    "mono-6.12.0.122-aarch64.squashfs"
    "python_3.11.squashfs"
    "pyxel_2.2.8_python_3.11.squashfs"
    "pyxel_2.3.18_python_3.11.squashfs"
    "pyxel_2.4.6_python_3.11.squashfs"
    "pyxel_2.9.5_python_3.11.squashfs"
    "qt6-eglfs-6.6.3-aarch64.squashfs"
    "renpy_8.1.3.squashfs"
    "renpy_8.3.4.squashfs"
    "rlvm.squashfs"
    "solarus-1.6.5.squashfs"
    "weston_pkg_0.2.squashfs"
    "zulu11.48.21-ca-jdk11.0.11-linux.squashfs"
    "zulu17.48.15-ca-jdk17.0.10-linux.squashfs"
    "zulu17.54.21-ca-jre17.0.13-linux.squashfs"
    "zulu23.32.11-ca-jre23.0.2-linux.squashfs"
    "zulu8.86.0.25-ca-jdk8.0.452-linux.squashfs"
  )

  # Check for missing files
  local missing=0
  for f in "${required_files[@]}"; do
    if [[ ! -f "$pm_libs_dir/$f" ]]; then
      missing=1
      break
    fi
  done

  if [[ $missing -eq 0 ]]; then
    log_ok "All pm_libs files are present: roms/tools/PortMaster/libs"
    return
  fi

  log_info "Downloading PortMaster runtimes (about 1.6 GB)..."
  mkdir -p "$pm_libs_dir"
  local zip_file="$pm_libs_dir/runtimes.zip"

  # Download
  if [[ -n "${SUDO_USER:-}" ]]; then
    if sudo -u "$SUDO_USER" wget $WGET_OPTS -O "$zip_file" "$runtimes_url"; then
      log_ok "Runtimes download complete"
    else
      log_error "Runtimes download failed"
      sudo -u "$SUDO_USER" rm -f "$zip_file" 2>/dev/null || true
      exit 1
    fi
    # Extract
    log_info "Extracting runtimes..."
    sudo -u "$SUDO_USER" unzip -o -q "$zip_file" -d "$pm_libs_dir"
    sudo -u "$SUDO_USER" rm -f "$zip_file"
  else
    if wget $WGET_OPTS -O "$zip_file" "$runtimes_url"; then
      log_ok "Runtimes download complete"
    else
      log_error "Runtimes download failed"
      rm -f "$zip_file" 2>/dev/null || true
      exit 1
    fi
    # Extract
    log_info "Extracting runtimes..."
    unzip -o -q "$zip_file" -d "$pm_libs_dir"
    rm -f "$zip_file"
  fi

  if [[ -n "${SUDO_USER:-}" ]]; then
    chown -R "$SUDO_USER" "$pm_libs_dir"
  fi
  log_ok "pm_libs files are ready: roms/tools/PortMaster/libs"
}

check_install_portmaster() {
  # Fetch Install.PortMaster.sh from the latest PortMaster-GUI release and
  # place it in roms/tools/ (bind-mounted as /opt/system/Tools on the device).
  # Use a cached copy if it is at least as recent as the online asset.
  # If the API is unavailable, reuse a local copy and fail only if none exists.
  local dst="$SCRIPT_DIR/roms/tools/Install.PortMaster.sh"
  local url="" updated_at=""

  log_info "Checking for the latest Install.PortMaster.sh..."
  local api_json
  # Timeouts prevent direct GitHub API requests from hanging when sudo strips proxy variables.
  api_json=$(curl -s --connect-timeout 8 --max-time 25 \
    https://api.github.com/repos/PortsMaster/PortMaster-GUI/releases/latest 2>/dev/null || true)
  if [[ -n "$api_json" ]]; then
    # Feed JSON through a here-string: the build's stdin is the sudo password
    # pipe (EOF), so reading JSON from stdin in Python would always fail.
    read -r url updated_at <<< "$(python3 -c "
import sys, json
try:
    d = json.loads(sys.argv[1])
    a = next(a for a in d['assets'] if a['name'] == 'Install.PortMaster.sh')
    print(a['browser_download_url'], a['updated_at'])
except Exception:
    pass
" "$api_json" 2>/dev/null || true)"
  fi

  # If the local copy is at least as recent as the online asset, skip downloading.
  if [[ -s "$dst" ]]; then
    if [[ -n "$updated_at" ]]; then
      local asset_epoch local_epoch
      asset_epoch=$(date -d "$updated_at" +%s 2>/dev/null || echo 0)
      local_epoch=$(stat -c%Y "$dst" 2>/dev/null || echo 0)
      if (( local_epoch >= asset_epoch )); then
        log_ok "Local Install.PortMaster.sh is up to date ($(date -d "@$local_epoch" '+%F %T')); skipping download"
        return 0
      fi
      log_info "A newer online version is available ($(date -d "@$asset_epoch" '+%F %T')); downloading..."
    else
      log_warn "Cannot check for updates (GitHub API unavailable); using the local copy"
      log_warn "Tip: To use a proxy, run sudo -E ./build_image.sh ... to preserve environment variables"
      return 0
    fi
  else
    if [[ -z "$url" ]]; then
      log_error "Could not get the Install.PortMaster.sh download URL (GitHub API), and no local copy exists"
      exit 1
    fi
  fi

  mkdir -p "$(dirname "$dst")"
  log_info "Downloading Install.PortMaster.sh ($url)..."
  if [[ -n "${SUDO_USER:-}" ]]; then
    sudo -u "$SUDO_USER" wget $WGET_OPTS -O "$dst" "$url"
  else
    wget $WGET_OPTS -O "$dst" "$url"
  fi
  if [[ ! -s "$dst" ]]; then
    log_error "Install.PortMaster.sh download failed"
    rm -f "$dst"
    exit 1
  fi
  chmod +x "$dst"
  log_ok "Install.PortMaster.sh is ready: roms/tools/ ($(du -h "$dst" | cut -f1))"
}

check_work_dir() {
  local dir="$1"
  if [[ ! -d "$dir" ]]; then
    log_info "Creating working directory: $dir"
    mkdir -p "$dir"
  fi
  # Check that the directory is writable.
  if [[ ! -w "$dir" ]]; then
    log_error "Working directory is not writable: $dir"
    exit 1
  fi
  log_ok "Working directory: $dir"
}

check_portmaster() {
  local pm_dir="$SCRIPT_DIR/PortMaster"
  local pm_dst="$SCRIPT_DIR/roms/tools/PortMaster"
  local pm_url="https://github.com/PortsMaster/PortMaster-GUI/releases/download/2026.09.13-0343/PortMaster.zip"

  if [[ -d "$pm_dst" && -f "$pm_dst/PortMaster.sh" ]]; then
    log_ok "PortMaster already exists: roms/tools/PortMaster"
    return
  fi

  if [[ ! -d "$pm_dir" || ! -f "$pm_dir/PortMaster.sh" ]]; then
    log_info "Downloading PortMaster..."
    local zip_file="$SCRIPT_DIR/PortMaster.zip"

    if [[ -n "${SUDO_USER:-}" ]]; then
      if sudo -u "$SUDO_USER" wget $WGET_OPTS -O "$zip_file" "$pm_url"; then
        log_ok "PortMaster download complete"
      else
        log_error "PortMaster download failed"
        sudo -u "$SUDO_USER" rm -f "$zip_file" 2>/dev/null || true
        exit 1
      fi
      log_info "Extracting PortMaster..."
      sudo -u "$SUDO_USER" unzip -q -o "$zip_file" -d "$SCRIPT_DIR"
      sudo -u "$SUDO_USER" rm -f "$zip_file"
    else
      if wget $WGET_OPTS -O "$zip_file" "$pm_url"; then
        log_ok "PortMaster download complete"
      else
        log_error "PortMaster download failed"
        rm -f "$zip_file" 2>/dev/null || true
        exit 1
      fi
      log_info "Extracting PortMaster..."
      unzip -q -o "$zip_file" -d "$SCRIPT_DIR"
      rm -f "$zip_file"
    fi
  else
    log_ok "Using cached PortMaster: ./PortMaster"
  fi

  mkdir -p "$pm_dst"
  cp -rf "$pm_dir/." "$pm_dst/"
  cp -f "$pm_dir/PortMaster.sh" "$SCRIPT_DIR/roms/tools/PortMaster.sh"
  if [[ -n "${SUDO_USER:-}" ]]; then
    chown -R "$SUDO_USER" "$SCRIPT_DIR/roms/tools"
  fi
  log_ok "PortMaster is ready: roms/tools/PortMaster"
}

check_clone_dependencies() {
  log_info "Checking dependencies for scripts/clone_support.sh..."
  local missing=0
  local missing_list=""

  # Required directories
  local dirs=(
    "boot/dArkOS"
    "boot/ArkOS"
    "rootfs/dArkOS"
    "rootfs/ArkOS"
  )

  # Required files
  local files=(
    "boot/dArkOS/dtb_selector_linux32"
    "boot/dArkOS/dtb_selector_macos"
    "boot/dArkOS/dtb_selector_win32.exe"
    "boot/dArkOS/clone.sh"
    "boot/dArkOS/expandtoexfat.sh"
    "boot/ArkOS/expandtoexfat.sh"
  )

  for f in "${files[@]}"; do
    if [[ ! -f "$SCRIPT_DIR/$f" ]]; then
      missing=1
      missing_list="$missing_list\n  Missing file: $f"
    fi
  done

  if [[ $missing -eq 1 ]]; then
    log_error "Dependency check failed for scripts/clone_support.sh"
    echo -e "$missing_list"
    exit 1
  fi

  log_ok "Dependencies for scripts/clone_support.sh are available"
}

step_build_dtb_selector() {
  log_info "Step 0/8: Building the dtb_selector tool..."
  if [[ -f "$SCRIPT_DIR/scripts/build_dtb_selector.sh" ]]; then
    cd "$SCRIPT_DIR"
    # Build as the original user, preserving the PATH environment variable.
    if [[ -n "${SUDO_USER:-}" ]]; then
      if sudo -u "$SUDO_USER" env PATH="$PATH" ./scripts/build_dtb_selector.sh; then
        log_ok "dtb_selector build complete"
      else
        log_warn "dtb_selector build failed; skipping (it may already exist)"
      fi
    else
      if ./scripts/build_dtb_selector.sh; then
        log_ok "dtb_selector build complete"
      else
        log_warn "dtb_selector build failed; skipping (it may already exist)"
      fi
    fi
    cd - > /dev/null
  else
    log_warn "scripts/build_dtb_selector.sh not found; skipping"
  fi
}

copy_image() {
  local src="$1"
  local dst="$2"
  log_info "Step 1/8: Copying the source image to the working directory..."
  cp "$src" "$dst"
  log_ok "Working copy created: $dst"
}

step_grow() {
  local img="$1"
  log_info "Step 2/8: Resizing image partitions..."
  if "$SCRIPT_DIR/scripts/repart_image.sh" "$img"; then
    log_ok "Partition resizing complete"
  else
    log_error "Partition resizing failed"
    exit 1
  fi
}

step_flash_uboot() {
  local img="$1"
  log_info "Step 3/8: Writing U-Boot..."
  # Run from the uboot directory and use an absolute path.
  local abs_img
  if [[ "$img" = /* ]]; then
    abs_img="$img"
  else
    abs_img="$(pwd)/$img"
  fi
  cd "$SCRIPT_DIR/uboot"
  if ./flash_uboot.sh -y -i "$abs_img"; then
    log_ok "U-Boot write complete"
  else
    log_error "U-Boot write failed"
    cd "$SCRIPT_DIR"
    exit 1
  fi
  cd "$SCRIPT_DIR"
}

step_mount() {
  local img="$1"
  log_info "Step 4/8: Mounting the image..."
  if "$SCRIPT_DIR/scripts/mount_arkos.sh" mount "$img"; then
    log_ok "Image mounted"
  else
    log_error "Failed to mount image"
    exit 1
  fi
}

step_inject() {
  log_info "Step 5/8: Injecting custom files..."
  if "$SCRIPT_DIR/scripts/clone_support.sh"; then
    log_ok "File injection complete"
  else
    log_error "File injection failed"
    # Attempt to unmount.
    "$SCRIPT_DIR/scripts/mount_arkos.sh" unmount 2>/dev/null || true
    exit 1
  fi
}

step_unmount() {
  log_info "Step 6/8: Unmounting the image..."
  # Trim free blocks before unmounting to speed up xz compression without increasing the output size.
  if mountpoint -q "${ARKOS_MNT}/root" && command -v fstrim >/dev/null 2>&1; then
    log_info "Running fstrim on the root partition (zeroing free blocks)..."
    fstrim -v "${ARKOS_MNT}/root" || log_warn "fstrim failed (discard is unsupported); skipping"
  fi
  if "$SCRIPT_DIR/scripts/mount_arkos.sh" unmount; then
    log_ok "Image unmounted"
  else
    log_error "Failed to unmount image"
    exit 1
  fi
}

step_verify_fs() {
  log_info "Step 7/8: Verifying the p2 filesystem..."
  local img="$1"
  local loop="" rc=0 fstype=""

  # Define cleanup before setting the trap; ${loop:-} is safe with set -u.
  _verify_fs_cleanup() {
    if [[ -n "${loop:-}" ]]; then
      losetup -d "$loop" 2>/dev/null || true
    fi
    return 0
  }
  trap _verify_fs_cleanup RETURN

  # Verify that a loop device was allocated before entering the trap-protected section.
  if ! loop=$(losetup --find -P --show "$img"); then
    loop=""
    log_error "Could not create a loop device for $img"
    return 1
  fi

  fstype=$(blkid -o value -s TYPE "${loop}p2" 2>/dev/null || true)

  case "$fstype" in
    ext2|ext3|ext4)
      log_info "Checking the p2 filesystem (e2fsck, $fstype)..."
      # -e passes through e2fsck's exit code; -y automatically confirms repairs.
      script -e -q -c "e2fsck -fvy '${loop}p2'" /dev/null
      rc=$?
      if (( rc > 3 )); then
        log_error "The p2 $fstype filesystem has uncorrected errors (e2fsck rc=$rc)"
        return 1
      fi
      ;;

    btrfs)
      log_info "Checking the p2 filesystem (btrfs check, $fstype)..."
      if btrfs check --readonly "${loop}p2"; then
        rc=0
      else
        rc=$?
      fi
      if (( rc != 0 )); then
        log_error "The p2 btrfs filesystem contains errors (btrfs check rc=$rc)"
        return 1
      fi
      ;;

    "")
      log_error "Could not detect the filesystem type on ${loop}p2 (blkid returned empty)"
      return 1
      ;;

    *)
      log_error "Unsupported filesystem type: $fstype"
      return 1
      ;;
  esac

  log_ok "p2 filesystem check passed ($fstype, rc=$rc)"

  # Read back every byte of roms.tar after dropping caches to force a disk read
  # and detect filesystem data corruption (a source of device-side I/O errors).
  mkdir -p /mnt/arkos_verify
  if mount -o ro "${loop}p2" /mnt/arkos_verify 2>/dev/null; then
    if [[ -f /mnt/arkos_verify/roms.tar ]]; then
      sync
      echo 3 > /proc/sys/vm/drop_caches 2>/dev/null || true
      log_info "Reading back all of roms.tar (cold cache, direct block reads)..."
      if ! md5sum /mnt/arkos_verify/roms.tar > /dev/null 2>&1; then
        log_error "I/O error while reading back roms.tar -- image data is corrupted"
        umount /mnt/arkos_verify 2>/dev/null
        losetup -d "$loop" 2>/dev/null
        exit 1
      fi
      local members
      members=$(tar -tf /mnt/arkos_verify/roms.tar 2>/dev/null | wc -l)
      log_ok "roms.tar readback check passed (${members} members, no I/O errors)"
    else
      log_warn "No roms.tar in the image; skipping readback check"
    fi
    umount /mnt/arkos_verify 2>/dev/null || true
  fi
  rmdir /mnt/arkos_verify 2>/dev/null || true
}

step_compress() {
  local img="$1"
  local xz_file="${img}.xz"
  log_info "Step 8/8: Compressing the image (xz -5)..."
  
  # Compression level 5, using multiple threads.
  if xz -5 -T0 -v "$img"; then
    log_ok "Compression complete: $xz_file"
    log_ok "File size: $(du -h "$xz_file" | cut -f1)"
    # Checksum sidecar: run md5sum -c after copying .xz to a 9p drive such as /mnt/d.
    # Large writes to WSL 9p can silently lose data.
    md5sum "$xz_file" > "${xz_file}.md5"
    log_ok "Checksum file: ${xz_file}.md5"
  else
    log_error "Compression failed"
    exit 1
  fi
}

move_to_script_dir() {
  local xz_file="$1"
  local dest="$SCRIPT_DIR/$(basename "$xz_file")"
  log_info "Moving output file to the script directory..."
  mv "$xz_file" "$dest" || true
  log_ok "Output file: $dest"
}

show_usage() {
  cat << USAGE
ArkOS4Clone one-click build script

Usage:
  sudo ./build_image.sh <source-image-path> [working-directory] [--ci]
  sudo ./build_image.sh --download [working-directory] [--ci]

Arguments:
  source-image-path  Path to the original ArkOS or dArkOS image (unless --download)
  --download         Download and extract the ArkOS R35S/R36S MultiPanel source
                     used by the release workflow, then build the modified image
  working-directory  Optional; directory for the image copy and temporary files
                     An ext4 filesystem is recommended for best performance
                     Default: directory containing the source image, or the
                     script directory with --download
  --ci               Optional; quiet mode to reduce download progress and other logs

Environment variables:
  ARKOS_MNT       Mount path (default: <working-directory>/mnt)
  ARKOS_WORK_DIR  Temporary working directory (default: <working-directory>)

Examples:
  # Download ArkOS and build ArkOS4Clone in one command
  sudo ./build_image.sh --download

  # Download and build in a dedicated working directory
  sudo ./build_image.sh --download /home/lcdyk/arkos --ci

  # Use the default working directory (the source image directory)
  sudo ./build_image.sh /path/to/ArkOS-*.img

  # Specify a working directory (recommended; use an ext4 filesystem)
  sudo ./build_image.sh /mnt/e/ArkOS.img /home/lcdyk/arkos

Steps:
  0. Build the dtb_selector tool (scripts/build_dtb_selector.sh)
  1. Copy the source image to the working directory
  2. Resize partitions (scripts/repart_image.sh): grow p1 to 256M and p2 to 11G, then recreate p3 at its original size
  3. Write U-Boot (flash_uboot.sh)
  4. Mount the image (scripts/mount_arkos.sh mount)
  5. Inject custom files (scripts/clone_support.sh)
  6. Unmount the image (scripts/mount_arkos.sh unmount)
  7. Verify the p2 filesystem
  8. Compress the image and move the output file to the script directory

Output:
  <script-directory>/ArkOS4Clone-MMDDYYYY.img.xz

Notes:
  - The source image is not modified.
  - --download needs wget and 7z (Ubuntu packages: wget, p7zip-full).
  - Downloaded sources are cached in <working-directory>/source-images.
    Delete the cached .img to force a new download; temporary archives are removed.
  - Use an ext4 working directory instead of a WSL /mnt path for best performance.

USAGE
}

main() {
  local download=0 ci=0 arg
  local positional=()
  for arg in "$@"; do
    case "$arg" in
      -h|--help) show_usage; return 0 ;;
      --download) download=1 ;;
      --ci) ci=1 ;;
      -*) log_error "Unknown option: $arg"; return 1 ;;
      *) positional+=("$arg") ;;
    esac
  done

  if (( (download == 0 && (${#positional[@]} < 1 || ${#positional[@]} > 2)) \
      || (download == 1 && ${#positional[@]} > 1) )); then
    log_error "Provide an image path and optional working directory, or --download and optional working directory"
    echo ""
    show_usage
    exit 1
  fi

  need_root
  local source_image=""
  
  # Determine the working directory.
  local work_dir
  if (( download )); then
    work_dir="${positional[0]:-$SCRIPT_DIR}"
  else
    source_image="${positional[0]}"
    check_image "$source_image"
    work_dir="${positional[1]:-$(cd "$(dirname "$source_image")" && pwd)}"
  fi

  # Convert to an absolute path.
  if [[ "$work_dir" != /* ]]; then
    work_dir="$(pwd)/$work_dir"
  fi

  if (( ci )); then
    WGET_OPTS="-q"
    export ARKOS_QUIET=1
  else
    WGET_OPTS="-q --show-progress"
  fi

  check_tools
  check_work_dir "$work_dir"
  if (( download )); then
    download_arkos_image "$work_dir/source-images"
    source_image="$work_dir/source-images/$ARKOS_SOURCE_NAME"
  fi

  # Set environment variables.
  ARKOS_MNT="${ARKOS_MNT:-${work_dir}/mnt}"
  ARKOS_WORK_DIR="${ARKOS_WORK_DIR:-${work_dir}}"
  ARKOS_IMAGE_NAME="$(basename "$source_image")"
  export ARKOS_MNT ARKOS_WORK_DIR ARKOS_IMAGE_NAME

  # Select the output prefix based on the source image name.
  local output_prefix
  if [[ "$ARKOS_IMAGE_NAME" == *dArkOS* ]]; then
    output_prefix="dArkOS4Clone"
  else
    output_prefix="ArkOS4Clone"
  fi
  local work_image="${work_dir}/${output_prefix}-${BUILD_DATE}.img"

  echo "========================================"
  echo "  ArkOS4Clone one-click build script"
  echo "========================================"
  echo "Source image:   $source_image"
  echo "Working directory: $work_dir"
  echo "Working copy:   $work_image"
  echo "Mount path:     $ARKOS_MNT"
  echo "========================================"
  echo ""

  # Step 0: Build dtb_selector (does not require root).
  step_build_dtb_selector
  echo ""

  # Prerequisite checks (do not require root).
  check_jdk_file
  check_portmaster
  check_pm_libs
  check_install_portmaster
  check_clone_dependencies

  # Checks that require root.
  check_image "$source_image"
  check_uboot_files

  # Step 1: Copy the image.
  echo ""
  copy_image "$source_image" "$work_image"
  # Step 2: Resize partitions.
  echo ""
  step_grow "$work_image"
  # Step 3: Write U-Boot.
  echo ""
  step_flash_uboot "$work_image"
  # Step 4: Mount the image.
  echo ""
  step_mount "$work_image"
  # Step 5: Inject custom files.
  echo ""
  step_inject
  # Step 6: Unmount the image.
  echo ""
  step_unmount
  # Step 7: Verify the p2 filesystem.
  echo ""
  step_verify_fs "$work_image"
  # Step 8: Compress and move the output.
  echo ""
  step_compress "$work_image"
  move_to_script_dir "${work_image}.xz"

  echo ""
  echo "========================================"
  log_ok "Build complete!"
  echo "Output file: $SCRIPT_DIR/$(basename "${work_image}").xz"
  echo "Source file preserved: $source_image"
  echo "========================================"
}

main "$@"
