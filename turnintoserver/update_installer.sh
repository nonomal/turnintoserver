#!/bin/bash
set -uo pipefail

APP_PID="$1"
DMG="$2"
TARGET_APP="$3"
APP_NAME="$(/usr/bin/basename "$TARGET_APP")"
APP_EXECUTABLE="$(/usr/libexec/PlistBuddy -c 'Print:CFBundleExecutable' "$TARGET_APP/Contents/Info.plist" 2>/dev/null || true)"
if [[ -z "$APP_EXECUTABLE" ]]; then
  APP_EXECUTABLE="${APP_NAME%.app}"
fi
MOUNT_DIR="$(/usr/bin/mktemp -d /tmp/turnintoserver-update.XXXXXX)"
TMP_TARGET="$TARGET_APP.updating"
BACKUP="$TARGET_APP.previous"
LOG_DIR="$HOME/Library/Logs"
LOG_FILE="$LOG_DIR/turnintoserver-update.log"
KEEP_AWAKE_PID=""

/bin/mkdir -p "$LOG_DIR" >/dev/null 2>&1 || true
exec >> "$LOG_FILE" 2>&1

log() {
  /bin/echo "[$(/bin/date '+%Y-%m-%d %H:%M:%S')] $*"
}

cleanup() {
  if [[ -n "$KEEP_AWAKE_PID" ]]; then
    /bin/kill "$KEEP_AWAKE_PID" >/dev/null 2>&1 || true
  fi
  /usr/bin/hdiutil detach "$MOUNT_DIR" -quiet >/dev/null 2>&1 || true
  /bin/rmdir "$MOUNT_DIR" >/dev/null 2>&1 || true
}
trap cleanup EXIT

start_keep_awake() {
  /usr/bin/caffeinate -dimsu -w "$$" >/dev/null 2>&1 &
  KEEP_AWAKE_PID="$!"
}

wait_for_app_to_exit() {
  local attempts=0
  log "Waiting for app pid $APP_PID to exit."
  while /bin/kill -0 "$APP_PID" >/dev/null 2>&1; do
    if [[ "$attempts" -ge 30 ]]; then
      log "App pid $APP_PID did not exit after 3 seconds; terminating it."
      /bin/kill "$APP_PID" >/dev/null 2>&1 || true
      break
    fi
    attempts=$((attempts + 1))
    /bin/sleep 0.1
  done

  attempts=0
  while /bin/kill -0 "$APP_PID" >/dev/null 2>&1; do
    if [[ "$attempts" -ge 20 ]]; then
      log "App pid $APP_PID still alive after 2 more seconds; force killing it."
      /bin/kill -9 "$APP_PID" >/dev/null 2>&1 || true
      break
    fi
    attempts=$((attempts + 1))
    /bin/sleep 0.1
  done
}

reopen_existing_app() {
  if [[ -d "$TARGET_APP" ]]; then
    /usr/bin/open -n "$TARGET_APP" >/dev/null 2>&1 || true
  elif [[ -d "$BACKUP" ]]; then
    /usr/bin/open -n "$BACKUP" >/dev/null 2>&1 || true
  fi
}

stop_stale_backup_instances() {
  local found=0
  while read -r pid command; do
    if [[ -z "${pid:-}" || -z "${command:-}" ]]; then
      continue
    fi
    case "$command" in
      *"$BACKUP/Contents/MacOS/$APP_EXECUTABLE"*|*"$TARGET_APP.previous/Contents/MacOS/$APP_EXECUTABLE"*)
        log "Stopping stale backup instance pid=$pid command=$command"
        /bin/kill "$pid" >/dev/null 2>&1 || true
        found=1
        ;;
    esac
  done < <(/bin/ps -axo pid=,command=)

  if [[ "$found" != "1" ]]; then
    return
  fi

  /bin/sleep 1
  while read -r pid command; do
    if [[ -z "${pid:-}" || -z "${command:-}" ]]; then
      continue
    fi
    case "$command" in
      *"$BACKUP/Contents/MacOS/$APP_EXECUTABLE"*|*"$TARGET_APP.previous/Contents/MacOS/$APP_EXECUTABLE"*)
        log "Force stopping stale backup instance pid=$pid command=$command"
        /bin/kill -9 "$pid" >/dev/null 2>&1 || true
        ;;
    esac
  done < <(/bin/ps -axo pid=,command=)
}

