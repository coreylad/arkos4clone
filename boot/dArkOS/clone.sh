#!/usr/bin/env bash
# Do not use set -e; a failed command could otherwise terminate the script unexpectedly.

# ============================================================
# ArkOS4Clone startup configuration script
# Functions: device detection, configuration, OTA updates, and localization.
# ============================================================

# ==================== Path configuration ====================
QUIRKS_DIR="/home/ark/.quirks"
CONSOLE_FILE="/boot/.console"
CONSOLE_DETECT="/usr/local/bin/console_detect"
LOG_FILE="/boot/clone_log.txt"

# ==================== Permission check ====================
if [[ $EUID -ne 0 ]]; then
  echo "[clone.sh] This script requires root privileges. Run: sudo $0 $@"
  exit 1
fi

# ==================== Logging functions ====================
# Clear the log on each run.
: > "$LOG_FILE" 2>/dev/null || true
msg()  { echo "[clone.sh] $*" | tee -a "$LOG_FILE"; }
warn() { echo "[clone.sh][WARN] $*" | tee -a "$LOG_FILE" >&2; }
err()  { echo "[clone.sh][ERR ] $*" | tee -a "$LOG_FILE" >&2; }

# ==================== Device detection ====================
# Device information variables.
DEVICE_NAME=""
SCREEN_WIDTH=640
SCREEN_HEIGHT=480
JOYSTICK_COUNT=2
HOTKEY_TYPE="happy5"
SCREEN_ROTATION=0
LED_TYPE="unsupported"

# ==================== Constants ====================
SDL2_VERSION="libSDL2-2.0.so.0.3200.10"
SDL3_VERSION="libSDL3.so.0.4.16"

detect_device() {
  if [[ -x "$CONSOLE_DETECT" ]]; then
    eval "$("$CONSOLE_DETECT" -s)"
    msg "Device: $DEVICE_NAME, ${SCREEN_WIDTH}x${SCREEN_HEIGHT}, joy=$JOYSTICK_COUNT, hotkey=$HOTKEY_TYPE, rot=$SCREEN_ROTATION, led=$LED_TYPE"
  else
    warn "console_detect not found, using defaults"
    DEVICE_NAME="r36s"
  fi
}

get_console_label() {
  tr -d '\r\n' < "$CONSOLE_FILE" 2>/dev/null || true
}

# ==================== Utility functions ====================
cp_if_exists() {
  local src="$1" dst="$2" isfile="${3:-no}"
  [[ -e "$src" ]] || { warn "Source not found: $src"; return 1; }
  
  if [[ "$isfile" == "yes" ]]; then
    mkdir -p "$(dirname "$dst")"
    # Remove the destination first, if it exists, to ensure it is replaced correctly.
    rm -f "$dst" 2>/dev/null || true
    # Use -L to follow symlinks and copy the actual file.
    cp -L "$src" "$dst" 2>/dev/null || install -m 0755 -D "$src" "$dst"
    sudo chmod 0755 "$dst" 2>/dev/null || true
  else
    mkdir -p "$dst"
    cp -a "$src" "$dst/"
    sudo chmod -R 0755 "$dst" 2>/dev/null || true
  fi
  sudo chown -R ark:ark "$dst" 2>/dev/null || true
  msg "Copied: $src -> $dst"
}

