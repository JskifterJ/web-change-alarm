#!/usr/bin/env bash
# Cloud watcher (GitHub Actions): checks the page in config.json and opens a
# GitHub issue (-> email / app notification) as soon as the watched text changes state.
set -u
export TZ="${TZ_NAME:-Europe/Zurich}"

CONFIG="${CONFIG:-config.json}"
UA="Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/130.0 Safari/537.36"
WINDOW_START="${WINDOW_START:-06:30}"
WINDOW_END="${WINDOW_END:-08:30}"
INTERVAL="${INTERVAL:-45}"
MODE="${MODE:-window}"
WATCH_UNTIL="${WATCH_UNTIL:-}"   # last day to watch, yyyy-mm-dd (repo variable WATCH_UNTIL)
OWNER="${GITHUB_REPOSITORY_OWNER:-}"
TODAY="$(date +%F)"
PAGE="$(mktemp)"

NAME="$(jq -r '.name // empty' "$CONFIG")"
URL="$(jq -r '.url // empty' "$CONFIG")"
WATCH_FOR="$(jq -r '.watchFor // empty' "$CONFIG")"
ALERT_WHEN="$(jq -r '.alertWhen // empty' "$CONFIG")"
mapfile -t MUST_CONTAIN < <(jq -r '(.mustContain // [])[]' "$CONFIG")
if [ -z "$NAME" ] || [ -z "$URL" ] || [ -z "$WATCH_FOR" ]; then
  echo "::error::$CONFIG needs name, url and watchFor."; exit 1
fi
case "$ALERT_WHEN" in gone|appears) ;; *) echo "::error::alertWhen must be 'gone' or 'appears'."; exit 1 ;; esac
case "$URL" in *\?*) SEP="&" ;; *) SEP="?" ;; esac

# Prints WAITING (nothing to report yet), TRIGGERED (the change happened) or ERROR (page not usable).
check() {
  if ! curl -sS -L --fail --max-time 20 -A "$UA" -H "Cache-Control: no-cache" \
       -o "$PAGE" "${URL}${SEP}_=$(date +%s)" 2>/dev/null; then
    echo ERROR; return
  fi
  # Make sure we really got the expected page, not an error/maintenance page.
  for p in "${MUST_CONTAIN[@]}"; do
    [ -n "$p" ] && ! grep -qP -- "$p" "$PAGE" && { echo ERROR; return; }
  done
  if grep -qP -- "$WATCH_FOR" "$PAGE"; then found=1; else found=0; fi
  if { [ "$ALERT_WHEN" = gone ] && [ $found -eq 0 ]; } || { [ "$ALERT_WHEN" = appears ] && [ $found -eq 1 ]; }; then
    echo TRIGGERED
  else
    echo WAITING
  fi
}

notify() { # title, body
  gh issue create --title "$1" --body "$2" --assignee "$OWNER" \
    || gh issue create --title "$1" --body "$2"
}

if [ "$MODE" = "test" ]; then
  state="$(check)"
  echo "Current state: $state"
  notify "Test: watcher works for $NAME (page state: $state)" \
    "@$OWNER this is a test of the alert email. Current page state: **$state**.

$URL"
  exit 0
fi

# Only run up to the end date the repo owner chose.
if [ -z "$WATCH_UNTIL" ]; then
  echo "::warning::Repository variable WATCH_UNTIL is not set (e.g. 2026-11-20) - not watching."; exit 0
fi
if ! date -d "$WATCH_UNTIL" +%F >/dev/null 2>&1; then
  echo "::error::WATCH_UNTIL='$WATCH_UNTIL' is not a valid date (use yyyy-mm-dd)."; exit 1
fi
if [[ "$TODAY" > "$(date -d "$WATCH_UNTIL" +%F)" ]]; then
  echo "Past the end date ($WATCH_UNTIL), exiting."; exit 0
fi

# Already alerted today? Then there is nothing left to do.
if gh issue list --state all --search "\"CHANGED\" \"$TODAY\" in:title" --json number --jq 'length' | grep -qv '^0$'; then
  echo "Alert already sent today, exiting."; exit 0
fi

start=$(date -d "$TODAY $WINDOW_START" +%s)
end=$(date -d "$TODAY $WINDOW_END" +%s)
now=$(date +%s)
if [ "$now" -ge "$end" ]; then echo "Window is over, exiting."; exit 0; fi
if [ "$now" -lt "$start" ]; then
  echo "Waiting $((start - now))s until $WINDOW_START..."
  sleep $((start - now))
fi

echo "Watching [$NAME] every ${INTERVAL}s until $WINDOW_END."
errors=0
warned=0
while [ "$(date +%s)" -lt "$end" ]; do
  state="$(check)"
  echo "$(date +%T) $state"
  case "$state" in
    TRIGGERED)
      sleep 5
      if [ "$(check)" = "TRIGGERED" ]; then   # confirm, to rule out a half-loaded page
        notify "CHANGED: $NAME $TODAY $(date +%H:%M)" \
          "@$OWNER the page changed (watched text is now **$ALERT_WHEN**). Go now:

$URL"
        echo "::error::Page changed - go now"
        exit 1   # failed run also triggers GitHub's own failure email as a backup
      fi
      ;;
    ERROR)
      errors=$((errors + 1))
      if [ "$errors" -ge 8 ] && [ "$warned" -eq 0 ]; then
        warned=1
        notify "Watcher cannot read the page ($NAME, $TODAY)" \
          "@$OWNER $errors checks in a row failed. Check the page by hand: $URL"
      fi
      ;;
    *) errors=0 ;;
  esac
  sleep "$INTERVAL"
done
echo "Window ended, nothing changed."
