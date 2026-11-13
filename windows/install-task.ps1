# Registers a Windows scheduled task that runs watch.ps1 on the chosen days until -Until.
#
# Example (watch weekdays 07:00-08:30 up to and including 20 Nov 2026):
#   powershell -ExecutionPolicy Bypass -File .\windows\install-task.ps1 -Until 2026-11-20
#
# Remove it again with:
#   Unregister-ScheduledTask -TaskName 'Web change alarm' -Confirm:$false
param(
    [Parameter(Mandatory = $true, HelpMessage = 'Last day to watch, yyyy-MM-dd (e.g. 2026-11-20)')]
    [string]$Until,
    [string]$StartTime = '07:00',
    [string]$EndTime = '08:30',
    [string[]]$Days = @('Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday'),
    [int]$IntervalSeconds = 30,
    [double]$AlarmVolume = 0.2,
    [string]$Config = (Join-Path (Split-Path $PSScriptRoot -Parent) 'config.json'),
    [string]$TaskName = 'Web change alarm'
)
$ErrorActionPreference = 'Stop'

try { $last = [datetime]::ParseExact($Until, 'yyyy-MM-dd', $null) }
catch { throw "-Until must look like 2026-11-20 (yyyy-MM-dd), got '$Until'." }
if ($last -lt [datetime]::Today) { throw "-Until ($Until) is in the past." }
if ([timespan]::Parse($EndTime) -le [timespan]::Parse($StartTime)) { throw '-EndTime must be after -StartTime.' }
if ($IntervalSeconds -lt 30) { throw '-IntervalSeconds must be at least 30 (be nice to the site).' }
if ($AlarmVolume -lt 0 -or $AlarmVolume -gt 1) { throw '-AlarmVolume must be between 0 and 1.' }
$Config = (Resolve-Path $Config).Path
$cfg = Get-Content -Path $Config -Raw -Encoding UTF8 | ConvertFrom-Json

$script = Join-Path $PSScriptRoot 'watch.ps1'
$scriptArgs = "-NoProfile -ExecutionPolicy Bypass -File `"$script`" -Config `"$Config`" -EndTime $EndTime " +
              "-IntervalSeconds $IntervalSeconds -AlarmVolume $($AlarmVolume.ToString([cultureinfo]::InvariantCulture)) -Until $Until"
$action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument $scriptArgs
$trigger = New-ScheduledTaskTrigger -Weekly -DaysOfWeek $Days -At $StartTime
# Stop triggering after the last day (midnight at the end of -Until).
$trigger.EndBoundary = $last.AddDays(1).ToString('yyyy-MM-ddTHH:mm:ss')
$settings = New-ScheduledTaskSettingsSet -WakeToRun -StartWhenAvailable -AllowStartIfOnBatteries `
    -DontStopIfGoingOnBatteries -ExecutionTimeLimit (New-TimeSpan -Hours 4)
Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger -Settings $settings `
    -Description "Watches '$($cfg.name)' every $IntervalSeconds s from $StartTime to $EndTime ($($Days -join ', ')) until $Until and sounds an alarm when it changes." `
    -Force | Out-Null

Write-Host "Installed '$TaskName' for '$($cfg.name)': $($Days -join ', ') $StartTime-$EndTime, until $Until."
Get-ScheduledTask -TaskName $TaskName | Get-ScheduledTaskInfo | Select-Object TaskName, NextRunTime | Format-List