# ==================== OTA update ====================
maybe_apply_ota_update() {
  local tar_path=""
  # Check for update bundles in .tar.gz or legacy .tar format
  for name in update-arkos.tar.gz update-darkos.tar.gz update-arkos.tar update-darkos.tar; do
    [[ -f "/roms/$name" ]] && tar_path="/roms/$name" && break
    [[ -f "/roms2/$name" ]] && tar_path="/roms2/$name" && break
  done
  [[ -z "$tar_path" ]] && return 0

  # Check that the update package matches the current system.
  local is_darkos=false
  grep -q "dArkOS" /usr/share/plymouth/themes/text.plymouth 2>/dev/null && is_darkos=true
  
  if [[ "$is_darkos" == "true" && "$tar_path" != *darkos* ]]; then
    err "Mismatch: current=dArkOS, package=ArkOS. Use update-darkos.tar.gz"
    return 0
  fi
  if [[ "$is_darkos" == "false" && "$tar_path" == *darkos* ]]; then
    err "Mismatch: current=ArkOS, package=dArkOS. Use update-arkos.tar.gz"
    return 0
  fi

  local tmpdir="/home/ark/.ota_update" TTY="/dev/tty1"
  local ota_title="ArkOS4Clone OTA"
  [[ "$is_darkos" == "true" ]] && ota_title="dArkOS4Clone OTA"
  
  msg "OTA package found: $tar_path"
  sudo rm -rf "$tmpdir" 2>/dev/null || true
  sudo mkdir -p "$tmpdir" || { err "Failed to create OTA dir"; return 0; }

  {
    printf '\033c'
    echo "==============================="; echo "        $ota_title        "; echo "==============================="
    echo; echo "[OTA] Package: $tar_path"; echo "[OTA] Step 1/2: Extracting... (Do NOT power off)"
  } > "$TTY"

  # Do not extract chunks/: install.sh streams each chunk directly from OTA_TAR_PATH,
  # saving about 2.3 GB of temporary space on p2 (which has limited free space).
  if ! sudo tar -xf "$tar_path" -C "$tmpdir" VERSION install.sh CHUNKS META 2>&1 | tee -a "$LOG_FILE" >> "$TTY"; then
    err "OTA extract failed"
    sudo rm -rf "$tmpdir" 2>/dev/null || true
    return 0
  fi

  echo "[OTA] Step 2/2: Running install.sh" >> "$TTY"
  [[ -f "$tmpdir/install.sh" ]] || { err "install.sh not found"; sudo rm -rf "$tmpdir"; return 0; }
  sudo chmod +x "$tmpdir/install.sh"
  
  if ! sudo env OTA_TAR_PATH="$tar_path" LOG_FILE="$LOG_FILE" bash "$tmpdir/install.sh" 2>&1 | tee -a "$LOG_FILE" >> "$TTY"; then
    err "OTA install failed"
    sudo rm -rf "$tmpdir" 2>/dev/null || true
    return 0
  fi

  sudo rm -f "$tar_path" 2>/dev/null || true
  sudo rm -rf "$tmpdir" 2>/dev/null || true
  sudo rm -f "$CONSOLE_FILE" 2>/dev/null || true
  sync

  {
    echo; echo "[OTA] SUCCESS"; echo "[OTA] Update package removed"
    for i in {10..1}; do echo "[OTA] Powering off in ${i}s..."; sleep 1; done
  } >> "$TTY"

  msg "OTA applied, powering off"
  sleep 2; poweroff -f || true; exit 0
}

# ==================== Configuration functions ====================
apply_hotkey_conf() {
  msg "apply_hotkey_conf: HOTKEY_TYPE=$HOTKEY_TYPE"
  local ogage_conf ra_conf="$QUIRKS_DIR/retroarch64.cfg" ra32_conf="$QUIRKS_DIR/retroarch32.cfg"

  # Select the ogage configuration based on HOTKEY_TYPE.
  case "$HOTKEY_TYPE" in
    select) 
      ogage_conf="$QUIRKS_DIR/ogage.select.conf"
      hotkey_btn="12"
      ;;
    happy5) 
      ogage_conf="$QUIRKS_DIR/ogage.happy5.conf"
      hotkey_btn="16"
      ;;
    *)      
      ogage_conf=""
      hotkey_btn=""
      ;;
  esac

  # Copy the ogage configuration.
  [[ -n "$ogage_conf" ]] && cp_if_exists "$ogage_conf" "/home/ark/ogage.conf" "yes"
  
  # Copy RetroArch configurations.
  cp_if_exists "$ra_conf" "/home/ark/.config/retroarch/retroarch.cfg" "yes" || true
  cp_if_exists "$ra32_conf" "/home/ark/.config/retroarch32/retroarch.cfg" "yes" || true
  
  # Set input_enable_hotkey_btn based on the hotkey type.
  if [[ -n "$hotkey_btn" ]]; then
    msg "Setting input_enable_hotkey_btn = $hotkey_btn for HOTKEY_TYPE=$HOTKEY_TYPE"
    for cfg in /home/ark/.config/retroarch/retroarch.cfg /home/ark/.config/retroarch32/retroarch.cfg; do
      [[ -f "$cfg" ]] || continue
      if grep -q '^input_enable_hotkey_btn' "$cfg" 2>/dev/null; then
        sed -i 's/^input_enable_hotkey_btn = ".*"/input_enable_hotkey_btn = "'"$hotkey_btn"'"/' "$cfg" 2>/dev/null
      else
        echo "input_enable_hotkey_btn = \"$hotkey_btn\"" >> "$cfg"
      fi
    done
    msg "Set hotkey_btn=$hotkey_btn in RetroArch configs"
  fi
}

