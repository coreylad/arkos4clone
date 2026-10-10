#!/usr/bin/env bash
set -euo pipefail

# ============ Configuration ============
# Quiet mode when ARKOS_QUIET=1 (set by build_image.sh --ci).
if [[ "${ARKOS_QUIET:-}" == "1" ]]; then
  RSYNC_PROGRESS="--quiet"
else
  RSYNC_PROGRESS="--info=progress2"
fi
P1_TARGET_MB=256              # Target size for p1 (boot): 256 MiB (stock: 112 MiB)
P2_TARGET_MB=11264            # Target size for p2 (root): 11 GiB; no resizing on-device
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
# Prefer ARKOS_WORK_DIR for temporary files; otherwise use the current directory.
WORK_BASE="${ARKOS_WORK_DIR:-$(pwd)}"
TMP_DIR="${WORK_BASE}/tmp"    # Backup/restore directory; created and removed by this script.
# The p3 filesystem type and label are detected from the original p3.
# =============================

if [[ $# -lt 1 ]]; then
  echo "Usage: $0 <image-file-path>"
  exit 1
fi
IMG="$1"
[[ -f "$IMG" ]] || { echo "Image not found: $IMG"; exit 1; }

# Runtime resources (mount points, etc.).
P1_OLD_MNT="$(mktemp -d -t p1_old.XXXXXX)"
P1_NEW_MNT="$(mktemp -d -t p1_new.XXXXXX)"
P3_OLD_MNT="$(mktemp -d -t p3_old.XXXXXX)"
P3_NEW_MNT="$(mktemp -d -t p3_new.XXXXXX)"
LOOP=""

settle() {
  # Wait for the kernel/udev to create device nodes; use sleep as a fallback
  # in environments without udev, such as WSL.
  if command -v udevadm >/dev/null 2>&1; then
    sudo udevadm settle || true
  else
    sleep 1
  fi
}

cleanup() {
  set +e
  mountpoint -q "$P1_OLD_MNT" && sudo umount "$P1_OLD_MNT"
  mountpoint -q "$P1_NEW_MNT" && sudo umount "$P1_NEW_MNT"
  mountpoint -q "$P3_OLD_MNT" && sudo umount "$P3_OLD_MNT"
  mountpoint -q "$P3_NEW_MNT" && sudo umount "$P3_NEW_MNT"
  [[ -d "$P1_OLD_MNT" ]] && rmdir "$P1_OLD_MNT" || true
  [[ -d "$P1_NEW_MNT" ]] && rmdir "$P1_NEW_MNT" || true
  [[ -d "$P3_OLD_MNT" ]] && rmdir "$P3_OLD_MNT" || true
  [[ -d "$P3_NEW_MNT" ]] && rmdir "$P3_NEW_MNT" || true
  # Clean up the temporary btrfs mount point.
  local btrfs_mnt="${WORK_BASE:-$(pwd)}/btrfs_resize"
  if [[ -d "$btrfs_mnt" ]]; then
    mountpoint -q "$btrfs_mnt" && sudo umount -l "$btrfs_mnt"
    sudo rmdir "$btrfs_mnt" 2>/dev/null
  fi
  # Detach the current loop device.
  if [[ -n "${LOOP:-}" ]] && losetup -a | grep -q "^$LOOP:"; then
    sudo losetup -d "$LOOP" || true
  fi
}
trap cleanup EXIT

# Detach any existing loop devices mapped to this image.
echo "== Detaching old loop devices (if any) =="
while read -r dev; do
  [[ -n "$dev" ]] && sudo losetup -d "$dev" || true
done < <(losetup -j "$IMG" | cut -d: -f1)

# Map the image to a loop device with partition scanning and return its unique name.
echo "== Mapping image to a loop device (with partitions) =="
LOOP="$(sudo losetup --find --show -P "$IMG")"
settle
echo "Using loop device: $LOOP"

# Clean up stale mount points (another process may have mounted the device).
echo "== Cleaning up stale mount points =="
for part in "${LOOP}p1" "${LOOP}p2" "${LOOP}p3"; do
  if [[ -b "$part" ]]; then
    while read -r mnt; do
      [[ -n "$mnt" ]] && sudo umount -l "$mnt" 2>/dev/null || true
    done < <(findmnt -n -o TARGET "$part" 2>/dev/null || true)
  fi
done

# Sector information
SECTOR_SIZE="$(sudo blockdev --getss "$LOOP")"  # Usually 512 bytes

# Helper: check whether p3 exists (machine-readable output).
has_p3() {
  sudo parted -sm "$LOOP" unit s print | grep -qE '^3:'
}

# Read current p1/p2/p3 sizes and calculate how much to grow each partition.
PARTED_OUT="$(sudo parted -sm "$LOOP" unit s print)"
P1_START="$(awk -F: '$1=="1"{gsub(/s/,"",$2); print $2}' <<< "$PARTED_OUT")"
P1_END="$(awk -F: '$1=="1"{gsub(/s/,"",$3); print $3}' <<< "$PARTED_OUT")"
[[ -n "${P1_START:-}" && -n "${P1_END:-}" ]] || { echo "Could not read partition 1 information; exiting."; exit 1; }
P1_CUR_MB=$(( (P1_END - P1_START + 1) * SECTOR_SIZE / 1024 / 1024 ))

CUR_START="$(awk -F: '$1=="2"{gsub(/s/,"",$2); print $2}' <<< "$PARTED_OUT")"
CUR_END="$(awk -F: '$1=="2"{gsub(/s/,"",$3); print $3}' <<< "$PARTED_OUT")"
[[ -n "${CUR_END:-}" ]] || { echo "Could not read partition 2 information; exiting."; exit 1; }
P2_CUR_MB=$(( (CUR_END - CUR_START + 1) * SECTOR_SIZE / 1024 / 1024 ))

P3_CUR_MB=0
if has_p3; then
  P3_START="$(awk -F: '$1=="3"{gsub(/s/,"",$2); print $2}' <<< "$PARTED_OUT")"
  P3_END="$(awk -F: '$1=="3"{gsub(/s/,"",$3); print $3}' <<< "$PARTED_OUT")"
  P3_CUR_MB=$(( (P3_END - P3_START + 1) * SECTOR_SIZE / 1024 / 1024 ))
fi

# Grow p1 to 256 MiB and p2 to 11 GiB; leave p3 unchanged (stock p3 is empty).
# Package roms/ as /roms.tar for extraction on first boot.
BOOT_ADD_MB=$(( P1_TARGET_MB > P1_CUR_MB ? P1_TARGET_MB - P1_CUR_MB : 0 ))
P2_DELTA=$(( P2_TARGET_MB > P2_CUR_MB ? P2_TARGET_MB - P2_CUR_MB : 0 ))

echo "Current p1: ${P1_CUR_MB} MiB, p2: ${P2_CUR_MB} MiB (end: $CUR_END), p3: ${P3_CUR_MB} MiB"
echo "Target: p1 → ${P1_TARGET_MB} MiB (+${BOOT_ADD_MB}), p2 → ${P2_TARGET_MB} MiB (+${P2_DELTA}), p3 remains ${P3_CUR_MB} MiB"

# Always store the p3 backup in $TMP_DIR/p3data (separate from the p1 backup
# in $TMP_DIR/bootfs); HAD_P3 prevents restoring the boot backup to p3.
HAD_P3=0

# ======= Step 1: Back up p3 to TMP_DIR/p3data (if present) =======
if has_p3; then
  HAD_P3=1
  echo "Found p3; preparing backup at $TMP_DIR/p3data"
  mkdir -p "$TMP_DIR/p3data"
  P3_DEV="${LOOP}p3"

  # Preserve the stock filesystem type when recreating p3 (stock images use NTFS).
  ORIG_P3_FS="$(sudo blkid -s TYPE -o value "$P3_DEV" 2>/dev/null || echo 'vfat')"
  ORIG_P3_LABEL="$(sudo blkid -s LABEL -o value "$P3_DEV" 2>/dev/null || echo 'EASYROMS')"
  echo "Original p3 type: $ORIG_P3_FS, label: $ORIG_P3_LABEL; preserving both"

  echo "Mounting old p3 at $P3_OLD_MNT (read-only first)"
  if ! sudo mount -o ro "$P3_DEV" "$P3_OLD_MNT"; then
    echo "Read-only mount failed; trying a regular mount"
    sudo mount "$P3_DEV" "$P3_OLD_MNT"
  fi

  echo "Backing up p3 -> $TMP_DIR/p3data (rsync -aH --delete for an exact mirror)"
  sudo rsync -aH --delete $RSYNC_PROGRESS "$P3_OLD_MNT"/ "$TMP_DIR/p3data"/

  echo "Unmounting old p3"
  sudo umount "$P3_OLD_MNT"
else
  echo "No p3 found; skipping backup."
  # Set defaults for creating a new p3.
  ORIG_P3_FS="exfat"
  ORIG_P3_LABEL="EASYROMS"
  echo "Creating p3 with defaults: filesystem=$ORIG_P3_FS, label=$ORIG_P3_LABEL"
fi

# ======= Step 2: Delete p3 (required before repartitioning) =======
echo "== Deleting old partition 3 =="
if sudo parted -s "$LOOP" rm 3 2>/dev/null; then
  echo "Deleted p3 (if it existed)"
else
  echo "Could not delete p3 (it may not have existed); continuing."
fi

# Check again and stop if p3 still exists.
if has_p3; then
  echo "Error: p3 still exists, so resizing cannot continue. Check the partition table and try again."
  sudo parted "$LOOP" unit s print || true
  exit 1
fi

if (( BOOT_ADD_MB > 0 )); then
  # ======= Step 3A: Grow p1 (boot) =======
  # p2 immediately follows p1, so growing p1 requires shifting all p2 data:
  # back up p1 -> remove the p1/p2 partition entries -> move p2 data in the image
  # -> recreate 256 MiB p1 and restore its contents -> recreate p2 at its new start.
  # boot.ini loads by partition number ("load mmc 1:1"), not UUID, so recreating FAT is safe.

  NEW_P1_END=$(( P1_START + P1_TARGET_MB * 1024 * 1024 / SECTOR_SIZE - 1 ))
  NEW_P2_START=$(( NEW_P1_END + 1 ))
  SHIFT_SECTORS=$(( NEW_P2_START - CUR_START ))
  SHIFT_BYTES=$(( SHIFT_SECTORS * SECTOR_SIZE ))
  MOVE_SRC=$(( CUR_START * SECTOR_SIZE ))
  MOVE_LEN=$(( (CUR_END - CUR_START + 1) * SECTOR_SIZE ))

  # Safety checks: align the new p2 start to 1 MiB and keep the move within the image.
  (( NEW_P2_START % (1024 * 1024 / SECTOR_SIZE) == 0 )) \
    || { echo "Error: new p2 start ${NEW_P2_START}s is not 1 MiB aligned; exiting."; exit 1; }
  IMG_SIZE_BYTES="$(stat -c %s "$IMG")"
  (( MOVE_SRC + MOVE_LEN + SHIFT_BYTES <= IMG_SIZE_BYTES )) \
    || { echo "Error: destination for p2 data would exceed the image size; exiting."; exit 1; }

  echo "== Backing up p1 (boot) contents -> $TMP_DIR/bootfs =="
  mkdir -p "$TMP_DIR/bootfs"
  ORIG_P1_LABEL="$(sudo blkid -s LABEL -o value "${LOOP}p1" 2>/dev/null || echo 'BOOT')"
  echo "Original p1 label: $ORIG_P1_LABEL (will be preserved)"
  if ! sudo mount -o ro "${LOOP}p1" "$P1_OLD_MNT"; then
    echo "Read-only mount failed; trying a regular mount"
    sudo mount "${LOOP}p1" "$P1_OLD_MNT"
  fi
  sudo rsync -rltD --delete --no-owner --no-group --no-perms --omit-dir-times \
    $RSYNC_PROGRESS "$P1_OLD_MNT"/ "$TMP_DIR/bootfs"/
  sudo umount "$P1_OLD_MNT"

  echo "== Deleting old partitions 1 and 2 (p3 is deleted; p2 data remains in the image) =="
  sudo parted -s "$LOOP" rm 2
  sudo parted -s "$LOOP" rm 1
  sudo partprobe "$LOOP" || true

  echo "== Shifting p2 data right by ${SHIFT_SECTORS} sectors (+${BOOT_ADD_MB} MiB), size ${P2_CUR_MB} MiB =="
  # Detach the loop device and move data directly in the image to avoid cache inconsistencies.
  sudo losetup -d "$LOOP"
  LOOP=""
  # Copy backward in chunks smaller than the shift to avoid overwriting unread data.
  CHUNK=$(( 16 * 1024 * 1024 ))
  remaining=$MOVE_LEN
  src_off=$(( MOVE_SRC + MOVE_LEN ))
  next_report=$(( 1024 * 1024 * 1024 ))
  while (( remaining > 0 )); do
    (( n = remaining < CHUNK ? remaining : CHUNK ))
    src_off=$(( src_off - n ))
    dd if="$IMG" of="$IMG" bs="$CHUNK" conv=notrunc status=none \
      iflag=count_bytes,skip_bytes oflag=seek_bytes \
      skip="$src_off" seek="$(( src_off + SHIFT_BYTES ))" count="$n"
    remaining=$(( remaining - n ))
    if [[ "${ARKOS_QUIET:-}" != "1" ]] && (( MOVE_LEN - remaining >= next_report )); then
      echo "  Moved $(( (MOVE_LEN - remaining) / 1024 / 1024 )) / $(( MOVE_LEN / 1024 / 1024 )) MiB"
      next_report=$(( next_report + 1024 * 1024 * 1024 ))
    fi
  done
  sync

  echo "== Growing image by $(( P2_DELTA + BOOT_ADD_MB )) MiB =="
  truncate -s +"$(( P2_DELTA + BOOT_ADD_MB ))M" "$IMG"

  echo "== Refreshing loop device size =="
  LOOP="$(sudo losetup --find --show -P "$IMG")"
  settle
  echo "Loop device refreshed: $LOOP"

  echo "== Recreating p1: ${P1_TARGET_MB} MiB FAT32 (${P1_START}s - ${NEW_P1_END}s) =="
  sudo parted -s "$LOOP" unit s "mkpart primary fat32 ${P1_START}s ${NEW_P1_END}s"
  # Partition type 0x0b matches stock (parted defaults to 0x0c).
  sudo sfdisk --change-id "$LOOP" 1 b 2>/dev/null || true
  sudo partprobe "$LOOP" || true
  settle
  sudo mkfs.vfat -F 32 -n "$ORIG_P1_LABEL" "${LOOP}p1"
  echo "== Restoring p1 contents =="
  sudo mount "${LOOP}p1" "$P1_NEW_MNT"
  sudo rsync -rltD --no-owner --no-group --no-perms --omit-dir-times \
    $RSYNC_PROGRESS "$TMP_DIR/bootfs"/ "$P1_NEW_MNT"/
  sync
  sudo umount "$P1_NEW_MNT"

  echo "== Recreating p2: ${P2_TARGET_MB} MiB (starting at ${NEW_P2_START}s) =="
  NEW_P2_END=$(( NEW_P2_START + P2_TARGET_MB * 1024 * 1024 / SECTOR_SIZE - 1 ))
  sudo parted -s "$LOOP" unit s "mkpart primary ${NEW_P2_START}s ${NEW_P2_END}s"
  sudo partprobe "$LOOP" || true
  settle
else
  # ======= Step 3B: p1 is large enough; grow p2 in place =======
  echo "p1 is already ${P1_TARGET_MB} MiB; skipping boot partition growth"

  echo "== Growing image by ${P2_DELTA} MiB (p2 only; p3 remains unchanged) =="
  truncate -s +"${P2_DELTA}"M "$IMG"

  echo "== Refreshing loop device size =="
  sudo losetup -d "$LOOP"
  LOOP="$(sudo losetup --find --show -P "$IMG")"
  settle
  echo "Loop device refreshed: $LOOP"

  ADD_SECTORS=$(( P2_DELTA * 1024 * 1024 / SECTOR_SIZE ))
  # Reread the p2 end sector in case parted/kernel updates changed the boundary.
  CUR_END="$(sudo parted -sm "$LOOP" unit s print | awk -F: '$1=="2"{gsub(/s/,"",$3); print $3}')"
  [[ -n "${CUR_END:-}" ]] || { echo "Could not read partition 2 information after refresh; exiting."; exit 1; }
  NEW_END=$(( CUR_END + ADD_SECTORS ))
  echo "Extending p2 through sector: $NEW_END"

  echo "== Extending p2 to the specified sector (not 100%) =="
  if [ "$P2_DELTA" -gt 0 ]; then
    sudo parted -s "$LOOP" unit s "resizepart 2 ${NEW_END}s"
  else
    echo "p2 is already at the target size; skipping"
  fi
  sudo partprobe "$LOOP" || true
  settle
fi

echo "== Resizing the filesystem on p2 (auto-detect ext4 / f2fs) =="
P2_DEV="${LOOP}p2"
P2_FS="$(blkid -s TYPE -o value "$P2_DEV" || true)"
case "$P2_FS" in
  ext4|"")
    sudo e2fsck -fy "$P2_DEV"
    sudo resize2fs "$P2_DEV"
    ;;
  f2fs)
    sudo fsck.f2fs -f "$P2_DEV" || true
    sudo resize.f2fs "$P2_DEV"
    ;;
  btrfs)
    # Use a fixed mount point under the working directory.
    P2_MNT="${WORK_BASE}/btrfs_resize"
    sudo mkdir -p "$P2_MNT"
    # Ensure there are no existing mounts.
    sudo umount -l "$P2_MNT" 2>/dev/null || true
    sudo umount -l "$P2_DEV" 2>/dev/null || true
    # Clear the btrfs kernel device cache.
    echo "Clearing btrfs device cache..."
    sudo btrfs device scan --forget 2>/dev/null || true
    # Mount and resize.
    sudo mount -t btrfs "$P2_DEV" "$P2_MNT"
    sudo btrfs filesystem resize max "$P2_MNT"
    sudo umount "$P2_MNT"
    sudo rmdir "$P2_MNT" 2>/dev/null || true
    ;;
  *)
    echo "Warning: unknown or unsupported p2 filesystem type: $P2_FS"
    echo "Manually resize the p2 filesystem before continuing."
    ;;
