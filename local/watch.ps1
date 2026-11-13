# Local watcher: checks the page in config.json every N seconds and sounds a
# looping alarm (and opens the page) as soon as the watched text changes state.
# Keep this file ASCII-only (Windows PowerShell 5.1 reads it as ANSI).
param(
    [string]$Config = (Join-Path (Split-Path $PSScriptRoot -Parent) 'config.json'),
    [string]$EndTime = '08:30',     # stop watching at this time today (HH:mm)
    [int]$IntervalSeconds = 30,     # please keep this >= 30 to be polite to the site
    [double]$AlarmVolume = 0.2,     # 0.0 - 1.0, speaker volume forced while the alarm plays
    [string]$Until = '',            # last day to watch (yyyy-MM-dd); later days exit at once
    [switch]$Test                   # one page check + 4 s of alarm, then exit
)

$cfg = Get-Content -Path $Config -Raw -Encoding UTF8 | ConvertFrom-Json
foreach ($k in 'name', 'url', 'watchFor', 'alertWhen') {
    if (-not $cfg.$k) { throw "config.json: '$k' is missing." }
}
if ($cfg.alertWhen -notin 'gone', 'appears') { throw "config.json: 'alertWhen' must be 'gone' or 'appears'." }
$MustContain = @($cfg.mustContain | Where-Object { $_ })