apply_ppsspp_config() {
  local joy_type="$1" roms_dir
  for roms_dir in "/roms/psp" "/roms2/psp" "/opt/ppsspp/backupforromsfolder"; do
    [[ -d "$roms_dir" ]] || continue
    local target="$roms_dir/ppsspp/PSP/SYSTEM"
    cp_if_exists "$QUIRKS_DIR/${joy_type}Joy/controls.ini"     "$target/controls.ini"       "yes" || true
    cp_if_exists "$QUIRKS_DIR/${joy_type}Joy/ppsspp.ini"       "$target/ppsspp.ini"         "yes" || true
    cp_if_exists "$QUIRKS_DIR/${joy_type}Joy/ppsspp.ini.sdl"   "$target/ppsspp.ini.sdl"     "yes" || true
  done
}

apply_joy_conf() {
  msg "apply_joy_conf: JOYSTICK_COUNT=$JOYSTICK_COUNT"

  # Map buttons based on whether the device has dual analog sticks.
  case "$JOYSTICK_COUNT" in
    0|1) apply_ppsspp_config "none" ;;
    2)   apply_ppsspp_config "dual" ;;
  esac
}

apply_input() {
  msg "apply_input: CONSOLE_FILE=$CONSOLE_FILE"

  # Copy the default RA ES input configuration.
  cp_if_exists "$QUIRKS_DIR/retroarch64.cfg" "/home/ark/.config/retroarch/retroarch.cfg" "yes" || true
  cp_if_exists "$QUIRKS_DIR/retroarch32.cfg" "/home/ark/.config/retroarch32/retroarch.cfg" "yes" || true
  cp_if_exists "$QUIRKS_DIR/es_input.cfg" "/etc/emulationstation/es_input.cfg" "yes" || true

  # Set the layout to OZONE.
  for cfg in /home/ark/.config/retroarch*/retroarch.cfg*; do
    sed -i 's/menu_driver = ".*"/menu_driver = "ozone"/' "$cfg" 2>/dev/null || true
  done
}

apply_es_setting() {
  msg "apply_es_setting: CONSOLE_FILE=$CONSOLE_FILE"

  # Copy the default RA ES input configuration.
  cp_if_exists "$QUIRKS_DIR/es_settings.cfg" "/home/ark/.emulationstation/es_settings.cfg" "yes" || true
}