esac

# ======= Step 4: Recreate p3 (from the end of p2 to the end of the disk) =======
echo "== Calculating the new p3 start sector (p2 end + 1) =="
P2_END_NOW="$(sudo parted -sm "$LOOP" unit s print | awk -F: '$1=="2"{gsub(/s/,"",$3); print $3}')"
[[ -n "${P2_END_NOW:-}" ]] || { echo "Could not read the latest p2 end sector; exiting."; exit 1; }
P3_START=$(( P2_END_NOW + 1 ))
echo "p2 End: $P2_END_NOW"
echo "p3 Start: $P3_START"

echo "== Recreating p3 at the end of the disk =="
sudo parted -s "$LOOP" unit s "mkpart primary ${P3_START}s 100%"
# Set partition type to 0x07 (exFAT/NTFS); parted defaults to 83 (Linux), which Windows hides.
sudo sfdisk --change-id "$LOOP" 3 7 2>/dev/null || true
sudo partprobe "$LOOP" || true
settle

echo "== Formatting the new p3 =="
P3_DEV="${LOOP}p3"
echo "Using filesystem: $ORIG_P3_FS, label: $ORIG_P3_LABEL"
case "$ORIG_P3_FS" in
  vfat|fat32|fat16)
    sudo mkfs.vfat -F 32 -n "$ORIG_P3_LABEL" "$P3_DEV"
    ;;
  ntfs)
    sudo mkfs.ntfs -F -L "$ORIG_P3_LABEL" "$P3_DEV"
    ;;
  exfat)
    sudo mkfs.exfat -n "$ORIG_P3_LABEL" "$P3_DEV"
    ;;
  *)
    echo "Warning: unknown filesystem type $ORIG_P3_FS; defaulting to exfat"
    sudo mkfs.exfat -n "$ORIG_P3_LABEL" "$P3_DEV"
    ;;