validate_installed_target() {
  if [[ ! -x "$TARGET_APP/Contents/MacOS/$APP_EXECUTABLE" ]]; then
    log "Installed app executable is missing."
    return 1
  fi
  /usr/bin/codesign --verify --deep --strict "$TARGET_APP" >/dev/null 2>&1
}

target_is_running() {
  local target_binary="$TARGET_APP/Contents/MacOS/$APP_EXECUTABLE"
  while read -r command; do
    case "$command" in
      *"$target_binary"*) return 0 ;;
    esac
  done < <(/bin/ps -axo command=)
  return 1
}

launch_installed_executable() {
  local target_binary="$TARGET_APP/Contents/MacOS/$APP_EXECUTABLE"
  if [[ ! -x "$target_binary" ]]; then
    log "Installed executable is not launchable: $target_binary"
    return 1
  fi

  log "Launching installed executable directly: $target_binary"
  /usr/bin/nohup "$target_binary" >/dev/null 2>&1 &
  local launched_pid="$!"
  log "Launched installed executable pid=$launched_pid"

  local attempts=0
  while [[ "$attempts" -lt 50 ]]; do
    if target_is_running; then
      return 0
    fi
    if ! /bin/kill -0 "$launched_pid" >/dev/null 2>&1; then
      log "Installed executable pid=$launched_pid exited before target was observed."
      return 1
    fi
    attempts=$((attempts + 1))
    /bin/sleep 0.1
  done

  log "Direct executable launch did not reach running state."
  return 1
}

open_installed_app() {
  stop_stale_backup_instances
  /bin/rm -rf "$BACKUP" >/dev/null 2>&1 || true

  if launch_installed_executable; then
    stop_stale_backup_instances
    return 0
  fi

  log "Direct executable launch failed; trying Launch Services open."
  if /usr/bin/open -n "$TARGET_APP"; then
    local attempts=0
    while [[ "$attempts" -lt 50 ]]; do
      /bin/sleep 0.1
      stop_stale_backup_instances
      if target_is_running; then
        return 0
      fi
      attempts=$((attempts + 1))
    done
    log "Launch Services open did not reach running state."
  fi
  return 1
}

register_app() {
  local lsregister="/System/Library/Frameworks/CoreServices.framework/Versions/Current/Frameworks/LaunchServices.framework/Versions/Current/Support/lsregister"
  if [[ -x "$lsregister" ]]; then
    "$lsregister" -f -R -trusted "$TARGET_APP" >/dev/null 2>&1 || true
  fi
}

install_without_privileges() {
  /bin/rm -rf "$TMP_TARGET" "$BACKUP" || return 1
  /usr/bin/ditto --norsrc --noextattr "$SOURCE_APP" "$TMP_TARGET" || return 1
  /usr/bin/xattr -cr "$TMP_TARGET" >/dev/null 2>&1 || true

  if [[ -d "$TARGET_APP" ]]; then
    /bin/mv "$TARGET_APP" "$BACKUP" || return 1
  fi
  if /bin/mv "$TMP_TARGET" "$TARGET_APP"; then
    return 0
  fi

  /bin/rm -rf "$TARGET_APP" >/dev/null 2>&1 || true
  if [[ -d "$BACKUP" ]]; then
    /bin/mv "$BACKUP" "$TARGET_APP" || return 1
  fi
  return 1
}

