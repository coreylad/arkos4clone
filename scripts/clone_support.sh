#!/usr/bin/env bash
set -euo pipefail

# ============================================================
# ArkOS4Clone image injection script
# Sync the repository's boot/, rootfs/, and roms/ trees into the mounted image:
#   boot/dArkOS  + boot/ArkOS   -> $MOUNT_DIR/boot
#   rootfs/dArkOS + rootfs/ArkOS -> $MOUNT_DIR/root
#   roms/ (if present) -> package as /roms.tar; extract on first boot to the expanded p3
# Sync strategy is selected by ARKOS_IMAGE_NAME:
#   *dArkOS*: sync dArkOS, permissions 777 / 1000:1000
#   otherwise: sync dArkOS then ArkOS, permissions 777 / 1002:1002
# ============================================================

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$SCRIPT_DIR"
MOUNT_DIR="${ARKOS_MNT:-/home/lcdyk/arkos/mnt}"
# Guard against an empty or root MOUNT_DIR; subsequent find/rm -rf commands could affect the host filesystem.
if [[ -z "$MOUNT_DIR" || "$MOUNT_DIR" == "/" || ! -d "$MOUNT_DIR/root/usr/lib" ]]; then
  echo "[ERROR] Invalid MOUNT_DIR: '${MOUNT_DIR:-empty}' (is the image mounted?)"
  exit 1
fi
UPDATE_DATE="$(TZ=Asia/Shanghai date +%Y%m%d)"
MODDER="kk&lcdyk"

# safe: best-effort operation; preserve the remaining state and fail the build at the end.
FAIL_COUNT=0
safe() {
  if ! "$@"; then
    echo "[WARN] Failed: $*"
    FAIL_COUNT=$((FAIL_COUNT + 1))
  fi
}

# fatal: abort immediately on a critical operation failure to avoid producing a damaged image.
fatal() {
  if ! "$@"; then
    echo "[ERROR] Fatal failure: $*"
    exit 1
  fi
}

echo "== Free space on the image root partition before injection =="
df -h "$MOUNT_DIR/root" || true

# rsync options for the boot (FAT32) and root (ext4) partitions.
# For root, -p and --chmod=D0777,F0777 ensure files are written with mode 777;
# --chown sets the owner.
# -c compares checksums: ArkOS/dArkOS trees have matching mtimes after git checkout,
# and files such as BMPs can have the same dimensions/size despite different contents.
RSYNC_BOOT_OPTS="-rltcD --no-owner --no-group --no-perms --omit-dir-times"
RSYNC_ROOT_OPTS="-rlptcD --omit-dir-times"

echo "== Extracting large cores (.so.xz -> .so; skipping already extracted files) =="
while IFS= read -r -d '' core_xz; do
  core_so="${core_xz%.xz}"
  # Keep the archive in the repository; rsync --exclude omits it from the image.
  if [[ ! -f "$core_so" ]]; then
    echo "Extracting $core_xz"
    fatal xz -dk -T0 "$core_xz"
  else
    echo "Already extracted; skipping $core_xz"
  fi
done < <(find rootfs -name '*.so.xz' -print0)

sync_boot() {
  fatal sudo rsync $RSYNC_BOOT_OPTS "boot/$1/" "$MOUNT_DIR/boot/"
}

sync_rootfs() {
  # $1: rootfs/ subdirectory; $2: owner (e.g. 1002:1002)
  fatal sudo rsync $RSYNC_ROOT_OPTS --exclude='/home/ark/.config/retroarch*/cores/*.so.xz' --chown="$2" --chmod=D0777,F0777 "rootfs/$1/" "$MOUNT_DIR/root/"
}

