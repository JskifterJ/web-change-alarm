#!/bin/bash
# Mac watcher: checks the page in config.json every N seconds and, as soon as the
# watched text changes state, opens the page and plays a looping alarm until you
# click "Stop alarm". Uses only tools that ship with macOS (bash 3.2, curl, perl,
# afplay, osascript, caffeinate).
#
#   bash mac/watch.sh --test                 one check + 4 s of alarm
#   bash mac/watch.sh --end-time 22:00       watch now until 22:00
set -u

DIR="$(cd "$(dirname "$0")" && pwd)"
CONFIG="$DIR/../config.json"
END_TIME="08:30"     # stop watching at this time today (HH:MM)
INTERVAL=30          # seconds between checks; please keep >= 30
VOLUME="0.2"         # 0.0 - 1.0, speaker volume forced while the alarm plays
UNTIL=""             # last day to watch (YYYY-MM-DD); later days exit at once
TEST=0

while [ $# -gt 0 ]; do
  case "$1" in
    --config)   CONFIG="$2"; shift 2 ;;
    --end-time) END_TIME="$2"; shift 2 ;;
    --interval) INTERVAL="$2"; shift 2 ;;
    --volume)   VOLUME="$2"; shift 2 ;;
    --until)    UNTIL="$2"; shift 2 ;;
    --test)     TEST=1; shift ;;
    *) echo "Unknown option: $1" >&2; exit 2 ;;
  esac
done

LOG="$DIR/watch.log"
ALARM_SOUND="/System/Library/Sounds/Sosumi.aiff"
WARN_SOUND="/System/Library/Sounds/Basso.aiff"
UA="Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/130.0 Safari/537.36"
PAGE="$(mktemp "${TMPDIR:-/tmp}/webchangealarm.XXXXXX")"
trap 'rm -f "$PAGE"' EXIT

log() {
  local line="$(date +%H:%M:%S)  $*"
  echo "$line"
  echo "$(date +%Y-%m-%d) $line" >> "$LOG"
}

# Read one text field from config.json (empty if missing).
cfg() {
  perl -MJSON::PP -e 'local $/; open my $f, "<", $ARGV[0] or die "cannot read $ARGV[0]\n";
    my $c = JSON::PP->new->utf8->decode(<$f>); my $v = $c->{$ARGV[1]};
    binmode STDOUT, ":utf8"; print defined $v ? $v : ""' "$CONFIG" "$1"
}

NAME="$(cfg name)" || exit 1
URL="$(cfg url)"
OPEN_URL="$(cfg openUrl)"; [ -z "$OPEN_URL" ] && OPEN_URL="$URL"
ALERT_WHEN="$(cfg alertWhen)"
if [ -z "$NAME" ] || [ -z "$URL" ] || [ -z "$(cfg watchFor)" ]; then
  echo "config.json needs name, url and watchFor." >&2; exit 1
fi
case "$ALERT_WHEN" in gone|appears) ;; *) echo "config.json: alertWhen must be 'gone' or 'appears'." >&2; exit 1 ;; esac
case "$URL" in *\?*) SEP="&" ;; *) SEP="?" ;; esac

# Prints WAITING (nothing to report yet), TRIGGERED (the change happened) or ERROR (page not usable).
check() {
  if ! curl -sS -L --fail --max-time 20 -A "$UA" -H "Cache-Control: no-cache" \
       -o "$PAGE" "${URL}${SEP}_=$(date +%s)" 2>/dev/null; then
    echo ERROR; return
  fi
  perl -MJSON::PP -MEncode -e '
    local $/;
    open my $f, "<", $ARGV[0] or die; my $c = JSON::PP->new->utf8->decode(<$f>);
    open my $p, "<", $ARGV[1] or die; my $html = Encode::decode("UTF-8", <$p>);
    for my $re (@{ $c->{mustContain} || [] }) {
      next unless length $re;
      if ($html !~ /$re/) { print "ERROR"; exit }   # not the expected page
    }
    my $found = $html =~ /$c->{watchFor}/ ? 1 : 0;
    my $hit = ($c->{alertWhen} eq "gone") ? !$found : $found;
    print $hit ? "TRIGGERED" : "WAITING";
  ' "$CONFIG" "$PAGE" 2>/dev/null || echo ERROR
}