esac

# ======= Step 5: Restore data (exact mirror) =======
if (( HAD_P3 )); then
  echo "== Restoring data (exact mirror): $TMP_DIR/p3data -> new p3 =="
  sudo mount "$P3_DEV" "$P3_NEW_MNT"
  # FAT32/exFAT do not support Unix permissions; use --no-perms --no-owner --no-group.
  case "$ORIG_P3_FS" in
    vfat|fat32|fat16|exfat)
      sudo rsync -rltD --no-perms --no-owner --no-group --delete $RSYNC_PROGRESS "$TMP_DIR/p3data"/ "$P3_NEW_MNT"/
      ;;
    *)
      sudo rsync -aH --delete $RSYNC_PROGRESS "$TMP_DIR/p3data"/ "$P3_NEW_MNT"/
      ;;
  esac
  sync
  sudo umount "$P3_NEW_MNT"
  echo "Restore complete."
else
  echo "The original image had no p3; skipping restore."
fi

# ======= Step 6: Optionally inspect the output =======
echo "== Final partition layout (MiB) =="
sudo parted "$LOOP" unit MiB print || true

# ======= Step 7: Remove the temporary directory and detach the loop device =======
echo "== Removing backup directory $TMP_DIR =="
sudo rm -rf "$TMP_DIR"

echo "== Detaching loop device =="
sudo losetup -d "$LOOP" || true
LOOP=""

echo "✅ Complete: back up p1+p3 -> delete p3 -> shift p2 and recreate p1 (${P1_TARGET_MB} MiB) -> recreate p2 (${P2_TARGET_MB} MiB) -> recreate p3 -> restore -> clean up tmp -> detach loop"