install_with_privileges() {
  /usr/bin/osascript - "$SOURCE_APP" "$TARGET_APP" "$TMP_TARGET" "$BACKUP" <<'APPLESCRIPT'
on run argv
  set sourceApp to item 1 of argv
  set targetApp to item 2 of argv
  set tmpTarget to item 3 of argv
  set backupApp to item 4 of argv
  set qSource to quoted form of sourceApp
  set qTarget to quoted form of targetApp
  set qTmp to quoted form of tmpTarget
  set qBackup to quoted form of backupApp
  set command to "set -e; /bin/rm -rf " & qTmp & " " & qBackup & "; /usr/bin/ditto --norsrc --noextattr " & qSource & " " & qTmp & "; /usr/bin/xattr -cr " & qTmp & " >/dev/null 2>&1 || true; if [ -d " & qTarget & " ]; then /bin/mv " & qTarget & " " & qBackup & "; fi; if /bin/mv " & qTmp & " " & qTarget & "; then /bin/rm -rf " & qBackup & "; else /bin/rm -rf " & qTarget & "; if [ -d " & qBackup & " ]; then /bin/mv " & qBackup & " " & qTarget & "; fi; exit 1; fi"
  do shell script command with administrator privileges
end run
APPLESCRIPT
}

log "Starting update. target=$TARGET_APP dmg=$DMG"
start_keep_awake
wait_for_app_to_exit

log "Mounting DMG."
if ! /usr/bin/hdiutil attach "$DMG" -mountpoint "$MOUNT_DIR" -nobrowse -quiet; then
  log "Failed to mount DMG."
  reopen_existing_app
  exit 1
fi

SOURCE_APP="$MOUNT_DIR/$APP_NAME"
if [[ ! -d "$SOURCE_APP" ]]; then
  SOURCE_APP="$(/usr/bin/find "$MOUNT_DIR" -maxdepth 1 -name "*.app" -type d | /usr/bin/head -n 1)"
fi
if [[ ! -d "$SOURCE_APP" ]]; then
  log "No app bundle found in mounted DMG."
  reopen_existing_app
  exit 1
fi

SOURCE_VERSION="$(/usr/libexec/PlistBuddy -c 'Print:CFBundleShortVersionString' "$SOURCE_APP/Contents/Info.plist" 2>/dev/null || true)"
SOURCE_EXECUTABLE="$(/usr/libexec/PlistBuddy -c 'Print:CFBundleExecutable' "$SOURCE_APP/Contents/Info.plist" 2>/dev/null || true)"
if [[ -n "$SOURCE_EXECUTABLE" ]]; then
  APP_EXECUTABLE="$SOURCE_EXECUTABLE"
fi
log "Found source app: $SOURCE_APP version=$SOURCE_VERSION"

if install_without_privileges; then
  log "Installed without elevated privileges."
else
  log "Direct install failed; trying administrator privileges."
  if ! install_with_privileges; then
    log "Administrator install failed."
    reopen_existing_app
    exit 1
  fi
  log "Installed with administrator privileges."
fi

TARGET_VERSION="$(/usr/libexec/PlistBuddy -c 'Print:CFBundleShortVersionString' "$TARGET_APP/Contents/Info.plist" 2>/dev/null || true)"
log "Installed target version=$TARGET_VERSION"

if ! validate_installed_target; then
  log "Installed target failed validation; rolling back."
  /bin/rm -rf "$TARGET_APP" >/dev/null 2>&1 || true
  if [[ -d "$BACKUP" ]]; then
    /bin/mv "$BACKUP" "$TARGET_APP" >/dev/null 2>&1 || true
  fi
  reopen_existing_app
  exit 1
fi

register_app
if open_installed_app; then
  log "Relaunched installed app."
else
  log "Failed to relaunch installed app."
  exit 1
fi

/bin/rm -f "$DMG"
/bin/rmdir "$(/usr/bin/dirname "$DMG")" >/dev/null 2>&1 || true
if [[ -f "$0" && "$0" == *turnintoserver-install-*.sh ]]; then
  /bin/rm -f "$0"
fi
exit 0