OLD_VOL=""; OLD_MUTED=""; LOOP_PID=""
alarm_start() {
  # Force the speakers on, whatever the current volume/mute state.
  OLD_VOL="$(osascript -e 'output volume of (get volume settings)' 2>/dev/null)"
  OLD_MUTED="$(osascript -e 'output muted of (get volume settings)' 2>/dev/null)"
  local pct; pct="$(awk -v v="$VOLUME" 'BEGIN { printf "%d", v * 100 }')"
  osascript -e "set volume without output muted" -e "set volume output volume $pct" 2>/dev/null
  ( while :; do afplay "$ALARM_SOUND"; done ) &
  LOOP_PID=$!
}
alarm_stop() {
  [ -n "$LOOP_PID" ] && kill "$LOOP_PID" 2>/dev/null
  pkill -f "afplay $ALARM_SOUND" 2>/dev/null
  [ -n "$OLD_VOL" ] && [ "$OLD_VOL" != "missing value" ] && osascript -e "set volume output volume $OLD_VOL" 2>/dev/null
  [ "$OLD_MUTED" = "true" ] && osascript -e "set volume with output muted" 2>/dev/null
  LOOP_PID=""
}
notify() { # title, text
  osascript -e 'on run a' -e 'display notification (item 2 of a) with title (item 1 of a) sound name "Glass"' -e 'end run' \
    "$1" "$2" 2>/dev/null
}

if [ "$TEST" -eq 1 ]; then
  log "TEST [$NAME] page state: $(check)"
  alarm_start; sleep 4; alarm_stop
  log "TEST alarm played"
  exit 0
fi

if [ -n "$UNTIL" ]; then
  if ! [[ "$UNTIL" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]]; then echo "--until must look like 2026-11-20" >&2; exit 2; fi
  if [ "$(date +%Y%m%d)" -gt "${UNTIL//-/}" ]; then log "Past the end date ($UNTIL), nothing to do."; exit 0; fi
fi
if ! [[ "$END_TIME" =~ ^[0-9]{1,2}:[0-9]{2}$ ]]; then echo "--end-time must look like 08:30" >&2; exit 2; fi
END_HHMM=$(( 10#${END_TIME%%:*} * 100 + 10#${END_TIME##*:} ))
now_hhmm() { echo $(( 10#$(date +%H) * 100 + 10#$(date +%M) )); }
if [ "$(now_hhmm)" -ge "$END_HHMM" ]; then log "Started after $END_TIME, nothing to do."; exit 0; fi

# Keep the Mac (and display) awake while this script runs.
caffeinate -dims -w $$ &
log "Watching [$NAME] every ${INTERVAL} s until $END_TIME."

errors=0
state=""
while [ "$(now_hhmm)" -lt "$END_HHMM" ]; do
  state="$(check)"
  log "$state"
  if [ "$state" = "TRIGGERED" ]; then
    sleep 3
    if [ "$(check)" = "TRIGGERED" ]; then   # confirm, to rule out a half-loaded page
      log "ALARM: the page changed"
      open "$OPEN_URL"
      notify "Web change alarm" "$NAME changed - go now!"
      alarm_start
      osascript -e 'on run a' \
        -e 'display dialog ((item 1 of a) & " changed - go now!") with title "Web change alarm" buttons {"Stop alarm"} default button 1 with icon caution' \
        -e 'end run' "$NAME" >/dev/null 2>&1
      alarm_stop
      log "Alarm stopped."
      break
    fi
  elif [ "$state" = "ERROR" ]; then
    errors=$((errors + 1))
    if [ "$errors" -eq 6 ]; then
      log "WARNING: 6 failed checks in a row - check the page by hand"
      notify "Web change alarm" "Cannot read the page for $NAME - check it by hand."
      for _ in 1 2 3; do afplay "$WARN_SOUND"; done
    fi
  else
    errors=0
  fi
  sleep "$INTERVAL"
done
log "Done."
