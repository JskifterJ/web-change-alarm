# Web change alarm

Watch a web page for a piece of text to **disappear** (e.g. *"sold out"*) or **appear**
(e.g. *"Add to cart"*) and get alerted the moment it happens:

- **Local alarm (Windows):** a loud looping alarm that also opens the page in your browser.
- **Cloud email (GitHub Actions):** a GitHub issue, which reaches you as an email or GitHub app notification, with nothing running at home.

It does **not** buy or click anything. It just tells you to go, fast.

The repo comes set up with a real example: the sold-out
[Verbier Opening Session + Saint-Nicolas Express](https://verbier4vallees.ch/fr/shop-en-ligne/activites/opening-session-saint-nicolas-express_activity_426820)
tickets. It alarms when the notice *"quota de forfait … vendu"* disappears. To watch something
else, see [Watch a different page](#watch-a-different-page).

**You always choose an end date.** After that date nothing runs.

| | Local alarm (Windows) | Cloud email (GitHub Actions) |
|---|---|---|
| Alert | Loud alarm + opens the page | Issue → email / GitHub app push |
| Needs | Your PC on and logged in | A free GitHub account |
| Speed | Every 30 s (default) | Every 45 s, email can lag a minute |

---

## Option 1: Local alarm on Windows

1. Get the files: **Code → Download ZIP** (then unzip), or `git clone` this repo.
2. Open PowerShell in the folder and test once. You should see the page state (`WAITING`)
   and hear 4 s of alarm:
   ```powershell
   powershell -ExecutionPolicy Bypass -File .\local\watch.ps1 -Test
   ```
3. Install the daily schedule with **your own end date** (last day to watch, `yyyy-MM-dd`):
   ```powershell
   powershell -ExecutionPolicy Bypass -File .\local\install-task.ps1 -Until 2026-11-20
   ```
   Default: **Monday–Friday, 07:00–08:30**, a check every 30 s, alarm at 20 % volume. Change any of it:
   ```powershell
   powershell -ExecutionPolicy Bypass -File .\local\install-task.ps1 -Until 2026-11-20 `
       -StartTime 06:45 -EndTime 09:00 -Days Monday,Wednesday,Friday -AlarmVolume 0.6
   ```
   Running the installer again replaces the previous schedule.

When the page changes, it opens in your browser and the alarm loops until you press a key
in the watcher window. Your PC must be on and you must be logged in (it can wake from sleep,
not from shutdown). Each check is logged in `local\watch.log`.

Watch right now without a schedule: `.\local\watch.ps1 -EndTime 22:00`

Remove the schedule:
```powershell
Unregister-ScheduledTask -TaskName 'Web change alarm' -Confirm:$false
```

## Option 2: Email alert via GitHub Actions

1. Click **Use this template → Create a new repository** (private is fine).
2. In your new repo: **Settings → Secrets and variables → Actions → Variables → New repository variable**:
   - `WATCH_UNTIL`: **required**, last day to watch, e.g. `2026-11-20`. Without it nothing runs.
   - Optional: `WINDOW_START` (default `06:30`), `WINDOW_END` (default `08:30`), `INTERVAL`
     (seconds, default `45`). Times are Swiss time (Europe/Zurich). `WINDOW_START` must be after ~05:20.
3. Test it: **Actions → Web change alarm → Run workflow**, mode `test`. You should get an
   issue (and an email) within a minute or two.
4. Make sure GitHub can reach you: profile **Settings → Notifications**. Turn on email and/or
   the GitHub mobile app, so you get a push notification instead of only an email.

It then runs every weekday morning on its own (Mon–Fri, edit the `cron` lines in
`.github/workflows/watch.yml` for other days) and stops after `WATCH_UNTIL`. To stop early,
delete the variable or **Actions → Web change alarm → ⋯ → Disable workflow**.

---

## Watch a different page

Everything about *what* to watch is in [`config.json`](config.json):

```json
{
  "name": "Verbier Opening Session + Saint-Nicolas Express",
  "url": "https://verbier4vallees.ch/fr/shop-en-ligne/activites/opening-session-saint-nicolas-express_activity_426820",
  "mustContain": [
    "box__intro",
    "\"name\": \"Opening Session \\+ Saint-Nicolas Express"
  ],
  "watchFor": "(?i)quota de forfait[^<]*vendu",
  "alertWhen": "gone"
}
```

| Field | Meaning |
|---|---|
| `name` | Label used in the alarm window and email titles. |
| `url` | The page to check. |
| `watchFor` | The text (a [regular expression](https://regex101.com/)) whose change you care about. |
| `alertWhen` | `"gone"`: alert when `watchFor` **disappears** (sold-out banner, "coming soon"…). `"appears"`: alert when it **shows up** ("Add to cart", a new date, a price…). |
| `mustContain` | Safety checks: text that is always on the real page. If any is missing, the check counts as an *error*, not an alarm. This stops a maintenance or error page from setting off a false alarm. |

### How to pick the element to track, step by step (the Verbier example)

1. **Open the page** in Chrome/Edge/Firefox while it is in the "before" state (sold out).
2. **Find the element** that will change: here the red notice *"Le quota de forfait pour
   aujourd'hui a été vendu (13.11.26)"*. Right-click it → **Inspect**. The developer tools show its HTML:
   `<span style="color: #e03e2d;">Le quota de forfait pour aujourd&#039;hui a été vendu (13.11.26)</span>`.
   The date changes every day, so the pattern must not include it.
3. **Check the watcher sees it too.** The watcher downloads the raw HTML and does not run
   JavaScript. Press **Ctrl+U** (view source) and **Ctrl+F** for your text. If it's in the
   source, you're good. If it only appears in *Inspect* but not in *view source*, the
   site builds it with JavaScript and this tool can't see it. Choose different text, or this
   page isn't a fit.
4. **Write `watchFor`.** Keep it short and robust. The Verbier one,
   `(?i)quota de forfait[^<]*vendu`, means: ignore upper/lower case (`(?i)`), find
   *"quota de forfait"*, then any text up to *"vendu"* that stays inside the same element (`[^<]*`).
   That skips the parts that vary (`aujourd&#039;hui a été`, the date) and the accents.
   Plain text works too; just put `\` before special characters like `+ . ( ) ? [ ]`.
5. **Pick `alertWhen`**: the notice will vanish when tickets return, so `"gone"`.
6. **Add `mustContain` safety checks** that are on the page in *both* states: the product
   name and a CSS class of the main layout (`box__intro`, found in Inspect). In JSON, `"`
   inside a string is written `\"` and a regex `\` is written `\\`.
7. **Test**: `.\local\watch.ps1 -Test` should print `WAITING`. Briefly swap `alertWhen`
   to the other value and run it again. It should print `TRIGGERED`. `ERROR` means a
   `mustContain` check didn't match or the page didn't load.

Keep your regexes simple (plain text, `(?i)`, `[^<]*`, `\s+`, `\d+`). The local watcher
(.NET) and the cloud watcher (`grep -P`) both understand those the same way.

Want to watch several pages? Make a copy of `config.json` and run the local watcher with
`-Config .\other.json` (and `install-task.ps1 -Config .\other.json -TaskName 'Other alarm'`).

## Good manners

Keep the interval at 30 s or more, and only watch during the hours that matter. The
installer refuses anything faster. Don't hammer someone else's website.