$UA  = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/130.0 Safari/537.36'
$AlarmWav = 'C:\Windows\Media\Alarm01.wav'
$LogFile = Join-Path $PSScriptRoot 'watch.log'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
[Guid("5CDF2C82-841E-4546-9722-0CF74078229A"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
interface IAudioEndpointVolume {
    int f(); int g(); int h(); int i();
    int SetMasterVolumeLevelScalar(float fLevel, Guid pguidEventContext);
    int j();
    int GetMasterVolumeLevelScalar(out float pfLevel);
    int k(); int l(); int m(); int n();
    int SetMute([MarshalAs(UnmanagedType.Bool)] bool bMute, Guid pguidEventContext);
    int GetMute(out bool pbMute);
}
[Guid("D666063F-1587-4E43-81F1-B948E807363F"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
interface IMMDevice {
    int Activate(ref Guid id, int clsCtx, IntPtr activationParams, [MarshalAs(UnmanagedType.IUnknown)] out object ppInterface);
}
[Guid("A95664D2-9614-4F35-A746-DE8DB63617E6"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
interface IMMDeviceEnumerator {
    int f();
    int GetDefaultAudioEndpoint(int dataFlow, int role, out IMMDevice endpoint);
}
[ComImport, Guid("BCDE0395-E52F-467C-8E3D-C4579291692E")] class MMDeviceEnumeratorComObject { }
public static class Audio {
    static IAudioEndpointVolume Vol() {
        var enumerator = new MMDeviceEnumeratorComObject() as IMMDeviceEnumerator;
        IMMDevice dev; Marshal.ThrowExceptionForHR(enumerator.GetDefaultAudioEndpoint(0, 1, out dev));
        Guid iid = typeof(IAudioEndpointVolume).GUID; object o;
        Marshal.ThrowExceptionForHR(dev.Activate(ref iid, 23, IntPtr.Zero, out o));
        return (IAudioEndpointVolume)o;
    }
    public static float Volume {
        get { float v; Marshal.ThrowExceptionForHR(Vol().GetMasterVolumeLevelScalar(out v)); return v; }
        set { Marshal.ThrowExceptionForHR(Vol().SetMasterVolumeLevelScalar(value, Guid.Empty)); }
    }
    public static bool Mute {
        get { bool m; Marshal.ThrowExceptionForHR(Vol().GetMute(out m)); return m; }
        set { Marshal.ThrowExceptionForHR(Vol().SetMute(value, Guid.Empty)); }
    }
}
public static class Power {
    [DllImport("kernel32.dll")] public static extern uint SetThreadExecutionState(uint esFlags);
}
'@

function Log([string]$msg) {
    $line = '{0}  {1}' -f (Get-Date -Format 'HH:mm:ss'), $msg
    Write-Host $line
    Add-Content -Path $LogFile -Value ('{0} {1}' -f (Get-Date -Format 'yyyy-MM-dd'), $line)
}

# Returns WAITING (nothing to report yet), TRIGGERED (the change happened) or ERROR (page not usable).
function Get-PageState {
    try {
        $sep = if ($cfg.url.Contains('?')) { '&' } else { '?' }
        $bust = [DateTimeOffset]::Now.ToUnixTimeSeconds()
        $r = Invoke-WebRequest -Uri "$($cfg.url)$($sep)_=$bust" -UserAgent $UA -UseBasicParsing -TimeoutSec 20 `
                -Headers @{ 'Cache-Control' = 'no-cache' }
        $html = $r.Content
    } catch { return 'ERROR' }
    # Make sure it really is the expected page and not an error/maintenance page.
    foreach ($p in $MustContain) { if ($html -notmatch $p) { return 'ERROR' } }
    $found = $html -match $cfg.watchFor
    if (($cfg.alertWhen -eq 'gone' -and -not $found) -or ($cfg.alertWhen -eq 'appears' -and $found)) { return 'TRIGGERED' }
    return 'WAITING'
}

function Start-Alarm([int]$Seconds = 0) {
    # Force the speakers on, whatever the current volume/mute state.
    $oldVol = $null; $oldMute = $null
    try { $oldVol = [Audio]::Volume; $oldMute = [Audio]::Mute; [Audio]::Mute = $false; [Audio]::Volume = [float]$AlarmVolume } catch { }
    $player = $null
    if (Test-Path $AlarmWav) {
        $player = New-Object System.Media.SoundPlayer $AlarmWav
        $player.PlayLooping()
    }
    if ($Seconds -gt 0) {
        if ($player) { Start-Sleep -Seconds $Seconds } else { 1..$Seconds | ForEach-Object { [Console]::Beep(1200, 700); Start-Sleep -Milliseconds 300 } }
    } else {
        Write-Host ''
        Write-Host "  >>> $($cfg.name): CHANGED - press any key to stop the alarm <<<" -ForegroundColor Red
        while ($true) {
            try { if ([Console]::KeyAvailable) { break } } catch { }
            if (-not $player) { [Console]::Beep(1200, 700) }
            Start-Sleep -Milliseconds 300
        }
    }
    if ($player) { $player.Stop() }
    try { if ($null -ne $oldVol) { [Audio]::Volume = $oldVol; [Audio]::Mute = $oldMute } } catch { }
}

if ($Test) {
    Log "TEST [$($cfg.name)] page state: $(Get-PageState)"
    Start-Alarm -Seconds 4
    Log 'TEST alarm played'
    exit 0
}

if ($Until -and [datetime]::Today -gt [datetime]::ParseExact($Until, 'yyyy-MM-dd', $null)) {
    Log "Past the end date ($Until), nothing to do."; exit 0
}
$end = [datetime]::Today.Add([timespan]::Parse($EndTime))
if ((Get-Date) -ge $end) { Log "Started after $EndTime, nothing to do."; exit 0 }

$Host.UI.RawUI.WindowTitle = "Web change alarm - $($cfg.name)"
# Keep the PC and the display awake while watching.
[void][Power]::SetThreadExecutionState([uint32]'0x80000003')
Log "Watching [$($cfg.name)] every $IntervalSeconds s until $EndTime."

$errors = 0
$state = ''
while ((Get-Date) -lt $end) {
    $state = Get-PageState
    Log $state
    if ($state -eq 'TRIGGERED') {
        Start-Sleep -Seconds 3
        if ((Get-PageState) -eq 'TRIGGERED') {   # confirm, to rule out a half-loaded page
            Log 'ALARM: the page changed'
            Start-Process $cfg.url
            Start-Alarm
            break
        }
    } elseif ($state -eq 'ERROR') {
        $errors++
        if ($errors -eq 6) {
            Log 'WARNING: 6 failed checks in a row - check the page by hand'
            1..3 | ForEach-Object { [Console]::Beep(600, 400) }
        }
    } else { $errors = 0 }
    Start-Sleep -Seconds $IntervalSeconds
}
Log 'Done.'
[void][Power]::SetThreadExecutionState([uint32]'0x80000000')
if ($state -ne 'TRIGGERED') { Start-Sleep -Seconds 5 }
