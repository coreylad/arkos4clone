#!/bin/bash

# ArkOS4Clone on-device update entry point (replaces dArkOS's Update.sh).
# Installed in the original Update.sh location and run when the user selects "Update" in Settings.
# Offline mode: place ArkOS4CloneUpdate.sh in /roms/update (or /roms2/update),
#               and dated archive parts in /roms/update/<date>/. If a local script
#               is found, run it without connecting to the network. On success,
#               remove the script and the dated archive directory.

if [[ "$(stat -c "%U" /home/ark)" != "ark" ]]; then
  printf "Fixing home folder permissions.  Please wait..."
  sudo chown -R ark:ark /home/ark
  sudo chmod -R 755 /home/ark
fi

printf "\nChecking for updates.  Please wait..."

LOG_FILE="/home/ark/esupdate.log"

if [ -f "$LOG_FILE" ]; then
  sudo mv -f "$LOG_FILE" "$LOG_FILE.old"
fi

sudo timedatectl set-ntp 1

LOCATION="https://raw.githubusercontent.com/lcdyk0517/arkos4clone-updates/master/update_files"

# ---- Offline mode: use a local update script if present. ----
LOCAL_DIR=""
for d in /roms/update /roms2/update; do
  if [ -f "$d/ArkOS4CloneUpdate.sh" ]; then
    LOCAL_DIR="$d"
    break
  fi
done

if [ -n "$LOCAL_DIR" ]; then
  RUN_SCRIPT="$LOCAL_DIR/ArkOS4CloneUpdate.sh"
  printf "\nUsing local update script in ${LOCAL_DIR}..."
else
  RUN_SCRIPT="/home/ark/ArkOS4CloneUpdate.sh"
  sudo rm -f "$RUN_SCRIPT"
  wget -t 3 -T 60 --no-check-certificate "$LOCATION"/ArkOS4CloneUpdate.sh -O "$RUN_SCRIPT" -a "$LOG_FILE"
  if [ $? -ne 0 ] || [ ! -s "$RUN_SCRIPT" ]; then
    sudo rm -f "$RUN_SCRIPT"
    sudo msgbox "Looks like OTA updating is currently down or your wifi or internet connection is not functioning correctly."
    printf "There was an error with attempting this update." | tee -a "$LOG_FILE"
    exit 1
  fi
fi

sudo chmod -v 777 "$RUN_SCRIPT" | tee -a "$LOG_FILE"

# The update script deletes itself on success, so capture the date first for offline cleanup.
UPDATE_DATE="$(grep -m1 '^UPDATE_DATE=' "$RUN_SCRIPT" 2>/dev/null | tr -dc '0-9')"

"$RUN_SCRIPT"

if [ $? -ne 187 ]; then
  # The update script displays the error details. Keep offline scripts for diagnosis;
  # remove only scripts downloaded from the network.
  printf "There was an error with attempting this update." | tee -a "$LOG_FILE"
  if [ -z "$LOCAL_DIR" ] && [ -f "$RUN_SCRIPT" ]; then
    rm -f "$RUN_SCRIPT"
  fi
else
  # Update complete: in offline mode, remove the script and all applied dated
  # archive directories; in online mode, remove the downloaded script.
  if [ -n "$LOCAL_DIR" ]; then
    rm -f "$LOCAL_DIR/ArkOS4CloneUpdate.sh"
    for d in "$LOCAL_DIR"/[0-9]*; do
      [ -d "$d" ] || continue
      DATE_NAME="$(basename "$d")"
      case "$DATE_NAME" in
        [0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]) ;;
        *) continue ;;
      esac
      if [ -f "/home/ark/.update/.${DATE_NAME}" ]; then
        sudo rm -rf "$d"
      fi
    done
  elif [ -f "$RUN_SCRIPT" ]; then
    rm -f "$RUN_SCRIPT"
  fi
fi

if [ ! -z "$(pidof rg351p-js2xbox)" ]; then
  sudo kill -9 "$(pidof rg351p-js2xbox)"
  sudo rm -f /dev/input/by-path/platform-odroidgo2-joypad-event-joystick
fi