apply_sdl_rotation() {
  local angle="$1"
  local sdl2_32="/usr/lib/arm-linux-gnueabihf/$SDL2_VERSION"
  local sdl2_64="/usr/lib/aarch64-linux-gnu/$SDL2_VERSION"
  local sdl3_32="/usr/lib/arm-linux-gnueabihf/$SDL3_VERSION"
  local sdl3_64="/usr/lib/aarch64-linux-gnu/$SDL3_VERSION"
  
  # Use the norotate file to restore the original library when rotation is 0.
  if [[ "$angle" == "0" ]]; then
    msg "Restoring original SDL (no rotation)"
    local src2_32="$QUIRKS_DIR/rotate/sdl2/32/$SDL2_VERSION.norotate"
    local src2_64="$QUIRKS_DIR/rotate/sdl2/64/$SDL2_VERSION.norotate"
    local src3_32="$QUIRKS_DIR/rotate/sdl3/32/$SDL3_VERSION.norotate"
    local src3_64="$QUIRKS_DIR/rotate/sdl3/64/$SDL3_VERSION.norotate"
    local ra_suffix="norotate"
  else
    local src2_32="$QUIRKS_DIR/rotate/sdl2/32/$SDL2_VERSION.rotate${angle}"
    local src2_64="$QUIRKS_DIR/rotate/sdl2/64/$SDL2_VERSION.rotate${angle}"
    local src3_32="$QUIRKS_DIR/rotate/sdl3/32/$SDL3_VERSION.rotate${angle}"
    local src3_64="$QUIRKS_DIR/rotate/sdl3/64/$SDL3_VERSION.rotate${angle}"
    local ra_suffix="$angle"
  fi
  
  # Check and record the source file type.
  if [[ -L "$src2_64" ]]; then
    msg "Source (64bit) is symlink: $src2_64 -> $(readlink "$src2_64")"
  elif [[ -f "$src2_64" ]]; then
    msg "Source (64bit) is regular file: $src2_64 ($(stat -c%s "$src2_64" 2>/dev/null || echo "unknown") bytes)"
  fi
  if [[ -L "$src3_64" ]]; then
    msg "Source (64bit) is symlink: $src3_64 -> $(readlink "$src3_64")"
  elif [[ -f "$src3_64" ]]; then
    msg "Source (64bit) is regular file: $src3_64 ($(stat -c%s "$src3_64" 2>/dev/null || echo "unknown") bytes)"
  fi
  
  # Remove the destination symlink, if present.
  rm -f "$sdl2_64" "$sdl2_32" "$sdl3_64" "$sdl3_32" 2>/dev/null || true
  
  # Copy the actual file.
  cp_if_exists "$src2_64" "$sdl2_64" "yes" || true
  cp_if_exists "$src2_32" "$sdl2_32" "yes" || true
  cp_if_exists "$src3_64" "$sdl3_64" "yes" || true
  cp_if_exists "$src3_32" "$sdl3_32" "yes" || true
  
  # Recreate symlinks with the correct link direction:
  # libSDL2.so -> libSDL2-2.0.so -> libSDL2-2.0.so.0 -> $SDL2_VERSION (actual file)
  # libSDL3.so -> libSDL3.so.0 -> $SDL3_VERSION (actual file)
  msg "Rebuilding SDL2 symlinks..."
  local sdl2_64_dir="${sdl2_64%/*}"
  local sdl2_32_dir="${sdl2_32%/*}"
  local sdl3_64_dir="${sdl3_64%/*}"
  local sdl3_32_dir="${sdl3_32%/*}"
  
  # 64-bit links
  ln -sf "$(basename $sdl2_64)" "$sdl2_64_dir/libSDL2-2.0.so.0" && msg "  Created: libSDL2-2.0.so.0 -> $(basename $sdl2_64)" || warn "  Failed: libSDL2-2.0.so.0"
  ln -sf "libSDL2-2.0.so.0" "$sdl2_64_dir/libSDL2-2.0.so" && msg "  Created: libSDL2-2.0.so -> libSDL2-2.0.so.0" || warn "  Failed: libSDL2-2.0.so"
  ln -sf "libSDL2-2.0.so" "$sdl2_64_dir/libSDL2.so" && msg "  Created: libSDL2.so -> libSDL2-2.0.so" || warn "  Failed: libSDL2.so"

  ln -sf "$(basename $sdl3_64)" "$sdl3_64_dir/libSDL3.so.0" && msg "  Created: libSDL3.so.0 -> $(basename $sdl3_64)" || warn "  Failed: libSDL3.so.0"
  ln -sf "libSDL3.so.0" "$sdl3_64_dir/libSDL3.so" && msg "  Created: libSDL3.so -> libSDL3.so.0" || warn "  Failed: libSDL3.so"
  
  # 32-bit links
  ln -sf "$(basename $sdl2_32)" "$sdl2_32_dir/libSDL2-2.0.so.0" && msg "  Created: libSDL2-2.0.so.0 -> $(basename $sdl2_32)" || warn "  Failed: libSDL2-2.0.so.0 (32)"
  ln -sf "libSDL2-2.0.so.0" "$sdl2_32_dir/libSDL2-2.0.so" && msg "  Created: libSDL2-2.0.so -> libSDL2-2.0.so.0 (32)" || warn "  Failed: libSDL2-2.0.so (32)"
  ln -sf "libSDL2-2.0.so" "$sdl2_32_dir/libSDL2.so" && msg "  Created: libSDL2.so -> libSDL2-2.0.so (32)" || warn "  Failed: libSDL2.so (32)"

  ln -sf "$(basename $sdl3_32)" "$sdl3_32_dir/libSDL3.so.0" && msg "  Created: libSDL3.so.0 -> $(basename $sdl3_32)" || warn "  Failed: libSDL3.so.0 (32)"
  ln -sf "libSDL3.so.0" "$sdl3_32_dir/libSDL3.so" && msg "  Created: libSDL3.so -> libSDL3.so.0 (32)" || warn "  Failed: libSDL3.so (32)"
}

apply_rotate_file() {
  msg "Screen rotation: $SCREEN_ROTATION degrees"
  apply_sdl_rotation "$SCREEN_ROTATION"
}

apply_all_quirks() {
  msg "Applying quirks for: $DEVICE_NAME"
  msg "QUIRKS_DIR: $QUIRKS_DIR"
  if [[ -d "$QUIRKS_DIR" ]]; then
    msg "Quirks directory exists, contents:"
    ls -la "$QUIRKS_DIR" 2>&1 | tee -a "$LOG_FILE" || true
    # Replace ES RA files.
    apply_input
    # Reset ES configuration.
    apply_es_setting
    # Map PPSSPP hotkeys.
    apply_joy_conf
    # Map RA OGAGE hotkeys.
    apply_hotkey_conf
    # SDL2 rotation.
    apply_rotate_file
  else
    warn "QUIRKS_DIR does not exist: $QUIRKS_DIR"
  fi
}