pack_roms_tar() {
  # Package roms/ as /roms.tar on p2; expandtoexfat.sh extracts it to p3 after
  # expanding that partition on first boot.
  # Note: extraction uses tar -xf /roms.tar -C /, so members must have a roms/ prefix.
  # Package through a temporary view in /tmp: the project's roms/ contains only
  # incremental files, and the stock structure is merged during packaging only.
  if [[ ! -d roms ]]; then
    echo "== Skipping roms packaging (roms/ directory not found) =="
    return 0
  fi
  echo "== Packaging roms/ -> image /roms.tar =="

  # Empty roms directories and the pymo scanner required on first boot (source is in rootfs).
  local d
  for d in hbmame native32 bbk flash gametank spmp8000 krkr2 pymo; do
    mkdir -p "roms/$d"
  done
  if [[ ! -f roms/pymo/Scan_for_new_games.pymo && -f rootfs/dArkOS/opt/pymo/Scan_for_new_games.pymo ]]; then
    cp -f rootfs/dArkOS/opt/pymo/Scan_for_new_games.pymo roms/pymo/
  fi


  # Assemble the package view from project additions and the stock structure
  # (p3 is reformatted on first boot, so the stock structure must be in the archive).
  # Place files under stage/roms/ so tar members include the roms/ prefix.
  local stage need_mb avail_mb
  stage="$(mktemp -d -t roms_stage.XXXXXXX)"
  need_mb="$(du -sm roms | cut -f1)"
  avail_mb="$(df -Pm /tmp | awk 'NR==2{print $4}')"
  if (( avail_mb < need_mb + 500 )); then
    echo "[ERROR] Not enough space in /tmp: packaging needs about ${need_mb} MB, only ${avail_mb} MB available"
    exit 1
  fi
  mkdir -p "$stage/roms"

  # Merge the stock structure first, then project additions (project files take precedence).
  # Otherwise the old stock PortMaster/PortMaster.sh could overwrite the newly downloaded version.
  if [[ -d "$MOUNT_DIR/roms" ]]; then
    echo "== Merging stock roms structure (archive only; not copied into the project) =="
    fatal sudo rsync -a --checksum \
      --exclude 'System Volume Information' \
      --exclude 'EUMONBMP.SYS' \
      --exclude '*.CBM' \
      --exclude 'tools/Gamma' \
      --exclude 'tools/ES-logo-changer' \
      --exclude 'tools/PortMaster.sh' \
      \
      "$MOUNT_DIR/roms/" "$stage/roms"/
  fi

  # Stock tempthemes, if present: dArkOS includes five themes such as freeplay;
  # ArkOS includes the complete nes-box theme.
  if [[ -d "$MOUNT_DIR/root/tempthemes" ]]; then
    echo "== Merging stock tempthemes themes (archive only) =="
    fatal sudo rsync -a "$MOUNT_DIR/root/tempthemes/" "$stage/roms/themes/"
  fi

  # --checksum: Always let project files override stock files (same-size, same-mtime
  # files can otherwise be missed, as happened with the logo).
  # Project themes (roms/themes, including es-theme-nes-box and pymo) go directly into the archive.
  fatal sudo rsync -a --checksum \
    \
    roms/ "$stage/roms"/

  # Gamma / ES-logo-changer are no longer distributed; remove them even if added to stage elsewhere.
  safe sudo rm -rf "$stage/roms/tools/Gamma" "$stage/roms/tools/ES-logo-changer" "$stage/roms/tools/PortMaster.sh"

  # -h dereferences symlinks because the device's exFAT filesystem does not support them.
  # --owner=0 --group=0 normalizes archive ownership to root; otherwise the build
  # machine's UID would be stored, and extraction on exFAT would report permission errors.
  fatal sudo tar -h --hard-dereference --owner=0 --group=0 -cf "$MOUNT_DIR/root/roms.tar" -C "$stage" roms
  fatal sudo chmod 777 "$MOUNT_DIR/root/roms.tar"
  safe sudo rm -rf "$stage"
}

