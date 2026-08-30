# Smart Drone worker refresh: pull the newest worker script — from the public release feed
# first (no credentials needed; CI republishes it there on every build), falling back to S3 —
# clear anything wedged, start ONE fresh worker, show the log tail.
# No secrets in this file — the S3 parts only work on the box that already holds config.json.
#
# Canonical one-liner (this same file lives as a raw file on the releases repo — NOT a release
# asset; a rolling release hijacked the app's update feed):
#   irm https://raw.githubusercontent.com/bobby500/smart-drone-releases/main/worker/refresh.ps1 | iex
# (The old s3://smartdrone-maps…/tiles/setup/refresh.ps1 copy keeps working but no longer
#  updates itself — prefer the raw URL.)
#
# It will NOT kill a job that is still working. The whole point of this script is to unstick a
# machine, and it used to do that by force-killing RealityScan on sight — which twice destroyed
# a render that was minutes from finishing, because "waiting on a dialog" and "hard at work"
# look identical from outside. Installing the new script is always safe on its own: the running
# worker self-updates at its next start, so a refresh during a live job still lands, it just
# lands when the job is done.

$ErrorActionPreference = 'Stop'

# The scheduled task only fires at logon, so the worker came back after a reboot but NOT after
# it stopped for any other reason - closing its PowerShell window, an unhandled error, a crash.
# The machine then sat there running, costing money, ignoring the queue, and every job in the
# app hung on "waiting for the GPU worker to claim the job" until someone started it by hand.
# A five-minute repeating trigger closes that gap. It cannot start a second worker: the script
# takes a machine-wide mutex at startup and any extra copy logs that it is exiting and does.
function Ensure-KeepAlive {
    $task = Get-ScheduledTask -TaskName SmartDroneWorker -ErrorAction SilentlyContinue
    if (-not $task) { return }
    if (@($task.Triggers | Where-Object { $_.Repetition -and $_.Repetition.Interval }).Count) { return }
    try {
        $tick = New-ScheduledTaskTrigger -Once -At (Get-Date).Date.AddMinutes(1) `
            -RepetitionInterval (New-TimeSpan -Minutes 5) -RepetitionDuration (New-TimeSpan -Days 3650)
        Set-ScheduledTask -TaskName SmartDroneWorker -Trigger (@($task.Triggers) + $tick) | Out-Null
        Write-Host 'Added a 5-minute keep-alive trigger - the worker now restarts itself if it stops.' -ForegroundColor Green
    } catch {
        Write-Host "Could not add the keep-alive trigger: $($_.Exception.Message)" -ForegroundColor Yellow
    }
}

$c = Get-Content C:\SmartDroneWorker\config.json -Raw | ConvertFrom-Json
$env:AWS_ACCESS_KEY_ID = $c.accessKeyId
$env:AWS_SECRET_ACCESS_KEY = $c.secretAccessKey
$env:AWS_DEFAULT_REGION = $c.region

# Feed first (credential-free, always the newest merged code), S3 as fallback.
$feed = 'https://raw.githubusercontent.com/bobby500/smart-drone-releases/main/worker/smartdrone-worker.ps1'
$got = $null
try {
    Invoke-WebRequest $feed -OutFile C:\SmartDroneWorker\smartdrone-worker.ps1 -UseBasicParsing -TimeoutSec 60
    $got = 'release feed'
} catch {
    Write-Host "Release feed unreachable ($($_.Exception.Message)) - falling back to S3" -ForegroundColor Yellow
    aws s3 cp "s3://$($c.bucket)/worker/smartdrone-worker.ps1" C:\SmartDroneWorker\smartdrone-worker.ps1
    $got = 'S3'
}
$version = (Select-String -Path C:\SmartDroneWorker\smartdrone-worker.ps1 -Pattern "ScriptVersion = '([^']+)'" |
    Select-Object -First 1).Matches.Groups[1].Value
Write-Host "Downloaded worker script $version (from $got)" -ForegroundColor Green
# Heal the S3 slot so the worker's own fallback source serves the same version.
if ($got -eq 'release feed') {
    aws s3 cp C:\SmartDroneWorker\smartdrone-worker.ps1 "s3://$($c.bucket)/worker/smartdrone-worker.ps1" --only-show-errors
}

# Safe to do whether or not a job is running - it only changes when the task fires.
Ensure-KeepAlive

# The remote command channel is deliberately NOT installed from here. It has to run as
# Administrator (RealityScan will not sign in as SYSTEM), so installing it needs a password
# prompt, and a refresh that suddenly asks for a password is a bad surprise in the middle of
# getting a render going. Install it on its own when it is wanted:
#   irm https://smartdrone-maps-232812966415.s3.ap-southeast-2.amazonaws.com/tiles/setup/agent-shell.ps1 | iex
if (Get-ScheduledTask -TaskName SmartDroneAgentShell -ErrorAction SilentlyContinue) {
    Write-Host 'Remote command channel: installed.' -ForegroundColor DarkGray
}

# Is a job actually being worked on right now? Anything written under the scratch job folder in
# the last two minutes means yes — RealityScan writing its cache, or an export growing on disk.
$busy = $null
foreach ($root in @('Z:\SmartDroneJobs', 'C:\SmartDroneJobs')) {
    if (-not (Test-Path $root)) { continue }
    $recent = Get-ChildItem $root -Recurse -File -ErrorAction SilentlyContinue |
        Where-Object { $_.LastWriteTime -gt (Get-Date).AddMinutes(-2) } |
        Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if ($recent) { $busy = $recent; break }
}

if ($busy) {
    Write-Host ''
    Write-Host 'A job is still working on this machine.' -ForegroundColor Yellow
    Write-Host "  last file written: $($busy.FullName)"
    Write-Host "  at: $($busy.LastWriteTime)"
    Write-Host ''
    Write-Host "The new script ($version) is installed and the worker will switch to it as soon as"
    Write-Host 'this job finishes. Nothing has been killed.'
    Write-Host ''
    $answer = Read-Host 'Kill the job and restart the worker anyway? Type YES to force'
    if ($answer -ne 'YES') {
        Write-Host 'Left the job running.' -ForegroundColor Green
        Get-Content C:\SmartDroneWorker\worker.log -Tail 5
        return
    }
    Write-Host 'Forcing a restart — the current job will fail.' -ForegroundColor Red
}

Stop-ScheduledTask -TaskName SmartDroneWorker -ErrorAction SilentlyContinue
Get-CimInstance Win32_Process -Filter "Name like 'powershell%'" |
  Where-Object { $_.CommandLine -like '*smartdrone-worker.ps1*' } |
  ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
# A RealityScan left sitting on an error dialog holds the GPU and the job's files — clear it too.
Get-Process -Name 'RealityScan', 'RealityCapture' -ErrorAction SilentlyContinue |
  ForEach-Object { Write-Host "Closing a stuck $($_.ProcessName) (pid $($_.Id))"; Stop-Process -Id $_.Id -Force -ErrorAction SilentlyContinue }
Start-ScheduledTask -TaskName SmartDroneWorker
Start-Sleep 8
Get-Content C:\SmartDroneWorker\worker.log -Tail 5