# ==================== Audio configuration ====================
setup_audio() {
  local state; state="$(amixer get 'Playback Path' 2>/dev/null | grep -oP "Item0: '\K\w+" || true)"
  if [[ "$state" == "OFF" || "$state" == "HP" ]]; then
    msg "Switching audio to SPK"
    amixer set 'Playback Path' 'SPK' || true
    sudo alsactl store || true
  fi
  cp_if_exists "$QUIRKS_DIR/asoundrc" "/home/ark/.asoundrc" "yes" || true
}

# ==================== Localization configuration ====================
apply_localization() {
  local lang="$1" es_lang ra_lang ppsspp_lang timezone
  # ES language, RA language, PPSSPP language, timezone.
  case "$lang" in
    cn) es_lang="zh-CN"; ra_lang="12"; scummvm_lang="zh_Hans"; ppsspp_lang="zh_CN"; timezone="Asia/Shanghai" ;;
    ko) es_lang="ko";    ra_lang="10"; scummvm_lang="ko"; ppsspp_lang="ko_KR"; timezone="Asia/Seoul" ;;
    *)  return 0 ;;
  esac

  msg "Applying $lang localization"
  
  # EmulationStation
  local es_cfg="/home/ark/.emulationstation/es_settings.cfg"
  if grep -q "Language" "$es_cfg" 2>/dev/null; then
    sed -i "s/<string name=\"Language\" value=\"[^\"]*\"/<string name=\"Language\" value=\"$es_lang\"/" "$es_cfg" || true
  else
    echo "<string name=\"Language\" value=\"$es_lang\" />" >> "$es_cfg"
  fi

  # Timezone
  sudo rm -f /etc/localtime
  ln -sf "/usr/share/zoneinfo/$timezone" /etc/localtime

  # PPSSPP
  for dir in /opt/ppsspp/backupforromsfolder/ppsspp/PSP/SYSTEM /roms/psp/ppsspp/PSP/SYSTEM /roms2/psp/ppsspp/PSP/SYSTEM; do
    [[ -d "$dir" ]] || continue
    for ini in ppsspp.ini ppsspp.ini.go ppsspp.ini.sdl; do
      sed -i "s/Language = en_US/Language = $ppsspp_lang/g" "$dir/$ini" 2>/dev/null || true
    done
  done

  # scummvm
  sed -i "s/^gui_language=.*/gui_language=${scummvm_lang}/" "/home/ark/.config/scummvm/scummvm.ini" 2>/dev/null || true

  # 
  for cfg in /home/ark/.config/retroarch/retroarch.cfg /home/ark/.config/retroarch32/retroarch.cfg; do
    sed -i "s/user_language = \"[^\"]*\"/user_language = \"$ra_lang\"/" "$cfg" 2>/dev/null || true
    sed -i "s/user_language = \"[^\"]*\"/user_language = \"$ra_lang\"/" "${cfg}.bak" 2>/dev/null || true
  done

  # Handle option separately.
  sudo rm -f "/opt/system/gamelist.xml"
  [[ "$lang" == "cn" ]] && cp_if_exists "$QUIRKS_DIR/option-gamelist.xml" "/opt/system/gamelist.xml" "yes" || true
}