cleanup_stock() {
  # Remove stock files retained in the image.
  safe sudo rm -rf "$MOUNT_DIR/boot/BMPs" "$MOUNT_DIR/boot/ScreenFiles"
  safe sudo rm -rf "$MOUNT_DIR/boot/boot.ini" "$MOUNT_DIR"/boot/*.dtb "$MOUNT_DIR"/boot/*.orig \
    "$MOUNT_DIR"/boot/*.tony "$MOUNT_DIR"/boot/Image "$MOUNT_DIR"/boot/*.bmp \
    "$MOUNT_DIR/boot/WHERE_ARE_MY_ROMS.txt"
  safe sudo rm -f "$MOUNT_DIR/boot/DTB Change Tool.exe"
  safe sudo rm -rf "$MOUNT_DIR/root/opt/system/DeviceType"
  safe sudo rm -f "$MOUNT_DIR/root/opt/system/Change LED to Red.sh"
  safe sudo rm -f "$MOUNT_DIR/root/opt/system/Update.sh"
  safe sudo rm -f "$MOUNT_DIR/root/opt/system/Wifi.sh"
  safe sudo rm -f "$MOUNT_DIR/root/opt/system/Network Info.sh"
  safe sudo rm -f "$MOUNT_DIR/root/opt/system/Enable Remote Services.sh"
  safe sudo rm -f "$MOUNT_DIR/root/opt/system/Disable Remote Services.sh"
  safe sudo rm -f "$MOUNT_DIR/root/opt/system/Change Time.sh"
  safe sudo rm -rf "$MOUNT_DIR/root/opt/system/Advanced/NDS Overlays"
  safe sudo rm -f "$MOUNT_DIR/root/opt/system/Advanced/Change Ports SDL.sh"
  safe sudo find "$MOUNT_DIR/root/opt/system/Advanced" -name 'Restore*.sh' ! -name 'Restore ArkOS Settings.sh' -exec rm -f {} +
  safe sudo rm -f "$MOUNT_DIR/root/opt/system/Advanced/Screen - Switch to Original Screen Timings.sh"
  safe sudo rm -f "$MOUNT_DIR/root/opt/system/Advanced/Reset EmulationStation Controls.sh"
  safe sudo rm -f "$MOUNT_DIR/root/opt/system/Advanced/Fix Global Hotkeys.sh"
  safe sudo rm -f "$MOUNT_DIR/root/etc/emulationstation/es_input.cfg"
  # The tempthemes mechanism is retired: themes are delivered in roms.tar instead.
  safe sudo rm -rf "$MOUNT_DIR/root/tempthemes"
  # Keep p3 as stock NTFS in the image; expandtoexfat.sh converts it to exFAT and
  # updates fstab on first boot.
  # Keep fstab.exfat in the boot partition for first boot; tempthemes is retired
  # because themes are delivered in roms.tar.
}

prune_old_libs() {
  # Remove redundant libraries from the stock image (image builds only; OTA leaves device libraries untouched).
  local arch_dir dir f b newest real
  local sdl2_keep=" libSDL2-2.0.so.0.3200.10 libSDL2-2.0.so.0.18.2 "
  local lib_dirs=(
    "$MOUNT_DIR/root/usr/lib/arm-linux-gnueabihf"
    "$MOUNT_DIR/root/usr/lib/aarch64-linux-gnu"
  )

  # ---- 1) Library-related junk: stock .bak/.zip/.last files (e.g. 23 MB flycast backups) ----
  local junk_dirs=(
    "${lib_dirs[@]}"
    "$MOUNT_DIR/root/home/ark/.config/retroarch/cores"
    "$MOUNT_DIR/root/home/ark/.config/retroarch32/cores"
    "$MOUNT_DIR/root/opt/mupen64plus"
  )
  for dir in "${junk_dirs[@]}"; do
    [[ -d "$dir" ]] || continue
    while IFS= read -r -d '' f; do
      safe sudo rm -f "$f"
      echo "  Removing junk library file: ${f#$MOUNT_DIR/root}"
    done < <(sudo find "$dir" -maxdepth 1 \( -name '*.bak' -o -name '*.zip' -o -name '*.last' \) -type f -print0 2>/dev/null)
  done

  # ---- 2) SDL2 versions: keep 0.18.2 (used by coco/mvem/dragon LD_PRELOAD)
  #         and the newest version in each architecture directory. 64-bit uses
  #         0.3200.10; stock 32-bit has no 0.3200.10, so keep 0.3000.10 and let
  #         quirks replace it with 0.3200.10 on first boot. ----
  for arch_dir in "${lib_dirs[@]}"; do
    [[ -d "$arch_dir" ]] || continue
    local keep_newest
    keep_newest=$(ls -1 "$arch_dir" 2>/dev/null | grep -E '^libSDL2-2\.0\.so\.0\.[0-9]+\.[0-9]+$' | sort -V | tail -1)
    local keep=" libSDL2-2.0.so.0.18.2 ${keep_newest:+$keep_newest} "
    for f in "$arch_dir"/libSDL2-2.0.so.0.*[0-9]; do
      [[ -f "$f" && ! -L "$f" ]] || continue
      b="$(basename "$f")"
      [[ "$keep" == *" $b "* ]] && continue
      safe sudo rm -f "$f"
      echo "  Removing obsolete SDL2: $b"
    done
  done

  # ---- 3) Fix SDL2 soname/dev links: stock links may point to a version just
  #         removed, so point them to the newest retained version
  #         (32-bit=0.3000.10, 64-bit=0.3200.10). ----
  for arch_dir in "${lib_dirs[@]}"; do
    [[ -d "$arch_dir" ]] || continue
    newest=$(ls -1 "$arch_dir" 2>/dev/null | grep -E '^libSDL2-2\.0\.so\.0\.[0-9]+\.[0-9]+$' | sort -V | tail -1)
    [[ -n "$newest" ]] || continue
    if [[ "$(readlink "$arch_dir/libSDL2-2.0.so.0" 2>/dev/null)" != "$newest" ]]; then
      fatal sudo ln -sfn "$newest" "$arch_dir/libSDL2-2.0.so.0"
      echo "  Fixed SDL2 soname link: libSDL2-2.0.so.0 -> $newest"
    fi
    if [[ "$(readlink "$arch_dir/libSDL2.so" 2>/dev/null)" != "libSDL2-2.0.so.0" ]]; then
      fatal sudo ln -sfn "libSDL2-2.0.so.0" "$arch_dir/libSDL2.so"
      echo "  Fixed SDL2 dev link: libSDL2.so -> libSDL2-2.0.so.0"
    fi
  done

  # ---- 4) Collapse duplicate identical files with the same base into symlink chains. ----
  # Stock images sometimes copy intermediate files that should be symlinks
  # (e.g. Qt5 chains, solarus, linapple). Convert only when cmp confirms all
  # files in the group are identical; retain the file with the longest version.
  local collapse_dirs=(
    "${lib_dirs[@]}"
    "$MOUNT_DIR/root/opt/solarus"
    "$MOUNT_DIR/root/opt/linapple/libs"
    "$MOUNT_DIR/root/opt/mupen64plus"
  )
  local -A seen_members=()
  for dir in "${collapse_dirs[@]}"; do
    [[ -d "$dir" ]] || continue
    local -A groups=()
    for f in "$dir"/*.so*; do
      [[ -f "$f" && ! -L "$f" ]] || continue
      b="${f##*/}"
      b="${b%%.so*}.so"
      groups["$b"]="${groups["$b"]:+${groups["$b"]}|}$f"
    done
    for b in "${!groups[@]}"; do
      IFS='|' read -r -a real <<< "${groups[$b]}"
      (( ${#real[@]} >= 2 )) || continue
      newest=$(printf '%s\n' "${real[@]}" | sed "s|$dir/||" | sort -V | tail -1)
      keep="$dir/$newest"
      local ok=1
      for f in "${real[@]}"; do
        [[ "$f" == "$keep" ]] && continue
        sudo cmp -s "$f" "$keep" || { ok=0; break; }
      done
      (( ok )) || continue
      for f in "${real[@]}"; do
        [[ "$f" == "$keep" ]] && continue
        safe sudo rm -f "$f"
        fatal sudo ln -sfn "$(basename "$keep")" "${f%/*}/${f##*/}"
        echo "  Replaced duplicate with symlink: ${f#$MOUNT_DIR/root} -> $(basename "$keep")"
      done
    done
    unset groups
  done
}

if [[ "$ARKOS_IMAGE_NAME" == *dArkOS* ]]; then
  # ============================================================
  # dArkOS (UID=1000)
  # ============================================================
  echo "=== Detected dArkOS image: syncing dArkOS, permissions 777 / 1000:1000 ==="
  CHOWN_USER="1000:1000"

  echo "== sync boot/dArkOS =="
  sync_boot dArkOS

  echo "== sync rootfs/dArkOS =="
  sync_rootfs dArkOS 1000:1000
  pack_roms_tar

  echo "== Removing files not needed by dArkOS =="
  cleanup_stock
  safe sudo rm -f "$MOUNT_DIR/root/etc/systemd/system/batt_led.service"
  safe sudo rm -rf "$MOUNT_DIR/root/opt/system/Advanced/Backup dArkOS Settings"
  safe sudo rm -f "$MOUNT_DIR/root/etc/systemd/system/logo.service" \
    "$MOUNT_DIR/root/etc/systemd/system/multi-user.target.wants/logo.service"

  echo "== Setting the dArkOS Plymouth title =="
  safe sudo sed -i "/title\=/c\title\=dArkOS4Clone ($UPDATE_DATE)($MODDER)" "$MOUNT_DIR/root/usr/share/plymouth/themes/text.plymouth"

else
  # ============================================================
  # ArkOS (UID=1002): sync dArkOS first, then overlay ArkOS.
  # ============================================================
  echo "=== Detected ArkOS image: syncing dArkOS then ArkOS, permissions 777 / 1002:1002 ==="
  CHOWN_USER="1002:1002"

  echo "== sync boot/dArkOS + boot/ArkOS =="
  sync_boot dArkOS
  sync_boot ArkOS

  # Free up space.
  echo "== Freeing up space =="
  prune_old_libs
  safe sudo rm -rf "$MOUNT_DIR/root/usr/lib/gcc"
  safe sudo rm -rf "$MOUNT_DIR/root/opt/ppssppgo"
  safe sudo rm -rf "$MOUNT_DIR/root/opt/hypseus"
  # Stock build/development files are unnecessary on a consumer device with no
  # on-device compilation use case.
  # Header files / kernel build directories
  safe sudo rm -rf "$MOUNT_DIR/root/usr/include" "$MOUNT_DIR/root/usr/src"
  # Static .a libraries (link-time artifacts, ~91 MB) and libtool .la files.
  # -prune skips modules/firmware; -print0/-0 handles unusual filenames.
  # Keep .pc files and pkg-config: some runtimes use them, and together they are under 100 KB.
  safe sudo find "$MOUNT_DIR/root/usr/lib" "$MOUNT_DIR/root/usr/local/lib" \
    \( -type d \( -name modules -o -name firmware \) \) -prune -o \
    \( -name '*.a' -o -name '*.la' \) -type f -print0 2>/dev/null |
    xargs -0 -r sudo rm -f
  # CMake development metadata (the CMake binary is also removed).
  safe sudo rm -rf "$MOUNT_DIR/root"/usr/lib/*/cmake "$MOUNT_DIR/root"/usr/lib/cmake
  # Cross-compilers/build-tool leftovers in /usr/bin (~25 MB); keep native pkg-config.
  safe sudo rm -f "$MOUNT_DIR/root"/usr/bin/aarch64-linux-gnu-* \
    "$MOUNT_DIR/root"/usr/bin/aarch64-unknown-* \
    "$MOUNT_DIR/root"/usr/bin/c89-gcc "$MOUNT_DIR/root"/usr/bin/c99-gcc \
    "$MOUNT_DIR/root"/usr/bin/cmake "$MOUNT_DIR/root"/usr/bin/ccmake \
    "$MOUNT_DIR/root"/usr/bin/ctest "$MOUNT_DIR/root"/usr/bin/cpack

  echo "== Syncing rootfs/dArkOS + rootfs/ArkOS =="
  sync_rootfs dArkOS 1002:1002
  sync_rootfs ArkOS 1002:1002
  pack_roms_tar

  echo "== Removing files not needed by ArkOS =="
  cleanup_stock
  safe sudo rm -f "$MOUNT_DIR/root/etc/systemd/system/batt_led.service"
  safe sudo rm -f "$MOUNT_DIR/root/etc/systemd/system/ddtbcheck.service"
  safe sudo rm -rf "$MOUNT_DIR/root/opt/system/Advanced/Read from SD1 and SD2 for Roms"
  safe sudo rm -f "$MOUNT_DIR/root/opt/system/Advanced/Read from SD1 and SD2 for Roms.sh"
  safe sudo rm -f "$MOUNT_DIR/root/opt/system/Advanced/Switch to SD2 for Roms.sh"
  safe sudo rm -f "$MOUNT_DIR/root/opt/system/Advanced/Switch to main SD for Roms.sh"
  safe sudo rm -rf "$MOUNT_DIR/root/opt/system/Advanced/Video Boot/"
  safe sudo rm -rf "$MOUNT_DIR/root/opt/system/Tools/Gamma/"
  safe sudo rm -rf "$MOUNT_DIR/root/opt/system/Tools/ES-logo-changer/"
  safe sudo rm -f "$MOUNT_DIR/root/usr/local/bin/Read from SD1 and SD2 for Roms"
  safe sudo rm -f "$MOUNT_DIR/root/usr/local/bin/Switch to SD2 for Roms.sh"
  safe sudo rm -f "$MOUNT_DIR/root/usr/local/bin/Switch to main SD for Roms.sh"

  echo "== Removing randomized logos =="
  safe sudo sed -i '/imageshift\.sh/d' "$MOUNT_DIR/root/var/spool/cron/crontabs/root"
  safe sudo rm -f "$MOUNT_DIR/root/home/ark/.config/imageshift.sh"
  safe sudo chown -R $CHOWN_USER "$MOUNT_DIR/root/lib/systemd/system/mpv.service"
  safe sudo chmod 777 "$MOUNT_DIR/root/lib/systemd/system/mpv.service"

  echo "== Setting the ArkOS Plymouth title =="
  safe sudo sed -i "/title\=/c\title\=ArkOS4Clone ($UPDATE_DATE)($MODDER)" "$MOUNT_DIR/root/usr/share/plymouth/themes/text.plymouth"
fi

echo "== Free space on the image root partition after injection =="
df -h "$MOUNT_DIR/root" || true
cat "$MOUNT_DIR/root/usr/share/plymouth/themes/text.plymouth"
if (( FAIL_COUNT > 0 )); then
  echo "[ERROR] $FAIL_COUNT command(s) failed during injection; the image may be incomplete. Aborting build."
  exit 1
fi
echo "== Complete =="
