#!/bin/bash
# Installs a launchd agent that runs mac/watch.sh on the chosen days until --until.
#
#   bash mac/install.sh --until 2026-11-20
#   bash mac/install.sh --until 2026-11-20 --start-time 06:45 --end-time 09:00 --days Mon,Wed,Fri --volume 0.6
#
# Remove it again with:  bash mac/uninstall.sh
set -eu

DIR="$(cd "$(dirname "$0")" && pwd)"
UNTIL=""
START_TIME="07:00"
END_TIME="08:30"
DAYS="Mon,Tue,Wed,Thu,Fri"
INTERVAL=30
VOLUME="0.2"
CONFIG="$DIR/../config.json"
LABEL="com.webchangealarm.watch"

die() { echo "Error: $*" >&2; exit 1; }
while [ $# -gt 0 ]; do
  case "$1" in
    --until)      UNTIL="$2"; shift 2 ;;
    --start-time) START_TIME="$2"; shift 2 ;;
    --end-time)   END_TIME="$2"; shift 2 ;;
    --days)       DAYS="$2"; shift 2 ;;
    --interval)   INTERVAL="$2"; shift 2 ;;
    --volume)     VOLUME="$2"; shift 2 ;;
    --config)     CONFIG="$2"; shift 2 ;;
    --label)      LABEL="$2"; shift 2 ;;
    *) die "unknown option $1" ;;
  esac
done

[ -n "$UNTIL" ] || die "--until is required: the last day to watch, e.g. --until 2026-11-20"
[[ "$UNTIL" =~ ^20[0-9]{2}-(0[1-9]|1[0-2])-(0[1-9]|[12][0-9]|3[01])$ ]] || die "--until must look like 2026-11-20, got '$UNTIL'"
[ "${UNTIL//-/}" -ge "$(date +%Y%m%d)" ] || die "--until ($UNTIL) is in the past"
hhmm() { [[ "$1" =~ ^([01]?[0-9]|2[0-3]):[0-5][0-9]$ ]] || die "time must look like 07:00, got '$1'"; echo $(( 10#${1%%:*} * 100 + 10#${1##*:} )); }
[ "$(hhmm "$END_TIME")" -gt "$(hhmm "$START_TIME")" ] || die "--end-time must be after --start-time"
[[ "$INTERVAL" =~ ^[0-9]+$ ]] && [ "$INTERVAL" -ge 30 ] || die "--interval must be at least 30 (be nice to the site)"
awk -v v="$VOLUME" 'BEGIN { exit !(v ~ /^[0-9.]+$/ && v >= 0 && v <= 1) }' || die "--volume must be between 0 and 1"
[ -f "$CONFIG" ] || die "config not found: $CONFIG"
CONFIG="$(cd "$(dirname "$CONFIG")" && pwd)/$(basename "$CONFIG")"

# macOS blocks background jobs from reading Desktop, Documents, Downloads and iCloud Drive.
case "$DIR" in
  "$HOME/Desktop"*|"$HOME/Documents"*|"$HOME/Downloads"*|"$HOME/Library/Mobile Documents"*)
    die "macOS won't let a scheduled job run from $DIR.
Move the folder into your home folder first, e.g.:
  mv \"$(dirname "$DIR")\" ~/web-change-alarm && cd ~/web-change-alarm
then run this installer again." ;;
esac

# One launchd calendar entry per weekday (launchd: 1 = Monday ... 7 = Sunday).
H=$((10#${START_TIME%%:*})); M=$((10#${START_TIME##*:}))
ENTRIES=""
IFS=',' read -r -a DAY_LIST <<< "$DAYS"
for d in "${DAY_LIST[@]}"; do
  case "$(echo "$d" | tr '[:upper:]' '[:lower:]' | cut -c1-3)" in
    mon) n=1 ;; tue) n=2 ;; wed) n=3 ;; thu) n=4 ;; fri) n=5 ;; sat) n=6 ;; sun) n=7 ;;
    *) die "unknown day '$d' (use Mon,Tue,Wed,Thu,Fri,Sat,Sun)" ;;
  esac
  ENTRIES="$ENTRIES
    <dict><key>Weekday</key><integer>$n</integer><key>Hour</key><integer>$H</integer><key>Minute</key><integer>$M</integer></dict>"
done

xml() { printf '%s' "$1" | sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g'; }
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
mkdir -p "$HOME/Library/LaunchAgents"
cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$(xml "$LABEL")</string>
  <key>ProgramArguments</key>
  <array>
    <string>/bin/bash</string>
    <string>$(xml "$DIR/watch.sh")</string>
    <string>--config</string><string>$(xml "$CONFIG")</string>
    <string>--end-time</string><string>$END_TIME</string>
    <string>--interval</string><string>$INTERVAL</string>
    <string>--volume</string><string>$VOLUME</string>
    <string>--until</string><string>$UNTIL</string>
  </array>
  <key>StartCalendarInterval</key>
  <array>$ENTRIES
  </array>
  <key>StandardOutPath</key><string>/dev/null</string>
  <key>StandardErrorPath</key><string>$(xml "$DIR/launchd.err")</string>
</dict>
</plist>
EOF
plutil -lint "$PLIST" >/dev/null

launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$PLIST"
echo "Installed '$LABEL': $DAYS $START_TIME-$END_TIME, every $INTERVAL s, until $UNTIL."
echo "It stops by itself after $UNTIL. Remove it earlier with: bash mac/uninstall.sh"