# ==================== Main flow ====================
main() {
  # Record whether .console exists before calling console_detect.
  local first_boot="no"
  [[ ! -f "$CONSOLE_FILE" ]] && first_boot="yes"
  
  # Get the device name detected by boot.ini (used to detect DTB changes).
  local bootini_device=""
  if [[ -x "$CONSOLE_DETECT" ]]; then
    bootini_device="$("$CONSOLE_DETECT" -b 2>/dev/null || true)"
  fi
  
  # Detect the device.
  detect_device

  # Check for OTA updates.
  maybe_apply_ota_update

  # Handle the .console file.
  local cur_val; cur_val="$(get_console_label)"
  
  # Detect DTB changes (the boot.ini device differs from .console).
  local dtb_changed="no"
  if [[ -n "$bootini_device" && "$cur_val" != "$bootini_device" ]]; then
    dtb_changed="yes"
    msg "DTB changed detected: .console=$cur_val, boot.ini=$bootini_device"
  fi
  
  if [[ "$first_boot" == "yes" ]]; then
    # First boot.
    printf '\033c'
    echo "==============================="; echo "   arkos for clone lcdyk  ..."; echo "==============================="
    sleep 2
    # sudo chown -R ark:ark "$QUIRKS_DIR" > /dev/null
    echo "$DEVICE_NAME" | sudo tee "$CONSOLE_FILE"  2>/dev/null || true
    msg "First boot, device=$DEVICE_NAME"
    echo "$DEVICE_NAME" | sudo tee /etc/hostname >/dev/null
    sudo hostnamectl set-hostname "$DEVICE_NAME" || true
    # Update /etc/hosts in the mounted root (add it only if missing).
    if ! grep -q "127.0.1.1.*$DEVICE_NAME" "/etc/hosts" 2>/dev/null; then
        sudo sed -i "/127.0.1.1/d" "/etc/hosts"
        echo "127.0.1.1    $DEVICE_NAME" | sudo tee -a "/etc/hosts" >/dev/null
    fi
    apply_all_quirks
    sleep 5
    sudo systemctl unmask systemd-journald.service systemd-journald.socket 2>/dev/null || true
    sudo systemctl enable --now systemd-journald.service systemd-journald.socket 2>/dev/null || true
    sudo systemctl daemon-reload 2>/dev/null || true
    # Load drivers.
    msg "Running depmod -a"
    sudo depmod -a 2>/dev/null || true
  elif [[ "$dtb_changed" == "yes" || "$cur_val" != "$DEVICE_NAME" ]]; then
    # Device changed (DTB or model changed).
    local new_device old_device
    if [[ "$dtb_changed" == "yes" ]]; then
      old_device="$cur_val"
      new_device="$bootini_device"
      msg "DTB changed: $old_device -> $new_device"
      # Update the .console file.
      echo "$bootini_device" | sudo tee "$CONSOLE_FILE" > /dev/null
      # Redetect device information because the device changed.
      if [[ -x "$CONSOLE_DETECT" ]]; then
        eval "$("$CONSOLE_DETECT" -s)"
        msg "Re-detected: $DEVICE_NAME, ${SCREEN_WIDTH}x${SCREEN_HEIGHT}, joy=$JOYSTICK_COUNT, hotkey=$HOTKEY_TYPE, rot=$SCREEN_ROTATION, led=$LED_TYPE"
      fi
    else
      old_device="$cur_val"
      new_device="$DEVICE_NAME"
      msg "Console changed: $old_device -> $new_device"
      echo "$DEVICE_NAME" | sudo tee "$CONSOLE_FILE" > /dev/null
    fi
    echo "$bootini_device" | sudo tee /etc/hostname >/dev/null
    sudo hostnamectl set-hostname "$bootini_device" || true
    # Update /etc/hosts in the mounted root (add it only if missing).
    if ! grep -q "127.0.1.1.*$bootini_device" "/etc/hosts" 2>/dev/null; then
        sudo sed -i "/127.0.1.1/d" "/etc/hosts"
        echo "127.0.1.1    $bootini_device" | sudo tee -a "/etc/hosts" >/dev/null
    fi
    sudo systemctl daemon-reload 2>/dev/null || true
    # Load drivers.
    msg "Running depmod -a"
    sudo depmod -a 2>/dev/null || true
    (
      printf '\033c'
      echo "==============================="; echo "   arkos for clone lcdyk  ..."; echo "==============================="
      echo; echo "Device changed!"; echo "old: $old_device"; echo "new: $new_device"
      apply_all_quirks
      sleep 5
    ) > /dev/tty1 2>&1
    sudo systemctl unmask systemd-journald.service systemd-journald.socket 2>/dev/null || true
    sudo systemctl enable --now systemd-journald.service systemd-journald.socket 2>/dev/null || true
  else
    msg "Console unchanged: $cur_val"
  fi

  # Configure audio.
  setup_audio

  # Apply localization.
  [[ -f "/boot/.cn" ]] && { apply_localization "cn"; sudo rm -f /boot/.cn; }
  [[ -f "/boot/.ko" ]] && { apply_localization "ko"; sudo rm -f /boot/.ko; }

  # Last game
  if [[ -x /home/ark/.config/lastgame.sh ]]; then
      msg "Executing lastgame.sh..."
      sudo -u ark /home/ark/.config/lastgame.sh
      msg "lastgame.sh completed"
  else
      msg "lastgame.sh not found or not executable"
  fi

  msg "Done. device=$DEVICE_NAME"
}

main "$@"
