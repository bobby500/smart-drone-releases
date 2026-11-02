# Smart Drone GPU worker — runs on the cloud Windows GPU machine as a scheduled task.
# Polls the S3 job queue, renders each flight with RealityScan (alignment -> model -> ortho +
# DSM exports), uploads the results, and shuts the machine down when there's nothing to do —
# the instance is billed by the minute, so idle time is money.
#
# Layout in S3 (shared contract with the Smart Drone app — src/main/cloud/photogrammetry.js):
#   queue/<id>.json           app: "ready" marker (worker claims by deleting it)
#   jobs/<id>/photos/*        app: uploaded flight photos
#   jobs/<id>/manifest.json   app: photo count + export params
#   jobs/<id>/status.json     worker: stage heartbeat  { stage, message, pct, updatedAt,
#                             elapsedSec, detail } — detail carries RealityScan's live output
#                             tail (and, on failure, the error log tails) for app diagnostics
#   jobs/<id>/results/*       worker: ortho.tif, dsm.tif, dem.tif (+model.glb), job-report.json
#                             (per-stage timings/args), worker + RealityScan CLI logs
#   jobs/<id>/cancel.json     app: cancellation request
#
# Config: C:\SmartDroneWorker\config.json (written by install-worker.ps1).

$ErrorActionPreference = 'Stop'
$ScriptVersion = '2026-11-02.105'  # logged at startup — proves which script revision is running
$ConfigDir = 'C:\SmartDroneWorker'
$Config = Get-Content (Join-Path $ConfigDir 'config.json') -Raw | ConvertFrom-Json
$LogFile = Join-Path $ConfigDir 'worker.log'

# Log must exist before ANYTHING that can log or fail (v11 defined it AFTER the disk init
# that calls it — the catch block then also hit the missing function, and the worker died
# silently at every boot before its first log line, self-update included).
# NOTHING in here may throw. A full C: drive took the whole box down through this function: the
# Add-Content failed, $ErrorActionPreference='Stop' turned that into a terminating error, and the
# worker died at its first log line — no status, no shutdown, no way back in. Losing a log line is
# survivable; losing the worker is not.
function Log($msg) {
    $line = "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')  $msg"
    try { Add-Content -Path $LogFile -Value $line -ErrorAction Stop } catch { }
    try { Write-Host $line } catch { }
}

# DEATHBED CONFESSION. The worker has died silently twice, mid-phase, with no final log line —
# which means whatever killed it never reached the log. Any terminating error that escapes to
# script scope now writes what and where before the process goes down, so the next death is a
# diagnosis instead of a mystery. `break` rethrows, keeping the exit behaviour unchanged; the
# keep-alive task still restarts the worker.
trap {
    try {
        Log "FATAL: unhandled error is killing the worker - $($_.Exception.Message) at line $($_.InvocationInfo.ScriptLineNumber): $($_.InvocationInfo.Line.Trim())"
    } catch { }
    break
}

$env:AWS_ACCESS_KEY_ID = $Config.accessKeyId
$env:AWS_SECRET_ACCESS_KEY = $Config.secretAccessKey
$env:AWS_DEFAULT_REGION = $Config.region
$Bucket = $Config.bucket
# Job scratch space. Prefer the instance-store NVMe (450 GB on g5.2xlarge — free, fast, and
# wiped on every stop/start, which is exactly right for scratch: everything durable lives in
# S3). Windows auto-mounts it as 'Temporary Storage 0' (usually Z:) on each boot. The 150 GB
# C: drive then only carries the OS + RealityScan, so photo sets 10x bigger still fit.
# The instance-store NVMe arrives RAW after every stop/start — Windows shows no drive at all
# until someone initialises it (field report: "no Z drive shows up"). The worker runs as
# Administrator at every boot, so it formats and mounts the scratch drive itself. Harmless when
# Z: already exists or the machine has no instance store; it never touches EBS volumes (those
# are never RAW after first setup).
function Initialize-EphemeralDisk {
    try {
        if (Test-Path 'Z:\') { return }
        # Match the instance store by what it IS, not its name or its size. Two earlier versions
        # of this check both failed by being too specific: a FriendlyName test missed this
        # machine's naming, and the 300-600 GB size band that replaced it fitted the g5.2xlarge's
        # 450 GB drive and nothing else - a g5.8xlarge's 900 GB store falls straight through it,
        # and every job then quietly runs on the 150 GB EBS boot volume instead of NVMe.
        # The durable description is: the largest uninitialised non-boot disk. Anything RAW on a
        # render box is the instance store; EBS volumes we actually use are already formatted.
        $disks = Get-Disk
        Log "Disks: $(($disks | ForEach-Object { "#$($_.Number) '$($_.FriendlyName)' $($_.PartitionStyle) $([Math]::Round($_.Size / 1GB))GB boot=$($_.IsBoot)" }) -join ' | ')"
        $raw = $disks | Where-Object {
            $_.PartitionStyle -eq 'RAW' -and -not $_.IsBoot -and $_.Size -gt 50GB
        } | Sort-Object Size -Descending | Select-Object -First 1
        if (-not $raw) {
            Log 'No uninitialised non-boot disk found - job scratch will use the boot volume, which is smaller and slower.'
            return
        }
        Initialize-Disk -Number $raw.Number -PartitionStyle GPT -PassThru |
            New-Partition -DriveLetter Z -UseMaximumSize |
            Format-Volume -FileSystem NTFS -NewFileSystemLabel 'Temporary Storage 0' -Confirm:$false | Out-Null
        Log "Initialized instance-store NVMe as Z: ($([Math]::Round($raw.Size / 1GB)) GB scratch)"
    } catch {
        Log "Ephemeral disk init skipped: $($_.Exception.Message)"
    }
}
Initialize-EphemeralDisk

function Resolve-WorkDir {
    # A configured workDir wins UNLESS it's the historical C:\ default while the big instance-
    # store scratch (Z:) is mounted — 10x photo sets only fit on Z:, and the old install wrote
    # workDir C:\SmartDroneJobs into config.json before Z: existed.
    if ($Config.workDir -and -not ($Config.workDir -like 'C:*' -and (Test-Path 'Z:\'))) { return $Config.workDir }
    $eph = Get-CimInstance Win32_Volume -ErrorAction SilentlyContinue |
        Where-Object { $_.DriveLetter -and $_.DriveLetter -ne 'C:' -and $_.DriveType -eq 3 -and ($_.Label -like 'Temporary Storage*' -or $_.Capacity -gt 300GB) } |
        Sort-Object Capacity -Descending | Select-Object -First 1
    if ($eph) { return (Join-Path $eph.DriveLetter 'SmartDroneJobs') }
    return 'C:\SmartDroneJobs'
}
$WorkDir = Resolve-WorkDir
# RealityScan's cache — watched by the jam detector as proof that work is happening.
$ScratchWatchDir = Join-Path (Split-Path (Resolve-WorkDir) -Qualifier) 'RealityScanCache'
# RealityScan's cache belongs on the big scratch drive, and now it actually goes there.
#
# This used to be a note asking someone to set Application settings > Cache location by hand,
# ONCE, as Administrator. Nobody ever did, and there is no such setting to script: the registry
# holds only window geometry and recent files, and RealityScan's own Operation Log gives the
# answer plainly —
#     instance0 = C:\Users\ADMINI~1\AppData\Local\Temp\RSTemp\{GUID}\
# — the cache is simply %TEMP%\RSTemp. So point TEMP at the scratch drive for the RealityScan
# processes the worker launches (see Invoke-RsPhase) and the cache follows.
#
# Left alone this reached 105.9 GB and filled the 150 GB boot volume to ZERO bytes, which killed
# the worker, killed the command channel, and parked RealityScan on an "Out of disk" modal that
# nothing could reach to click. The scratch drive has 838 GB and is wiped on every stop/start,
# which is exactly what a cache wants.
$RsTempDir = Join-Path (Split-Path (Resolve-WorkDir) -Qualifier) 'RealityScanCache'
New-Item -ItemType Directory -Force -Path $RsTempDir -ErrorAction SilentlyContinue | Out-Null
# The worker's own scratch (status payloads, gdalinfo dumps, tool logs) moves off C: for the same
# reason — those writes are what actually killed it. Falls back to the old location if the
# scratch drive is missing, so a box with no instance store still runs.
$TempDir = Join-Path (Split-Path (Resolve-WorkDir) -Qualifier) 'SmartDroneTemp'
if (-not (Test-Path (Split-Path $TempDir -Qualifier))) { $TempDir = $env:TEMP }
New-Item -ItemType Directory -Force -Path $TempDir -ErrorAction SilentlyContinue | Out-Null
# Every child process the worker starts inherits this, which is the whole mechanism: RealityScan
# writes its cache to %TEMP%\RSTemp, GDAL spills here too, and both now land on the scratch drive.
# The worker's own files use $TempDir explicitly rather than relying on the variable.
$env:TEMP = $RsTempDir
$env:TMP = $RsTempDir
$PollSeconds = if ($Config.pollSeconds) { $Config.pollSeconds } else { 15 }
# Idle shutdown: the minutes a machine with no job waits before it shuts itself down. These are
# the defaults; at startup (see Select-IdleSetting, before the first poll) each setting takes the
# first sane value of, in order: the S3 override in the jobs bucket (worker/idle-minutes.txt,
# worker/rdp-grace-minutes.txt), the fleet settings published beside this script
# (worker/fleet-settings.json on the releases repo), local config.json, then these. The S3
# override changes the setting WITHOUT touching a machine or the repo - a quick test on the fleet;
# delete the object to go back.
$IdleShutdownMinutes = 3
# COST GUARD (field: the machine billed for ~16 h while a wedged render "ran", and an open
# Remote Desktop session used to postpone the idle shutdown indefinitely). An idle machine now
# always shuts down: after IdleShutdownMinutes with nobody on RDP, or after RdpGraceMinutes
# even with someone connected. Nothing here can stop a machine that is actually rendering — the
# idle clock only advances between jobs.
$RdpGraceMinutes = 15
# QUIET SHUTDOWN: the minutes an idle machine waits when nothing is queued and no job is uploading
# its photos (no fresh pending marker anywhere in the bucket). The idle shutdown above applies
# instead while a fresh marker exists, and the Remote Desktop grace while someone is connected.
$QuietShutdownMinutes = 1
# A pending marker holds the idle shutdown only while the app keeps refreshing it: its
# LastModified must be within this many minutes (the app rewrites it every 2 minutes for the whole
# upload), and its startedAt within 6 hours.
$PendingFreshMinutes = 8
$PendingMaxHours = 6
$IdleSource = 'default'
$RdpGraceSource = 'default'
$QuietSource = 'default'
$PendingFreshSource = 'default'
# Auto-shutdown is ON unless config.json explicitly says false. It used to be `$Config.autoShutdown
# -and ...`, which made a MISSING key mean "never shut down" — one hand-edited or pre-flag config
# and the box bills forever with nothing to say why (the $1,000 lesson, Aug 2026). Absent = on.
$AutoShutdownOn = if ($null -eq $Config.autoShutdown) { $true } else { [bool]$Config.autoShutdown }


function Find-RealityScan {
    if ($Config.rsExe -and $Config.rsExe -ne 'auto' -and (Test-Path $Config.rsExe)) { return $Config.rsExe }
    $candidates = @(
        'C:\Program Files\Epic Games\RealityScan*\RealityScan.exe',
        'C:\Program Files\Epic Games\RealityScan*\RealityCapture.exe',
        'C:\Program Files\Capturing Reality\RealityCapture\RealityCapture.exe'
    )
    foreach ($pattern in $candidates) {
        $hit = Get-Item $pattern -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($hit) { return $hit.FullName }
    }
    throw "RealityScan executable not found - set 'rsExe' in $ConfigDir\config.json"
}

function Write-Status($JobId, $Stage, $Message, $Pct = 0, $Outputs = $null, $Detail = $null, $StageIndex = 0, $StageCount = 0) {
    $status = [ordered]@{
        stage = $Stage; message = $Message; pct = $Pct
        updatedAt = (Get-Date).ToUniversalTime().ToString('o')
    }
    # Step counter. Every stage of a job belongs to ONE numbering, fixed when the job's phase
    # list is known — fetch, each render phase, optimize, the ground surface, upload. Stages used
    # to pass their own numbers ad hoc, so the bar counted "Step 1 of 10" while fetching photos,
    # "Step 4 of 6" while rendering, and showed no step at all for the rest.
    if ($StageIndex -le 0) { $StageIndex = $script:StageIndex }
    if ($StageCount -le 0) { $StageCount = $script:StageCount }
    if ($StageIndex -gt 0 -and $StageCount -gt 0) { $status.stageIndex = $StageIndex; $status.stageCount = $StageCount }
    if ($script:JobStarted) { $status.elapsedSec = [int]((Get-Date) - $script:JobStarted).TotalSeconds }
    # WHETHER THIS RENDER IS RUNNING CLEANLY, as two counters the app can act on.
    #
    # The worker has always known when a phase jammed and had to be cleared and restarted, and when
    # it repaired a graphics driver under itself — it just kept that to its own log. The app records
    # every finished job into its render history and levels all future estimates off the median, so
    # a job that was fighting the machine was being used as a measurement of how long a good render
    # takes. One three-and-a-half-hour render of a 60-photo flight (RealityScan crashed with a Mini
    # Dump; the driver did not match the instance family after a type change) then became a
    # confident three-and-a-half-hour quote for every 60-photo flight after it.
    #
    # phaseRetries counts RealityScan phases this JOB had to restart. gpuRepairs is how many driver
    # repairs this INSTANCE TYPE has needed and not yet cleared — a machine mid-repair is not a
    # machine to measure. Either being non-zero makes the app keep the row but leave it out of the
    # median (see perf.record in photogrammetry.js).
    $status.phaseRetries = [int]$script:PhaseRetries
    # Wrapped for the same reason the S3 write below is: a status update is a progress report, not
    # the work, and a probe that hiccups must never be able to fail a render.
    try { $status.gpuRepairs = [int](Get-GpuRepairAttempts (Get-InstanceType)) } catch { $status.gpuRepairs = 0 }
    # detail = the interesting tail (RealityScan's own output, error context). The app mirrors it
    # into its Troubleshooting timeline, so keep it status.json-sized.
    if ($Detail) { $d = "$Detail"; $status.detail = if ($d.Length -gt 3500) { $d.Substring($d.Length - 3500) } else { $d } }
    if ($Outputs) { $status.outputs = $Outputs }
    # Everything delivered so far, so the app can import each artefact the moment it lands
    # instead of waiting for the whole job (see Publish-Artifact).
    if ($script:Delivered -and $script:Delivered.Count) { $status.delivered = @($script:Delivered) }
    # What the bar should be weighted by: the stages this job will actually run, and how long
    # each has taken on this machine before. Without it the app has to guess, and its guesses put
    # the photo upload at half the bar and the entire render in the last tenth.
    if ($script:StagePlan) { $status.stagePlan = @($script:StagePlan) }
    $tmp = Join-Path $TempDir "sd-status.json"
    # WriteAllText = UTF-8 WITHOUT BOM. PowerShell's Set-Content -Encoding UTF8 adds a BOM,
    # which the app's JSON.parse rejected — every status write was invisible to the app and
    # every cloud job looked stuck on "waiting for the cloud GPU". Do not switch back.
    #
    # Wrapped, because this exact call is what killed the worker when the disk filled: the job
    # was rendering perfectly well and a failed 2 KB status write threw it away. A status update
    # is a progress report, not the work.
    try {
        [IO.File]::WriteAllText($tmp, ($status | ConvertTo-Json -Depth 4))
        aws s3 cp $tmp "s3://$Bucket/jobs/$JobId/status.json" --no-progress | Out-Null
    } catch {
        Log "Status update dropped ($($_.Exception.Message)) - the job carries on"
    }
    # The machine's heartbeat rides on the job's own status beat, at most once a minute, so the
    # machine reads as 'job' for exactly as long as the job reports. Stop requests are not read
    # here: a request is only ever honoured while the machine is idle.
    Write-Heartbeat 'job' $JobId
}

# ---- Disk space ---------------------------------------------------------------------------
#
# A render needs room on two drives at once: the scratch drive holds the photos, the project and
# the exports, and C: holds Windows, RealityScan and (until v65) its entire cache. Running either
# to zero does not fail the job cleanly - it wedges RealityScan behind a modal nothing can click.
# So: measure first, clear what is safe to clear, and refuse the job with a plain reason if the
# room still is not there.
$MinScratchGB = 60   # a 97-photo flight peaks around 40 GB of project + cache + exports
$MinSystemGB = 10    # Windows itself misbehaves below this

# Returns -1 when the probe fails (CIM can hiccup under load) - callers must treat a negative
# as "could not measure", never as a measurement. The old sentinel here was 999, which read as
# a huge empty drive: harmless for a go/no-go headroom check, poison for anything that SIZES
# work from the number (the strip planner divides by it).
function Get-FreeGB($Path) {
    try {
        $q = (Split-Path $Path -Qualifier)
        if (-not $q) { return -1 }
        $d = Get-CimInstance Win32_LogicalDisk -Filter "DeviceID='$q'" -ErrorAction Stop
        return [Math]::Round($d.FreeSpace / 1GB, 1)
    } catch { return -1 }
}

# Everything a finished job leaves behind. Called when a job ends - succeeded, failed OR
# cancelled. "Old projects shouldn't be cached once cancelled": a cancelled render is exactly the
# case that used to leave tens of GB of RSTemp behind, because nothing ran to clean it up.
function Remove-JobScratch($JobId, $JobDir) {
    if ($JobDir -and (Test-Path $JobDir)) {
        try {
            $gb = [Math]::Round((Get-ChildItem $JobDir -Recurse -File -EA SilentlyContinue | Measure-Object Length -Sum).Sum / 1GB, 1)
            Remove-Item $JobDir -Recurse -Force -ErrorAction Stop
            Log "Job ${JobId}: cleared $gb GB of job scratch"
        } catch { Log "Job ${JobId}: could not clear the job scratch ($($_.Exception.Message))" }
    }
    Clear-RsCache $JobId | Out-Null
}

# RealityScan's cache. Safe to remove between jobs and ONLY between jobs - the dialog's warning
# ("do not remove files from the cache location") is about doing it mid-render.
#
# The WHOLE dedicated cache directory is cleared, not just its RSTemp subfolder. RealityScan 2.2
# writes its working cache directly under the configured cache dir, so the old RSTemp-only clear
# silently left everything behind: measured, ~466 GB of dead cache from two finished model runs
# survived every "cleanup" and blocked the next job's disk check on a drive that was really
# almost empty. Nothing but RealityScan writes under $RsTempDir - it exists to be wiped.
# Returns $true when the cache was actually cleared, $false when the clear was SKIPPED because
# RealityScan is still running. Callers that depend on the space coming back (the strip loop
# clears between strips and immediately budgets the freed room) must check the result and
# re-measure - a silent skip here used to be indistinguishable from a successful clear.
function Clear-RsCache($JobId = '') {
    if (Get-Process RealityScan, RealityCapture -ErrorAction SilentlyContinue) {
        Log 'Leaving the RealityScan cache alone - RealityScan is still running'
        return $false
    }
    $freed = 0
    if ($RsTempDir -and (Test-Path $RsTempDir)) {
        try {
            $freed += (Get-ChildItem $RsTempDir -Recurse -File -EA SilentlyContinue | Measure-Object Length -Sum).Sum
            Get-ChildItem $RsTempDir -Force -EA SilentlyContinue | Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
        } catch { }
    }
    $rst = Join-Path (Join-Path $env:LOCALAPPDATA 'Temp') 'RSTemp'
    if (Test-Path $rst) {
        try {
            $freed += (Get-ChildItem $rst -Recurse -File -EA SilentlyContinue | Measure-Object Length -Sum).Sum
            Remove-Item $rst -Recurse -Force -ErrorAction SilentlyContinue
        } catch { }
    }
    if ($freed -gt 1GB) { Log "Cleared $([Math]::Round($freed / 1GB, 1)) GB of RealityScan cache" }
    return $true
}

# Job directories left by earlier runs. The instance store is wiped on stop/start so these are
# usually already gone, but a box that only ever reboots accumulates them.
function Clear-OldJobDirs($KeepJobId = '') {
    if (-not (Test-Path $WorkDir)) { return }
    foreach ($d in (Get-ChildItem $WorkDir -Directory -ErrorAction SilentlyContinue)) {
        if ($d.Name -eq $KeepJobId) { continue }
        if (((Get-Date) - $d.LastWriteTime).TotalHours -lt 2) { continue }
        try {
            Remove-Item $d.FullName -Recurse -Force -ErrorAction Stop
            Log "Cleared abandoned job scratch $($d.Name)"
        } catch { }
    }
}

# Called before a job starts. Frees what it safely can, then reports whether there is room.
# Returns $null when the job may proceed, or a plain-English reason why it may not.
function Test-DiskHeadroom($JobId, $NeedScratchGB = 0) {
    $need = if ($NeedScratchGB -gt $MinScratchGB) { $NeedScratchGB } else { $MinScratchGB }
    $scratch = Get-FreeGB $WorkDir
    $system = Get-FreeGB 'C:\'
    if (($scratch -ge 0 -and $scratch -lt $need) -or ($system -ge 0 -and $system -lt $MinSystemGB)) {
        Log "Job ${JobId}: low disk (scratch $scratch GB, C: $system GB) - clearing caches before starting"
        Clear-RsCache $JobId | Out-Null
        Clear-OldJobDirs $JobId
        $scratch = Get-FreeGB $WorkDir
        $system = Get-FreeGB 'C:\'
    }
    Log "Job ${JobId}: disk check - scratch $scratch GB free, C: $system GB free"
    # A -1 reads as "could not measure": proceed on the unknown (the old 999 sentinel's optimism,
    # made explicit) - this gate's worst case is a job that later dies, and refusing every job
    # because a CIM probe hiccuped would be worse.
    if ($scratch -ge 0 -and $scratch -lt $need) {
        return "Not enough working space on the GPU: the scratch drive has $scratch GB free and this job needs about $need GB. Nothing was rendered."
    }
    if ($system -ge 0 -and $system -lt $MinSystemGB) {
        return "Not enough space on the GPU's system drive ($system GB free). Nothing was rendered."
    }
    return $null
}

# Run an aws CLI call with stderr suppressed AND the Stop preference relaxed. Under a
# console-less scheduled task, PS 5.1 turns redirected native stderr into a TERMINATING error
# when $ErrorActionPreference is Stop — a routine 404 from head-object killed a job with an
# empty error message right after its photos downloaded. Only the exit code matters here.
function Invoke-AwsQuiet {
    $ErrorActionPreference = 'Continue'
    try {
        aws @args 2>$null | Out-Null
        return $LASTEXITCODE
    } finally {
        $ErrorActionPreference = 'Stop'
    }
}

# Last N non-empty lines of a log file (best-effort; $null when the file doesn't exist yet).
function Get-LogTail($Path, $Lines = 25) {
    if (-not ($Path -and (Test-Path $Path))) { return $null }
    try { ((Get-Content $Path -Tail $Lines -ErrorAction Stop) | Where-Object { $_ -and $_.Trim() }) -join "`n" } catch { return $null }
}

# Per-job report: a timestamped record of every stage (what ran, with what arguments, how long,
# what came out). Uploaded with the results as job-report.json — success or failure — so the app
# can show exactly where a job spent its time or died without anyone RDPing into this box.
function Add-Report($Stage, $Info = $null) {
    if ($null -eq $script:Report) { return }
    $entry = [ordered]@{ stage = $Stage; at = (Get-Date).ToUniversalTime().ToString('o') }
    if ($script:JobStarted) { $entry.elapsedSec = [int]((Get-Date) - $script:JobStarted).TotalSeconds }
    if ($Info) { $entry.info = $Info }
    $script:Report.stages += $entry
}

# Which machine is this? Needed to compare stage timings ACROSS GPU types — a stage that is slow
# on one instance family and fast on another is a scheduling decision, not a mystery. IMDSv2
# first (token required on newer AMIs), falling back to v1. Cached: it never changes at runtime.
# One reader for every metadata name (instance-type, instance-id) so the two answers can never
# come from different code paths with different fallbacks.
$script:ImdsCache = @{}
function Get-ImdsValue($Name, $Fallback = 'unknown') {
    if ($script:ImdsCache.ContainsKey($Name)) { return $script:ImdsCache[$Name] }
    $v = $null
    try {
        $tok = Invoke-RestMethod -Method Put -Uri 'http://169.254.169.254/latest/api/token' `
            -Headers @{ 'X-aws-ec2-metadata-token-ttl-seconds' = '60' } -TimeoutSec 3 -ErrorAction Stop
        $v = Invoke-RestMethod -Uri "http://169.254.169.254/latest/meta-data/$Name" `
            -Headers @{ 'X-aws-ec2-metadata-token' = $tok } -TimeoutSec 3 -ErrorAction Stop
    } catch {
        try { $v = Invoke-RestMethod -Uri "http://169.254.169.254/latest/meta-data/$Name" -TimeoutSec 3 -ErrorAction Stop } catch { }
    }
    $v = "$v".Trim()
    if (-not $v) { $v = "$Fallback" }
    if (-not $v) { $v = 'unknown' }
    $script:ImdsCache[$Name] = $v
    return $v
}
function Get-InstanceType { return (Get-ImdsValue 'instance-type' 'unknown') }
# The instance ID keys the boot/shutdown events below. Without IMDS (a dev box) the computer
# name stands in, so the events still land somewhere findable rather than under 'unknown'.
function Get-InstanceId { return (Get-ImdsValue 'instance-id' $env:COMPUTERNAME) }

# ---- Admin diagnostics feed ---------------------------------------------------------------
#
# Everything under telemetry/ in the bucket is the admin diagnostics feed: one record per job
# (telemetry/<jobId>.json, written on EVERY exit - done, error, cancelled) and one per instance
# lifecycle event (telemetry/instance/<instanceId>/<stamp>-boot.json and ...-shutdown.json).
# Nothing is kept on this box: the scratch disk is wiped on every stop/start, so a record that
# only lived here would be gone before anyone asked for it. Every write goes through here, and
# NOTHING in here may throw - a diagnostics record is a footnote to the job, never the job.
# Returns $true when the object landed, so callers can log success without a second guess.
function Save-TelemetryObject($Key, $Record) {
    try {
        $tmp = Join-Path $TempDir ("sd-telemetry-{0}.json" -f ([guid]::NewGuid().ToString('N').Substring(0, 8)))
        [IO.File]::WriteAllText($tmp, ($Record | ConvertTo-Json -Depth 6))
        $rc = Invoke-AwsQuiet s3 cp $tmp "s3://$Bucket/telemetry/$Key" --no-progress
        Remove-Item $tmp -Force -ErrorAction SilentlyContinue
        if ($rc -ne 0) { Log "Telemetry not recorded (aws exit $rc): telemetry/$Key"; return $false }
        return $true
    } catch {
        Log "Telemetry not recorded ($($_.Exception.Message)): telemetry/$Key"
        return $false
    }
}

# One file per boot and per shutdown, keyed by instance, so a day's worth of starts and stops
# reads as a timeline: when each boot happened, why it stopped, how long it had been idle and
# how many jobs it ran in between. The billing questions ("why was the box up all night?") are
# answered from these, not from guesswork over the worker log.
$script:JobsRun = 0
$script:QueuedAt = $null   # queue marker's queuedAt for the job being run (see Get-NextJob)
function Save-InstanceEvent($Kind, $Extra = $null) {
    try {
        $now = (Get-Date).ToUniversalTime()
        $id = Get-InstanceId
        $rec = [ordered]@{
            instanceId    = $id
            instanceType  = Get-InstanceType
            scriptVersion = $ScriptVersion
        }
        # Every kind carries `at`; boot/shutdown keep their original field names so the existing
        # readers of this feed do not have to change.
        $rec.at = $now.ToString('o')
        if ($Kind -eq 'boot') { $rec.bootedAt = $now.ToString('o') }
        elseif ($Kind -eq 'shutdown') { $rec.shutdownAt = $now.ToString('o') }
        if ($Extra) { foreach ($k in @($Extra.Keys)) { $rec[$k] = $Extra[$k] } }
        # Filesystem-safe stamp (no colons - the key doubles as a sortable filename when the feed
        # is mirrored to disk on the admin side). Backslashes make T and Z literal for .NET.
        $stamp = $now.ToString('yyyyMMdd\THHmmss\Z')
        $key = "instance/$id/$stamp-$Kind.json"
        if (Save-TelemetryObject $key $rec) { Log "Instance $Kind event recorded (telemetry/$key)" }
    } catch {
        Log "Instance $Kind event not recorded: $($_.Exception.Message)"
    }
}

# One row per finished job, in a central prefix, so stage timings can be compared across GPU
# types later without trawling per-job result folders. Written on EVERY exit - done, error and
# cancelled - because a history of survivors only cannot answer the admin view's questions
# (which jobs ran long and died, who cancels what, how long the queue kept people waiting).
# Still small and flat: instance, depth, photo count, who owns it, what happened, and the
# seconds each stage took. Best effort — telemetry must never be able to fail a job that has
# already produced its rasters.
#
# $Outcome is 'done' | 'error' | 'cancelled'; left out, it follows $Ok. $Manifest is the parsed
# manifest.json (owner, totalBytes, createdAt come from it) and may be $null on a job that died
# before it was read.
function Save-JobTelemetry($JobId, $Depth, $PhotoCount, $Ok, $Outcome = $null, $ErrorMessage = $null, $Manifest = $null) {
    try {
        if (-not $Outcome) { $Outcome = if ($Ok) { 'done' } else { 'error' } }
        # Per-stage seconds out of the report's STAGES ARRAY.
        #
        # This read $script:Report.Keys, which yields the report's four top-level names
        # (jobId, worker, startedAt, stages) and never matches 'phase-done-*' — so stageSeconds
        # was {} on EVERY job ever recorded, and the render-time model had nothing but job
        # totals to fit against. Add-Report appends to .stages; the duration is at
        # .stages[].info.seconds.
        #
        # SUMMED per stage name, not overwritten: a RealityScan phase that jams and is retried
        # reports twice, and the mid-render deliveries report once per artefact. What a stage
        # cost is all the wall time it took, the attempt that failed included.
        $stages = [ordered]@{}
        foreach ($entry in @($script:Report.stages)) {
            if (-not $entry) { continue }
            $name = "$($entry.stage)"
            if ($name -notlike 'phase-done-*') { continue }
            $secs = $entry.info.seconds
            if ($null -eq $secs) { continue }
            $key = $name -replace '^phase-done-', ''
            if ($stages.Contains($key)) { $stages[$key] = [int]$stages[$key] + [int]$secs } else { $stages[$key] = [int]$secs }
        }
        # Claim time, as the moment this worker took the job (the same instant Write-Status
        # 'claimed' went out).
        $startedAt = if ($script:JobStarted) { $script:JobStarted.ToUniversalTime().ToString('o') } else { $null }
        # Time spent WAITING before this worker picked the job up. Preferred source is the queue
        # marker's queuedAt (read in Get-NextJob a moment before the marker is deleted); a marker
        # without it falls back to the manifest's createdAt, which the app writes just before it
        # queues. Both best effort - $null is an honest "not known", never a zero.
        $queueWait = $null
        $queuedAt = if ($script:QueuedAt) { "$($script:QueuedAt)" } elseif ($Manifest -and $Manifest.createdAt) { "$($Manifest.createdAt)" } else { $null }
        if ($queuedAt -and $script:JobStarted) {
            try {
                $q = [DateTimeOffset]::Parse($queuedAt, [Globalization.CultureInfo]::InvariantCulture).UtcDateTime
                $queueWait = [int]($script:JobStarted.ToUniversalTime() - $q).TotalSeconds
                if ($queueWait -lt 0) { $queueWait = 0 }
            } catch { $queueWait = $null }
        }
        # Who the job belongs to, copied field by field: the device and project stamps the app
        # writes into the manifest's owner, plus the licence and its device when they are there.
        # Nothing else from the manifest travels - no local paths, no photo lists.
        $owner = $null
        if ($Manifest -and $Manifest.owner) {
            $owner = [ordered]@{}
            foreach ($f in @('deviceId', 'projectName', 'projectId', 'licence', 'licenceDevice8')) {
                $prop = $Manifest.owner.PSObject.Properties[$f]
                if ($prop -and $null -ne $prop.Value) { $owner[$f] = $prop.Value }
            }
            if ($owner.Count -eq 0) { $owner = $null }
        }
        # Who pulled the plug. The app's cancel.json carries cancelledBy ('admin' from the admin
        # view, 'user' from the owner's own app); a file without the field can only have come
        # from the owner. The BODY is read here - Test-Cancelled only ever needs a HEAD.
        $cancelledBy = $null
        if ($Outcome -eq 'cancelled') {
            $cancelledBy = 'user'
            try {
                $cancelRaw = aws s3 cp "s3://$Bucket/jobs/$JobId/cancel.json" - --no-progress 2>$null
                if ($cancelRaw) {
                    $cancel = ($cancelRaw -join "`n") | ConvertFrom-Json
                    if ($cancel -and $cancel.cancelledBy) { $cancelledBy = "$($cancel.cancelledBy)" }
                }
            } catch { }
        }
        $rec = [ordered]@{
            jobId         = $JobId
            instanceId    = Get-InstanceId
            instanceType  = Get-InstanceType
            scriptVersion = $ScriptVersion
            depth         = $Depth
            photos        = $PhotoCount
            photoBytes    = if ($Manifest -and $Manifest.totalBytes) { [long]$Manifest.totalBytes } else { $null }
            owner         = $owner
            ok            = [bool]$Ok
            outcome       = $Outcome
            error         = if ($ErrorMessage) { "$ErrorMessage" } else { $null }
            cancelledBy   = $cancelledBy
            startedAt     = $startedAt
            finishedAt    = (Get-Date).ToUniversalTime().ToString('o')
            totalSeconds  = if ($script:JobStarted) { [int]((Get-Date) - $script:JobStarted).TotalSeconds } else { 0 }
            queueWaitSec  = $queueWait
            stageSeconds  = $stages
            # The idle settings in force, so the costs page can compare the idle tail across them.
            idleShutdownMinutes = $IdleShutdownMinutes
            rdpGraceMinutes     = $RdpGraceMinutes
            quietShutdownMinutes = $QuietShutdownMinutes
            pendingFreshMinutes  = $PendingFreshMinutes
        }
        if (Save-TelemetryObject "$JobId.json" $rec) {
            Log "Job ${JobId}: telemetry recorded ($Outcome on $($rec.instanceType), $($rec.totalSeconds)s total)"
        }
    } catch {
        Log "Job ${JobId}: telemetry not recorded: $($_.Exception.Message)"
    }
}

function Save-Report($OutDir) {
    if ($null -eq $script:Report) { return }
    try { [IO.File]::WriteAllText((Join-Path $OutDir 'job-report.json'), ($script:Report | ConvertTo-Json -Depth 8)) } catch { }
}

function Test-Cancelled($JobId) {
    return ((Invoke-AwsQuiet s3api head-object --bucket $Bucket --key "jobs/$JobId/cancel.json") -eq 0)
}

# Claim the oldest queued job. Returns the job id or $null.
function Get-NextJob {
    $raw = aws s3api list-objects-v2 --bucket $Bucket --prefix 'queue/' --query 'Contents[].{k:Key,t:LastModified}' --output json 2>$null
    if (-not $raw -or $raw -eq 'null') { return $null }
    $items = $raw | ConvertFrom-Json | Sort-Object t
    foreach ($item in $items) {
        $id = [IO.Path]::GetFileNameWithoutExtension($item.k)
        # A job cancelled between being queued and being claimed. The app removes the queue
        # marker itself, but there is a window either side of that, and downloading a gigabyte
        # of photos to render something nobody is waiting for is worth one HEAD request to avoid.
        if (Test-Cancelled $id) {
            Log "Skipping $id - it was cancelled before any worker claimed it"
            aws s3 rm "s3://$Bucket/$($item.k)" --only-show-errors | Out-Null
            continue
        }
        # The marker's queuedAt is read first (best effort) so the job's diagnostics record can
        # say how long it waited - once the marker is deleted that number is gone for good.
        $script:QueuedAt = $null
        try {
            $markerRaw = aws s3 cp "s3://$Bucket/$($item.k)" - --no-progress 2>$null
            if ($markerRaw) {
                $marker = ($markerRaw -join "`n") | ConvertFrom-Json
                if ($marker -and $marker.queuedAt) { $script:QueuedAt = "$($marker.queuedAt)" }
            }
        } catch { }
        # Claim = delete the queue marker; S3 delete is atomic enough for a single worker.
        aws s3 rm "s3://$Bucket/$($item.k)" --only-show-errors | Out-Null
        if ($LASTEXITCODE -eq 0) { return $id }
    }
    return $null
}

# RealityScan runs as a SEQUENCE OF PHASES, one CLI pass each (field request: "rendering" hid
# aligning, model building, texturing and the exports behind one word — a jam looked exactly
# like progress). Each phase saves the project and the next one loads it, so every phase has its
# own name, its own timing, its own stall watchdog, and the app can show "Step 3 of 8".
#
# Settings XMLs are saved once from the RealityScan UI (each tool/dialog's save-settings):
#   alignment-params.xml = Alignment settings (RTK camera priors 0.03/0.03/0.05 m)
#   ortho-params.xml     = Ortho Projection Tool settings (Map (GPS) type, pixel size)
#   export-ortho.xml     = orthomosaic GeoTIFF export
#   export-dsm.xml       = DSM GeoTIFF export
# Any that haven't been saved are dropped from the arguments — the CLI then uses the
# Administrator account's last-used UI settings.
# The ortho projection, set on the COMMAND LINE.
#
# RealityScan keeps these settings inside the project, and -newScene starts every job without
# them - which is why every render landed at origin -4962432, 223468, nowhere near New Zealand.
# The settings FILE is not a way in: -calculateOrthoProjection rejects it, and so do all six
# plausible load/import command names (each rejected identically to a deliberately bogus flag,
# which is what makes that a result rather than a guess). -set is the way in. Measured:
#
#   -set rrCoordinateSystem=epsg:2193   ACCEPTED
#   -set orthoPixelSize=0.011           ACCEPTED
#   -set rrRotZ=0                       ACCEPTED
#   three -set on one command line      ACCEPTED
#   proj4 string unquoted               REJECTED - Windows splits it on spaces
#
# EPSG short form on purpose: no spaces, so nothing depends on quoting surviving the trip
# through Start-Process, which is exactly what broke the proj4 form.
#
# CAVEAT, because it matters: "accepted" means the command line parsed and RealityScan exited
# cleanly. It does NOT prove the setting took effect. Only a render does that - the ortho's
# origin must land in real NZTM (easting ~1.9-2.0 million) and its geotransform must be
# north-up. Until a job proves both, this is a well-evidenced hypothesis, not a fix.
function Get-OrthoSetArgs {
    # setProjectCoordinateSystem / setOutputCoordinateSystem, from the official command
    # reference - NOT "-set key=value", which touches application settings and silently does
    # nothing to the project (verified: a full render with -set rrCoordinateSystem=epsg:2193 on
    # the command line produced the identical wrong frame).
    #
    # The frame was never "arbitrary". A project with no CRS is GEOCENTRIC - the .rsbox reported
    # globalCoordinateSystem "+proj=geocent +ellps=WGS84", so origin -4962433, 223468 was ECEF X
    # and Y in metres, with -3987499 the Z that also showed up in the DSM heights. Setting the
    # CRS and re-exporting the region moved its centre to 1983404, 5680153 - real NZTM, matching
    # rrPosX/rrPosY in the saved UI settings - and collapsed pitch and roll from -128.9/92.6 to
    # zero, because those were the ECEF tilt rather than any box orientation.
    #
    # What survives is a 2.7837-degree heading, exactly rrRotZ from the saved settings, which
    # also settles that rrRotZ is DEGREES. That is the reconstruction region's true bearing and
    # is handled separately by straightening the .rsbox.
    $crs = if ($Config.orthoCrs) { $Config.orthoCrs } else { 'epsg:2193' }
    return @('-setProjectCoordinateSystem', $crs, '-setOutputCoordinateSystem', $crs)
}

# SQUARE THE RECONSTRUCTION REGION TO NORTH.
#
# The ortho is the TOP FACE of the reconstruction region, so the box's heading becomes the
# raster's rotation. -setReconstructionRegionAuto fits that box to the flight lines, which is
# why every ortho arrived turned ~2.78 degrees and had to be warped north-up afterwards - a full
# resample of a multi-gigabyte raster, costing time and a little sharpness, on every single job.
#
# The .rsbox is plain XML with a <yawPitchRoll> element. Export it, zero the rotation, import it
# back. Measured against a real project: before setting the CRS the triple read
# "-2.9e-08 -128.94 92.58" (the geocentric tilt); after, "-5.5e-05 4.5e-05 2.78372309" - the
# third value being exactly rrRotZ from the saved UI settings, which is also what settles that
# rrRotZ is in DEGREES. Zeroing all three leaves an axis-aligned box.
#
# The CRS must be set BEFORE exporting, or the box comes back in geocentric coordinates and its
# rotation means something entirely different.
function Square-ReconstructionRegion($JobId, $Proj) {
    $exe = Find-RealityScan
    $box = Join-Path (Split-Path $Proj) 'region.rsbox'
    $crsArgs = Get-OrthoSetArgs
    try {
        Remove-Item $box -Force -ErrorAction SilentlyContinue
        # The same courtesy every real phase gets at Invoke-RsPhase: sweep stale Epic helpers
        # BEFORE launching. Squaring runs seconds after the aligning phase's RealityScan exits,
        # which is precisely when its launcher helpers are still mid-shutdown and can deadlock the
        # next start - the freeze of 8 Sep 2026 sat here for ninety minutes.
        Clear-EpicJam $JobId 'leftovers before squaring' | Out-Null
        # 12 minutes, not the default: each of these launches only loads the project, touches the
        # region, and quits. On a healthy box that is seconds; past twelve minutes it is a jam, and
        # the fallback (straighten the ortho afterwards) is the pre-v61 behaviour, always safe.
        $rc = Invoke-ToolWithBeat $JobId 'squaring' 'Squaring the mapping area to north...' $exe `
            (@('-headless', '-load', $Proj) + $crsArgs + @('-exportReconstructionRegion', $box, '-quit')) 0.3 10 12
        if (-not (Test-Path $box)) { Log "Job ${JobId}: could not export the reconstruction region (exit $rc) - the ortho will be straightened afterwards instead"; return $false }

        [xml]$x = Get-Content $box -Raw
        $node = $x.ReconstructionRegion.yawPitchRoll
        $before = "$node"
        if (-not $node) { Log "Job ${JobId}: .rsbox has no yawPitchRoll - leaving the region alone"; return $false }
        $x.ReconstructionRegion.yawPitchRoll = '0 0 0'
        $x.Save($box)
        Log "Job ${JobId}: region rotation [$before] -> [0 0 0]"

        $rc2 = Invoke-ToolWithBeat $JobId 'squaring' 'Applying the squared mapping area...' $exe `
            (@('-headless', '-load', $Proj) + $crsArgs + @('-setReconstructionRegion', $box, '-save', $Proj, '-quit')) 0.6 10 12
        if ($rc2 -ne 0) { Log "Job ${JobId}: could not apply the squared region (exit $rc2) - continuing with the fitted one"; return $false }
        Log "Job ${JobId}: reconstruction region squared to north - the ortho should need no warp"
        Add-Report 'region-squared' @{ before = $before }
        return $true
    } catch {
        # Never fail a job over this: a rotated ortho is still straightened downstream.
        Log "Job ${JobId}: squaring the region failed ($($_.Exception.Message)) - the ortho will be straightened afterwards instead"
        return $false
    }
}

# SIZE THE ORTHO TO WHAT THE PHOTOS ACTUALLY RESOLVE.
#
# Measured on a real flight: the ortho came out 26738 x 46675 px at 1.09 cm/px, while the photos
# only support about 1.80 cm/px (63.2 m altitude, 24 mm-equivalent lens, 5280 px wide). That is
# 1248 megapixels carrying 461 megapixels of real detail, and the excess is paid for three times
# - in the ortho export, in the COG conversion, and in the operator's download.
#
# A .rsortho has NO pixel-size field. It carries width= and height= IN PIXELS, and the ground
# extent comes from the reconstruction region, so
#     pixel size = region extent / pixel count
# Confirmed against that finished job: 290.947 m / 26738 px = 1.088 cm and
# 511.110 m / 46675 px = 1.095 cm, which is exactly the 1.09 cm/px GDAL reports for the file.
# To render at a chosen GSD, invert it.
#
# The region is SPLICED IN from this job's own region.rsbox rather than left as the template's.
# A .rsortho embeds its own <ReconstructionRegion>, and calculateOrthoProjection also takes a
# .rsbox as a separate argument; which one governs is not something to find out by guessing,
# because a stale region would silently put the ortho on the wrong ground - a far worse fault
# than rendering it too fine. Splicing makes the answer irrelevant: both then describe THIS job.
#
# Note the two files serialise the region differently - the .rsbox carries widthHeightDepth as an
# ATTRIBUTE, the .rsortho as a child ELEMENT - so the whole block is swapped rather than edited
# field by field. And a .rsortho has TWO root elements (OrthoProjection, then
# ReconstructionRegion), which is not valid single-root XML: [xml] cannot parse it, hence the
# text splice.
#
# ALL OF THIS IS MEASURED, on a 24-photo project built on the box for the purpose:
#
#   A. Pixel count obeys the .rsortho. Asked for 13369x23338 (half the default), got exactly
#      13369x23338, in 95 s.
#   B. The embedded region does NOT relocate the raster. Its centre was shifted 200 m east and
#      the true .rsbox passed alongside; the export landed on the same origin to 10 decimal
#      places (1983375.7194527925, 5680298.8548298785) and was byte-identical in size to the
#      default. RealityScan then REWROTE the .rsortho with the region it actually used.
#   C. The spliced file - attribute-form region inside an element-form template, i.e. exactly
#      what this function emits - is accepted. Asked for 13455x16201 at 1.8 cm, got 13455x16201
#      at 1.8000 x 1.8000 cm, same origin, 70 s, 15.3 MB against the default's 89.6 MB.
#
# And the reason this is needed at all: RealityScan's default is a FIXED 26738 x 46675 px grid,
# not a resolution. Two projects with different photo counts and different ground extents
# (290.9 x 511.1 m and 242.2 x 291.6 m) both produced exactly 26738 x 46675 - which means the
# default pixel size is whatever falls out of the region, and on the second project that was
# 0.906 cm across and 0.625 cm down: NON-SQUARE, and 2-3x finer than the photos can support.
function Build-JobOrtho($JobId, $OutDir, $TargetGsdM) {
    $tmpl = Join-Path $ConfigDir 'template.rsortho'
    $box = Join-Path $OutDir 'region.rsbox'
    if (-not ($TargetGsdM -gt 0)) { return $null }
    if (-not (Test-Path $tmpl)) { Log "Job ${JobId}: no template.rsortho - the ortho keeps RealityScan's own pixel count"; return $null }
    if (-not (Test-Path $box)) { Log "Job ${JobId}: no region.rsbox (the squaring step did not run) - the ortho keeps RealityScan's own pixel count"; return $null }
    try {
        $boxText = (Get-Content $box -Raw)
        $bi = $boxText.IndexOf('<ReconstructionRegion')
        if ($bi -lt 0) { Log "Job ${JobId}: region.rsbox has no ReconstructionRegion - skipping ortho sizing"; return $null }
        $boxBlock = $boxText.Substring($bi).TrimEnd()

        # Ground extent, from whichever way this build serialised it.
        $rw = 0.0; $rh = 0.0
        if ($boxBlock -match 'widthHeightDepth="([-0-9.eE]+)\s+([-0-9.eE]+)') { $rw = [double]$Matches[1]; $rh = [double]$Matches[2] }
        elseif ($boxBlock -match '<widthHeightDepth>\s*([-0-9.eE]+)\s+([-0-9.eE]+)') { $rw = [double]$Matches[1]; $rh = [double]$Matches[2] }
        if (-not ($rw -gt 0 -and $rh -gt 0)) { Log "Job ${JobId}: could not read the region size - skipping ortho sizing"; return $null }

        # Guard rails, checked as doubles BEFORE the cast. Below a few hundred pixels the ortho is
        # useless for finding a bush; above 200k on a side RealityScan and GDAL both start to
        # struggle, and no flight needs it. Casting first would mean a daft GSD blew up on [int]'s
        # 2.1-billion ceiling and got caught by the catch below as a type error - the right
        # outcome by luck rather than by the rail that is supposed to produce it.
        $gsd = $TargetGsdM
        # What the photos can actually resolve, from first principles: photoCount x ~20 Mpx each,
        # /9 for 80/70% overlap, spread over the region. Validated against the two healthy jobs:
        # predicts 1.9 cm where the app's EXIF measured 1.64, and 1.6 cm where it measured 1.46 -
        # within 15%, always on the safe (coarser) side.
        $supported = 0.0
        if ($script:JobPhotoCount -gt 0) {
            $supported = [Math]::Sqrt(($rw * $rh * 9.0) / ($script:JobPhotoCount * 20e6))
        }
        # The app's GSD can be nonsense against the real flight (measured twice: 0.54 cm/px
        # claimed on flights whose photos hold ~2). The first version of this guard only fired
        # past 200k px on a side - and a 875x1045 m region at that same bad 0.54 slipped UNDER it
        # at 161628x192906 px, a 31-GIGAPIXEL export that would have run for hours and produced a
        # raster too large to ever download. So the fallback now engages whenever the request is
        # meaningfully beyond the photos (1.5x linear headroom allows honest EXIF variation), or
        # the raster is huge in total, not just per side.
        $wd = [Math]::Round($rw / $gsd)
        $hd = [Math]::Round($rh / $gsd)
        $beyondPhotos = ($supported -gt 0) -and ($gsd -lt ($supported / 1.5))
        if ($beyondPhotos -or ($wd * $hd) -gt 8e9 -or $wd -gt 200000 -or $hd -gt 200000) {
            if ($supported -gt 0) {
                $gsd = [Math]::Max(0.008, [Math]::Min(0.10, $supported))
                $wd = [Math]::Round($rw / $gsd)
                $hd = [Math]::Round($rh / $gsd)
                Log "Job ${JobId}: requested $([Math]::Round($TargetGsdM*100,2)) cm/px is beyond what $($script:JobPhotoCount) photos hold over $([Math]::Round($rw))m x $([Math]::Round($rh))m - using the photo-supported $([Math]::Round($gsd*100,2)) cm/px instead"
            }
        }
        if ($wd -lt 500 -or $hd -lt 500) { Log "Job ${JobId}: computed ortho ${wd}x${hd} px is too small to be useful - keeping RealityScan's own size"; return $null }
        # The final grid this job wants, recorded whether or not the single-pass rail below lets
        # it through - it is exactly what the strip planner (Build-StripPlan) needs to split an
        # oversized flight into row windows of this same grid.
        $script:PlannedGridRows = [long]$hd; $script:PlannedGridCols = [long]$wd; $script:PlannedGridGsdM = $gsd
        if ($wd -gt 200000 -or $hd -gt 200000) {
            if ($supported -gt 0 -and $gsd -ge ($supported / 1.5)) {
                # The GSD is honest - the photos really hold this detail; the flight is simply
                # too long/large for one pass. Silently keeping RealityScan's fixed default grid
                # here delivered a ~5x degraded ortho with no warning (a 4 km corridor at
                # 1.67 cm/px computes 239k rows, trips this rail, and ships at 8.6 cm/px).
                # Owner's policy is refuse-or-split, never degrade: the call site turns this
                # reason into a failed job with a plain explanation. When strip mode is wired
                # ($Config.stripsEnabled), it routes these jobs to Build-StripPlan instead.
                $script:OrthoRefuseReason = "This flight renders ${wd}x${hd} px at $([Math]::Round($gsd*100,2)) cm/px - too large for a single rendering pass, and split rendering is not enabled yet. Refusing rather than delivering a degraded ortho."
                Log "Job ${JobId}: $($script:OrthoRefuseReason)"
                return $null
            }
            Log "Job ${JobId}: computed ortho ${wd}x${hd} px is implausibly large - keeping RealityScan's own size"
            return $null
        }
        $w = [int]$wd
        $h = [int]$hd

        $rs = Get-Content $tmpl -Raw
        if ($rs -notmatch 'width="\d+"\s+height="\d+"') { Log "Job ${JobId}: template.rsortho has no width/height to set - skipping ortho sizing"; return $null }
        $rs = [regex]::Replace($rs, 'width="\d+"\s+height="\d+"', "width=`"$w`" height=`"$h`"", 1)
        $ri = $rs.IndexOf('<ReconstructionRegion')
        if ($ri -lt 0) { Log "Job ${JobId}: template.rsortho has no ReconstructionRegion to replace - skipping ortho sizing"; return $null }
        $out = Join-Path $OutDir 'job.rsortho'
        Set-Content -Path $out -Value ($rs.Substring(0, $ri) + $boxBlock) -Encoding Ascii

        $gsdCm = [Math]::Round($gsd * 100, 3)
        $script:FinalOrthoGsdM = $gsd  # the texture budget must match what the raster actually renders at
        Log "Job ${JobId}: ortho sized to ${w}x${h} px = $gsdCm cm/px over $([Math]::Round($rw))m x $([Math]::Round($rh))m"
        Add-Report 'ortho-sized' @{ widthPx = $w; heightPx = $h; gsdCm = $gsdCm; regionM = "$([Math]::Round($rw,1))x$([Math]::Round($rh,1))" }
        return $out
    } catch {
        Log "Job ${JobId}: could not size the ortho ($($_.Exception.Message)) - keeping RealityScan's own pixel count"
        return $null
    }
}

# SIZE THE TEXTURE BUDGET TO THE ORTHO. Measured on the first real Detailed render (job
# job-202608161118-6273, 1044 photos, 534x1084 m): the ortho raster was correctly sized to
# 1.46 cm/px, but the model texture it takes its colour from was left on RealityScan's default
# unwrap budget - the delivered pixels are uniform 10-20 cm squares (native-res crop inspected),
# i.e. the texture holds roughly 1/10th the linear detail the photos captured. The mesh is fine
# (the DSM off the same model is smooth); the TEXTURE is the quality ceiling of every ortho.
#
# Unwrap settings are application settings, settable per-invocation on the texturing command
# line (Epic's own CLI tutorial: -set "unwrapMaximalTexCount=1" -set "unwrapStyle=1"). Style 1
# is maximal-texture-count mode: RealityScan fits the texel detail into count x resolution, so
# giving it a budget computed from THIS job's region and target GSD makes the texture carry what
# the ortho asks for. If a build rejects the keys the phase jams before doing work and the
# minimal-mode retry drops every extra switch; if it silently ignores them the ortho is exactly
# as blocky as before - the downside is bounded both ways.
function Build-TextureBudget($JobId, $OutDir, $TargetGsdM) {
    if (-not ($TargetGsdM -gt 0)) { return $null }
    $box = Join-Path $OutDir 'region.rsbox'
    if (-not (Test-Path $box)) { return $null }
    try {
        $boxText = Get-Content $box -Raw
        $rw = 0.0; $rh = 0.0
        if ($boxText -match 'widthHeightDepth="([-0-9.eE]+)\s+([-0-9.eE]+)') { $rw = [double]$Matches[1]; $rh = [double]$Matches[2] }
        elseif ($boxText -match '<widthHeightDepth>\s*([-0-9.eE]+)\s+([-0-9.eE]+)') { $rw = [double]$Matches[1]; $rh = [double]$Matches[2] }
        if (-not ($rw -gt 0 -and $rh -gt 0)) { return $null }
        $res = 8192
        # Ground pixels the ortho will hold, plus ~35% for UV-island packing waste, expressed as
        # a count of res x res textures. Floor of 4 keeps small paddocks sharp. The cap bounds
        # texturing time and disk on the largest flights - but the texture IS the ortho's quality
        # ceiling, so a need beyond the cap must REFUSE the job (owner's policy: never trade
        # quality for fit), not silently clamp: the old cap of 64 would have textured the
        # 4,719-photo job at ~55% of the linear detail its 1.67 cm grid asks for, logged as
        # success. 256 covers grids to ~14 Gpx (256 x 8192^2 / 1.35); config can override.
        $cap = if ($Config.maxTexSheets) { [int]$Config.maxTexSheets } else { 256 }
        $need = ($rw / $TargetGsdM) * ($rh / $TargetGsdM) * 1.35 / ($res * $res)
        $count = [int][Math]::Ceiling($need)
        if ($count -lt 4) { $count = 4 }
        if ($count -gt $cap) {
            $script:TextureRefuseReason = "This flight's ortho needs $count x ${res}px textures to carry its full detail and the texturing budget allows $cap - too large for a single rendering pass, and split rendering is not enabled yet. Refusing rather than delivering a soft ortho."
            Log "Job ${JobId}: $($script:TextureRefuseReason)"
            return $null
        }
        Log "Job ${JobId}: texture budget sized to $count x ${res}px textures of $([Math]::Ceiling($need)) needed (region $([Math]::Round($rw))m x $([Math]::Round($rh))m at $([Math]::Round($TargetGsdM*100,2)) cm/px)"
        Add-Report 'texture-sized' @{ count = $count; resolution = $res; gsdCm = [Math]::Round($TargetGsdM * 100, 3) }
        return @('-set', "unwrapStyle=1", '-set', "unwrapMaximalTexCount=$count", '-set', "unwrapMaximalTextureResolution=$res")
    } catch {
        Log "Job ${JobId}: could not size the texture budget ($($_.Exception.Message)) - texturing keeps RealityScan's defaults"
        return $null
    }
}

# SPLIT-MERGE STRIP PLANNER (docs/split-merge.md). Pure geometry, no side effects: given the
# final raster grid (H rows at $GsdM over a north-squared region) and this machine's scratch
# reality, return the strip row-windows that let a flight of ANY size render at FULL High detail
# — each strip's cache fits, strips overlap for feathering, and every strip is a row window of
# the final grid so the merge (worker/merge-strips.py + merge_core.py) never resamples.
#
# NOT YET WIRED into the live job flow: gated behind $Config.stripsEnabled until the V1-V4
# verification experiments in docs/split-merge.md pass on the real box. The maths here mirrors
# test/stripPlan.test.js exactly - change one, change both.
function Build-StripPlan($TotalRows, $GsdM, $NeedScratchGB, $FreeScratchGB, $OverlapM = 24.0, $TotalCols = 0, $MaxTexSheets = 64) {
    if (-not ($TotalRows -gt 0 -and $GsdM -gt 0)) { return $null }
    # A failed disk probe reads -1 (Get-FreeGB): the planner must never size K off a sentinel -
    # the caller retries the measurement or refuses the job with a plain reason.
    if (-not ($FreeScratchGB -gt 0)) { return $null }
    # Strips sized so one strip's cache uses at most 60% of free scratch (cache is cleared
    # between strips; 40% headroom carries the strip's own outputs and the aligned-project copy).
    $budgetGB = [Math]::Max(1.0, $FreeScratchGB * 0.6)
    $k = [int][Math]::Ceiling($NeedScratchGB / $budgetGB)
    # The texture is the ortho's quality ceiling and each strip's texturing gets at most
    # $MaxTexSheets 8192px sheets, so K must also be large enough that every strip's ground
    # pixels (x1.35 packing waste) fit its sheet budget - otherwise strips render full mesh
    # detail but silently soft colour, the exact degradation strip mode exists to avoid.
    if ($TotalCols -gt 0 -and $MaxTexSheets -gt 0) {
        $sheetsTotal = [double]$TotalRows * $TotalCols * 1.35 / (8192.0 * 8192.0)
        $kTex = [int][Math]::Ceiling($sheetsTotal / $MaxTexSheets)
        if ($kTex -gt $k) { $k = $kTex }
    }
    if ($k -lt 2) { $k = 2 }
    $ovlRows = [int][Math]::Ceiling($OverlapM / $GsdM)
    # Core windows partition [0, TotalRows) exactly; overlap extends each side, clamped at the
    # raster edges. Core must exceed TWICE the overlap: an interior strip carries core + 2*ovl
    # rows and its rising and falling feather ramps are 2*ovl each - any smaller core makes the
    # ramps collide (triple overlap), which turns the feather into a hard seam.
    $coreRows = [int][Math]::Ceiling($TotalRows / $k)
    if ($coreRows -le 2 * $ovlRows) { return $null }  # absurdly small strips - caller falls back
    # Strips carry core + 2*ovl rows; if that still busts a strip's sheet budget, split finer.
    while ($TotalCols -gt 0 -and $MaxTexSheets -gt 0 -and
           (([double]($coreRows + 2 * $ovlRows) * $TotalCols * 1.35 / (8192.0 * 8192.0)) -gt $MaxTexSheets)) {
        $k++
        $coreRows = [int][Math]::Ceiling($TotalRows / $k)
        if ($coreRows -le 2 * $ovlRows) { return $null }
    }
    $strips = @()
    for ($i = 0; $i -lt $k; $i++) {
        $coreStart = $i * $coreRows
        $coreEnd = [Math]::Min($TotalRows, ($i + 1) * $coreRows)
        if ($coreStart -ge $TotalRows) { break }
        $rowStart = [Math]::Max(0, $coreStart - $ovlRows)
        $rowEnd = [Math]::Min($TotalRows, $coreEnd + $ovlRows)
        $rowCount = $rowEnd - $rowStart
        # Region geometry for this strip's rsbox: rows grow SOUTHWARD from the raster top, so a
        # strip whose row-midpoint sits below the raster midpoint is shifted south (negative
        # north shift) from the region centre by that row distance in metres.
        $northShiftM = -((($rowStart + $rowCount / 2.0) - ($TotalRows / 2.0)) * $GsdM)
        $strips += @{
            index = $strips.Count; rowStart = $rowStart; rowCount = $rowCount
            heightM = [Math]::Round($rowCount * $GsdM, 6)
            northShiftM = [Math]::Round($northShiftM, 6)
        }
    }
    return $strips
}

# Which products this job wants, as booleans. Reads the app's checklist (manifest.params.outputs);
# an older manifest carries only a depth, so fall back to exactly the pre-checklist behaviour.
#
#   texture is kept whenever the ortho PROJECTION runs (ortho or dsm), because the DSM is exported
#   from that same projection and the worker textures before it. Skipping texture on a heights-only
#   job is a real saving but it is UNVERIFIED against the live pipeline, so it is deliberately not
#   done here — a field test must confirm the DSM export survives without a texture first.
function Resolve-Wanted($Outputs, $Depth) {
    $ids = @()
    if ($Outputs) { $ids = @($Outputs | ForEach-Object { "$_".ToLower().Trim() }) }
    if ($ids.Count -gt 0) {
        # 'ortho2d' was the retired Standard ortho (removed app-side 19 Aug — its coarse output
        # GSD also starved the texture budget). Still accepted here so a job queued by an older
        # app build renders rather than silently losing its ortho; it now means the detailed one,
        # which is the only ortho there is. The app upgrades the id too (cloudOutputs
        # LEGACY_PRODUCT_IDS), so this is the belt to that braces.
        $ortho = ($ids -contains 'ortho2ddetailed') -or ($ids -contains 'ortho2d')
        $dsm   = ($ids -contains 'dsm') -or ($ids -contains 'dem')
        return @{
            ortho   = $ortho
            dsm     = $dsm
            dem     = ($ids -contains 'dem')
            model3d = ($ids -contains 'model3d')
            texture = $ortho -or $dsm -or ($ids -contains 'model3d')
        }
    }
    # Legacy depth fallback — identical to the behaviour before the checklist existed.
    return @{
        ortho   = $true
        dsm     = ($Depth -eq 'full')
        dem     = ($Depth -eq 'full')
        model3d = ($Depth -ne 'quick')
        texture = $true
    }
}

function Get-RsPhases($Depth, $PhotoDir, $OutDir, $Proj, $Minimal = $false, $Want = $null, $MeshDetail = 'high') {
    if (-not $Want) { $Want = Resolve-Wanted $null $Depth }
    $phases = @()
    # -align takes NO arguments (RealityScan err:7182 "the command 'align' expects zero
    # arguments" — the settings XML we used to pass here popped a modal parse-error box and the
    # whole run hung behind it). Alignment follows the settings saved in the RealityScan UI.
    # MINIMAL mode drops every optional switch and keeps only what RealityCapture/RealityScan has
    # always accepted, so one unsupported extra can't block the whole render. The worker retries
    # in this mode automatically when the full line jams before doing any work.
    # Start from the TEMPLATE when one exists: copy it to this job's project path and -load it
    # instead of -newScene, so the ortho projection (coordinate system above all) is already
    # configured before anything is exported. -setReconstructionRegionAuto still runs: the
    # template's region sits over whatever paddock it was made on and would not cover this
    # flight. That refit re-introduces the box's ROTATION, which the north-align step downstream
    # removes — so the template fixes WHERE the ortho lands, not which way up it is. Those are
    # two separate faults and only one of them is solved here.
    $template = Join-Path $ConfigDir 'template.rsproj'
    $useTemplate = Test-Path $template
    if ($useTemplate) {
        try {
            Copy-Item $template $Proj -Force
            $tData = Join-Path $ConfigDir 'template'
            if (Test-Path $tData) { Copy-Item $tData (Join-Path (Split-Path $Proj) 'job') -Recurse -Force }
            Log "Job: starting from the template project (ortho projection pre-configured)"
        } catch {
            Log "Could not stage the template project ($($_.Exception.Message)) - falling back to a new scene"
            $useTemplate = $false
        }
    }
    $phases += @{ stage = 'aligning'; label = 'Aligning the photos (finding camera positions)'; produces = 'job.rsproj';
        args = if ($Minimal) {
            @('-addFolder', $PhotoDir, '-align', '-save', $Proj, '-quit')
        } elseif ($useTemplate) {
            @('-headless', '-load', $Proj, '-addFolder', $PhotoDir, '-align',
              '-selectMaximalComponent', '-setReconstructionRegionAuto', '-save', $Proj, '-quit')
        } else {
            @('-headless', '-newScene', '-addFolder', $PhotoDir, '-align',
              '-selectMaximalComponent', '-setReconstructionRegionAuto', '-save', $Proj, '-quit')
        } }
    # MESH QUALITY IS THE SAME AT EVERY DEPTH: highest detail, always textured.
    #
    # Depth used to trade mesh quality, which turned out to be the wrong dial. Measured on a real
    # 97-photo flight: the high-detail mesh took 190 s and texturing 103 s, against an ortho
    # export at 352 s, a DSM at 482 s and post-processing at over half an hour. Meshing is the
    # cheap part, and a coarse mesh degrades everything derived from it - the ortho takes its
    # colour and its surface from the model. So depth now selects WHICH OUTPUTS are produced,
    # which is where the time actually goes:
    #
    #   quick    - 2D orthophoto only. Paddock boundaries, obstacles, visual weed detection.
    #   standard - adds the DSM and the textured 3D model.
    #   full     - adds the bare-earth DEM, and with it canopy-height gating.
    #
    # Texturing is not optional anywhere: without it the ortho is shaded white geometry with no
    # imagery on it at all (measured R 200 / G 213 / B 219, sd 18, against a real paddock).
    #
    # MESH DETAIL COMES FROM THE APP'S CHECKLIST, and from nothing else.
    #
    # High is the default and covers every measured product. Normal is reached ONLY when the app
    # sends meshDetail='normal', which cloudOutputs.meshDetailFor returns for exactly one selection:
    # the Standard 2D ortho on its own — the reconnaissance job, where the operator wants fence
    # lines quickly and has said so by ticking it. Absent or unrecognised means High, so an older
    # app (and the legacy depth path) keeps full detail.
    #
    # This is deliberately NOT the .91/.92 experiment that meshed 2000+ photo jobs at Normal to
    # squeeze them onto the disk. The owner rejected that trade on 18 Aug — "I don't want to lose
    # quality to make these jobs work" — and it stays rejected: nothing here reads the photo count,
    # the free disk or a failure. A job whose High cache cannot fit is still REFUSED up front with
    # a plain reason. The only way to a coarser mesh is to have asked for the coarser product.
    $normalMesh = "$MeshDetail" -eq 'normal'
    $meshCmd = if ($normalMesh) { '-calculateNormalModel' } else { '-calculateHighModel' }
    $meshLabel = if ($normalMesh) { 'Building the 3D model (standard detail)' } else { 'Building the 3D model (high detail)' }
    if ($normalMesh) { Log "Job: Standard 2D ortho only - meshing at standard detail, as the checklist asked" }
    $phases += @{ stage = 'model'; label = $meshLabel;
        args = @('-headless', '-load', $Proj, $meshCmd, '-save', $Proj, '-quit') }
    # Texturing runs whenever a coloured or projected product is wanted. Only a job that asked for
    # NOTHING that needs the mesh painted (which the checklist does not allow) would skip it.
    if ($Want.texture) {
        $phases += @{ stage = 'texturing'; label = 'Texturing the model';
            args = @('-headless', '-load', $Proj, '-calculateTexture', '-save', $Proj, '-quit') }
    }
    # THE ORTHOPHOTO. This phase went missing in the v62 depth restructure and no version since
    # produced one: quick and standard rendered a mesh and exported nothing at all, and full
    # exported a DSM with no imagery beside it. Every job then died at the end on "produced no
    # ortho.tif/dsm.tif" - after paying for the whole render.
    #
    # -save comes BEFORE the export, not after. The export ends on a dialog that RealityScan
    # waits on forever, so the pass is closed out by force once the raster is on disk - and with
    # -save at the end of the line it never ran, leaving the ortho projection out of the saved
    # project. The DSM step then loaded that project, found no projection to export, and died
    # with "Unknown error". Saving first costs nothing and makes the projection durable the
    # moment it exists.
    # CHAINED DSM EXPORT. The DSM is the same calculateOrthoProjection with different export
    # settings, and it used to be a whole second pass: load the project again, compute the
    # projection again, export. That doubled the most expensive computation in the job - on a
    # 221-photo flight the two passes were 282 s and 331 s, and the projection is the bulk of
    # both, so roughly four minutes of GPU time per full render bought nothing.
    #
    # The reason given for the second pass was that "the ortho export ends on a warning dialog
    # that blocks every command after it". That WAS true and is no longer: the worker log holds
    # ten force-closes ("had already written X and then went idle"), every one of them on 6-7 Aug
    # and the last at 06:36 on the 7th, against fourteen clean exits since - including both
    # exports of the most recent job, exit 0 in 282 s and 331 s. It was never ortho-specific
    # either; three of the ten were the DSM. The likeliest original cause is the settings-file
    # bug in the README (ortho-params.xml handed to a command expecting a .rsortho gives "Invalid
    # or corrupted input data" and waits on the box), fixed around the same date. The workaround
    # outlived the fault.
    #
    # Chained as a `wants`, not a `produces`: if RealityScan will not do the second export the
    # ortho phase still succeeds, and the dsm phase below runs exactly as it does today. The
    # worst case is what we already do; the best case is four minutes cheaper.
    # THE ORTHO PROJECTION runs when the 2D ortho OR the DSM is wanted — both are exported from it.
    # The 2D ortho.tif is exported only when it was ticked; the DSM is chained onto the same pass
    # when it was. A job that wants neither (only the 3D model) skips this phase entirely.
    if ($Want.ortho -or $Want.dsm) {
        $orthoArgs = @('-headless', '-load', $Proj) + (Get-OrthoSetArgs) + @('-calculateOrthoProjection', '-save', $Proj)
        $orthoProduces = $null
        $orthoDelivers = $null
        $orthoWants = @()
        if ($Want.ortho) {
            $orthoArgs += @('-exportOrthoProjection', "$OutDir\ortho.tif", "$ConfigDir\export-ortho.xml")
            $orthoProduces = 'ortho.tif'
            $orthoDelivers = 'ortho.tif'
        }
        if ($Want.dsm -and (Test-Path "$ConfigDir\export-dsm.xml") -and -not $Minimal) {
            $orthoArgs += @('-exportOrthoProjection', "$OutDir\dsm.tif", "$ConfigDir\export-dsm.xml")
            # When the 2D ortho is also being made the DSM is a `wants` (best-effort second export);
            # when it is the ONLY product of this pass it is what the phase produces.
            if ($orthoProduces) { $orthoWants += 'dsm.tif' } else { $orthoProduces = 'dsm.tif'; $orthoDelivers = 'dsm.tif' }
        }
        $orthoArgs += '-quit'
        $label = if ($Want.ortho) { 'Projecting and exporting the orthophoto' } else { 'Projecting and exporting the surface heights (DSM)' }
        $phases += @{ stage = 'ortho'; label = $label; produces = $orthoProduces; delivers = $orthoDelivers; wants = $orthoWants; args = $orthoArgs }
    }
    if ($Want.model3d) {
        # Standard and above: the textured 3D model, straight off the same high-detail mesh.
        # It sits directly after the 2D ortho because that is the delivery order that matters:
        # 2D first so the operator can start work, 3D next, heights after.
        #
        # THE EXPORT COMMAND, from the official reference (rshelp .../allcommands.htm), verbatim:
        #
        #   exportModel          modelName fileName [params.xml]
        #       Export a model (modelName from the project) as a file (fileName including path
        #       and file extension) ...
        #   exportSelectedModel  fileName [params.xml]
        #       Export the selected model as a file (fileName including path and file extension) ...
        #   simplify             [targetTriangleCount or params.xml]
        #       Simplify a selected model using the current settings (use it without any
        #       parameters) to the selected triangle count ...
        #
        # So the long-standing failure was -exportModel given ONE argument: the path was read as
        # the modelName, there was no fileName, and the line was rejected — RealityScan opened,
        # burned 4 s of CPU, wrote nothing and sat on a blank window. Measured on two full
        # renders, on both the full and the minimal command line.
        #
        # -selectModel FIRST. This is the whole bug, and it took three failed renders and three
        # probes to find, because every failure looked like a rejected command line.
        #
        # PROVEN on the box: building and exporting in ONE session works and writes a 1490 MB
        # GLB —
        #   -newScene -addFolder ... -align -calculateHighModel -calculateTexture
        #   -exportSelectedModel out.glb
        # This phase is a SEPARATE pass that starts with -load, and after a -load NO MODEL IS
        # SELECTED. "Export the selected model" then has nothing to export, so RealityScan opens,
        # burns about 4 s of CPU, writes nothing and sits on a blank window — indistinguishable
        # from a syntax error, which is exactly how it was misread twice.
        #
        # Epic's own sample calls -selectModel before -exportSelectedModel for this reason. The
        # name is not a guess: this pipeline's ortho.rsortho records modelName="Model 1", so that
        # is what -calculateHighModel produces here. Configurable in case a future build names it
        # differently, and the phase stays optional so a wrong name costs the model, not the job.
        #
        # -simplify keeps its explicit triangle count. Bare is legal (the reference says "use it
        # without any parameters") but "current settings" means whatever was last used in the UI
        # on that machine, which a render must not depend on. It matters here: 24 photos produced
        # a 1490 MB GLB unsimplified, and GLB has a hard 4 GB ceiling.
        $tris = if ($Config.modelTriangles) { "$($Config.modelTriangles)" } else { '8000000' }
        $modelName = if ($Config.modelName) { "$($Config.modelName)" } else { 'Model 1' }
        $phases += @{ stage = 'model3d'; label = 'Exporting the 3D model'; produces = 'model.glb'; optional = $true;
            delivers = 'model.glb'
            args = @('-headless', '-load', $Proj, '-selectModel', $modelName, '-simplify', $tris,
                     '-calculateTexture', '-exportSelectedModel', "$OutDir\model.glb", '-quit') }
    }
    # FULL depth only. The DSM is the slowest export in the job - 482 s against 352 s for the
    # ortho on a measured flight, then the largest file to optimize and download at 5.2 GB - and
    # it exists to feed the canopy-height gate, which lives at full depth with the DEM. The 3D
    # model comes off the same detailed mesh far faster, so standard delivers 2D and 3D and
    # leaves the height work to full.
    if ($Want.dsm) {
        # The DSM is the SAME command as the ortho with different export settings, so without
        # export-dsm.xml it would write a second orthophoto into dsm.tif — heights that are
        # really imagery. Skip the phase and tell the user rather than ship a fake DSM.
        if (Test-Path "$ConfigDir\export-dsm.xml") {
            # -calculateOrthoProjection again, deliberately. The DSM export is only available
            # once an ortho projection is COMPLETE IN THE SESSION - it is not enough for one to
            # be saved in the project, which is what loading it and exporting straight away
            # assumed. That pass ran its full length and then failed with "Unknown error",
            # because there was nothing live to export a surface from.
            #
            # This costs the projection compute twice per job. The alternative is to chain both
            # exports into the ortho pass, which would be free - except the ortho export ends on
            # a warning dialog that blocks every command after it, so the second export would
            # never run. Correct and slower beats fast and absent.
            #
            # The bare -calculateOrthoProjection here is PATCHED after alignment to carry this
            # job's sized .rsortho, same as the ortho phase - see the Build-JobOrtho call site.
            # Left bare it recomputes at RealityScan's fixed default grid, which is what made the
            # last real job's DSM 3389 MB.
            # FALLBACK ONLY, most of the time. The ortho pass above chains this export on, so by
            # the time we get here dsm.tif usually already exists and skipIfExists turns this
            # whole pass into a no-op that still DELIVERS the file. It runs for real only when
            # the chained export did not produce one - which is the pre-chaining behaviour, kept
            # deliberately so a RealityScan build that refuses two exports on one line costs
            # nothing but the time it used to cost.
            $phases += @{ stage = 'dsm'; label = 'Exporting the surface heights (DSM)'; produces = 'dsm.tif'; optional = $true;
                delivers = 'dsm.tif'; skipIfExists = 'dsm.tif'
                args = @('-headless', '-load', $Proj) + (Get-OrthoSetArgs) + @('-calculateOrthoProjection',
                         '-exportOrthoProjection', "$OutDir\dsm.tif", "$ConfigDir\export-dsm.xml", '-quit') }
        } else {
            Log "DSM export SKIPPED: $ConfigDir\export-dsm.xml has not been saved from the RealityScan UI yet. Without it the DSM export would just write another orthophoto."
        }
    }
    if ($Minimal) {
        # Strip everything optional: the switches this build might not know, and the settings
        # XMLs (a command that takes no arguments rejects the whole line and parks on a dialog).
        # Exports then follow the settings last used in the RealityScan UI.
        foreach ($ph in $phases) {
            $ph.args = @($ph.args | Where-Object {
                $_ -ne '-headless' -and $_ -ne '-newScene' -and
                $_ -ne '-selectMaximalComponent' -and $_ -ne '-setReconstructionRegionAuto' -and
                # export-*.xml are REQUIRED arguments, not optional extras - keep them.
                ($_ -notlike "$ConfigDir\*.xml" -or $_ -like "$ConfigDir\export-*.xml")
            })
        }
    }
    return $phases
}

# One CLI pass, watched. Returns $true when it finished, $false when the app cancelled.
# Throws with a plain-English reason on failure OR on a jam.
# Run a long child process while still beating.
#
# The COG translate, the ground-surface python and the result uploads all used to be blocking
# calls — `& $tool ... | Out-Null` — so the main loop wrote nothing for minutes at a time and a
# healthy job was indistinguishable from a dead one. That is why the app had to wait 20 minutes
# before calling a worker dead, and why 50 minutes of GPU time went to a job that had been frozen
# for most of it. Beating from THIS loop is what makes a fast timeout safe: the beat proves the
# worker's own main thread is running, which a separate heartbeat process could not.
function Invoke-ToolWithBeat($JobId, $Stage, $Message, $Exe, $ToolArgs, $Pct = 0.5, $BeatSeconds = 10, $MaxMinutes = 180) {
    # System.Diagnostics.Process, NOT Start-Process -PassThru.
    #
    # Start-Process returns a Process object whose ExitCode can stay EMPTY even after
    # WaitForExit(), and an empty ExitCode is not zero - so a tool that plainly succeeded was
    # judged a failure. Measured, on a real render: GDAL printed "0...100 - done in 00:00:33",
    # and the worker logged "could not north-align ortho.tif" and deleted the good output, then
    # did the same to the COG. Both files were correct and both were binned.
    #
    # A Process started from StartInfo owns its handle, so ExitCode is always populated. Streams
    # are drained to files rather than pipes: a child that fills a pipe buffer nobody is reading
    # blocks forever, which is a deadlock this loop would otherwise never escape.
    $out = Join-Path $TempDir "sd-tool-$([guid]::NewGuid().ToString('N').Substring(0,8)).log"
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $Exe
    # .Arguments (a single string), NOT .ArgumentList. ArgumentList is .NET Core only; on the
    # box's Windows PowerShell 5.1 it is simply absent, so $psi.ArgumentList is $null and .Add()
    # threw "You cannot call a method on a null-valued expression" - which failed a job at the
    # optimize stage. It parsed fine and ran fine under PowerShell 7 here, which is exactly why
    # a parse check could never have caught it: the runtime differs from the test runtime.
    # Quote any argument containing whitespace; leave the rest bare so GDAL switches are intact.
    $psi.Arguments = (($ToolArgs | ForEach-Object {
        $a = [string]$_
        if ($a -match '\s') { '"' + ($a -replace '"', '\"') + '"' } else { $a }
    }) -join ' ')
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.CreateNoWindow = $true
    $p = [System.Diagnostics.Process]::Start($psi)
    # Async reads keep both pipes drained while we beat.
    $so = $p.StandardOutput.ReadToEndAsync()
    $se = $p.StandardError.ReadToEndAsync()
    # THE CAP (field, 8 Sep 2026: "squaring to the north... definitely frozen. It's been there for
    # ninety minutes"). This loop used to wait forever — and every beat re-published status.json,
    # so the worker actively reported itself healthy while RealityScan sat behind a modal dialog.
    # All the jam defences (Clear-EpicJam, the dialog whitelist, the stall watchdog) live in the
    # PHASE machinery; the squaring step launches RealityScan through here instead and got none of
    # them. Nothing this wrapper runs is legitimately unbounded, so no call may wait forever:
    # on expiry the tool is killed, the caller gets 124 (GNU timeout's convention), and every
    # Invoke-ToolWithBeat caller already treats a non-zero exit as "fall back, do not fail the job".
    $isRs = [System.IO.Path]::GetFileNameWithoutExtension($Exe) -match 'RealityScan|RealityCapture'
    $dialogLogged = ''
    $t0 = Get-Date
    while (-not $p.WaitForExit($BeatSeconds * 1000)) {
        $mins = [int]((Get-Date) - $t0).TotalMinutes
        Write-Status $JobId $Stage "$Message$(if ($mins -ge 1) { " - $mins min in" })" $Pct
        # If this is RealityScan and it has put up a window, say WHAT it says. The ninety-minute
        # freeze taught us nothing because nobody could see the dialog; this line is the diagnosis
        # arriving in the log while the jam is still happening.
        if ($isRs -and $mins -ge 2) {
            $txt = (Get-RsDialogText) -replace "`n", ' | '
            if ($txt -and $txt -ne $dialogLogged) {
                $dialogLogged = $txt
                Log "Job ${JobId}: RealityScan has a window up during '$Stage': $txt"
            }
        }
        if (((Get-Date) - $t0).TotalMinutes -ge $MaxMinutes) {
            Log "Job ${JobId}: '$Stage' still running after $MaxMinutes min - killing $([System.IO.Path]::GetFileName($Exe)) (pid $($p.Id)) and moving on$(if ($dialogLogged) { ". Last window seen: $dialogLogged" })"
            # /T takes the children too - RealityScan drags Epic helpers along, and an orphaned
            # helper is exactly the lock Clear-EpicJam exists to break.
            try { & taskkill /PID $p.Id /T /F 2>$null | Out-Null } catch { }
            try { if (-not $p.WaitForExit(15000)) { $p.Kill() } } catch { }
            if ($isRs) { Clear-EpicJam $JobId "killed a wedged '$Stage' tool" | Out-Null }
            Add-Report 'tool-timeout' @{ stage = $Stage; exe = [System.IO.Path]::GetFileName($Exe); minutes = $MaxMinutes; dialog = $dialogLogged }
            Remove-Item $out -Force -ErrorAction SilentlyContinue
            return 124
        }
    }
    $p.WaitForExit()
    $code = $p.ExitCode
    if ($code -ne 0) {
        $tail = ''
        try { $tail = (($so.Result + ' ' + $se.Result) -replace '\s+', ' ') } catch { }
        if ($tail.Length -gt 600) { $tail = $tail.Substring($tail.Length - 600) }
        Log "Job ${JobId}: tool exited $code -$(if ($tail) { " $tail" } else { ' no output captured' })"
    }
    Remove-Item $out -Force -ErrorAction SilentlyContinue
    return $code
}

# EPIC JAM CLEAR.
#
# RealityScan 2.2 ships through the Epic Games Launcher and leans on it for sign-in, so starting
# RealityScan also starts EpicGamesLauncher / EpicWebHelper / UnrealCEFSubProcess. Those helpers
# outlive a RealityScan that was killed, and they hold RealityScan's single-instance event. The
# next launch then dies on "Failed to create instance event (error 5)" — and what that looks like
# from here is a RealityScan process that exists, burns 0% CPU, writes nothing, and never exits.
# Measured: two ten-minute runs at 0.0 s and 0.2 s of CPU.
#
# Seen for real when the remote command channel was (wrongly) registered as SYSTEM: its Epic
# helpers ran as SYSTEM, and the interactive Administrator session then could not start
# RealityScan AT ALL until those processes were ended by hand. Clearing them is safe precisely
# because it is only ever done when no RealityScan is doing work — a live render is never touched.
function Clear-EpicJam($JobId, $Reason) {
    $names = @('RealityScan', 'RealityCapture', 'EpicGamesLauncher', 'EpicWebHelper', 'UnrealCEFSubProcess')
    $found = @(Get-Process -Name $names -ErrorAction SilentlyContinue)
    if (-not $found) { return $false }
    $desc = ($found | Group-Object ProcessName |
        ForEach-Object { "$($_.Name) x$($_.Count)" }) -join ', '
    Log "Job ${JobId}: clearing stale RealityScan/Epic processes ($Reason): $desc"
    foreach ($p in $found) {
        try { Stop-Process -Id $p.Id -Force -ErrorAction Stop } catch {
            Log "Job ${JobId}: could not stop $($p.ProcessName) (pid $($p.Id)): $($_.Exception.Message)"
        }
    }
    Start-Sleep 3
    $left = @(Get-Process -Name $names -ErrorAction SilentlyContinue)
    if ($left) { Log "Job ${JobId}: $($left.Count) process(es) survived the clear" }
    Add-Report 'epic-jam-clear' @{ reason = $Reason; killed = $desc; survived = $left.Count }
    return $true
}

function Invoke-RsPhase($JobId, $Phase, $StageIndex, $StageCount) {
    # ALREADY DONE BY AN EARLIER PASS. The ortho pass chains the DSM export onto itself, so by
    # the time the dsm phase comes round the file is usually already on disk. Returning true here
    # skips only the RealityScan launch - the caller still delivers the artefact, so Smart Drone
    # receives it exactly as it would have.
    if ($Phase.skipIfExists) {
        $already = Join-Path $OutDirGlobal $Phase.skipIfExists
        if ((Test-Path $already) -and (Get-Item $already).Length -gt 0) {
            Log "Job ${JobId}: [$($Phase.stage)] $($Phase.skipIfExists) was already exported alongside the orthophoto - skipping the second projection pass"
            Add-Report "phase-skipped-$($Phase.stage)" @{ reason = 'produced by the chained ortho export' }
            Write-Status $JobId $Phase.stage "$($Phase.label) - already done" 1 -StageIndex $StageIndex -StageCount $StageCount
            return $true
        }
    }
    $exe = Find-RealityScan
    # Nothing of ours should be running before a phase starts. Anything that IS running is a
    # leftover holding the instance event, and starting on top of it produces the 0% CPU zombie
    # rather than an error we could read.
    Clear-EpicJam $JobId 'leftovers before phase start' | Out-Null
    # Drop any settings XML that hasn't been saved yet.
    $args = @($Phase.args | Where-Object { $_ -notlike "$ConfigDir\*.xml" -or (Test-Path $_) })
    # QUOTE ANYTHING WITH A SPACE IN IT.
    #
    # Start-Process -ArgumentList takes an ARRAY and joins it with spaces, quoting nothing. So an
    # argument that contains a space silently becomes two arguments. This file already records the
    # same failure for proj4 strings ("unquoted - REJECTED, Windows splits it on spaces") and it
    # came straight back the moment a value with a space was passed: -selectModel "Model 1" went
    # out as `-selectModel Model 1`, RealityScan read `Model` as the name and `1` as a stray
    # argument, rejected the line, and parked on its "Error Parsing or Executing Commandline
    # Batch" box. Three renders lost the 3D model to that, and every one of them looked like a
    # jam rather than a typo because the window that appears says "New project".
    #
    # Fixed HERE rather than at the call site so the next value with a space in it - a model name,
    # a path under "Program Files", a coordinate system description - cannot reintroduce it.
    $args = @($args | ForEach-Object {
        $a = "$_"
        if ($a -match '\s' -and $a -notmatch '^".*"$') { '"' + $a + '"' } else { $a }
    })
    Log "Job ${JobId}: [$($Phase.stage)] $exe $($args -join ' ')"
    Add-Report "phase-start-$($Phase.stage)" @{ commandLine = ($args -join ' ') }

    $stdoutLog = Join-Path $OutDirGlobal "rs-$($Phase.stage)-stdout.log"
    $stderrLog = Join-Path $OutDirGlobal "rs-$($Phase.stage)-stderr.log"
    $proc = Start-Process -FilePath $exe -ArgumentList $args -PassThru -NoNewWindow `
        -RedirectStandardOutput $stdoutLog -RedirectStandardError $stderrLog
    $started = Get-Date
    # JAM WATCHDOG. A live phase always burns CPU, or the GPU is busy, or files are growing. When
    # NONE of those moves for StallMinutes the pass is wedged (a RealityScan dialog, a lost GPU
    # context) — stop immediately and fail the job with the reason, rather than letting the app
    # believe it is rendering (field: 15 hours of "rendering" at 1.4% CPU).
    # Beat every 5 seconds, not 20. Everything this loop reacts to - the export warning that
    # blocks -quit, a finished raster, a dead pass - is only noticed on a beat, so the beat
    # interval IS the response time. A finished ortho used to sit behind its dialog for minutes
    # before anyone looked. Each beat costs one CPU read, one nvidia-smi and one directory scan.
    $BeatSeconds = 5
    $StallMinutes = if ($Config.stallMinutes) { [double]$Config.stallMinutes } else { 2 }
    $StallBeatsNeeded = [Math]::Max(6, [int](($StallMinutes * 60) / $BeatSeconds))
    $DoneBeatsNeeded = 3    # output written + 15 s of nothing anywhere = the pass is finished
    $stallBeats = 0
    $beats = 0
    $lastCpu = -1.0
    $lastFingerprint = ''
    $firstFingerprint = ''
    $script:LastDialogSeen = ''
    $script:DeliberateThrow = $false
    while (-not $proc.HasExited) {
        Start-Sleep -Seconds $BeatSeconds
        # BEAT ARMOUR. The worker has now died silently TWICE deep inside long model phases on the
        # 4719-photo job, both times leaving no log line - which points at a terminating error out
        # of one of this loop's probes (a process query racing a vanishing pid, nvidia-smi
        # hiccuping under load, an S3 status write failing) escaping through
        # $ErrorActionPreference='Stop' and killing the whole process. A probe that fails ONCE
        # must cost one beat, not the worker: everything below is caught, logged and retried on
        # the next beat. The watchdog's own deliberate verdicts (jam, out-of-disk) still
        # propagate - they set DeliberateThrow before throwing.
        try {
        $mins = [int]((Get-Date) - $started).TotalMinutes
        $tail = Get-LogTail $stdoutLog 3
        $cpu = Get-RsCpuSeconds $proc
        $gpu = Get-GpuBusy
        # Fingerprint = total size + newest write time across the outputs and the scratch cache.
        # This one recurses a cache directory that can hold thousands of files, so it stays on a
        # 20 s cadence even though the beat is 5 s - the cheap signals carry the fast path.
        if (($beats % [Math]::Max(1, [int](20 / $BeatSeconds))) -eq 0 -or $lastFingerprint -eq '') {
            $fingerprint = try {
                $items = Get-ChildItem -Path @($OutDirGlobal, $ScratchWatchDir) -Recurse -File -ErrorAction SilentlyContinue
                "$(($items | Measure-Object -Property Length -Sum).Sum)|$((($items | Sort-Object LastWriteTime -Descending | Select-Object -First 1).LastWriteTime))"
            } catch { $lastFingerprint }
        } else {
            $fingerprint = $lastFingerprint
        }
        # The CPU threshold is per beat, so it has to scale with the beat: 1.5 s of CPU in 20 s
        # was the original bar, and hard-coding it would call a busy machine idle at 5 s beats.
        $cpuMoved = ($lastCpu -lt 0) -or (($cpu - $lastCpu) -ge ($BeatSeconds * 0.075))
        $idle = ($lastCpu -ge 0) -and (-not $cpuMoved) -and (-not $gpu) -and ($fingerprint -eq $lastFingerprint)
        if ($idle) { $stallBeats++ } else { $stallBeats = 0 }
        if ($firstFingerprint -eq '') { $firstFingerprint = $fingerprint }
        $lastCpu = $cpu
        $lastFingerprint = $fingerprint
        # "Never started": nothing anywhere has changed since the pass launched AND it has been
        # idle for two minutes. This used to be a CPU test on its own - under 15 seconds of CPU
        # after two minutes was called a parse box - and that killed a healthy render five
        # minutes into a real export, because the process the worker launches is not necessarily
        # the one doing the work. Low CPU is now only ever corroborating evidence; the decision
        # rests on nothing having been written, which a working RealityScan never manages.
        $startupJam = ($stallBeats -ge $DoneBeatsNeeded * 4) -and ($fingerprint -eq $firstFingerprint)
        if ($startupJam -or $stallBeats -ge $StallBeatsNeeded) {
            # Before calling anything a jam: if this is one of RealityScan's harmless pop-ups,
            # click it and let the pass carry on rather than killing a live render.
            $clicked = Close-RsDialogs
            if ($clicked) {
                Log "Job ${JobId}: dismissed a RealityScan dialog ($clicked) - letting [$($Phase.stage)] continue"
                Add-Report "phase-dialog-dismissed-$($Phase.stage)" @{ button = $clicked }
                $stallBeats = 0
                $lastCpu = -1.0
                continue
            }
        }
        # If the pass has already written what it was asked for and then everything went quiet -
        # no CPU, no GPU, not a byte changing anywhere for a minute - the work is DONE and
        # RealityScan is just sitting there waiting to be acknowledged. Take the output rather
        # than throw away a finished render, and don't wait out the full stall window to do it.
        # The file must post-date this pass's start, so a leftover from an earlier attempt can
        # never be claimed as this one's work.
        # `wants` are extra outputs this pass may also write (the DSM, chained onto the ortho
        # pass). They are NOT required - if RealityScan will not do the second export the phase
        # still succeeds and the fallback pass picks it up - but the pass must not be closed out
        # while one of them is still coming, or chaining could never work at all.
        if ($Phase.produces -and $stallBeats -ge $DoneBeatsNeeded) {
            $pfItem = Get-Item (Join-Path $OutDirGlobal $Phase.produces) -ErrorAction SilentlyContinue
            $waitingOn = @($Phase.wants | Where-Object {
                $_ -and -not (Test-Path (Join-Path $OutDirGlobal $_))
            })
            if ($pfItem -and $waitingOn.Count -gt 0 -and $stallBeats -lt ($DoneBeatsNeeded * 3)) {
                # Written the required file, idle, but a chained export has not appeared yet.
                # Give it a while longer before giving up on it.
                $pfItem = $null
            }
            if ($pfItem -and $pfItem.Length -gt 0 -and $pfItem.LastWriteTime -gt $started) {
                $secsDone = [int]((Get-Date) - $started).TotalSeconds
                Log "Job ${JobId}: [$($Phase.stage)] had already written $($Phase.produces) ($([Math]::Round($pfItem.Length / 1MB)) MB) and then went idle - taking it as finished and closing RealityScan"
                Add-Report "phase-done-$($Phase.stage)" @{ exitCode = 0; seconds = $secsDone; note = 'output complete; RealityScan was left waiting on a dialog' }
                try { $proc | Stop-Process -Force } catch { }
                Save-PhaseExpectation $Phase.stage $secsDone
                Push-PhaseLogs $JobId
                return $true
            }
        }
        if ($startupJam -or $stallBeats -ge $StallBeatsNeeded) {
            $why = if ($startupJam) {
                "The '$($Phase.label)' step never started working - RealityScan opened and wrote nothing at all. That is what a command-line error looks like: it shows an 'Error Parsing or Executing Commandline Batch' box and waits for someone to click it."
            } else {
                "The '$($Phase.label)' step stopped doing any work for $StallMinutes minutes (no CPU, no GPU, no files changing) - RealityScan is wedged, not rendering."
            }
            # The evidence behind the verdict, so a wrong call can be spotted rather than argued
            # about: this watchdog has killed a healthy render before.
            $why += " [$([int]$cpu)s CPU across RealityScan, GPU $(if ($gpu) { 'busy' } else { 'idle' }), $stallBeats idle checks, files $(if ($fingerprint -eq $firstFingerprint) { 'unchanged since launch' } else { 'changed during the pass' })]"
            if ($SessionId -eq 0) { $why += " The worker is running in Windows session 0, where RealityScan cannot open a window or use the GPU - run fix-session.ps1 on the machine." }
            else { $why += " It is most likely waiting on a dialog (licence, sign-in or an error box) - connect over Remote Desktop and look at the screen." }
            $dialog = Get-RsDialogText
            if ($dialog) {
                $why += " RealityScan is showing this on screen: $dialog"
                Log "Job ${JobId}: RealityScan dialog text: $dialog"
            }
            Log "Job ${JobId}: JAM in $($Phase.stage) - $why"
            Add-Report "phase-jammed-$($Phase.stage)" @{ minutes = $mins; cpuSeconds = [int]$cpu; session = $SessionId }
            $script:LastCliDetail = "$why`n--- $($Phase.stage) stdout (tail) ---`n$(Get-LogTail $stdoutLog 30)`n--- $($Phase.stage) stderr (tail) ---`n$(Get-LogTail $stderrLog 30)"
            try { $proc | Stop-Process -Force } catch { }
            Push-PhaseLogs $JobId
            # A startup jam with NO CPU at all is the signature of the Epic instance-event lock,
            # not of a bad command line: a rejected command line still parses, draws a dialog and
            # burns a little CPU, whereas a launch blocked on the event does nothing whatsoever.
            # Clear the Epic helpers and give the phase exactly one more go rather than failing a
            # job over a stale process. Once only — if it jams again the cause is something else
            # and retrying forever would just hide it.
            if ($startupJam -and $cpu -lt 2 -and -not $script:EpicRetryUsed) {
                $script:EpicRetryUsed = $true
                if (Clear-EpicJam $JobId 'startup jam with zero CPU') {
                    # Counted, not just logged: this is the signal the app uses to keep a restarted
                    # render out of the history it levels future estimates from. See Write-Status.
                    $script:PhaseRetries = [int]$script:PhaseRetries + 1
                    Log "Job ${JobId}: retrying $($Phase.stage) once after clearing the Epic lock"
                    Write-Status $JobId $Phase.stage 'Clearing a stuck RealityScan and retrying...' 0.05
                    return (Invoke-RsPhase $JobId $Phase $StageIndex $StageCount)
                }
            }
            $script:DeliberateThrow = $true
            throw $why
        }
        # Within-phase progress: the learned duration for this phase on this machine, so the bar
        # advances sensibly instead of pretending to know the whole job's length.
        $expect = Get-StageExpectation $Phase.stage
        $pct = if ($expect -gt 0) { [Math]::Min(0.95, ((Get-Date) - $started).TotalSeconds / $expect) } else { [Math]::Min(0.95, $mins / 20.0) }
        # Show RealityScan's OWN progress line when it has one - it beats our elapsed-time guess.
        # Same pass clears any harmless pop-up, so the ortho export's coordinate-system warning
        # is clicked within a minute instead of parking the render until the watchdog notices.
        # ($beats was never actually incremented, so this ran on every 20 s beat - fixed here.)
        $beats++
        # Every beat, not every third: this is what clears the export warning that blocks -quit,
        # and the delay in noticing it was most of the wait at the end of a render.
        # Whatever RealityScan has on screen goes in the log the first time it changes. Without
        # this the only evidence of a pop-up was whatever happened to be up at the moment the
        # watchdog fired, which is far too late to learn anything from.
        $onScreen = Get-RsDialogText
        if ($onScreen -and $onScreen -ne $script:LastDialogSeen) {
            $script:LastDialogSeen = $onScreen
            Log "Job ${JobId}: RealityScan on screen: $($onScreen -replace "`n", ' | ')"
        }
        # OUT OF DISK is not something to wait out. RealityScan puts up a modal "Out of disk /
        # There is no disk space left on drive" with Retry and Cancel and then sits there for
        # ever, holding its whole cache open. Clicking either button is pointless - the space is
        # not coming back on its own - so stop now and say what is actually wrong, instead of
        # burning the stall window and then reporting the generic "stopped doing any work".
        if ($onScreen -match 'no disk space|Out of disk|not enough space') {
            $free = "scratch $(Get-FreeGB $WorkDir) GB, C: $(Get-FreeGB 'C:\') GB"
            $why = "The GPU ran out of disk space during '$($Phase.label)' ($free free). Nothing further was rendered."
            Log "Job ${JobId}: OUT OF DISK - $why"
            Add-Report "phase-out-of-disk-$($Phase.stage)" @{ free = $free }
            $script:LastCliDetail = "$why`nRealityScan on screen: $onScreen"
            try { $proc | Stop-Process -Force } catch { }
            Push-PhaseLogs $JobId
            # Reclaim on the way out so the NEXT job is not dead on arrival too - the cache this
            # render was holding is exactly what filled the drive.
            Clear-RsCache $JobId | Out-Null
            $script:DeliberateThrow = $true
            throw $why
        }
        $dismissed = Close-RsDialogs
        if ($dismissed) {
            Log "Job ${JobId}: dismissed a RealityScan dialog ($dismissed)"
            Add-Report "phase-dialog-dismissed-$($Phase.stage)" @{ button = $dismissed }
            $stallBeats = 0
        }
        $script:RsLine = Get-RsProgressLine
        $msg = if ($script:RsLine) { "$($Phase.label) - $($script:RsLine)" } else { "$($Phase.label) - $mins min in..." }
        Write-Status $JobId $Phase.stage $msg $pct -Detail $tail -StageIndex $StageIndex -StageCount $StageCount
        if (Test-Cancelled $JobId) {
            Log "Job ${JobId}: cancelled by app - stopping RealityScan"
            try { $proc | Stop-Process -Force } catch { }
            return $false
        }
        } catch {
            if ($script:DeliberateThrow) { throw }
            Log "Job ${JobId}: beat probe failed ($($_.Exception.Message) at line $($_.InvocationInfo.ScriptLineNumber)) - ignored, the watchdog carries on"
        }
    }
    $secs = [int]((Get-Date) - $started).TotalSeconds
    # ExitCode stays $null on a -PassThru process until its handle is waited on. Treat "exited
    # but no code reported" as success and let the produces-check below be the real verdict —
    # a finished run was being called a failure purely because $null -ne 0.
    try { $proc.WaitForExit() } catch { }
    $code = $proc.ExitCode
    if ($null -eq $code) { $code = 0 }
    Add-Report "phase-done-$($Phase.stage)" @{ exitCode = $code; seconds = $secs }
    Log "Job ${JobId}: [$($Phase.stage)] finished in ${secs}s (exit $code)"
    if ($code -ne 0) {
        $script:LastCliDetail = "--- $($Phase.stage) stderr (tail) ---`n$(Get-LogTail $stderrLog 30)`n--- $($Phase.stage) stdout (tail) ---`n$(Get-LogTail $stdoutLog 30)"
        Push-PhaseLogs $JobId
        throw "The '$($Phase.label)' step failed (RealityScan exit code $code) - see the logs in this job's results."
    }
    if ($Phase.produces -and -not (Test-Path (Join-Path $OutDirGlobal $Phase.produces))) {
        $script:LastCliDetail = "--- $($Phase.stage) stdout (tail) ---`n$(Get-LogTail $stdoutLog 40)"
        Push-PhaseLogs $JobId
        throw "The '$($Phase.label)' step finished but produced no $($Phase.produces) - check the export settings saved in RealityScan."
    }
    Save-PhaseExpectation $Phase.stage $secs
    return $true
}




# The RealityScan presets (alignment/ortho tool settings and the export settings) are hand-made
# in the UI and easy to lose - a rebuilt machine, a wiped C: drive, or a new worker in a fleet
# would all start with none. Keep them mirrored in S3: anything present locally is backed up,
# anything missing locally is restored. A new machine therefore inherits the calibration.
function Sync-SettingsFiles {
    $names = @('alignment-params.xml', 'ortho-params.xml', 'export-ortho.xml', 'export-dsm.xml')
    # TEMPLATE PROJECT. RealityScan keeps the ortho projection INSIDE the project, and the CLI
    # refuses ortho-params.xml ("Invalid or corrupted input data"), so a job started with
    # -newScene has no projection at all and falls back to a default frame — which is why every
    # render so far landed at origin -4962432, 223468, nowhere near New Zealand. Starting from a
    # project that already carries the projection is the only way to give the CLI those settings.
    # Mirrored like the rest so a rebuilt machine inherits it.
    $names += 'template.rsproj'
    # TEMPLATE ORTHO PROJECTION. Build-JobOrtho starts from this to size each job's ortho to what
    # its photos actually resolve; without it that step returns null and RealityScan's own pixel
    # count stands, which is the 1.65x-too-fine render this was written to stop. It has to be a
    # real .rsortho written by RealityScan — a hand-made one is exactly the mistake that produced
    # "Invalid or corrupted input data" from ortho-params.xml, which is an .xml and not a
    # .rsortho at all. Mirrored like the rest so a rebuilt machine inherits it.
    $names += 'template.rsortho'
    foreach ($name in $names) {
        $local = Join-Path $ConfigDir $name
        $remote = "s3://$Bucket/worker/settings/$name"
        try {
            if (Test-Path $local) {
                Invoke-AwsQuiet s3 cp $local $remote --no-progress | Out-Null
            } else {
                Invoke-AwsQuiet s3 cp $remote $local --no-progress | Out-Null
                if (Test-Path $local) { Log "Restored $name from the cloud settings backup" }
            }
        } catch { }
    }
}


# RealityScan's own progress window, read off the screen ("Calculating Orthographic Projection",
# "total 12:05 | finish estimation 10:33:14 AM"). Its numbers are the REAL ones - the worker's
# own percentage is only elapsed time against a learned average, which is misleading on a step
# whose length depends on the ortho resolution and whether a DTM is being built.
function Get-RsProgressLine {
    $text = Get-RsDialogText
    if (-not $text) { return '' }
    $best = ''
    foreach ($line in ($text -split "`n")) {
        $l = $line.Trim()
        if (-not $l -or $l -like '`[window`]*') { continue }
        # Prefer the line carrying a time estimate, else any "Calculating ..." style status.
        if ($l -match 'estimation|remaining|elapsed|total\s+\d') { return $l }
        if ($l -match '^(Calculating|Computing|Exporting|Building|Texturing|Colorizing|Rendering)' -and -not $best) { $best = $l }
    }
    return $best
}

# Which optional CLI switches this RealityScan build actually accepts. Probed once and cached in
# cli-support.json: an unsupported switch parks on the "Error Parsing or Executing Commandline
# Batch" dialog and never exits, so a switch that does not return quickly is unusable. Only
# scene-independent switches are probed — the rest need a project loaded to mean anything.
function Get-CliSupport($exe) {
    $f = Join-Path $ConfigDir 'cli-support.json'
    if (Test-Path $f) {
        try { return (Get-Content $f -Raw | ConvertFrom-Json) } catch { }
    }
    $result = [ordered]@{}
    foreach ($sw in '-headless', '-newScene') {
        $ok = $false
        try {
            $p = Start-Process -FilePath $exe -ArgumentList @($sw, '-quit') -PassThru -NoNewWindow
            $ok = $p.WaitForExit(45000)
            if (-not $ok) { try { $p | Stop-Process -Force } catch { } }
        } catch { $ok = $false }
        $result[$sw] = $ok
        Log "CLI probe: $sw -> $(if ($ok) { 'supported' } else { 'NOT supported (never exited)' })"
    }
    $obj = [PSCustomObject]$result
    try { [IO.File]::WriteAllText($f, ($obj | ConvertTo-Json)) } catch { }
    return $obj
}

# The text of any window RealityScan currently has open — read straight off the screen with UI
# Automation. A command-line mistake shows an "Error Parsing or Executing Commandline Batch" box
# that NAMES the offending command, and that message never reaches stdout/stderr; without this
# the only way to see it was to sit at the machine over Remote Desktop (field: two separate
# nights lost to exactly that). Works because the worker runs in the interactive session.
function Get-RsDialogText {
    try {
        Add-Type -AssemblyName UIAutomationClient -ErrorAction Stop
        Add-Type -AssemblyName UIAutomationTypes -ErrorAction Stop
        $root = [System.Windows.Automation.AutomationElement]::RootElement
        $winCond = New-Object System.Windows.Automation.PropertyCondition(
            [System.Windows.Automation.AutomationElement]::ControlTypeProperty,
            [System.Windows.Automation.ControlType]::Window)
        $windows = $root.FindAll([System.Windows.Automation.TreeScope]::Children, $winCond)
        $lines = @()
        foreach ($w in $windows) {
            $procId = $w.Current.ProcessId
            $p = Get-Process -Id $procId -ErrorAction SilentlyContinue
            if (-not $p) { continue }
            if ($p.ProcessName -notmatch 'RealityScan|RealityCapture') { continue }
            if ($w.Current.Name) { $lines += "[window] $($w.Current.Name)" }
            $textCond = New-Object System.Windows.Automation.PropertyCondition(
                [System.Windows.Automation.AutomationElement]::ControlTypeProperty,
                [System.Windows.Automation.ControlType]::Text)
            foreach ($t in $w.FindAll([System.Windows.Automation.TreeScope]::Descendants, $textCond)) {
                $n = $t.Current.Name
                if ($n -and $n.Trim().Length -gt 2) { $lines += $n.Trim() }
            }
        }
        return (($lines | Select-Object -Unique) -join "`n")
    } catch { return '' }
}

# Click RealityScan's benign pop-ups so an unattended render doesn't sit behind one.
#
# The ortho export ALWAYS ends on "Ortho projection export warning - the current coordinate
# system cannot be written to the file... the world file has been exported too". The raster is
# already written and correct at that point (the worker stamps the EPSG on with gdal_translate
# -a_srs and reads the .tfw), but the box waits for a click, so -save and -quit never run and a
# finished 1.9 GB ortho looked like a 40-minute hang. Only known-harmless dialogs are clicked -
# anything else is left alone so the jam watchdog can still report it honestly.
$SafeDialogPatterns = @(
    'coordinate system cannot be written',
    'world file has been exported'
)

# TITLES, not body text. The Win32 path below enumerates windows, and a window gives up its
# CAPTION — "Ortho projection export warning" — not the paragraph inside it. Matching the
# body-text patterns against a caption never hits, which would have left the new clicker as
# useless as the old one. Kept deliberately narrow: only boxes that are known to be an
# acknowledgement with nothing to decide. Anything else is reported and left alone, because
# clicking a dialog you have not identified is how a render gets silently ruined.
$SafeDialogTitles = @(
    'Ortho projection export',
    'export warning',
    'World file'
)

# PostMessage, for the cases where UI Automation can see a control but not operate it, plus the
# window enumeration UI Automation cannot do at all (see Get-RsWindowsWin32).
if (-not ('SmartDrone.Win32' -as [type])) {
    Add-Type -Namespace SmartDrone -Name Win32 -MemberDefinition @'
[System.Runtime.InteropServices.DllImport("user32.dll", CharSet = System.Runtime.InteropServices.CharSet.Auto)]
public static extern bool PostMessage(System.IntPtr hWnd, uint msg, System.IntPtr wParam, System.IntPtr lParam);
[System.Runtime.InteropServices.DllImport("user32.dll")]
public static extern bool EnumWindows(EnumProc cb, System.IntPtr p);
[System.Runtime.InteropServices.DllImport("user32.dll")]
public static extern bool EnumChildWindows(System.IntPtr h, EnumProc cb, System.IntPtr p);
public delegate bool EnumProc(System.IntPtr hWnd, System.IntPtr p);
[System.Runtime.InteropServices.DllImport("user32.dll", CharSet = System.Runtime.InteropServices.CharSet.Unicode)]
public static extern int GetWindowTextW(System.IntPtr h, System.Text.StringBuilder s, int n);
[System.Runtime.InteropServices.DllImport("user32.dll", CharSet = System.Runtime.InteropServices.CharSet.Unicode)]
public static extern int GetClassNameW(System.IntPtr h, System.Text.StringBuilder s, int n);
[System.Runtime.InteropServices.DllImport("user32.dll")]
public static extern uint GetWindowThreadProcessId(System.IntPtr h, out uint pid);
[System.Runtime.InteropServices.DllImport("user32.dll")]
public static extern bool IsWindowVisible(System.IntPtr h);
'@ -ErrorAction SilentlyContinue
}

# Every visible top-level window owned by RealityScan, straight from Windows.
#
# THIS IS THE ONE THAT WORKS. UI Automation reports only RealityScan's MAIN window title — it
# never surfaces the modal boxes. Proven in the field twice: a params test called every candidate
# ACCEPTED while "Invalid or corrupted input data" was on screen, and a DSM export sat 33 minutes
# behind "Ortho projection export warning" while the log dutifully recorded
# "[window] job* saved to ... - RealityScan" and nothing else. Because Close-RsDialogs gated on
# the UIA text, the clicker never even tried. Qt draws these boxes as ordinary HWNDs, so
# EnumWindows finds them when the accessibility bridge will not.
function Get-RsWindowsWin32 {
    $script:RsPidSet = @(Get-Process -Name 'RealityScan', 'RealityCapture' -ErrorAction SilentlyContinue |
        ForEach-Object { [uint32]$_.Id })
    $script:RsWins = New-Object System.Collections.ArrayList
    if (-not $script:RsPidSet) { return @() }
    $cb = [SmartDrone.Win32+EnumProc] {
        param($h, $l)
        $owner = [uint32]0
        [void][SmartDrone.Win32]::GetWindowThreadProcessId($h, [ref]$owner)
        if ($script:RsPidSet -contains $owner -and [SmartDrone.Win32]::IsWindowVisible($h)) {
            $sb = New-Object System.Text.StringBuilder 512
            [void][SmartDrone.Win32]::GetWindowTextW($h, $sb, 512)
            [void]$script:RsWins.Add([pscustomobject]@{ Handle = $h; Title = $sb.ToString().Trim() })
        }
        return $true
    }
    [void][SmartDrone.Win32]::EnumWindows($cb, [IntPtr]::Zero)
    return @($script:RsWins)
}

# Click an acknowledgement button inside a window, by walking its real child controls.
function Invoke-Win32DialogButton($Handle) {
    $script:BtnHit = $null
    $cb = [SmartDrone.Win32+EnumProc] {
        param($h, $l)
        if ($script:BtnHit) { return $false }
        $cls = New-Object System.Text.StringBuilder 128
        [void][SmartDrone.Win32]::GetClassNameW($h, $cls, 128)
        $txt = New-Object System.Text.StringBuilder 256
        [void][SmartDrone.Win32]::GetWindowTextW($h, $txt, 256)
        $t = $txt.ToString() -replace '&', ''
        if ($t -match '^(OK|Ok|Close|Continue|Yes)$') {
            [void][SmartDrone.Win32]::PostMessage($h, 0x00F5, [IntPtr]::Zero, [IntPtr]::Zero)  # BM_CLICK
            $script:BtnHit = $t
            return $false
        }
        return $true
    }
    [void][SmartDrone.Win32]::EnumChildWindows($Handle, $cb, [IntPtr]::Zero)
    return $script:BtnHit
}

function Close-RsDialogs {
    # WIN32 FIRST. This path does not depend on the accessibility bridge showing anything, and
    # the accessibility bridge is exactly what failed. Only windows whose title matches a known
    # harmless dialog are touched; a title we do not recognise is left alone and reported.
    foreach ($w in (Get-RsWindowsWin32)) {
        if (-not $w.Title) { continue }
        $m = $SafeDialogTitles | Where-Object { $w.Title -match $_ } | Select-Object -First 1
        if (-not $m) { continue }
        $btn = Invoke-Win32DialogButton $w.Handle
        if ($btn) { return "$btn on '$($w.Title)' (win32)" }
        [void][SmartDrone.Win32]::PostMessage($w.Handle, 0x0010, [IntPtr]::Zero, [IntPtr]::Zero)  # WM_CLOSE
        return "closed '$($w.Title)' (win32 WM_CLOSE)"
    }

    $text = Get-RsDialogText
    if (-not $text) { return '' }
    $match = $SafeDialogPatterns | Where-Object { $text -match $_ } | Select-Object -First 1
    if (-not $match) { return '' }
    try {
        Add-Type -AssemblyName UIAutomationClient -ErrorAction Stop
        Add-Type -AssemblyName UIAutomationTypes -ErrorAction Stop
        $root = [System.Windows.Automation.AutomationElement]::RootElement
        $winCond = New-Object System.Windows.Automation.PropertyCondition(
            [System.Windows.Automation.AutomationElement]::ControlTypeProperty,
            [System.Windows.Automation.ControlType]::Window)
        $btnCond = New-Object System.Windows.Automation.PropertyCondition(
            [System.Windows.Automation.AutomationElement]::ControlTypeProperty,
            [System.Windows.Automation.ControlType]::Button)
        foreach ($w in $root.FindAll([System.Windows.Automation.TreeScope]::Children, $winCond)) {
            $p = Get-Process -Id $w.Current.ProcessId -ErrorAction SilentlyContinue
            if (-not $p -or $p.ProcessName -notmatch 'RealityScan|RealityCapture') { continue }
            foreach ($b in $w.FindAll([System.Windows.Automation.TreeScope]::Descendants, $btnCond)) {
                if ($b.Current.Name -notmatch '^(Close|OK|Ok|Continue|Yes)$') { continue }
                # RealityScan is a Qt application and Qt exposes UI Automation through the
                # accessibility bridge, which does not always carry InvokePattern. Try it, then
                # fall back to the legacy accessibility default action, then to clicking the
                # button's own window. Any one of the three is enough.
                try {
                    $b.GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern).Invoke()
                    return "$($b.Current.Name) on '$($w.Current.Name)'"
                } catch { }
                try {
                    $b.GetCurrentPattern([System.Windows.Automation.LegacyIAccessiblePattern]::Pattern).DoDefaultAction()
                    return "$($b.Current.Name) (default action) on '$($w.Current.Name)'"
                } catch { }
                $h = [IntPtr]$b.Current.NativeWindowHandle
                if ($h -ne [IntPtr]::Zero) {
                    [SmartDrone.Win32]::PostMessage($h, 0x00F5, [IntPtr]::Zero, [IntPtr]::Zero) | Out-Null  # BM_CLICK
                    return "$($b.Current.Name) (BM_CLICK) on '$($w.Current.Name)'"
                }
            }
            # No button we could reach. A warning box with nothing but an acknowledgement is
            # closed by WM_CLOSE just as if its X had been clicked - and this one is only ever
            # reached after the pattern above matched a known-harmless dialog.
            $wh = [IntPtr]$w.Current.NativeWindowHandle
            if ($wh -ne [IntPtr]::Zero) {
                [SmartDrone.Win32]::PostMessage($wh, 0x0010, [IntPtr]::Zero, [IntPtr]::Zero) | Out-Null  # WM_CLOSE
                return "closed '$($w.Current.Name)' (WM_CLOSE)"
            }
        }
    } catch { }
    return ''
}

# CPU seconds burned by RealityScan, counted across EVERY RealityScan process on the box, not
# just the one the worker launched. RealityScan does not necessarily do its work in the process
# that was started - a render can leave the launched process near-idle while another burns the
# cores - so reading one process made a busy machine look asleep. Falls back to the launched
# process alone if the enumeration fails.
function Get-RsCpuSeconds($Proc) {
    try {
        $all = Get-Process -Name 'RealityScan', 'RealityCapture' -ErrorAction SilentlyContinue
        if ($all) {
            # Sum TotalSeconds, not the TimeSpans - Measure-Object -Sum only handles numbers.
            $secs = $all | ForEach-Object { try { $_.TotalProcessorTime.TotalSeconds } catch { 0 } }
            return (($secs | Measure-Object -Sum).Sum)
        }
    } catch { }
    try { $Proc.Refresh(); return $Proc.TotalProcessorTime.TotalSeconds } catch { return -1.0 }
}

# ---- CAN THIS MACHINE RENDER AT ALL? ---------------------------------------------------------
#
# The app re-fits this box to a different instance type on almost every job start, walking its
# ladder from the top (g5 -> g6 -> g4dn) as capacity allows. An NVIDIA driver installed for one
# GPU family does not bind to another, so a routine resize can leave a perfectly healthy machine
# with no usable GPU - and RealityScan's answer to that is a modal error box nobody can see,
# which the jam watchdog then reports two minutes later as "wedged". That cost an afternoon on
# 1 Sep 2026 (nvidia-smi: "couldn't communicate with the NVIDIA driver" on a box that had just
# been moved onto a T4).
#
# So the worker now asks the question ITSELF, at startup and again before every job:
#   1. probe the GPU,
#   2. if it is missing, INSTALL THE DRIVER and reboot - the box repairs itself,
#   3. and if that cannot be done, fail claimed jobs IMMEDIATELY with a sentence the operator
#      can act on, instead of jamming behind an invisible dialog.
$script:GpuState = $null            # last Test-GpuReady result, refreshed at startup and per job
$GpuRepairStateFile = Join-Path $ConfigDir 'gpu-repair.json'
$GpuRepairMaxAttempts = 2           # per instance type: a driver that will not take twice is not
                                    # going to take on the tenth reboot, and a loop bills all night

# Distinct from Get-GpuBusy below, which asks "is the GPU doing anything right now" and treats a
# missing driver as merely idle. This asks "is there a usable GPU here", where the answer decides
# whether the machine can work at all.
function Test-GpuReady {
    $result = [ordered]@{ ok = $false; name = ''; driver = ''; reason = '' }
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $out = & nvidia-smi --query-gpu=name,driver_version --format=csv,noheader 2>&1
        $rc = $LASTEXITCODE
        $text = ($out | Out-String).Trim()
        $failed = $text -match "has failed|couldn't communicate|not recognized|No devices were found|NVIDIA-SMI has failed"
        if ($rc -eq 0 -and $text -and -not $failed) {
            $first = (($text -split "`n")[0]).Trim()
            $parts = $first -split ','
            $result.ok = $true
            $result.name = $parts[0].Trim()
            if ($parts.Count -gt 1) { $result.driver = $parts[1].Trim() }
        } else {
            $result.reason = if ($text) { (($text -split "`n")[0]).Trim() } else { "nvidia-smi exited $rc with no output" }
        }
    } catch {
        # nvidia-smi missing from PATH entirely lands here - no driver package at all.
        $result.reason = $_.Exception.Message
    } finally {
        $ErrorActionPreference = $prev
    }
    return $result
}

function Get-GpuRepairAttempts($Key) {
    try {
        if (-not (Test-Path $GpuRepairStateFile)) { return 0 }
        $d = Get-Content $GpuRepairStateFile -Raw | ConvertFrom-Json
        $v = $d.$Key
        if ($v) { return [int]$v }
        return 0
    } catch { return 0 }
}

function Set-GpuRepairAttempts($Key, $Count) {
    try {
        $d = @{}
        if (Test-Path $GpuRepairStateFile) {
            $existing = Get-Content $GpuRepairStateFile -Raw | ConvertFrom-Json
            foreach ($p in $existing.PSObject.Properties) { $d[$p.Name] = $p.Value }
        }
        $d[$Key] = $Count
        [IO.File]::WriteAllText($GpuRepairStateFile, ($d | ConvertTo-Json -Depth 3))
    } catch { Log "Could not record the GPU repair attempt: $($_.Exception.Message)" }
}

# Install AWS's current NVIDIA driver package. One driver covers T4, A10G and L4, so a machine
# that repairs itself once can be moved between families afterwards without breaking again.
# Returns $true when an installer actually ran, meaning the caller should reboot.
function Repair-GpuDriver($Reason) {
    $type = Get-InstanceType
    $key = "$type"
    $tries = Get-GpuRepairAttempts $key
    if ($tries -ge $GpuRepairMaxAttempts) {
        Log "GPU driver repair already attempted $tries time(s) on $type and the GPU is still missing - not trying again (a human needs to look)."
        return $false
    }
    Set-GpuRepairAttempts $key ($tries + 1)
    Log "No usable GPU ($Reason). Installing the NVIDIA driver for $type - attempt $($tries + 1) of $GpuRepairMaxAttempts."
    Save-InstanceEvent 'gpu-repair' ([ordered]@{ reason = "$Reason"; attempt = ($tries + 1); instanceTypeAtRepair = $type })
    # The script's own temp dir, which lives on the scratch volume when there is one: the driver
    # package is the better part of a gigabyte, and $env:TEMP is both smaller and (as the tests
    # found) not guaranteed to be set at all.
    $base = if ($TempDir) { $TempDir } elseif ($env:TEMP) { $env:TEMP } else { $ConfigDir }
    $dir = Join-Path $base 'sd-nvidia'
    try {
        if (Test-Path $dir) { Remove-Item $dir -Recurse -Force -ErrorAction SilentlyContinue }
        New-Item -ItemType Directory -Force -Path $dir | Out-Null
        # The bucket is public, so the unsigned read works even where this box's own IAM identity
        # is scoped to the smartdrone buckets alone; the signed call is the fallback.
        $rc = Invoke-AwsQuiet s3 cp --recursive s3://ec2-windows-nvidia-drivers/latest/ $dir --region us-east-1 --no-sign-request
        if ($rc -ne 0) {
            Log 'Unsigned driver download refused - retrying with this machine''s own credentials.'
            $rc = Invoke-AwsQuiet s3 cp --recursive s3://ec2-windows-nvidia-drivers/latest/ $dir --region us-east-1
        }
        if ($rc -ne 0) { Log "Could not download the NVIDIA driver (aws exit $rc)."; return $false }
        # The driver package is by far the biggest file in there; the rest is readmes.
        $exe = Get-ChildItem $dir -Recurse -Filter *.exe -ErrorAction SilentlyContinue |
            Sort-Object Length -Descending | Select-Object -First 1
        if (-not $exe) { Log 'The driver download contained no installer.'; return $false }
        Log "Running $($exe.Name) silently ($([int]($exe.Length / 1MB)) MB) - this takes a few minutes."
        # -clean matters on a family switch: it removes the settings of the driver that was
        # installed for the OTHER card, which is what stops the new one binding.
        $proc = Start-Process -FilePath $exe.FullName -ArgumentList '-s', '-noreboot', '-clean' -PassThru
        if (-not $proc.WaitForExit(20 * 60 * 1000)) {
            Log 'The NVIDIA installer did not finish within 20 minutes - abandoning it.'
            try { $proc | Stop-Process -Force } catch { }
            return $false
        }
        Log "NVIDIA installer finished (exit $($proc.ExitCode))."
        return $true
    } catch {
        Log "GPU driver repair failed: $($_.Exception.Message)"
        return $false
    } finally {
        try { Remove-Item $dir -Recurse -Force -ErrorAction SilentlyContinue } catch { }
    }
}

# Startup and per-job gate. Probes, repairs once if it can, and reboots into the repaired driver.
# Returns the state so callers can fail a job with a reason rather than guessing.
function Confirm-GpuOrRepair([switch]$AllowReboot) {
    $state = Test-GpuReady
    $script:GpuState = $state
    if ($state.ok) {
        # A machine that needed repairing before and is healthy now starts its count again, so a
        # future family switch gets its own full allowance.
        try { Set-GpuRepairAttempts (Get-InstanceType) 0 } catch { }
        return $state
    }
    Log "GPU CHECK FAILED: $($state.reason)"
    Save-InstanceEvent 'gpu-fault' ([ordered]@{ reason = "$($state.reason)" })
    if (-not $AllowReboot) { return $state }
    if (Repair-GpuDriver $state.reason) {
        Log 'Rebooting to bring the new NVIDIA driver up. The worker restarts with the machine.'
        Save-InstanceEvent 'shutdown' ([ordered]@{ why = 'reboot after installing the NVIDIA driver'; idleMinutes = 0; jobsRun = [int]$script:JobsRun })
        try { Restart-Computer -Force } catch { Log "Reboot refused: $($_.Exception.Message)" }
        Start-Sleep -Seconds 120   # hold the loop while Windows goes down
    }
    return $state
}

# nvidia-smi utilisation, $true when the GPU is doing anything. Absent driver = $false (the
# other two signals then decide).
function Get-GpuBusy {
    try {
        $out = & nvidia-smi --query-gpu=utilization.gpu --format=csv,noheader,nounits 2>$null
        if (-not $out) { return $false }
        foreach ($line in @($out)) { if ([int]($line.Trim()) -ge 5) { return $true } }
        return $false
    } catch { return $false }
}

# Per-phase durations learned on THIS machine — they drive the in-phase progress and give the app a
# sane per-stage ETA. They are NO LONGER photo-count independent: what is stored is a rate per unit
# of whatever drives the stage, with the unit recorded beside it (see Save-PhaseExpectation).
# Seed durations, in seconds, for a stage this machine has never run. Measured on a real
# 97-photo flight rather than guessed, so the very first job's bar is already roughly right and
# the smoothing in Save-PhaseExpectation only has to correct, not discover.
# Re-seeded from four finished 97-photo renders (jobs crs / eaf8 / v67 / 618c) rather than the
# one early job the old figures came from. Those were low on exactly the stages that dominate -
# texturing by nearly 2x, the ortho and DSM by about a quarter - and a seed that undershoots
# makes the bar race and then stall. dem was 300 s and is really 29 s; optimizing drops because
# the rasters are now sized to the photos instead of RealityScan's fixed grid.
#
# THESE MUST MATCH SEED_SECONDS in src/main/cloud/renderCost.js. The app quotes a time from that
# table before the render and the bar is weighted by this one during it; if they drift the
# operator is shown two different answers to the same question.
$StageSeed = @{
    downloading = 111; aligning = 66;  model = 700; texturing = 197
    ortho       = 440; model3d = 330;  dsm   = 579; dem       = 30
    optimizing  = 150; uploading = 240
}

# WHAT EACH STAGE'S TIME IS DRIVEN BY. Mirrors STAGE_DRIVER in src/main/cloud/renderCost.js and is
# held to it by test/workerSeeds.test.js — the app quotes a time from that table before the render
# and the bar is weighted by this one during it, so a stage tagged differently on the two sides
# would move the bar for a reason the quote did not.
#
# 'photos' — work done once per image (a download, a feature match, a depth map).
# 'area'   — work done once per output pixel: the raster exports, the COG conversion, the upload.
$StageDriver = @{
    downloading = 'photos'; aligning = 'photos'; model = 'photos'; texturing = 'photos'
    ortho       = 'area';   model3d  = 'area';   dsm   = 'area';   dem       = 'area'
    optimizing  = 'area';   uploading = 'area'
}

# The SIZE the seeds above were measured at: 97 photos, and RealityScan's fixed default grid of
# 26738 x 46675 = 1248 Mpx over that job's 290.9 x 511.1 m region (worker/README.md). A seed is a
# duration at a size, and it is useless without the size — that is the whole bug this replaces.
$StageSeedUnits = @{ photos = 97; mpx = 1248 }

# THE ORTHO AND DSM PHASES ARE NOT A FLAT RATE, and pretending they were is what makes a learned
# per-megapixel number dangerous. Both are one -calculateOrthoProjection pass plus an export, and
# the projection is the bulk of it: fitting the two rasters on record (1248 Mpx at 440/579 s and
# 441 Mpx at 282/331 s) gives intercepts of 195.6 s and 195.4 s — the same number twice, which is
# what a shared projection looks like. Held here so the plan for a Low-tier job does not weight the
# ortho at almost nothing; the app carries the identical figures in renderCost.js.
$StageProjectionSec = 196
$StageExportSecPerMpx = @{ ortho = 0.196; dsm = 0.307 }

# How big THIS job is, in each driver's own units. Zero means "not known yet" and the caller falls
# back to the seed rather than inventing a size.
#
# Photos: the count actually on disk after the fetch. Megapixels: the grid Build-JobOrtho computed
# for this job, which is what the exports and the COG conversion really cost. Before alignment has
# run there is no grid, which is exactly why Set-StagePlan is called a second time once there is.
function Get-StageUnits($Stage) {
    $driver = if ($StageDriver.ContainsKey($Stage)) { $StageDriver[$Stage] } else { 'photos' }
    if ($driver -eq 'photos') {
        if ($script:JobPhotoCount -gt 0) { return [double]$script:JobPhotoCount } else { return 0.0 }
    }
    if ($script:PlannedGridRows -gt 0 -and $script:PlannedGridCols -gt 0) {
        return ([double]$script:PlannedGridRows * [double]$script:PlannedGridCols) / 1000000.0
    }
    return 0.0
}

function Get-StageDriverName($Stage) {
    if ($StageDriver.ContainsKey($Stage) -and $StageDriver[$Stage] -eq 'area') { return 'mpx' }
    return 'photos'
}

# What this stage is expected to cost on THIS job, in seconds.
#
# Learned per-unit rate first, then the seed rate at this job's size, then the bare seed. The
# raster phases skip the learned rate entirely — see Save-PhaseExpectation.
function Get-StageExpectation($Stage) {
    $units = Get-StageUnits $Stage
    $seed = if ($StageSeed.ContainsKey($Stage)) { [double]$StageSeed[$Stage] } else { 180.0 }
    if ($Stage -eq 'ortho' -or $Stage -eq 'dsm') {
        if ($units -le 0) { return $seed }
        return $StageProjectionSec + ($StageExportSecPerMpx[$Stage] * $units)
    }
    if ($units -gt 0) {
        $rate = Get-PhaseRate $Stage
        if ($rate -gt 0) { return $rate * $units }
        $refUnits = [double]$StageSeedUnits[(Get-StageDriverName $Stage)]
        if ($refUnits -gt 0) { return ($seed / $refUnits) * $units }
    }
    return $seed
}

# The bar's weights. The app cannot know how long a stage takes - only this machine does, and it
# has been recording exactly that in phase-times.json all along. Publishing the plan turns the
# progress bar from a fixed guess (which put the photo upload at half the bar and squeezed the
# whole render into the last tenth) into something proportional to real measured time.
#
# THESE NUMBERS ONLY EVER SET PROPORTIONS. photogrammetry.js planSpans divides every expectSec by
# the total, so nothing here reaches the operator as a duration and no absolute error in this file
# can produce a wrong quote. What it CAN do is distort the shape of the bar, and it did: a 600-photo
# job left 'model' at ~4300 s in the file, the next 60-photo job gave the mesh most of the bar, the
# within-phase percentage never got past 0.10 before the stage ended, and the bar lurched at every
# boundary. That distortion also drives the app's live "about X left", which is why a render could
# feel like it was taking forever regardless of what it had been quoted.
function Set-StagePlan($Stages) {
    $plan = @()
    foreach ($s in $Stages) {
        $secs = Get-StageExpectation $s
        if ($secs -le 0) { $secs = if ($StageSeed.ContainsKey($s)) { $StageSeed[$s] } else { 180 } }
        $plan += @{ stage = $s; expectSec = [int][Math]::Max(1.0, [double]$secs) }
    }
    $script:StagePlan = $plan
    Log "Job stage plan ($($script:JobPhotoCount) photos, $([Math]::Round((Get-StageUnits 'ortho'), 1)) Mpx): $(($plan | ForEach-Object { "$($_.stage) ~$($_.expectSec)s" }) -join ', ')"
}

# ---- phase-times.json ---------------------------------------------------------------------------
#
# WHAT THIS FILE HOLDS NOW: a RATE PER UNIT, with the unit it was measured in, keyed by instance
# type. What it held before: a bare number of seconds, smoothed 60/40 across jobs, with nothing
# recording how big the job was. So a 600-photo render taught this machine numbers that were then
# applied unchanged to a 60-photo one, and convergence back took about nine same-size renders of
# paid GPU time. Keying by instance type follows the precedent Get-GpuRepairAttempts already set:
# this box gets moved between families, and a rate learned on four T4s is not a rate for four A10Gs.
#
# A v1 FILE IS NOT CONVERTED, IT IS RETIRED. A v1 number is a duration at an unknown size; dividing
# it by an assumed 97 photos would manufacture a measurement this repo does not have. It is renamed
# to phase-times.v1.json (kept, because it is evidence) and learning restarts from the seeds.
$PhaseTimesFile = Join-Path $ConfigDir 'phase-times.json'

function Read-PhaseTimes {
    try {
        if (-not (Test-Path $PhaseTimesFile)) { return $null }
        $j = Get-Content $PhaseTimesFile -Raw | ConvertFrom-Json
        if (-not $j) { return $null }
        if (-not $j.v) {
            $retired = Join-Path $ConfigDir 'phase-times.v1.json'
            try {
                Move-Item $PhaseTimesFile $retired -Force
                Log "phase-times.json was the old size-blind format - kept as phase-times.v1.json and relearning from the seeds. Its numbers are durations at an unknown job size and cannot be converted."
            } catch { }
            return $null
        }
        return $j
    } catch { return $null }
}

# The learned seconds-per-unit for a stage on THIS machine, or 0 when nothing has been learned.
function Get-PhaseRate($Stage) {
    try {
        $j = Read-PhaseTimes
        if (-not $j) { return 0.0 }
        $machine = "$(Get-InstanceType)"
        $byMachine = $j.stages.$machine
        if (-not $byMachine) { return 0.0 }
        $entry = $byMachine.$Stage
        if (-not $entry) { return 0.0 }
        # A rate is only usable against the same kind of unit it was measured in.
        if ("$($entry.driver)" -ne (Get-StageDriverName $Stage)) { return 0.0 }
        $v = [double]$entry.perUnit
        if ($v -gt 0) { return $v } else { return 0.0 }
    } catch { return 0.0 }
}

# Learn from a finished stage. $Seconds is its wall time; the size is read off the job.
#
# THE RASTER PHASES DO NOT LEARN, deliberately. The ortho phase's wall time is a projection plus one
# or two exports (the DSM is chained onto it), so a single seconds-per-megapixel number taken off it
# is not a measurement of anything: it would be learned on a job that exported two rasters and then
# spent on a job that exports one. The fitted two-term model in Get-StageExpectation is better than
# a rate fitted to a mixture, and the app quotes the operator from the same fit.
function Save-PhaseExpectation($Stage, $Seconds) {
    try {
        if ($Stage -eq 'ortho' -or $Stage -eq 'dsm') { return }
        if (-not ($Seconds -gt 0)) { return }
        $units = Get-StageUnits $Stage
        if (-not ($units -gt 0)) { return }   # no size recorded means no measurement to keep
        $driver = Get-StageDriverName $Stage
        $perUnit = [double]$Seconds / $units
        $machine = "$(Get-InstanceType)"
        $j = Read-PhaseTimes
        if (-not $j) { $j = [PSCustomObject]@{ v = 2; stages = [PSCustomObject]@{} } }
        if (-not $j.stages) { $j | Add-Member -NotePropertyName stages -NotePropertyValue ([PSCustomObject]@{}) -Force }
        if (-not $j.stages.$machine) { $j.stages | Add-Member -NotePropertyName $machine -NotePropertyValue ([PSCustomObject]@{}) -Force }
        $prevEntry = $j.stages.$machine.$Stage
        $prev = 0.0
        if ($prevEntry -and "$($prevEntry.driver)" -eq $driver) { $prev = [double]$prevEntry.perUnit }
        $n = 0
        if ($prevEntry -and $prevEntry.n) { $n = [int]$prevEntry.n }
        # Smoothed on the RATE, not on the seconds. Smoothing seconds across two different job sizes
        # averages two answers to two different questions.
        $next = if ($prev -gt 0) { ($prev * 0.6) + ($perUnit * 0.4) } else { $perUnit }
        $j.stages.$machine | Add-Member -NotePropertyName $Stage -NotePropertyValue ([PSCustomObject]@{
            driver = $driver; perUnit = $next; n = ($n + 1)
            lastSec = [int]$Seconds; lastUnits = [Math]::Round($units, 3)
        }) -Force
        [IO.File]::WriteAllText($PhaseTimesFile, ($j | ConvertTo-Json -Depth 6))
    } catch { }
}

# Ship this phase's logs to the job results immediately, so a failure is diagnosable from inside
# Smart Drone without anyone logging on to the machine.
function Push-PhaseLogs($JobId) {
    try {
        Get-ChildItem -Path $OutDirGlobal -Filter 'rs-*.log' -ErrorAction SilentlyContinue | ForEach-Object {
            Invoke-AwsQuiet s3 cp $_.FullName "s3://$Bucket/jobs/$JobId/results/$($_.Name)" --no-progress | Out-Null
        }
    } catch { }
}

# $Depth is a PARAMETER, not something read from the caller's manifest here.
#
# It used to be assigned inside this function, which made it local: Invoke-Job's own $Depth was
# never set, so `if ($Depth -eq 'full')` there was comparing against an empty string and
# Build-Dem NEVER RAN, at any depth. Every full-depth job produced its DSM and then silently
# skipped the bare-earth ground surface the canopy-height gate is built on — and the telemetry
# recorded an empty depth for every job as well. Caught by a log line reading
# "ground surface (DEM) not requested at depth ''" on a job that had asked for standard.
function Invoke-RealityScan($JobId, $PhotoDir, $OutDir, $Epsg, $Depth, $Outputs = $null, $MeshDetail = 'high') {
    $script:OutDirGlobal = $OutDir
    if (-not $Depth) { $Depth = 'full' }
    # The checklist, resolved to booleans once and threaded through every gate below. An older
    # manifest carries no outputs, so this falls back to the depth exactly as before.
    $want = Resolve-Wanted $Outputs $Depth
    $proj = Join-Path $OutDir 'job.rsproj'
    # PRECONDITION: RealityScan's ortho export takes its settings file as a REQUIRED argument.
    # Without it the export dies on a dialog after all the rendering has been paid for, so check
    # first and say exactly how to produce it.
    $orthoXml = Join-Path $ConfigDir 'export-ortho.xml'
    if (-not (Test-Path $orthoXml)) {
        $how = "RealityScan cannot export an orthophoto without its export-settings file, and $orthoXml does not exist yet. " +
               "To create it, on the GPU machine open RealityScan, load any project with an ortho, press the export button in the [3] Output group, " +
               "choose a file name (the format you want, e.g. GeoTIFF), and when the export SETTINGS window appears use its save-settings control to write the file to $orthoXml. " +
               "Then run this job again - the photos are already uploaded, so it starts straight away."
        Log "Job ${JobId}: $how"
        $script:LastCliDetail = $how
        throw $how
    }
    $phases = Get-RsPhases $Depth $PhotoDir $OutDir $proj $script:MinimalCli $want $MeshDetail
    if ($script:MinimalCli) { Log "Job ${JobId}: using the MINIMAL RealityScan command line" }
    # Drop any switch this build rejects, so a job never burns two minutes hitting the dialog.
    $support = Get-CliSupport (Find-RealityScan)
    foreach ($sw in '-headless', '-newScene') {
        if ($support.$sw -eq $false) {
            foreach ($ph in $phases) { $ph.args = @($ph.args | Where-Object { $_ -ne $sw }) }
            Log "Job ${JobId}: dropping $sw - this RealityScan build does not accept it"
        }
    }
    # Stage count the app shows: fetch, the render phases, optimize, the ground surface when
    # there is a DSM to derive it from, and upload.
    $hasDsm = [bool]($phases | Where-Object { $_.stage -eq 'dsm' })
    $stageCount = $phases.Count + 3 + $(if ($want.dem) { 1 } else { 0 })
    $script:StageCount = $stageCount
    Log "Job ${JobId}: depth=$Depth, outputs=[ortho=$($want.ortho) dsm=$($want.dsm) dem=$($want.dem) 3d=$($want.model3d)], $($phases.Count) RealityScan phases: $(($phases | ForEach-Object { $_.stage }) -join ' -> ')"
    # Tell the app how this job's time is really distributed, so its bar can be proportional
    # instead of assuming a fixed shape for every depth.
    $planStages = @('downloading') + @($phases | ForEach-Object { $_.stage }) + @('optimizing')
    if ($want.dem) { $planStages += 'dem' }
    $planStages += 'uploading'
    Set-StagePlan $planStages
    $i = 1
    foreach ($phase in $phases) {
        $i++  # step 1 was fetching the photos
        $script:StageIndex = $i
        try {
            if (-not (Invoke-RsPhase $JobId $phase $i $stageCount)) { return $false }
            # Straight after alignment the region exists but is turned to fit the flight. Square
            # it here, before anything is modelled or projected off it.
            if ($phase.stage -eq 'aligning') {
                Square-ReconstructionRegion $JobId $Proj | Out-Null
                # region.rsbox now exists and is squared, so the ortho can be sized to the
                # photos' own resolution. Done HERE rather than when the phase list was built,
                # because the region is only known once alignment has run.
                #
                # The arguments are patched in only if the file was actually written: passing a
                # path that does not exist would make calculateOrthoProjection reject the whole
                # line, and losing the ortho to save some pixels is a bad trade. Every failure
                # inside Build-JobOrtho returns $null and leaves RealityScan's own sizing alone.
                #
                # BOTH raster phases get it. The DSM is the same calculateOrthoProjection with
                # different export settings, and left bare it computes its own projection at
                # RealityScan's default size — which is how the last real job delivered a 3389 MB
                # DSM at 1.09 cm/px off photos that only resolve 1.8. Sizing it too also puts the
                # DSM on the SAME grid as the ortho, so the canopy-height gate compares pixels
                # that line up instead of resampling one onto the other.
                if ($script:TargetOrthoGsdM -gt 0) {
                    $jobOrtho = Build-JobOrtho $JobId $OutDir $script:TargetOrthoGsdM
                    # A refusal is not a sizing failure: the grid is honest but too large for a
                    # single pass. Degrading silently is the one outcome the owner has ruled
                    # out, so fail the job with the plain reason (the strip wiring will route
                    # these to Build-StripPlan instead of throwing, once verified + enabled).
                    if ($script:OrthoRefuseReason) { throw $script:OrthoRefuseReason }
                    # RE-PLAN NOW THE GRID IS REAL. The first plan was built before alignment, when
                    # the only size known was the photo count — so every raster stage was weighted
                    # off the seed grid whatever tier the operator picked. Build-JobOrtho has just
                    # computed the grid this job will actually export, and the four longest stages
                    # (texturing, ortho, dsm, optimizing) have not run yet, so a re-plan here is
                    # both cheap and in time to matter.
                    Set-StagePlan $planStages
                    # The texture is what the ortho renders FROM, so its budget is sized to the
                    # GSD the raster will ACTUALLY use — Build-JobOrtho may have swapped an
                    # implausible app figure for the photo-supported one, and budgeting off the
                    # bad figure burnt 52 minutes texturing 64 sheets for a raster that rendered
                    # at RealityScan's default anyway (measured, job -7685). Ortho jobs only: a
                    # heights-only job needs the texture to exist, not to be sharp.
                    if ($want.ortho) {
                        $texGsd = if ($script:FinalOrthoGsdM -gt 0) { $script:FinalOrthoGsdM } else { $script:TargetOrthoGsdM }
                        $texSet = Build-TextureBudget $JobId $OutDir $texGsd
                        if ($script:TextureRefuseReason) { throw $script:TextureRefuseReason }
                        if ($texSet) {
                            foreach ($tp in @($phases | Where-Object { $_.stage -eq 'texturing' })) {
                                $tp.args = @($tp.args | ForEach-Object {
                                    if ($_ -eq '-calculateTexture') { $texSet + @($_) } else { $_ }
                                })
                                Log "Job ${JobId}: texturing phase will carry the sized texture budget"
                            }
                        }
                    }
                    if ($jobOrtho) {
                        $box = Join-Path $OutDir 'region.rsbox'
                        foreach ($op in @($phases | Where-Object { $_.stage -eq 'ortho' -or $_.stage -eq 'dsm' })) {
                            $op.args = @($op.args | ForEach-Object {
                                if ($_ -eq '-calculateOrthoProjection') { $_; $jobOrtho; $box } else { $_ }
                            })
                            Log "Job ${JobId}: $($op.stage) phase will use $([IO.Path]::GetFileName($jobOrtho)) + region.rsbox"
                        }
                    }
                }
            }
            # This phase's artefact goes to Smart Drone NOW, not at the end of the job. The next
            # phase starts as soon as this returns, so the optimize and the upload overlap the
            # render that follows them.
            if ($phase.delivers) { Publish-Artifact $JobId $OutDir $phase.delivers $Epsg | Out-Null }
        } catch {
            $msg = "$($_.Exception.Message)"
            # A phase that jammed without doing real work was rejected by the CLI, not defeated
            # by the data: retry it ONCE with the bare-minimum arguments (this is how the
            # alignment step was recovered) and keep minimal mode for the rest of the job.
            if ($msg -match 'never started working|stopped doing any work') {
                Log "Job ${JobId}: retrying [$($phase.stage)] with the minimal command line"
                Write-Status $JobId $phase.stage "Retrying $($phase.label) with a simpler RealityScan command..." 0 -StageIndex $i -StageCount $stageCount
                $script:MinimalCli = $true
                # Rebuilding from Get-RsPhases DROPS the per-job ortho sizing patched in after
                # alignment, so a retried ortho or DSM comes back at RealityScan's default pixel
                # count. That is the intent, not an oversight: this path exists because the CLI
                # rejected the line, and the sized .rsortho is exactly the kind of extra worth
                # giving up to get an output at all. A bigger file beats no file.
                $rebuilt = Get-RsPhases $Depth $PhotoDir $OutDir $proj $true $want $MeshDetail
                $mp = @($rebuilt | Where-Object { $_.stage -eq $phase.stage })[0]
                if ($mp) {
                    try {
                        if (-not (Invoke-RsPhase $JobId $mp $i $stageCount)) { return $false }
                        if ($phase.delivers) { Publish-Artifact $JobId $OutDir $phase.delivers $Epsg | Out-Null }
                        continue
                    } catch {
                        if ($phase.optional) {
                            Log "Job ${JobId}: optional step '$($phase.label)' failed after retry - continuing"
                            continue
                        }
                        throw
                    }
                }
            }
            if ($phase.optional) {
                Log "Job ${JobId}: optional step '$($phase.label)' failed - continuing. $msg"
                Add-Report "phase-optional-failed-$($phase.stage)" @{ error = $msg }
                continue
            }
            throw
        }
    }
    Push-PhaseLogs $JobId
    return $true
}


# ---- Pipelined delivery ---------------------------------------------------------------------
#
# Deliver each artefact the instant it is rendered, instead of holding the whole job back until
# the last one is done. The chain per artefact is optimize -> upload -> announce, and it runs at
# the phase boundary, before the next RealityScan pass is launched. Field reasoning: the 2D ortho
# is what the operator actually needs to start marking up a paddock, and on a full-depth job it
# was finished forty minutes before anything arrived, purely because the DSM and DEM were queued
# behind it.
#
# NOT YET TRULY CONCURRENT: this runs BETWEEN phases, not alongside the next one. Total job
# wall-clock is therefore unchanged (the same optimize and upload work happens, just earlier) —
# what changes is when the operator can start using each layer, which is the point. Overlapping
# the optimize with the following render needs it in a background runspace and is the next step.
#
# Delivery order is fixed and matches the depth ladder, so each level simply tags stages onto the
# one below: ortho.tif (quick) -> model.glb (standard) -> dsm.tif -> dem.tif (full).
#
# The announcement is status.json's `delivered` array. The app polls status.json anyway, so an
# artefact appearing there is all the signal it needs to start downloading - no second channel.
$script:Delivered = @()

function Publish-Artifact($JobId, $OutDir, $Name, $Epsg) {
    $src = Join-Path $OutDir $Name
    if (-not (Test-Path $src)) { return $false }
    if ($script:Delivered | Where-Object { $_.artifact -eq $Name }) { return $true }  # already gone up
    try {
        $deliverStarted = Get-Date
        # GeoTIFFs are optimized first so the app imports them with a file copy rather than
        # minutes of local conversion. The GLB has no equivalent step.
        $send = $Name
        if ($Name -like '*.tif') {
            Optimize-GeoTiffs $JobId $OutDir $Epsg $Name
            $cog = $Name -replace '\.tif$', '.cog.tif'
            if (Test-Path (Join-Path $OutDir $cog)) { $send = $cog }
        }
        $file = Join-Path $OutDir $send
        $bytes = (Get-Item $file).Length
        $mb = [Math]::Round($bytes / 1MB)
        Write-Status $JobId 'delivering' "Sending $Name ($mb MB) to Smart Drone..." 0.5
        $rc = Invoke-AwsQuiet s3 cp $file "s3://$Bucket/jobs/$JobId/results/$send" --only-show-errors
        if ($rc -ne 0) {
            Log "Job ${JobId}: could not deliver $send yet (aws exit $rc) - it still goes up with the final sync"
            return $false
        }
        $script:Delivered += @{ artifact = $Name; file = $send; bytes = $bytes
                                at = (Get-Date).ToUniversalTime().ToString('o') }
        Add-Report "delivered-$Name" @{ file = $send; bytes = $bytes }
        # Optimize + send, per artefact; summed across artefacts by Save-JobTelemetry.
        Add-Report 'phase-done-delivering' @{ seconds = [int]((Get-Date) - $deliverStarted).TotalSeconds; artifact = $Name }
        Log "Job ${JobId}: delivered $send ($mb MB) - Smart Drone can import it now"
        Write-Status $JobId 'delivering' "$Name is on its way into Smart Drone" 1
        return $true
    } catch {
        # A delivery that fails is not a job that fails: the final sync still uploads everything.
        Log "Job ${JobId}: early delivery of $Name failed ($($_.Exception.Message)) - it will go up at the end instead"
        return $false
    }
}

# The six geotransform numbers of a raster AS IT IS ON DISK RIGHT NOW, or $null.
#
# Needed because the north-align warp above REPLACES the file: any geotransform read before it is
# describing a raster that no longer exists, and comparing an export tier against a stale rotated
# transform is how a DSM got upsampled instead of downsampled. Same regex-not-ConvertFrom-Json
# reasoning as the main read: gdalinfo emits an empty-string key that Windows PowerShell's JSON
# parser rejects outright.
function Get-GeoTransform($Path, $O4w, $TempDir) {
    if (-not (Test-Path $Path)) { return $null }
    $tmp = Join-Path $TempDir ("gt-" + [System.IO.Path]::GetFileNameWithoutExtension($Path) + ".json")
    Remove-Item $tmp -Force -ErrorAction SilentlyContinue
    try {
        $gi = Start-Process $O4w -ArgumentList 'gdalinfo', '-json', '-nomd', '-norat', '-noct', "`"$Path`"" -PassThru -NoNewWindow `
            -RedirectStandardOutput $tmp -RedirectStandardError (Join-Path $TempDir 'gdalinfo-err.txt')
        $gi.WaitForExit(120000) | Out-Null
        $txt = if (Test-Path $tmp) { Get-Content $tmp -Raw } else { '' }
        $m = [regex]::Match($txt, '"geoTransform"\s*:\s*\[([^\]]*)\]')
        if (-not $m.Success) { return $null }
        $vals = @($m.Groups[1].Value -split ',' | ForEach-Object { [double]$_.Trim() })
        if ($vals.Count -lt 6) { return $null }
        return $vals
    } catch { return $null }
}

# Convert ortho.tif / dsm.tif into Cloud Optimized GeoTIFFs in place (best-effort; requires the
# optional OSGeo4W GDAL install). A failure leaves the plain GeoTIFF — the app handles both.
# $Only restricts the pass to a single named raster. Delivery is pipelined now: the ortho is
# optimized and uploaded the moment it exists, while the 3D model is still rendering, so the
# optimizer has to be able to work on one file rather than "whatever happens to be in out/".
function Optimize-GeoTiffs($JobId, $OutDir, $AssignEpsg = $null, $Only = $null) {
    $o4w = 'C:\OSGeo4W\OSGeo4W.bat'
    if (-not (Test-Path $o4w)) { return }
    # RealityScan's GeoTIFFs carry correct projection parameters but NO root EPSG identity —
    # the app then can't label the CRS and the imagery rendered black. The render pipeline's
    # export CRS is pinned by the manifest, so stamp it here (-a_srs relabels, no reprojection).
    # The generic optimize-job branch passes nothing — arbitrary user files must not be relabeled.
    $srs = if ($AssignEpsg) { @('-a_srs', "EPSG:$AssignEpsg") } else { @() }
    $targets = if ($Only) { @($Only) } else { @('ortho.tif', 'dsm.tif') }
    foreach ($name in $targets) {
        $src = Join-Path $OutDir $name
        if (-not (Test-Path $src)) { continue }
        $dst = Join-Path $OutDir ($name -replace '\.tif$', '.cog.tif')
        # Already optimized by the pipelined delivery, and the source has not changed since?
        # Then there is nothing to do. Without this the end-of-job sweep re-optimized every
        # artefact the pipeline had already handled - the most expensive part of the job, done
        # twice, for a byte-identical result.
        $dstItem = Get-Item $dst -ErrorAction SilentlyContinue
        if ($dstItem -and $dstItem.Length -gt 0 -and $dstItem.LastWriteTime -ge (Get-Item $src).LastWriteTime) {
            Log "Job ${JobId}: $name is already optimized - skipping"
            continue
        }
        # Mid-render deliveries report as 'delivering', not 'optimizing'. Reporting the
        # optimize stage while RealityScan is still on the model would throw the progress bar
        # forward to the end of the job and then back again on the next beat - which is the
        # bouncing the bar was just fixed to stop doing.
        $stageName = if ($Only) { 'delivering' } else { 'optimizing' }
        Write-Status $JobId $stageName "Optimizing $name for instant display..." 0.5
        # ROTATED RASTERS: RealityScan renders the ortho on the reconstruction region's own
        # plane, which is usually turned to fit the paddock. That leaves rotation terms in the
        # geotransform, and a rotated raster is not a valid COG - nor can the map tile it. When
        # rotation is present, north-align it first (gdalwarp resamples once, into the export
        # CRS); a north-up file passes straight through untouched.
        # Read gdalinfo through a FILE, not the pipeline. Piping `& OSGeo4W.bat gdalinfo -json`
        # into Out-String returned nothing at all, so every parse below failed into its catch and
        # the rotation check, the size report AND the coordinate-system guard were all skipped in
        # silence - a rotated ortho in an arbitrary local frame was stamped EPSG:2193 and shipped
        # twice while this code looked like it was checking. A wrapper .bat is not a reliable
        # source of piped output; a redirect to disk is.
        $infoFile = Join-Path $TempDir "gdalinfo-$JobId-$($name -replace '\.tif$', '').json"
        Remove-Item $infoFile -Force -ErrorAction SilentlyContinue
        # -nomd suppresses the metadata block, which is where the unparseable empty key lives.
        $gi = Start-Process $o4w -ArgumentList 'gdalinfo', '-json', '-nomd', '-norat', '-noct', "`"$src`"" -PassThru -NoNewWindow `
            -RedirectStandardOutput $infoFile -RedirectStandardError (Join-Path $TempDir 'gdalinfo-err.txt')
        $gi.WaitForExit(120000) | Out-Null
        $info = if (Test-Path $infoFile) { Get-Content $infoFile -Raw } else { '' }
        $brace = $info.IndexOf('{')
        if ($brace -gt 0) { $info = $info.Substring($brace) }
        $rotated = $false
        $gt = $null
        $sizePx = @(0, 0)
        # The six geotransform numbers and the raster size are pulled straight out of the text.
        # ConvertFrom-Json cannot be used on gdalinfo's output at all: it always emits an
        # EMPTY-STRING key for the default metadata domain, and Windows PowerShell's JSON parser
        # rejects empty property names, so every call threw and every check below was skipped.
        # -nomd removes that block; this regex means it does not matter if something else in the
        # document upsets the parser tomorrow.
        try {
            $m = [regex]::Match($info, '"geoTransform"\s*:\s*\[([^\]]*)\]')
            if ($m.Success) {
                $gt = @($m.Groups[1].Value -split ',' | ForEach-Object { [double]$_.Trim() })
                if ($gt.Count -lt 6) { $gt = $null }
            }
            $ms = [regex]::Match($info, '"size"\s*:\s*\[\s*(\d+)\s*,\s*(\d+)\s*\]')
            if ($ms.Success) { $sizePx = @([int]$ms.Groups[1].Value, [int]$ms.Groups[2].Value) }
            # RELATIVE to the pixel size, matching the app's orthoImport.rotationOf. An absolute
            # 1e-9 threshold means something different on a 1 cm ortho than on a 10 m DEM, and
            # tripping it costs a full resample of a multi-gigabyte raster for nothing.
            if ($gt) {
                $pxScale = [Math]::Max(
                    [Math]::Sqrt([Math]::Pow([double]$gt[1], 2) + [Math]::Pow([double]$gt[4], 2)),
                    [Math]::Sqrt([Math]::Pow([double]$gt[2], 2) + [Math]::Pow([double]$gt[5], 2)))
                if ($pxScale -gt 0 -and (
                        [Math]::Abs([double]$gt[2]) / $pxScale -gt 1e-6 -or
                        [Math]::Abs([double]$gt[4]) / $pxScale -gt 1e-6)) { $rotated = $true }
            }
            if ($gt) {
                # Report the GSD that actually came out. Depth (quick/standard/full) changes the
                # mesh detail, never the pixel size - that is set once in RealityScan's Ortho
                # Projection tool - and this line is how that gets confirmed rather than assumed.
                # Rotation has to be included: reading gt[1] alone reports 0.03 cm for a turned
                # raster that is really 1.1 cm.
                $cm = [Math]::Round([Math]::Sqrt([Math]::Pow([double]$gt[1], 2) + [Math]::Pow([double]$gt[4], 2)) * 100, 2)
                Log "Job ${JobId}: $name is $($sizePx[0]) x $($sizePx[1]) px at $cm cm/px$(if ($rotated) { ', rotated' })"
                Add-Report "raster-$($name -replace '\.tif$', '')" @{ widthPx = $sizePx[0]; heightPx = $sizePx[1]; cmPerPixel = $cm; rotated = $rotated; originX = [double]$gt[0]; originY = [double]$gt[3] }
            }
        } catch { }
        if (-not $gt) {
            # Say so. This block silently doing nothing is exactly how two mis-georeferenced
            # orthos got shipped while the checks below looked like they were running.
            Log "Job ${JobId}: WARNING - could not read $name's geotransform from gdalinfo, so the rotation and coordinate-system checks were skipped. First 200 chars of what came back: $($info.Substring(0, [Math]::Min(200, $info.Length)))"
            Add-Report "raster-unreadable-$($name -replace '\.tif$', '')" @{ bytes = $info.Length }
        }

        # A raster whose own coordinates cannot be in the CRS about to be stamped on it. This was
        # a hard failure, on the reasoning that a silently mis-georeferenced ortho is the worst
        # possible result - nothing about it looks broken, so it gets used. That reasoning still
        # holds for SILENT, but failing the job destroys imagery that is perfectly good to look
        # at while the projection is being sorted out, and the imagery is what the whole render
        # is for. So it is reported loudly and the raster is delivered anyway: the position is
        # wrong, the picture is not. (Deliberately outside the try above: a parse failure must
        # not be able to swallow it.)
        $localFrame = $false
        if ($AssignEpsg -eq 2193 -and $gt) {
            $x = [double]$gt[0]; $y = [double]$gt[3]
            if ($x -lt 800000 -or $x -gt 3200000 -or $y -lt 4000000 -or $y -gt 7000000) {
                $localFrame = $true
                Log "Job ${JobId}: WARNING - $name is in an arbitrary local coordinate system, not NZTM. Its origin is $([int]$x), $([int]$y), which is nowhere in New Zealand, so the imagery is usable but its POSITION is not. RealityScan keeps the ortho projection settings inside the project, and every job starts a new one, so the projection falls back to a default frame."
                Add-Report "raster-local-frame-$($name -replace '\.tif$', '')" @{ originX = $x; originY = $y }
            }
        }
        if ($rotated) {
            $flat = Join-Path $OutDir ($name -replace '\.tif$', '.northup.tif')
            $tsrs = if ($AssignEpsg) { @('-t_srs', "EPSG:$AssignEpsg") } else { @() }
            $ssrs = if ($AssignEpsg) { @('-s_srs', "EPSG:$AssignEpsg") } else { @() }
            # Cubic for imagery, bilinear for heights. Cubic overshoots at a sharp edge, which on
            # a picture is invisible and on a surface model is a spike of invented elevation.
            $resample = if ($name -like 'dsm*' -or $name -like 'dem*') { 'bilinear' } else { 'cubic' }
            Log "Job ${JobId}: $name is rotated - north-aligning it ($resample) before optimizing"
            Write-Status $JobId $stageName "Straightening $name to north-up..." 0.4
            # Beats while it warps. This was left blocking when the COG translate was
            # converted, and a 1.5 GB north-align then went silent for minutes — long enough
            # for the app's new 4-minute stall timeout to fail a perfectly healthy job. The
            # whole point of tightening that timeout was that every long step beats; missing
            # one turns the safety net into the fault.
            # -multi ALONE is only two threads (compute split from I/O). The warp itself needs
            # -wo NUM_THREADS and the DEFLATE needs -co NUM_THREADS, or this runs on about one
            # core: measured 6.7% CPU on a 16-vCPU box straightening a DSM, against 22-32% for
            # the COG translate right next to it that already carried the flag. Same
            # 1.2-gigapixel raster, about five sixths of the machine idle.
            # (Comments must stay ABOVE this line: a comment after a line-continuation backtick
            # breaks the continuation, which is exactly how a broken script reached S3 once.)
            $wrc = Invoke-ToolWithBeat $JobId $stageName "Straightening $name to north-up..." $o4w `
                (@('gdalwarp') + $ssrs + $tsrs + @('-r', $resample, '-multi',
                  '-wo', 'NUM_THREADS=ALL_CPUS', '-co', 'NUM_THREADS=ALL_CPUS',
                  '-co', 'COMPRESS=DEFLATE', '-co', 'BIGTIFF=IF_SAFER', $src, $flat)) 0.4
            if ($wrc -eq 0 -and (Test-Path $flat)) {
                Remove-Item $src -Force
                Rename-Item $flat $name
                Log "Job ${JobId}: $name north-aligned"
            } else {
                Remove-Item $flat -Force -ErrorAction SilentlyContinue
                Log "Job ${JobId}: could not north-align $name - continuing with the rotated file"
            }
        }
        # Beats every 10 s while GDAL works. A 1.5 GB COG translate runs for minutes, and the
        # old blocking call made that look identical to a wedged worker.
        #
        # PREDICTOR=YES: the COG driver picks the predictor by data type on its own — the
        # floating-point predictor for float rasters (dsm/dem), horizontal differencing for the
        # byte ortho. It is LOSSLESS either way (verified: pixel checksums are byte-identical
        # with and without it) and it is a large, free win on the surface models — a fine-GSD
        # DSM over 30 ha came off the last job at 10.7 GB, and the FP predictor turns those
        # smooth height gradients into small deltas that DEFLATE crushes: local tests on
        # synthetic terrain cut a float COG to ~42 % of its DEFLATE-only size (58 % smaller),
        # and even a heavily-grained photographic ortho still shrank ~28 %. Nothing about the
        # imagery or the heights changes; only the download does.
        # DOWNSAMPLE TO THE TIER HERE, in the pass that was already going to rewrite the file.
        # The projection was built at the finest resolution any product asked for; a product that
        # asked for less gets it on the way into the COG rather than in an extra pass.
        #
        # -r average for the IMAGERY: a genuine reduction, and averaging keeps the picture honest
        # instead of picking one pixel in twenty-five.
        #
        # -r nearest for the HEIGHTS, and that is not a compromise -- it is the correct answer.
        # RealityScan marks DSM voids in a separate Float32 alpha band while the height band holds
        # a plain fill value, and gdal_translate honours an alpha band as a mask only when it is
        # Byte. Averaging therefore resamples the two bands INDEPENDENTLY: a cell that is 90% real
        # ground keeps an alpha of ~230 (valid) while its height has had 10% of a -9999 fill blended
        # into it, which is metres of invented terrain at every void edge. Nearest keeps each output
        # cell's height and its alpha taken from the SAME source pixel, so a void stays a void and a
        # measured height stays exactly the height that was measured.
        $tr = @()
        $prodId = if ($name -eq 'ortho.tif') { 'ortho2d' } elseif ($name -eq 'dsm.tif') { 'dsm' } elseif ($name -eq 'dem.tif') { 'dem' } else { $null }
        if ($prodId -and $script:ExportGsd -and $script:ExportGsd.ContainsKey($prodId)) {
            $wantGsd = [double]$script:ExportGsd[$prodId]
            # Only ever COARSER. Upsampling would invent detail and cost the operator a bigger file
            # for it, so a tier finer than what the projection produced is simply ignored.
            #
            # The scale is read from the geotransform AS IT IS NOW and with the rotation included.
            # Both halves were wrong: gt was captured before the north-align warp above replaced the
            # file, and gt[1] alone reports 0.03 cm for a turned raster that is really 1.1 cm -- so
            # a rotated DSM compared its tier against a hundredth of its true pixel size and got
            # UPSAMPLED to a file thirty times bigger carrying no more information.
            $curGsd = 0.0
            $ngt = Get-GeoTransform $src $o4w $TempDir
            if ($ngt -and $ngt.Count -ge 6) {
                $curGsd = [Math]::Sqrt([Math]::Pow([double]$ngt[1], 2) + [Math]::Pow([double]$ngt[4], 2))
            } elseif ($gt -and $gt.Count -ge 6) {
                $curGsd = [Math]::Sqrt([Math]::Pow([double]$gt[1], 2) + [Math]::Pow([double]$gt[4], 2))
            }
            if ($curGsd -gt 0 -and $wantGsd -gt $curGsd * 1.05) {
                $how = if ($name -eq 'ortho.tif') { 'average' } else { 'nearest' }
                $tr = @('-tr', "$wantGsd", "$wantGsd", '-r', $how)
                Log "Job ${JobId}: $name exported at $([Math]::Round($wantGsd*100,1)) cm/px by $how (projection was $([Math]::Round($curGsd*100,2)) cm/px)"
            } elseif ($curGsd -le 0) {
                Log "Job ${JobId}: WARNING - could not read $name's pixel size, so its export tier was not applied; it ships at the projection grid."
            }
        }
        $rc = Invoke-ToolWithBeat $JobId $stageName "Optimizing $name for instant display..." $o4w `
            (@('gdal_translate', '-of', 'COG') + $srs + $tr + @('-co', 'COMPRESS=DEFLATE', '-co', 'PREDICTOR=YES',
              '-co', 'NUM_THREADS=ALL_CPUS', '-co', 'BIGTIFF=IF_SAFER', '-co', 'OVERVIEWS=AUTO', $src, $dst)) 0.5
        if ($rc -eq 0 -and (Test-Path $dst)) {
            Remove-Item $src -Force
            Rename-Item $dst $name
            Log "Job ${JobId}: $name optimized to COG"
        } else {
            Remove-Item $dst -Force -ErrorAction SilentlyContinue
            Log "Job ${JobId}: COG optimization of $name failed - uploading the plain GeoTIFF"
        }
    }
}

# ---- Bare-earth DEM ---------------------------------------------------------------------------
# RealityScan can build a DTM itself, but only inside the ortho step and only by adding tens of
# minutes to it. The DSM is already a free by-product of the mesh, and the ground surface can be
# derived from it here in about a minute. The model lives in build-dem.py below - the short
# version is that a plain rolling-minimum DEM (what most tools do) is wrong by
# (window radius x slope) on steep country, which on a 30 degree face is over a metre of fake
# canopy height, so the minimum is taken on a plane-detrended surface instead.
$DemScript = @'
"""Derive a bare-earth DEM (ground surface) from a photogrammetric DSM.

Why this exists: RealityScan's own "Generate DTM" runs inside the ortho step and costs
tens of minutes on a big flight. The DSM it already gives us for free (a raster of the
mesh) carries the same information, so the ground surface is derived here instead.

The naive method - take the minimum height over a rolling 3-5 m window - is what most
tools do, and it is wrong on steep country: inside a window on a slope the lowest cell
sits at the DOWNHILL edge, so the "ground" comes out low by (window radius x slope).
On a 30 deg face with a 4 m window that is 1.2 m of pure error, which would then show
up as 1.2 m of fake canopy height in the CHM.

The fix is to take the minimum of the DETRENDED surface. Each pass:

    trend    = local least-squares PLANE fit to the current surface   (follows the hill)
    residual = surface - trend                                        (hill removed, flat)
    rmin     = rolling minimum of the residual                        (finds ground/gaps)
    ground   = trend + smooth(rmin)

On a uniform slope the residual is flat, so the minimum has nothing to bias it and the
ground estimate lands back on the hillside. Passes run coarse -> fine (30, 12, 6, 3 m)
and each pass may only LOWER the estimate, so dense canopy is peeled off progressively
without ever cutting into the terrain. The coarse pass is what carries a solid block of
gorse - up to about 30 m across - where no bare ground is visible at all.

The trend has to be a plane fit rather than a simple average: the moment a window is
clipped (paddock edge) or holed (no-data), an average of sloping ground is pulled toward
whichever side survived, by up to (window radius x slope). A plane reads the slope out of
the data and evaluates it at the cell itself, so half a window still lands right.

The estimate is then snapped back onto reality. A cell counts as observed bare ground if
the DSM sits within a small tolerance of the lowest nearby height-above-estimate, OR if
the surface there is smooth at half-metre scale - ridge lines, gully floors, cut banks
and farm tracks are exactly what a minimum-based peel shaves off, and they are also the
only things that are perfectly smooth while vegetation never is. Observed cells keep
their true DSM height; the gaps are carried across on a plane fitted through the ground
that surrounds them, so a hole on a hillside keeps the hillside instead of flattening.

The DSM is read twice on the way in, at the 25 cm working grid: once taking the lowest
height in each cell and once the typical one. The low copy is what finds ground - it keeps
the glimpse of dirt in a cell that is mostly bush - but its heights carry the same bias in
miniature (about cell x slope / 2, plus a pull from the noise floor), so both parts are
measured off this flight's own bare ground and taken back out before the heights are used.

Measured against synthetic scenes with 35% canopy cover (bias / RMS / p99 error, metres,
over cells where the ground was really visible):

    terrain          naive 4 m minimum        this method
    flat            -0.05  0.05  0.07      -0.01  0.01  0.05
    30 deg slope    -1.17  1.17  1.39      -0.01  0.02  0.05
    40 deg slope    -1.68  1.69  1.94      -0.01  0.02  0.05
    ridge / gully   -0.95  0.95  1.31      -0.01  0.07  0.18
    2 m cut bank    -0.45  0.48  1.56      -0.02  0.08  0.42

Canopy height over 1 m+ bushes on a 40 deg face reads 1.70 m against a true 1.70 m; the
naive minimum reads 3.35 m. Known limit: where a stand is wider than the coarsest window
(~30 m) with no bare ground anywhere inside it, there is nothing left to measure against
and heights in the middle of the stand read low.

Usage:  build-dem.py <dsm.tif> <dem.tif> [cell=0.25] [windows=30,12,6,3] [tol=0.15]
"""

import math
import sys
import numpy as np


# --------------------------------------------------------------------- filters ----------

def _box_sum(a, r):
    """Sum over a (2r+1)^2 window, edges clamped, via a summed-area table."""
    if r <= 0:
        return a.astype(np.float64, copy=True)
    h, w = a.shape
    ii = np.zeros((h + 1, w + 1), np.float64)
    np.cumsum(np.cumsum(a, axis=0, dtype=np.float64), axis=1, out=ii[1:, 1:])
    y0 = np.clip(np.arange(h) - r, 0, h)[:, None]
    y1 = np.clip(np.arange(h) + r + 1, 0, h)[:, None]
    x0 = np.clip(np.arange(w) - r, 0, w)[None, :]
    x1 = np.clip(np.arange(w) + r + 1, 0, w)[None, :]
    return ii[y1, x1] - ii[y0, x1] - ii[y1, x0] + ii[y0, x0]


def box_mean(a, r):
    """NaN-aware box mean. Cells with no valid neighbour come back NaN."""
    valid = np.isfinite(a)
    s = _box_sum(np.where(valid, a, 0.0), r)
    n = _box_sum(valid.astype(np.float64), r)
    out = np.full(a.shape, np.nan, np.float64)
    np.divide(s, n, out=out, where=n > 0)
    return out


def plane_trend(a, r, cell):
    """Local least-squares PLANE through the (2r+1)^2 window, evaluated at the centre cell.

    A box mean would do the same job in the middle of a full window - but the moment the
    window is clipped (paddock edge) or holed (no-data under canopy) the mean of a sloping
    surface is pulled towards whichever side survived, by up to (window radius x slope).
    That is metres on steep country, and it is the single biggest error in the naive
    minimum-filter method. A plane fit reads the slope out of the data and evaluates it at
    the cell itself, so a half-window on a hillside still lands on the right height.

    All nine sums come from summed-area tables, so cost is independent of window size.
    """
    h, w = a.shape
    valid = np.isfinite(a)
    v = valid.astype(np.float64)
    z = np.where(valid, a, 0.0)
    # Coordinates centred on the raster keep x^2 small enough that the normal equations
    # stay well conditioned in float64.
    X = ((np.arange(w) - w / 2.0) * cell)[None, :] * np.ones((h, 1))
    Y = ((np.arange(h) - h / 2.0) * cell)[:, None] * np.ones((1, w))

    N = _box_sum(v, r)
    Sx, Sy, Sz = _box_sum(v * X, r), _box_sum(v * Y, r), _box_sum(z, r)
    Sxx, Sxy, Syy = _box_sum(v * X * X, r), _box_sum(v * X * Y, r), _box_sum(v * Y * Y, r)
    Sxz, Syz = _box_sum(z * X, r), _box_sum(z * Y, r)

    # Re-centre every window on its own cell: fit z = a + b*u + c*t, u = X - x0, t = Y - y0.
    Su = Sx - N * X
    St = Sy - N * Y
    Suu = Sxx - 2 * X * Sx + N * X * X
    Sut = Sxy - X * Sy - Y * Sx + N * X * Y
    Stt = Syy - 2 * Y * Sy + N * Y * Y
    Suz = Sxz - X * Sz
    Stz = Syz - Y * Sz

    # 3x3 Cramer. Only `a` (the height at the cell) is wanted.
    det = (N * (Suu * Stt - Sut * Sut)
           - Su * (Su * Stt - Sut * St)
           + St * (Su * Sut - Suu * St))
    da = (Sz * (Suu * Stt - Sut * Sut)
          - Su * (Suz * Stt - Sut * Stz)
          + St * (Suz * Sut - Suu * Stz))

    out = np.full(a.shape, np.nan, np.float64)
    mean = np.full(a.shape, np.nan, np.float64)
    np.divide(Sz, N, out=mean, where=N > 0)
    ok = (N >= 8) & (np.abs(det) > 1e-9 * np.maximum(N, 1) ** 3)
    np.divide(da, det, out=out, where=ok)
    out[~ok] = mean[~ok]        # too few points to see a slope - the mean is the best guess
    return out


def _min1d(a, r, axis):
    """Rolling minimum along one axis, van Herk / Gil-Werman: two passes of running
    minima over blocks of the window width, so cost is flat no matter how wide the
    window gets. That is what makes a 30 m peel affordable at 25 cm cells."""
    w = 2 * r + 1
    a = np.moveaxis(a, axis, -1)
    n = a.shape[-1]
    p = np.pad(a, [(0, 0)] * (a.ndim - 1) + [(r, r)], mode='edge')
    extra = (-p.shape[-1]) % w
    if extra:
        p = np.pad(p, [(0, 0)] * (p.ndim - 1) + [(0, extra)], mode='edge')
    blocks = p.reshape(p.shape[:-1] + (p.shape[-1] // w, w))
    fwd = np.fmin.accumulate(blocks, axis=-1).reshape(p.shape)          # fmin ignores NaN
    bwd = np.fmin.accumulate(blocks[..., ::-1], axis=-1)[..., ::-1].reshape(p.shape)
    out = np.fmin(bwd[..., :n], fwd[..., w - 1:w - 1 + n])
    return np.moveaxis(out, -1, axis)


def min_filter(a, r):
    """Rolling minimum over a (2r+1)^2 window, NaN-tolerant, edges clamped."""
    if r <= 0:
        return a.copy()
    return _min1d(_min1d(a, r, 0), r, 1)


def roughness(a, r):
    """RMS departure from the local plane - near zero on bare ground of ANY steepness,
    large over vegetation. Measured against a plane rather than a mean precisely so that
    a steep hillside doesn't read as rough."""
    resid = a - plane_trend(a, r, 1.0)
    return np.sqrt(np.maximum(box_mean(resid * resid, r), 0.0))


def plane_basis(seed, cell, radii):
    """A surface to interpolate the ground across canopy on.

    Filling holes by averaging what surrounds them flattens the fill - across a 20 m gorse
    block on a 30 deg face that is metres of error at the top and bottom edges. Fitting a
    plane through the surrounding ground instead carries the hillside straight through the
    gap. Each cell uses the SMALLEST window that still holds enough ground to fit, so open
    country keeps fine detail and only the middle of a big block reaches out wide.
    """
    valid = np.isfinite(seed).astype(np.float64)
    out = np.full(seed.shape, np.nan, np.float64)
    for r_m in radii:
        need = np.isnan(out)
        if not need.any():
            break
        r = max(1, int(round(r_m / cell)))
        n = _box_sum(valid, r)
        t = plane_trend(seed, r, cell)
        take = need & (n >= 24) & np.isfinite(t)
        out[take] = t[take]
    return out


# ------------------------------------------------------------------ hole filling --------

def _shrink(v, w):
    """Sum 2x2 blocks of value*weight and of weight (pads to even)."""
    h, wd = v.shape
    ph, pw = h % 2, wd % 2
    if ph or pw:
        v = np.pad(v, ((0, ph), (0, pw)))
        w = np.pad(w, ((0, ph), (0, pw)))
    v = v.reshape(v.shape[0] // 2, 2, v.shape[1] // 2, 2).sum(axis=(1, 3))
    w = w.reshape(w.shape[0] // 2, 2, w.shape[1] // 2, 2).sum(axis=(1, 3))
    return v, w


def fill_holes(a):
    """Fill NaNs by interpolating from the valid cells (image pyramid, smooth + fast).

    Coarser and coarser averages are built until the whole scene is covered, then the
    holes are painted back in from the coarsest level that has data. Big canopy gaps
    come out as a smooth surface stretched between the surrounding ground, which is
    what a ground surface under a bush should look like.
    """
    valid = np.isfinite(a)
    if valid.all():
        return a.astype(np.float64, copy=True)
    if not valid.any():
        return np.zeros_like(a, np.float64)

    levels = [(np.where(valid, a, 0.0).astype(np.float64), valid.astype(np.float64))]
    while levels[-1][0].shape[0] > 2 and levels[-1][0].shape[1] > 2:
        levels.append(_shrink(*levels[-1]))

    # Coarsest level: anything still empty takes the overall mean.
    v, w = levels[-1]
    mean = v.sum() / max(w.sum(), 1e-9)
    coarse = np.where(w > 0, v / np.maximum(w, 1e-9), mean)

    for i in range(len(levels) - 2, -1, -1):
        v, w = levels[i]
        up = np.repeat(np.repeat(coarse, 2, axis=0), 2, axis=1)[:v.shape[0], :v.shape[1]]
        here = np.where(w > 0, v / np.maximum(w, 1e-9), up)
        coarse = here

    out = a.astype(np.float64, copy=True)
    out[~valid] = coarse[:a.shape[0], :a.shape[1]][~valid]
    return out


# --------------------------------------------------------------------- the model --------

def ground_from_surface(dsm, cell, windows=(30.0, 12.0, 6.0, 3.0), tol=0.15, trend_mult=1.5,
                        rough_tol=0.06, fill_radii=(3.0, 6.0, 12.0, 25.0, 50.0), ref=None):
    """DSM (metres, NaN = no data) -> bare-earth ground surface, same grid.

    `windows` are the detrended-minimum window widths in metres, coarse first. They are
    deliberately modest: the slope is already removed before the minimum is taken, so a
    wide window buys nothing and blunts ridge lines and gully floors.
    `tol` is how close to the estimate a DSM cell must sit to count as observed ground.

    `dsm` should be the lowest height in each working cell and `ref` the typical one (the
    two resamplings of the same source). The low version FINDS ground - it keeps the glimpse
    of dirt in a cell that is mostly bush - while the typical version supplies the HEIGHTS,
    because taking a minimum inside a cell repeats the very bias this module exists to
    remove, only at cell scale: about (cell x slope / 2) plus a pull from the noise floor,
    which measured 12 cm on a 30 degree face at 25 cm cells. `ref` also carries the
    roughness test, since the noise in a per-cell minimum is what roughness would see.
    """
    if ref is None:
        ref = dsm
    g = dsm.astype(np.float64, copy=True)
    for w_m in windows:
        r = max(1, int(round(w_m / cell / 2.0)))
        trend = plane_trend(g, int(round(r * trend_mult)), cell)
        resid = g - trend
        rmin = box_mean(min_filter(resid, r), r)   # smooth the blocky minimum back out
        cand = trend + rmin
        g = np.fmin(g, cand)                        # passes may only ever lower the ground

    # Snap onto observed ground. The estimate can still sit a little under true ground
    # (every pass may only push it down, so noise accumulates one way), which an absolute
    # test would read as "no ground visible anywhere". Measuring each cell against the
    # LOWEST nearby height-above-estimate self-corrects that, and carries no slope bias
    # because the slope is already out of the residual.
    finite = np.isfinite(dsm) & np.isfinite(ref)
    d = dsm - g
    r_ref = max(1, int(round(windows[-1] / cell / 2.0)))
    floor = box_mean(min_filter(d, r_ref), r_ref)
    observed = finite & (d - floor <= tol) & (d <= tol + 0.5)

    # Rescue anything the peel cut into that is plainly bare ground. Ridge lines, gully
    # floors, cut banks and farm tracks are the places a minimum-based method always
    # shaves, because a window straddling a break in slope sits below the break itself.
    # They are also perfectly smooth at half-metre scale, where vegetation never is - so
    # smoothness re-admits them without ever re-admitting a bush.
    r_s = max(1, int(round(0.5 / cell)))
    smooth = finite & (roughness(ref, r_s) < rough_tol)
    observed |= smooth

    # Un-bias the per-cell minimum before its height is used. This only applies when `dsm`
    # really is an aggregate of something finer; with a single surface there is nothing to
    # correct. Two parts, both measurable: the slope across a cell (the lowest corner sits
    # about cell x slope / 2 below the middle) and the noise floor (the lowest of a few
    # hundred sub-samples runs below the true surface by a fixed amount). The noise part is
    # read off the smooth bare ground in this very flight, so a clean survey and a grainy
    # one each get their own figure.
    height = dsm
    if ref is not dsm:
        gy_, gx_ = np.gradient(fill_holes(g), cell)
        slope_part = (np.abs(gx_) + np.abs(gy_)) * cell / 2.0
        gap = ref - dsm - slope_part
        noise_part = float(np.median(gap[smooth & np.isfinite(gap)])) if smooth.any() else 0.0
        noise_part = min(max(noise_part, 0.0), 0.5)
        height = dsm + slope_part + noise_part

    seed = np.where(observed, height, np.nan)
    basis = plane_basis(seed, cell, fill_radii)
    basis = fill_holes(basis)
    dem = basis + fill_holes(seed - basis)   # exact at observed cells, plane-carried across gaps
    dem = box_mean(dem, r_s)                 # light 1 m smooth
    dem = np.fmin(dem, ref)                  # ground is never above the surface
    dem[~finite] = np.nan
    return dem


# ------------------------------------------------------------------------- main ---------

def main(argv):
    from osgeo import gdal
    gdal.UseExceptions()

    src_path, dst_path = argv[1], argv[2]
    cell = float(argv[3]) if len(argv) > 3 else 0.25
    windows = tuple(float(x) for x in argv[4].split(',')) if len(argv) > 4 else (30.0, 12.0, 6.0, 3.0)
    tol = float(argv[5]) if len(argv) > 5 else 0.15

    src = gdal.Open(src_path)
    gt = src.GetGeoTransform()
    src_cell = max(abs(gt[1]), abs(gt[5]))
    cell = max(cell, src_cell)

    # The whole derivation runs in memory, so a very large block gets coarsened until it
    # fits rather than thrashing the machine. 8 M cells at 25 cm is 50 ha; beyond that
    # the ground surface loses a little detail, which matters far less than finishing.
    MAX_CELLS = 8e6
    area = (src.RasterXSize * abs(gt[1])) * (src.RasterYSize * abs(gt[5]))
    if area / (cell * cell) > MAX_CELLS:
        cell = math.sqrt(area / MAX_CELLS)
        print('DEM: block is %.0f ha - working at %.2f m instead of 0.25 m' % (area / 1e4, cell))

    # Work at ~25 cm: a ground surface needs nothing finer, and it turns a gigapixel DSM
    # into a few megapixels so the whole derivation takes seconds. Two resamplings of the
    # same source: `min` keeps the glimpse of dirt in a cell that is mostly bush and is what
    # finds the ground; `med` is what the heights are read from (see ground_from_surface).
    # Voids in the mesh matter more than anything else here. RealityScan marks them with an
    # alpha band, and if that alpha is ignored a hole written as 0.0 in 100 m terrain reads as
    # a 100 m pit that drags the derived ground down for tens of metres around it - measured at
    # 91 m of error on a scene with one 8 m hole in it.
    #
    # The alpha band is read and applied by hand rather than left to GDAL. A DSM's alpha is
    # Float32, like its heights, and GDAL only treats an alpha band as a mask when it is Byte -
    # so srcAlpha resampled the hole straight back in and reported the result fully valid.
    alpha_band = next((i + 1 for i in range(src.RasterCount)
                       if src.GetRasterBand(i + 1).GetColorInterpretation() == gdal.GCI_AlphaBand), None)

    def warped(alg, name):
        w = gdal.Warp('/vsimem/' + name, src, xRes=cell, yRes=cell,
                      resampleAlg=alg, multithread=True)
        b = w.GetRasterBand(1)
        a = b.ReadAsArray().astype(np.float64)
        nd = b.GetNoDataValue()
        if nd is not None:
            a[a == nd] = np.nan
        a[~np.isfinite(a)] = np.nan
        # Sentinel voids only, and ONLY the unmistakable ones. This used to discard anything
        # below -9000 m, on the reasoning that no real terrain goes there — until a DSM arrived
        # whose heights all sat near -3,987,500 because the projection had fallen back to an
        # earth-centred frame. Every height was thrown away and the step reported "DSM has no
        # valid heights", blaming the data for a filter's assumption. Validity is the alpha
        # band's job; this only catches the float extremes used as fill.
        a[a <= -1e30] = np.nan
        if alpha_band and alpha_band <= w.RasterCount:
            # Resampled the same way as the heights, which gives exactly the behaviour each
            # copy wants: on the `min` copy any cell touching a void goes out entirely, so a
            # hole can never supply the minimum; on the `med` copy a cell survives while most
            # of it is real.
            av = w.GetRasterBand(alpha_band).ReadAsArray().astype(np.float64)
            a[av < 128] = np.nan
        return w, a

    lo, arr = warped('min', 'dsm_lo.tif')
    ref_ds, ref = warped('med', 'dsm_ref.tif')

    if not np.isfinite(arr).any():
        raise SystemExit('DSM has no valid heights')

    dem = ground_from_surface(arr, cell, windows, tol, ref=ref)

    out_nodata = -32767.0
    out = dem.astype(np.float32)
    out[~np.isfinite(out)] = out_nodata

    drv = gdal.GetDriverByName('GTiff')
    # PREDICTOR=3 is the float predictor (GTiff takes the numeric form; the COG driver takes
    # PREDICTOR=YES). Lossless, and it shrinks this intermediate before the COG pass re-reads
    # it — less peak scratch on a box that has run the disk to zero before.
    dst = drv.Create(dst_path, lo.RasterXSize, lo.RasterYSize, 1, gdal.GDT_Float32,
                     ['COMPRESS=DEFLATE', 'PREDICTOR=3', 'TILED=YES', 'BIGTIFF=IF_SAFER'])
    dst.SetGeoTransform(lo.GetGeoTransform())
    dst.SetProjection(lo.GetProjection())
    b = dst.GetRasterBand(1)
    b.SetNoDataValue(out_nodata)
    b.WriteArray(out)
    b.FlushCache()
    dst = None
    lo = None
    ref_ds = None
    gdal.Unlink('/vsimem/dsm_lo.tif')
    gdal.Unlink('/vsimem/dsm_ref.tif')

    good = np.isfinite(dem)
    chm = (ref - dem)[good]
    print('DEM %dx%d at %.2f m; canopy median %.2f m, 95th %.2f m'
          % (out.shape[1], out.shape[0], cell,
             float(np.median(chm)) if chm.size else 0.0,
             float(np.percentile(chm, 95)) if chm.size else 0.0))


if __name__ == '__main__':
    main(sys.argv)
'@

# A python with numpy AND the GDAL bindings. OSGeo4W's `gdal` package does not always pull the
# Python side in, so it gets installed on demand - once; a failed install is remembered so it
# cannot slow every later job down.
function Get-DemPython {
    if ($script:DemPython) { return $script:DemPython }
    $o4w = 'C:\OSGeo4W\OSGeo4W.bat'
    if (-not (Test-Path $o4w)) { return $null }
    $probe = Join-Path $ConfigDir 'dem-probe.py'
    # Written as a file rather than passed with -c: OSGeo4W.bat hands arguments through cmd,
    # which mangles quoted one-liners.
    Set-Content -Path $probe -Value "import numpy, osgeo.gdal" -Encoding Ascii
    foreach ($py in @('python3', 'python')) {
        try {
            & $o4w $py $probe 2>&1 | Out-Null
            if ($LASTEXITCODE -eq 0) { $script:DemPython = $py; return $py }
        } catch { }
    }
    return $null
}

function Install-DemPython {
    $marker = Join-Path $ConfigDir 'dem-python-install.tried'
    if (Test-Path $marker) { return $null }
    New-Item -ItemType File -Path $marker -Force | Out-Null
    try {
        Log 'Installing the GDAL Python bindings + numpy (needed for the ground-surface step)...'
        $setup = Join-Path $TempDir 'osgeo4w-setup.exe'
        Invoke-WebRequest 'https://download.osgeo.org/osgeo4w/v2/osgeo4w-setup.exe' -OutFile $setup
        $p = Start-Process $setup -ArgumentList '--quiet-mode', '--no-desktop', '--advanced',
            '--arch', 'x86_64', '--site', 'https://download.osgeo.org/osgeo4w/v2', '--only-site',
            '--packages', 'python3-gdal,python3-numpy', '--root', 'C:\OSGeo4W' -Wait -PassThru
        $p.WaitForExit()
        $script:DemPython = $null
        return (Get-DemPython)
    } catch {
        Log "GDAL Python install failed: $($_.Exception.Message)"
        return $null
    }
}

# A python that can train the weed classifier: torch + torchvision + pillow + numpy inside the
# OSGeo4W python (same interpreter the DEM step uses). PyPI's Windows torch wheels are CPU-only,
# which is deliberate — a few hundred 224px crops train in minutes on this box's cores, and CPU
# wheels sidestep every CUDA-version fragility. Install is attempted once (DEM-python semantics:
# delete the marker file to retry after fixing whatever broke).
function Get-TrainPython {
    # Local EAP: under the script-wide 'Stop', a native tool writing to a REDIRECTED stderr
    # raises NativeCommandError in this console-less PS 5.1 host (two prior incidents in this
    # file) — a mere deprecation warning from a healthy python would fail the probe.
    $ErrorActionPreference = 'Continue'
    if ($script:TrainPython) { return $script:TrainPython }
    $o4w = 'C:\OSGeo4W\OSGeo4W.bat'
    if (-not (Test-Path $o4w)) { return $null }
    $probe = Join-Path $ConfigDir 'train-probe.py'
    # onnxruntime is part of the probe ON PURPOSE: it powers the trainer's export-fidelity gate,
    # and a python that merely has torch would pass a weaker probe, skip the install, and let
    # the gate silently no-op — the exact broken-export defect it exists to catch.
    Set-Content -Path $probe -Value "import torch, torchvision, PIL, numpy, onnx, onnxruntime" -Encoding Ascii
    foreach ($py in @('python3', 'python')) {
        try {
            & $o4w $py $probe 2>&1 | Out-Null
            if ($LASTEXITCODE -eq 0) { $script:TrainPython = $py; return $py }
        } catch { }
    }
    return $null
}

function Install-TrainPython {
    # Local EAP (same reason as Get-TrainPython): pip routinely writes progress/warnings to
    # stderr, and with 2>&1 under 'Stop' that would abort the one-shot install spuriously and
    # burn the marker — the fallback line would never even run.
    $ErrorActionPreference = 'Continue'
    # Versioned marker: when the dependency list grows, boxes that burned the old marker still
    # get exactly one attempt at the new set.
    $marker = Join-Path $ConfigDir 'train-python-install.tried-v2'
    if (Test-Path $marker) { return $null }
    New-Item -ItemType File -Path $marker -Force | Out-Null
    $o4w = 'C:\OSGeo4W\OSGeo4W.bat'
    if (-not (Test-Path $o4w)) { Log 'Classifier training needs OSGeo4W (GDAL) installed first - re-run install-worker.ps1'; return $null }
    try {
        Log 'Installing torch/torchvision/pillow for classifier training (one-time, ~200 MB)...'
        & $o4w python3 -m pip --version 2>&1 | Out-Null
        if ($LASTEXITCODE -ne 0) { & $o4w python3 -m ensurepip --default-pip 2>&1 | Out-Null }
        $out = (& $o4w python3 -m pip install --quiet torch torchvision pillow numpy onnx onnxruntime 2>&1 | Out-String).Trim()
        if ($LASTEXITCODE -ne 0) { throw ("pip install failed" + $(if ($out) { ": $($out.Substring([Math]::Max(0, $out.Length - 400)))" } else { '' })) }
        $script:TrainPython = $null
        return (Get-TrainPython)
    } catch {
        Log "Training python install failed: $($_.Exception.Message)"
        return $null
    }
}

# dsm.tif -> dem.tif (bare earth). Never fatal: without a DEM the app simply has no canopy-height
# gate for this flight, which is a degraded result, not a failed render.
function Build-Dem($JobId, $OutDir) {
    $dsm = Join-Path $OutDir 'dsm.tif'
    if (-not (Test-Path $dsm)) { return }
    $o4w = 'C:\OSGeo4W\OSGeo4W.bat'
    if (-not (Test-Path $o4w)) { Log "Job ${JobId}: ground surface skipped - GDAL is not installed"; return }

    $py = Get-DemPython
    if (-not $py) { $py = Install-DemPython }
    if (-not $py) {
        Log "Job ${JobId}: ground surface skipped - no python with numpy + GDAL bindings on this machine"
        Add-Report 'dem-skipped' @{ reason = 'python/numpy/gdal bindings unavailable' }
        return
    }

    $started = Get-Date
    try {
        Write-Status $JobId 'dem' 'Working out the ground surface under the vegetation...' 0.2
        $script = Join-Path $ConfigDir 'build-dem.py'
        Set-Content -Path $script -Value $DemScript -Encoding Ascii
        $raw = Join-Path $OutDir 'dem.raw.tif'
        Remove-Item $raw -Force -ErrorAction SilentlyContinue
        $out = (& $o4w $py $script $dsm $raw 2>&1 | Out-String).Trim()
        if ($LASTEXITCODE -ne 0 -or -not (Test-Path $raw)) {
            throw ("build-dem exited $LASTEXITCODE" + $(if ($out) { ": $($out.Substring(0, [Math]::Min(400, $out.Length)))" } else { '' }))
        }
        if ($out) { Log "Job ${JobId}: $out" }

        Write-Status $JobId 'dem' 'Optimizing the ground surface...' 0.8
        $dem = Join-Path $OutDir 'dem.tif'
        # Beats while it runs. Third and last instance of this pattern: the ortho COG and the
        # north-align warp were converted one at a time, each after it had already gone
        # silent long enough to look wedged. Converting the known ones together rather than
        # waiting for this one to bite too.
        # PREDICTOR=YES — the DEM is float, so this is the floating-point predictor: lossless,
        # and the same large win the DSM gets (see the shared COG translate above).
        $drc = Invoke-ToolWithBeat $JobId 'dem' 'Optimizing the ground surface...' $o4w `
            @('gdal_translate', '-of', 'COG', '-co', 'COMPRESS=DEFLATE', '-co', 'PREDICTOR=YES',
              '-co', 'NUM_THREADS=ALL_CPUS', '-co', 'BIGTIFF=IF_SAFER', '-co', 'OVERVIEWS=AUTO', $raw, $dem) 0.8
        # $drc, NOT $LASTEXITCODE: the call now goes through a function, so $LASTEXITCODE holds
        # whatever ran last INSIDE it and says nothing about gdal_translate.
        if ($drc -eq 0 -and (Test-Path $dem)) {
            Remove-Item $raw -Force -ErrorAction SilentlyContinue
        } else {
            Remove-Item $dem -Force -ErrorAction SilentlyContinue
            Rename-Item $raw 'dem.tif'      # plain GeoTIFF still imports fine
        }
        $secs = [int]((Get-Date) - $started).TotalSeconds
        Log "Job ${JobId}: ground surface (DEM) built from the DSM in ${secs}s"
        Add-Report 'dem-built' @{ seconds = $secs; note = $out }
    } catch {
        Log "Job ${JobId}: ground surface step failed - $($_.Exception.Message)"
        Add-Report 'dem-failed' @{ message = $_.Exception.Message }
        Remove-Item (Join-Path $OutDir 'dem.raw.tif') -Force -ErrorAction SilentlyContinue
    }
}


function Invoke-Job($JobId) {
    $jobDir = Join-Path $WorkDir $JobId
    $photoDir = Join-Path $jobDir 'photos'
    $outDir = Join-Path $jobDir 'out'
    New-Item -ItemType Directory -Force -Path $photoDir, $outDir | Out-Null

    $script:JobStarted = Get-Date
    $script:StageIndex = 1   # step 1 is always fetching the photos
    $script:StageCount = 0   # real total lands once the phase list for this depth is known
    $script:LastCliDetail = $null
    $script:EpicRetryUsed = $false  # the Epic-lock retry is once PER JOB, not once per worker life
    $script:PhaseRetries = 0        # and so is the count of them the app reads off status.json
    $script:Delivered = @()         # artefacts already sent ahead (see Publish-Artifact)
    $script:StagePlan = $null       # filled once the depth's phase list is known
    $script:Report = [ordered]@{
        jobId = $JobId
        worker = $env:COMPUTERNAME
        startedAt = (Get-Date).ToUniversalTime().ToString('o')
        stages = @()
    }

    try {
        Write-Status $JobId 'claimed' 'Cloud GPU claimed the job'
        Add-Report 'claimed'
        $manifest = $null
        try {
            $manifestRaw = aws s3 cp "s3://$Bucket/jobs/$JobId/manifest.json" - --no-progress 2>$null
            if ($manifestRaw) { $manifest = $manifestRaw | ConvertFrom-Json }
        } catch { }
        # NO GPU, NO RENDER - and say so NOW. Without this the job runs all the way to the
        # RealityScan launch, which puts up "could not find a usable NVIDIA graphics card" on a
        # desktop nobody is looking at, and the operator sees only a two-minute jam and a wedged
        # machine. Re-probed per job on purpose: a driver repaired by hand between jobs is picked
        # up without restarting the worker.
        $gpu = Confirm-GpuOrRepair
        if (-not $gpu.ok) {
            $msg = "This render machine has no working GPU driver, so the job was not started ($($gpu.reason)). The machine repairs its own driver on the next restart; if this keeps happening its NVIDIA driver needs reinstalling."
            Log "Job ${JobId}: refused - $msg"
            Add-Report 'gpu-unavailable' @{ reason = "$($gpu.reason)" }
            Write-Status $JobId 'error' $msg
            Save-JobTelemetry $JobId 'unknown' 0 $false 'error' $msg $manifest
            return
        }
        $epsg = if ($manifest -and $manifest.params -and $manifest.params.exportEpsg) { $manifest.params.exportEpsg } else { 2193 }
        # Resolved HERE, in the function that uses it for the DEM decision and the telemetry, and
        # passed down. Reading it inside Invoke-RealityScan made it local to that function and
        # left this one's copy empty (see the note on Invoke-RealityScan).
        $depth = if ($manifest -and $manifest.params -and $manifest.params.depth) { "$($manifest.params.depth)" } else { 'full' }
        # The app's output checklist (any of ortho2dDetailed/ortho2d/dsm/dem/model3d). Absent on an
        # older manifest, in which case every gate below falls back to $depth exactly as before.
        $outputs = if ($manifest -and $manifest.params -and $manifest.params.outputs) { @($manifest.params.outputs) } else { $null }
        $want = Resolve-Wanted $outputs $depth
        # WHICH MESH, decided by the app from the checklist alone (cloudOutputs.meshDetailFor).
        # 'normal' arrives only for a Standard-2D-ortho-only job. Anything else — including the key
        # being absent, an older app, or a value this worker does not recognise — is High, so the
        # default is always the accurate one and no fault can select the coarse mesh.
        $meshDetail = if ($manifest -and $manifest.params -and "$($manifest.params.meshDetail)" -eq 'normal') { 'normal' } else { 'high' }
        # WHAT EACH RASTER SHOULD SHIP AT, in metres per pixel, keyed by product id. The projection
        # is built at the FINEST of these, so a product wanting less is downsampled on export --
        # which is where a low tier buys its speed, its smaller download and a lighter raster for
        # the app to hold. Absent (an older app) means "ship whatever the projection produced",
        # which is the accurate answer and never the cheap one.
        $script:ExportGsd = @{}
        if ($manifest -and $manifest.params -and $manifest.params.exportGsdM) {
            foreach ($prop in $manifest.params.exportGsdM.PSObject.Properties) {
                $v = 0.0; if ([double]::TryParse("$($prop.Value)", [ref]$v) -and $v -gt 0) { $script:ExportGsd[$prop.Name] = $v }
            }
            if ($script:ExportGsd.Count) { Log "Job ${JobId}: export resolutions $(($script:ExportGsd.GetEnumerator() | ForEach-Object { "$($_.Key)=$([Math]::Round($_.Value*100,1))cm" }) -join ', ')" }
        }
        if ($meshDetail -eq 'normal') { Log "Job ${JobId}: checklist asks for the Standard 2D ortho alone - standard-detail mesh" }
        # What the PHOTOS actually resolve, measured by the app from focal length, altitude and
        # image width before the upload. Absent (an older app, or a flight whose EXIF does not
        # carry enough) means "leave RealityScan's own sizing alone" - never a guess, because
        # guessing low throws away detail that cannot be recovered without re-rendering.
        $script:TargetOrthoGsdM = 0
        if ($manifest -and $manifest.params -and $manifest.params.orthoGsdM) {
            $g = [double]$manifest.params.orthoGsdM
            # Sanity band: a drone ortho is millimetres to tens of centimetres per pixel. Outside
            # that the figure is not a GSD and must not be allowed to resize anything.
            if ($g -ge 0.002 -and $g -le 0.5) { $script:TargetOrthoGsdM = $g }
            else { Log "Job ${JobId}: ignoring an implausible target pixel size of $g m" }
        }
        # For the photo-supported fallback in Build-JobOrtho: when the app's GSD turns out to be
        # nonsense against the real region, the photo count bounds what the flight can resolve.
        $script:JobPhotoCount = if ($manifest -and $manifest.photoCount) { [int]$manifest.photoCount } else { 0 }
        $script:FinalOrthoGsdM = 0
        # Per-job quality state: refusal reasons raised by Build-JobOrtho / Build-TextureBudget
        # (never-degrade policy) and the final grid recorded for the strip planner.
        $script:OrthoRefuseReason = $null
        $script:TextureRefuseReason = $null
        $script:PlannedGridRows = 0; $script:PlannedGridCols = 0; $script:PlannedGridGsdM = 0

        # 'optimize' jobs skip RealityScan entirely: download one GeoTIFF, COG-convert it on this
        # machine's cores, send it back. (Accelerates imports of orthos made in other programs.)
        if ($manifest -and $manifest.type -eq 'optimize') {
            Write-Status $JobId 'downloading' 'Fetching the ortho from S3'
            $inDir = Join-Path $jobDir 'input'
            New-Item -ItemType Directory -Force -Path $inDir | Out-Null
            aws s3 sync "s3://$Bucket/jobs/$JobId/input" $inDir --only-show-errors
            if ($LASTEXITCODE -ne 0) { throw 'Ortho download from S3 failed' }
            $tif = Get-ChildItem $inDir -File | Where-Object { $_.Name -match '\.tiff?$' } | Select-Object -First 1
            if (-not $tif) { throw 'No GeoTIFF found in the optimize job' }
            if (-not (Test-Path 'C:\OSGeo4W\OSGeo4W.bat')) { throw 'GDAL is not installed on the worker - re-run install-worker.ps1' }
            Write-Status $JobId 'processing' 'Optimizing GeoTIFF (COG)...' 0.5
            Copy-Item $tif.FullName (Join-Path $outDir 'ortho.tif')
            Optimize-GeoTiffs $JobId $outDir
            Write-Status $JobId 'uploading' 'Uploading the optimized ortho'
            aws s3 sync $outDir "s3://$Bucket/jobs/$JobId/results" --only-show-errors
            if ($LASTEXITCODE -ne 0) { throw 'Result upload to S3 failed' }
            Write-Status $JobId 'done' 'Complete' 1
            Log "Job ${JobId}: optimize job done"
            Save-JobTelemetry $JobId 'optimize' 1 $true 'done' $null $manifest
            return
        }

        # 'weedtrain' jobs skip RealityScan too: fine-tune the operator's own weed crop
        # classifier from the label crops the app synced to training/<weedId>/, and publish
        # model + metrics for the app's sweep to load. The trainer (train-weed.py) is fetched
        # fresh from S3 beside this worker script so it can evolve without an AMI change; it
        # owns the honesty gate — exit 3 with a plain reason means "not publishable", and that
        # reason is what the operator sees. Never touches the photos/render pipeline.
        if ($manifest -and $manifest.type -eq 'weedtrain') {
            $weedId = "$($manifest.weedId)"
            if (-not $weedId) { throw 'weedtrain manifest carries no weedId' }
            Write-Status $JobId 'downloading' 'Fetching the training labels'
            $trainDir = Join-Path $jobDir 'training'
            New-Item -ItemType Directory -Force -Path $trainDir | Out-Null
            aws s3 sync "s3://$Bucket/training/$weedId" $trainDir --only-show-errors
            if ($LASTEXITCODE -ne 0) { throw 'Training data download from S3 failed' }
            $trainer = Join-Path $ConfigDir 'train-weed.py'
            if ((Invoke-AwsQuiet s3 cp "s3://$Bucket/worker/train-weed.py" $trainer --only-show-errors) -ne 0 -or -not (Test-Path $trainer)) {
                throw 'Could not fetch train-weed.py from S3 (publish it at worker/train-weed.py)'
            }
            $py = Get-TrainPython
            if (-not $py) { $py = Install-TrainPython }
            if (-not $py) { throw 'This box has no python with torch/torchvision and the one-time install failed - see the worker log' }

            Write-Status $JobId 'processing' 'Training your weed classifier (takes a few minutes)...' 0.3
            # Own process loop (not Invoke-ToolWithBeat) because the REFUSED reason on the
            # trainer's stdout must reach the job status verbatim.
            $o4w = 'C:\OSGeo4W\OSGeo4W.bat'
            $psi = New-Object System.Diagnostics.ProcessStartInfo
            $psi.FileName = $o4w
            $psi.Arguments = "$py `"$trainer`" `"$trainDir`" `"$outDir`""
            $psi.UseShellExecute = $false
            $psi.RedirectStandardOutput = $true
            $psi.RedirectStandardError = $true
            $psi.CreateNoWindow = $true
            $p = [System.Diagnostics.Process]::Start($psi)
            $so = $p.StandardOutput.ReadToEndAsync()
            $se = $p.StandardError.ReadToEndAsync()
            $t0 = Get-Date
            while (-not $p.WaitForExit(15000)) {
                $mins = [int]((Get-Date) - $t0).TotalMinutes
                Write-Status $JobId 'processing' "Training your weed classifier...$(if ($mins -ge 1) { " - $mins min in" })" 0.5
            }
            $p.WaitForExit()
            $trainOut = ''
            try { $trainOut = ($so.Result + "`n" + $se.Result).Trim() } catch { }
            if ($trainOut) { Log "Job ${JobId}: trainer said: $($trainOut -replace '\s+', ' ' | ForEach-Object { $_.Substring(0, [Math]::Min(1500, $_.Length)) })" }
            if ($p.ExitCode -ne 0) {
                $refused = ($trainOut -split "`n" | Where-Object { $_ -match '^REFUSED:' } | Select-Object -First 1)
                if ($refused) { throw ($refused -replace '^REFUSED:\s*', 'Training refused: ') }
                throw "Classifier training exited $($p.ExitCode) - see the worker log"
            }
            $modelFile = Join-Path $outDir 'model.onnx'
            $metricsFile = Join-Path $outDir 'metrics.json'
            if (-not (Test-Path $modelFile) -or -not (Test-Path $metricsFile)) { throw 'Trainer exited 0 but did not write model.onnx + metrics.json' }

            Write-Status $JobId 'uploading' 'Publishing the trained classifier' 0.95
            # Versioned prefix + a single pointer object written LAST. Uploading into a fixed
            # prefix could pair a new model with old metrics whenever the second upload failed
            # on a RETRAIN (the first publish was safe, later ones were not) — an immutable
            # v<stamp>/ pair plus an atomic latest.json pointer can never serve a mixed pair.
            $ver = 'v' + (Get-Date).ToUniversalTime().ToString('yyyyMMddHHmmss')
            Invoke-AwsQuiet s3 cp $modelFile "s3://$Bucket/models/weeds/$weedId/$ver/model.onnx" --only-show-errors | Out-Null
            if ($LASTEXITCODE -ne 0) { throw 'Model upload to S3 failed' }
            Invoke-AwsQuiet s3 cp $metricsFile "s3://$Bucket/models/weeds/$weedId/$ver/metrics.json" --only-show-errors | Out-Null
            if ($LASTEXITCODE -ne 0) { throw 'Metrics upload to S3 failed' }
            $ptr = Join-Path $outDir 'latest.json'
            @{ prefix = $ver; publishedAt = (Get-Date).ToUniversalTime().ToString('o') } | ConvertTo-Json | Set-Content -Path $ptr -Encoding Ascii
            Invoke-AwsQuiet s3 cp $ptr "s3://$Bucket/models/weeds/$weedId/latest.json" --only-show-errors | Out-Null
            if ($LASTEXITCODE -ne 0) { throw 'Model pointer upload to S3 failed' }
            $auc = ''
            try { $auc = " (validation AUC $(([Math]::Round((Get-Content $metricsFile -Raw | ConvertFrom-Json).valAuc, 3)))" + ')' } catch { }
            Write-Status $JobId 'done' "Classifier trained and published$auc" 1
            Log "Job ${JobId}: weedtrain job done for weed $weedId$auc"
            # A finished training job leaves a job record like a render does, so its machine time
            # is on its owner's usage page rather than counted as a machine that ran no job.
            Save-JobTelemetry $JobId 'weedtrain' 0 $true 'done' $null $manifest
            return
        }

        # RealityScan's working files dwarf the photos (a full-detail render can chew through
        # 100+ GB) — refuse up front with a clear message instead of dying mid-download or,
        # worse, mid-render. The photo bytes come from the manifest.
        #
        # Test-DiskHeadroom does not just measure: it clears the RealityScan cache and any
        # abandoned job scratch FIRST, and only then decides. That ordering matters — the box
        # that filled up was carrying 105 GB of cache from jobs finished days earlier, so the
        # room to run was always there, nothing had ever reclaimed it. C: is checked too: the
        # cache used to land there and take Windows down with it.
        # x45, not the old x10: the first 4719-photo High-detail render consumed ~750 GB of cache
        # by halfway through its model stage (39.4 GB of photos), and the x10 guess let it start
        # and die 3.7 hours in. 45x photo bytes matches every measured job within ~15% and makes
        # this check refuse - with a plain reason - any flight whose full-quality cache cannot
        # fit, which is the owner's chosen behaviour (refuse honestly, never degrade quality).
        #
        # SIZED TO THE MESH THIS JOB WILL ACTUALLY BUILD, matching the app's own guard
        # (photogrammetry.js scratchFitFor). A standard-detail mesh processes a quarter of the
        # depth-map pixels, so it needs about a quarter of the cache - and a reconnaissance flight
        # over a big block is exactly the job the app now lets through. Left at a flat x45 this
        # check refused those jobs AFTER the photos were uploaded, so the two guards disagreed and
        # the operator paid the upload to be told no by the second one.
        $cacheRatio = if ($meshDetail -eq 'normal') { 45.0 / 4.0 } else { 45.0 }
        $needGB = [Math]::Ceiling([Math]::Max(30GB, ($(if ($manifest -and $manifest.totalBytes) { [long]$manifest.totalBytes } else { 0 }) * $cacheRatio)) / 1GB)
        Log "Job ${JobId}: reserving $needGB GB of scratch for a $meshDetail-detail mesh"
        $tooTight = Test-DiskHeadroom $JobId $needGB
        if ($tooTight) { throw $tooTight }

        Write-Status $JobId 'downloading' 'Fetching your photos onto the GPU...' 0 -StageIndex 1
        $fetchStarted = Get-Date   # the fetch is timed as a stage of its own for the diagnostics feed
        # New manifests list content-addressed keys (photolib/<hash>) — fetch each by key under
        # its original name. Legacy manifests fall back to the jobs/<id>/photos sync.
        if ($manifest -and $manifest.photos) {
            # IN BATCHES, NOT ONE PROCESS PER PHOTO. The per-photo Start-Process approach turned
            # out to be quietly broken as well as slow: on the 119-photo job of 2026-08-16, 117 of
            # the 119 parallel fetches failed and the whole flight was really downloaded by the
            # one-at-a-time retry loop below — which never updates the status counter, so the app
            # showed "(0 / N)" for the entire download and it looked like nothing was happening.
            #
            # One CLI process per BATCH instead: `aws s3 cp --recursive` over photolib/ with
            # explicit --include filters fetches ~64 photos in a single launch, with the CLI's own
            # internal parallel transfers doing the moving. Two batch processes run side by side.
            # Batches land under their content hash and are renamed to the original photo names
            # afterwards (two names sharing a hash are the same bytes — the extras are copies).
            #
            # THE COUNTER IS FILES ON DISK. Not "processes that exited cleanly" — the count the
            # operator watches is Get-ChildItem on the photo folder, so it ticks up as the bytes
            # actually arrive and cannot freeze at zero while a fallback path does the real work.
            $list = @($manifest.photos)
            $total = $list.Count
            $photolib = @($list | Where-Object { $_.key -like 'photolib/*' })
            $otherKeys = @($list | Where-Object { $_.key -notlike 'photolib/*' })
            $lastBeat = Get-Date
            $beat = {
                $have = (Get-ChildItem $photoDir -File -ErrorAction SilentlyContinue).Count
                Write-Status $JobId 'downloading' "Fetching your photos onto the GPU ($have / $total)..." ($have / [Math]::Max(1, $total)) -StageIndex 1
            }
            if ($photolib.Count) {
                $batchSize = 64
                $maxProcs = 2
                $batches = @()
                for ($b = 0; $b -lt $photolib.Count; $b += $batchSize) {
                    $batches += , @($photolib[$b..([Math]::Min($b + $batchSize, $photolib.Count) - 1)])
                }
                $queue = [System.Collections.Queue]::new()
                foreach ($batch in $batches) { $queue.Enqueue($batch) }
                $running = @()
                while ($queue.Count -gt 0 -or $running.Count -gt 0) {
                    while ($running.Count -lt $maxProcs -and $queue.Count -gt 0) {
                        $batch = $queue.Dequeue()
                        $args = @('s3', 'cp', "s3://$Bucket/photolib/", "`"$photoDir`"", '--recursive', '--exclude', '*', '--only-show-errors')
                        foreach ($p in $batch) { $args += @('--include', ($p.key -replace '^photolib/', '')) }
                        $errFile = Join-Path $OutDir ("fetch-err-{0}.txt" -f [Guid]::NewGuid().ToString('N').Substring(0, 8))
                        $proc = Start-Process 'aws' -PassThru -NoNewWindow -RedirectStandardError $errFile -ArgumentList $args
                        $running += @{ proc = $proc; batch = $batch; err = $errFile }
                    }
                    Start-Sleep -Milliseconds 500
                    foreach ($r in @($running | Where-Object { $_.proc.HasExited })) {
                        if ($r.proc.ExitCode -ne 0) {
                            $why = ''
                            try { $why = (Get-Content $r.err -Raw -ErrorAction SilentlyContinue | Out-String).Trim() } catch { }
                            Log "Job ${JobId}: a fetch batch of $($r.batch.Count) exited $($r.proc.ExitCode)$(if ($why) { ": $($why.Substring(0, [Math]::Min(200, $why.Length)))" }) - the sweep below re-fetches whatever is missing"
                        }
                        Remove-Item $r.err -ErrorAction SilentlyContinue
                    }
                    $running = @($running | Where-Object { -not $_.proc.HasExited })
                    if (((Get-Date) - $lastBeat).TotalSeconds -ge 3) { $lastBeat = Get-Date; & $beat }
                }
                # Hashes -> original names. Duplicate content (one hash, several names) is copied.
                $byHash = @{}
                foreach ($p in $photolib) {
                    $h = $p.key -replace '^photolib/', ''
                    if (-not $byHash.ContainsKey($h)) { $byHash[$h] = @() }
                    $byHash[$h] += $p.name
                }
                foreach ($h in $byHash.Keys) {
                    $src = Join-Path $photoDir $h
                    if (-not (Test-Path $src)) { continue } # missing — the sweep below fetches it by name
                    $names = $byHash[$h]
                    for ($i = 1; $i -lt $names.Count; $i++) { Copy-Item $src (Join-Path $photoDir $names[$i]) -Force }
                    Rename-Item $src $names[0] -Force
                }
            }
            # Everything not fetched above — legacy keys, or stragglers from a failed batch — gets
            # the patient one-at-a-time treatment with backoff. On a healthy run this loop is empty.
            $sweep = @($otherKeys) + @($photolib | Where-Object { -not (Test-Path (Join-Path $photoDir $_.name)) })
            if ($sweep.Count) { Log "Job ${JobId}: $($sweep.Count) photo(s) left for the one-at-a-time sweep" }
            foreach ($p in $sweep) {
                $ok = $false
                for ($try = 1; $try -le 3 -and -not $ok; $try++) {
                    if ((Invoke-AwsQuiet s3 cp "s3://$Bucket/$($p.key)" (Join-Path $photoDir $p.name) --only-show-errors) -eq 0) { $ok = $true }
                    else { Start-Sleep -Seconds (5 * $try) }
                }
                if (-not $ok) { throw "Photo download from S3 failed: $($p.key) ($($p.name))" }
                if (((Get-Date) - $lastBeat).TotalSeconds -ge 3) { $lastBeat = Get-Date; & $beat }
            }
            & $beat
        } else {
            # Retry the sync — a transient S3/network hiccup shouldn't kill the whole job — and
            # keep the CLI's own error text so a real failure travels back to the app readable.
            $syncErr = ''
            $ok = $false
            for ($try = 1; $try -le 3 -and -not $ok; $try++) {
                $syncErr = (aws s3 sync "s3://$Bucket/jobs/$JobId/photos" $photoDir --only-show-errors 2>&1 | Out-String).Trim()
                if ($LASTEXITCODE -eq 0) { $ok = $true } else {
                    Log "Job ${JobId}: photo sync attempt $try failed: $syncErr"
                    Start-Sleep -Seconds (10 * $try)
                }
            }
            if (-not $ok) {
                $reason = if ($syncErr) { $syncErr.Substring(0, [Math]::Min(400, $syncErr.Length)) } else { 'no error output' }
                throw "Photo download from S3 failed after 3 attempts: $reason"
            }
        }
        $count = (Get-ChildItem $photoDir -File).Count
        # The count ON DISK, not the manifest's. This is what every photo-driven stage is really
        # sized by, and it is the denominator the learned rates are stored against — a manifest
        # that over-counts (a photo that failed to upload) would otherwise teach a rate that is
        # quietly too low for ever.
        $script:JobPhotoCount = [int]$count
        Log "Job ${JobId}: $count photos downloaded"
        Add-Report 'photos-downloaded' @{ count = $count }
        # phase-done-<stage> is the shape Save-JobTelemetry sums into stageSeconds, so every
        # non-RealityScan step (fetch, optimize, ground surface, upload, delivery) reports the
        # same way the render phases do and the feed sees the whole job, not just the render.
        Add-Report 'phase-done-downloading' @{ seconds = [int]((Get-Date) - $fetchStarted).TotalSeconds; count = $count }
        # LEARNS, like the RealityScan phases do. Save-PhaseExpectation had exactly two call sites,
        # both inside Invoke-RsPhase, so downloading/optimizing/dem/uploading were frozen at the
        # 97-photo seeds for ever while the rest of the plan drifted to whatever the last job's size
        # was — half the bar learning and half of it not is worse than neither.
        Save-PhaseExpectation 'downloading' ([int]((Get-Date) - $fetchStarted).TotalSeconds)
        if ($count -eq 0) { throw 'No photos found for this job' }
        if (Test-Cancelled $JobId) {
            Write-Status $JobId 'cancelled' 'Cancelled before processing'
            # A cancelled job is still a job that happened: recorded so the admin view can see
            # who stopped what, and how far it had got.
            Save-JobTelemetry $JobId $depth $count $false 'cancelled' $null $manifest
            return
        }

        Write-Status $JobId 'aligning' "Starting RealityScan on $count photos..." 0
        $completed = Invoke-RealityScan $JobId $photoDir $outDir $epsg $depth $outputs $meshDetail
        if (-not $completed) {
            Write-Status $JobId 'cancelled' 'Cancelled during processing'
            Save-JobTelemetry $JobId $depth $count $false 'cancelled' $null $manifest
            return
        }

        # Optimise anything the pipelined delivery did not already handle (a render that failed
        # its early upload, or an output no phase declared). Files already delivered are skipped
        # inside Publish-Artifact, so this is a safety net rather than a second pass.
        $script:StageIndex++
        $optimizeStarted = Get-Date
        Optimize-GeoTiffs $JobId $outDir $epsg
        Add-Report 'phase-done-optimizing' @{ seconds = [int]((Get-Date) - $optimizeStarted).TotalSeconds }
        # LEARNS, like the RealityScan phases do. Save-PhaseExpectation had exactly two call sites,
        # both inside Invoke-RsPhase, so downloading/optimizing/dem/uploading were frozen at the
        # 97-photo seeds for ever while the rest of the plan drifted to whatever the last job's size
        # was — half the bar learning and half of it not is worse than neither.
        Save-PhaseExpectation 'optimizing' ([int]((Get-Date) - $optimizeStarted).TotalSeconds)

        # Derive the bare-earth ground surface from the DSM (RealityScan's own DTM option costs
        # far more time inside the ortho step than this does out here).
        $script:StageIndex++
        # FULL depth only. The bare-earth DEM exists to give the canopy-height gate a ground
        # surface, and that gate is the full-depth feature; standard delivers the DSM without
        # it. Deriving it regardless would add minutes to every standard job for an output
        # nothing at that level uses.
        if ($want.dem) {
            $demStarted = Get-Date
            Build-Dem $JobId $outDir
            Add-Report 'phase-done-dem' @{ seconds = [int]((Get-Date) - $demStarted).TotalSeconds }
            # LEARNS, like the RealityScan phases do. Save-PhaseExpectation had exactly two call sites,
            # both inside Invoke-RsPhase, so downloading/optimizing/dem/uploading were frozen at the
            # 97-photo seeds for ever while the rest of the plan drifted to whatever the last job's size
            # was — half the bar learning and half of it not is worse than neither.
            Save-PhaseExpectation 'dem' ([int]((Get-Date) - $demStarted).TotalSeconds)
            # Last rung of the ladder, and the last thing the app is waiting on.
            Publish-Artifact $JobId $outDir 'dem.tif' $epsg | Out-Null
        }
        else { Log "Job ${JobId}: DEM not requested (outputs=[$($outputs -join ',')], depth '$depth')" }

        # Whatever landed in out/ goes back (ortho.tif + dsm.tif + dem.tif are what the app imports).
        Copy-Item $LogFile (Join-Path $outDir 'worker.log') -ErrorAction SilentlyContinue
        $produced = Get-ChildItem $outDir -File
        Add-Report 'outputs' @{ files = @($produced | ForEach-Object { "$($_.Name) ($([Math]::Round($_.Length / 1MB)) MB)" }) }
        if (-not ($produced | Where-Object { $_.Name -in @('ortho.tif', 'dsm.tif') })) {
            $script:LastCliDetail = "--- realityscan-stdout (tail) ---`n$(Get-LogTail (Join-Path $outDir 'realityscan-stdout.log') 30)"
            throw 'RealityScan finished but produced no ortho.tif/dsm.tif - check the CLI template and export settings (see realityscan-stdout.log)'
        }
        $script:StageIndex = $script:StageCount
        Write-Status $JobId 'uploading' 'Uploading results'
        Add-Report 'done'
        Save-Report $outDir
        # NOT the whole out\ folder. RealityScan keeps its project DATA in out\job\ - 226 files
        # and 5.7 GB of it on a real 97-photo flight, against 4.1 GB of actual outputs. Nothing
        # in Smart Drone opens any of it, so every byte was paid for twice: once uploading it
        # here, and again when the app dutifully downloaded the lot and appeared to hang on
        # "Downloading results (dsm.tif)". The .rsproj and the region/projection files stay -
        # they are kilobytes and they are what makes a job reproducible.
        $uploadStarted = Get-Date
        aws s3 sync $outDir "s3://$Bucket/jobs/$JobId/results" --only-show-errors --exclude 'job/*' --exclude '*.autosave.new'
        if ($LASTEXITCODE -ne 0) { throw 'Result upload to S3 failed' }
        # After Save-Report by necessity (the report is part of what was just uploaded), so this
        # entry reaches the diagnostics feed but not job-report.json.
        Add-Report 'phase-done-uploading' @{ seconds = [int]((Get-Date) - $uploadStarted).TotalSeconds }
        # LEARNS, like the RealityScan phases do. Save-PhaseExpectation had exactly two call sites,
        # both inside Invoke-RsPhase, so downloading/optimizing/dem/uploading were frozen at the
        # 97-photo seeds for ever while the rest of the plan drifted to whatever the last job's size
        # was — half the bar learning and half of it not is worse than neither.
        Save-PhaseExpectation 'uploading' ([int]((Get-Date) - $uploadStarted).TotalSeconds)

        $outputs = $produced | ForEach-Object { @{ name = $_.Name; bytes = $_.Length } }
        Write-Status $JobId 'done' 'Complete' 1 $outputs
        Save-JobTelemetry $JobId $depth $count $true 'done' $null $manifest
        Log "Job ${JobId}: done ($($produced.Count) files)"
    } catch {
        $msg = $_.Exception.Message
        Log "Job ${JobId}: FAILED - $msg"
        Add-Report 'error' @{ message = $msg }
        # Best effort: ship the logs + report so the failure is diagnosable from the app side.
        Copy-Item $LogFile (Join-Path $outDir 'worker.log') -ErrorAction SilentlyContinue
        Save-Report $outDir
        Invoke-AwsQuiet s3 sync $outDir "s3://$Bucket/jobs/$JobId/results" --only-show-errors --exclude 'job/*' --exclude '*.autosave.new' | Out-Null
        Write-Status $JobId 'error' $msg -Detail $script:LastCliDetail
        # Record the FAILURE too. Telemetry was written on the success path only, so every model
        # built on it saw survivors and nothing else — the jobs that ran long and then died were
        # exactly the ones missing from the history. $count is not in scope on every failure
        # path (a job can die before the photos are counted), so fall back to the manifest.
        $failPhotos = if ($count) { $count } elseif ($manifest -and $manifest.photoCount) { $manifest.photoCount } else { 0 }
        Save-JobTelemetry $JobId $depth $failPhotos $false 'error' $msg $manifest
    } finally {
        # Local job files are scratch; S3 keeps the originals + results. This runs on EVERY exit
        # — finished, failed, or cancelled — and now takes RealityScan's cache with it. A
        # cancelled render was the case that leaked worst: nothing else ever cleaned up after it,
        # and tens of GB of RSTemp stayed behind per job until the disk was full.
        Remove-JobScratch $JobId $jobDir
    }
}

# Is a job on its way but not yet queued?
#
# The app writes jobs/<id>/pending.json before it starts uploading photos, because the manifest
# and the queue marker only appear once every photo is up. On a big batch that upload runs for a
# long time, and a GPU left running from an earlier job would otherwise see an empty queue, call
# itself idle and shut down mid-upload - the box disappearing from under the very job it was
# meant to run. A pending marker with no status.json and no cancel.json means work is coming.
#
# FRESH MARKERS ONLY. The app rewrites the marker every 2 minutes for the whole upload and deletes
# it when the upload is cancelled or fails, so a marker whose LastModified is older than
# PendingFreshMinutes belongs to an upload that has stopped (the app closed, the laptop slept, the
# line went down) and holds nothing. A marker whose startedAt is more than PendingMaxHours old
# holds nothing either, however recently it was written.
function Get-PendingJobs {
    try {
        $raw = Invoke-AwsQuietOut s3api list-objects-v2 --bucket $Bucket --prefix 'jobs/' `
            --query "Contents[?ends_with(Key, 'pending.json')].{k:Key,t:LastModified}" --output json
        $items = @(($raw -join '') | ConvertFrom-Json)
        $live = @()
        foreach ($it in $items) {
            if (-not $it.k) { continue }
            if (((Get-Date) - [datetime]$it.t).TotalMinutes -gt $PendingFreshMinutes) { continue }
            $id = ($it.k -split '/')[1]
            # Already running or already dealt with? Then it is not "coming".
            $done = Invoke-AwsQuietOut s3 ls "s3://$Bucket/jobs/$id/status.json"
            if ($done) { continue }
            $cancelled = Invoke-AwsQuietOut s3 ls "s3://$Bucket/jobs/$id/cancel.json"
            if ($cancelled) { continue }
            $started = Get-PendingStartedUtc $id
            if ($started -and ((Get-Date).ToUniversalTime() - $started).TotalHours -gt $PendingMaxHours) { continue }
            $live += $id
        }
        return $live
    } catch { return @() }
}

# The startedAt the app wrote into jobs/<id>/pending.json, as UTC, or $null when the marker cannot
# be read or carries none. Windows PowerShell leaves the ISO text as a string; PowerShell 7 turns it
# into a DateTime - both are accepted.
function Get-PendingStartedUtc($JobId) {
    try {
        $raw = Invoke-AwsQuietOut s3 cp "s3://$Bucket/jobs/$JobId/pending.json" - --no-progress
        if (-not $raw) { return $null }
        $m = ($raw -join "`n") | ConvertFrom-Json
        if (-not $m -or -not $m.startedAt) { return $null }
        if ($m.startedAt -is [datetime]) { return $m.startedAt.ToUniversalTime() }
        return [DateTimeOffset]::Parse("$($m.startedAt)", [Globalization.CultureInfo]::InvariantCulture).UtcDateTime
    } catch { return $null }
}

# ---- Rescue before shutdown --------------------------------------------------------------------
# NOTHING FINISHED MAY BE THROWN AWAY TO SAVE IDLE MINUTES.
#
# The scratch drive is instance store: stopping the machine wipes it. A job ended around the
# optimize stage, the loop went idle, and ten minutes later the worker stopped the box - taking
# a finished 1536 MB ortho and 821 MB DSM with it, neither of which had been uploaded. The idle
# check only ever asked "is a job running?", never "is there finished work on disk?".
#
# So before any shutdown, sweep the job folders for outputs that are not in S3 yet and push them.
# Whole-file compare is not worth it: presence of the key is enough, because these files are
# written once and never edited. Best effort throughout - a rescue that throws must not prevent
# the shutdown it precedes, or an unreachable S3 would keep a GPU billing all night.
function Rescue-UnuploadedOutputs {
    $wanted = @('ortho.tif', 'dsm.tif', 'dem.tif', 'model.glb', 'model.obj')
    try {
        foreach ($root in @($WorkDir, 'C:\SmartDroneJobs')) {
            if (-not (Test-Path $root)) { continue }
            foreach ($jobDir in (Get-ChildItem $root -Directory -ErrorAction SilentlyContinue)) {
                $jobId = $jobDir.Name
                $outDir = Join-Path $jobDir.FullName 'out'
                if (-not (Test-Path $outDir)) { continue }
                $files = @(Get-ChildItem $outDir -File -ErrorAction SilentlyContinue |
                    Where-Object { $wanted -contains $_.Name -and $_.Length -gt 0 })
                if (-not $files) { continue }
                $remote = @(Invoke-AwsQuietOut s3 ls "s3://$Bucket/jobs/$jobId/results/") -join "`n"
                foreach ($f in $files) {
                    if ($remote -match [regex]::Escape($f.Name)) { continue }
                    Log "RESCUE: $($f.Name) ($([Math]::Round($f.Length / 1MB)) MB) from $jobId was never uploaded - sending it to S3 before shutdown"
                    Invoke-AwsQuiet s3 cp $f.FullName "s3://$Bucket/jobs/$jobId/results/$($f.Name)" --only-show-errors | Out-Null
                }
            }
        }
    } catch {
        Log "Pre-shutdown rescue failed: $($_.Exception.Message)"
    }
}

# Like Invoke-AwsQuiet but hands back the OUTPUT, for the listing above.
function Invoke-AwsQuietOut {
    $ErrorActionPreference = 'Continue'
    try { return (& aws @args 2>$null) } catch { return @() }
}

# ---- Heartbeat and stop requests ---------------------------------------------------------------
#
# telemetry/instance/<instanceId>/alive.json is this machine's heartbeat, overwritten about once a
# minute and straight away whenever the state changes:
#   { at, state, jobId, idleSince, scriptVersion, instanceType, autoShutdown,
#     settings: { idle, quiet, rdp, fresh } }
# state is 'idle' | 'job' | 'holding-upload' | 'holding-rdp' | 'gpu-check'. The licence server
# (proxy/reaper.js) reads it: a fresh 'job' heartbeat is never touched; an idle machine well past its
# own idle setting, or one whose heartbeat has stopped, is asked to stop and then stopped.
#
# control/stop/<instanceId>.json is that request. It is honoured ONLY while the machine is idle: it
# is read about once a minute from the idle branch of the main loop and never while a job runs,
# whatever the request says. (The control/stop/ prefix is writable by the credentials every
# licensed install holds, so a request is not proof it came from the licence server; a request
# can therefore end idle time and nothing else.) A request that arrives during a job is read once
# the job has ended and the machine is idle again. Obeying it rescues unuploaded outputs, records
# the shutdown, deletes the request and stops the machine. A request written before this machine
# last booted is stale: it is deleted and ignored, so a request that outlived its machine can never
# stop the next boot.
#
# Nothing here may throw out of the loop: a heartbeat or a check that fails is logged once and
# tried again a minute later.
$script:HeartbeatAt = [datetime]::MinValue
$script:HeartbeatState = ''
$script:HeartbeatFailLogged = $false
$script:StopCheckAt = [datetime]::MinValue
$script:WorkerStartedAt = Get-Date
$script:BootedAtUtc = $script:WorkerStartedAt.ToUniversalTime()
try { $script:BootedAtUtc = (Get-CimInstance Win32_OperatingSystem -ErrorAction Stop).LastBootUpTime.ToUniversalTime() } catch { }

function Write-Heartbeat($State, $JobId = $null, $IdleSince = $null) {
    try {
        $now = Get-Date
        if ($State -eq $script:HeartbeatState -and ($now - $script:HeartbeatAt).TotalSeconds -lt 60) { return }
        $script:HeartbeatAt = $now
        $script:HeartbeatState = $State
        $since = $null
        if ($IdleSince) { $since = ([datetime]$IdleSince).ToUniversalTime().ToString('o') }
        $rec = [ordered]@{
            at            = $now.ToUniversalTime().ToString('o')
            state         = "$State"
            jobId         = $JobId
            idleSince     = $since
            scriptVersion = $ScriptVersion
            instanceType  = Get-InstanceType
            autoShutdown  = [bool]$AutoShutdownOn
            settings      = [ordered]@{ idle = $IdleShutdownMinutes; quiet = $QuietShutdownMinutes; rdp = $RdpGraceMinutes; fresh = $PendingFreshMinutes }
        }
        $tmp = Join-Path $TempDir 'sd-alive.json'
        [IO.File]::WriteAllText($tmp, ($rec | ConvertTo-Json -Depth 4))
        $rc = Invoke-AwsQuiet s3 cp $tmp "s3://$Bucket/telemetry/instance/$(Get-InstanceId)/alive.json" --no-progress
        if ($rc -eq 0) {
            $script:HeartbeatFailLogged = $false
        } elseif (-not $script:HeartbeatFailLogged) {
            $script:HeartbeatFailLogged = $true
            Log "Heartbeat not written (aws exit $rc) - tried again every minute, logged once"
        }
    } catch {
        if (-not $script:HeartbeatFailLogged) {
            $script:HeartbeatFailLogged = $true
            Log "Heartbeat not written ($($_.Exception.Message)) - tried again every minute, logged once"
        }
    }
}

# The stop request for this machine as @{ reason; key }, or $null when there is none or it cannot
# be read. A request that is there but is not JSON still counts.
function Read-StopRequest {
    $tmp = Join-Path $TempDir 'sd-stop-request.json'
    $key = "control/stop/$(Get-InstanceId).json"
    try {
        Remove-Item $tmp -Force -ErrorAction SilentlyContinue
        $meta = Invoke-AwsQuietOut s3api get-object --bucket $Bucket --key $key $tmp
        if (-not $meta -or -not (Test-Path $tmp)) { return $null }
        $written = $null
        try {
            $lm = (($meta -join "`n") | ConvertFrom-Json).LastModified
            if ($lm -is [datetime]) { $written = $lm.ToUniversalTime() }
            elseif ($lm) { $written = [DateTimeOffset]::Parse("$lm", [Globalization.CultureInfo]::InvariantCulture).UtcDateTime }
        } catch { $written = $null }
        $req = $null
        try { $req = (Get-Content $tmp -Raw) | ConvertFrom-Json } catch { $req = $null }
        $reason = 'no reason given'
        if ($req -and $req.reason) { $reason = ("$($req.reason)" -replace '[\r\n]+', ' ').Trim() }
        if ($reason.Length -gt 200) { $reason = $reason.Substring(0, 200) }
        if ($written -and $written -lt $script:BootedAtUtc) {
            Log "A stop request written before this machine booted ($reason) - removing it and carrying on"
            Invoke-AwsQuiet s3 rm "s3://$Bucket/$key" --only-show-errors | Out-Null
            return $null
        }
        return @{ reason = $reason; key = $key }
    } catch {
        return $null
    } finally {
        Remove-Item $tmp -Force -ErrorAction SilentlyContinue
    }
}

# Obeys a stop request on an idle machine: outputs on the scratch drive go to S3 first, then the
# shutdown record, then the request is deleted and the machine stops.
function Invoke-StopRequest($Request, $IdleSince = $null) {
    $idle = 0
    try { if ($IdleSince) { $idle = [int]((Get-Date) - [datetime]$IdleSince).TotalMinutes } } catch { $idle = 0 }
    Log "Stop request from the licence server ($($Request.reason)) - rescuing outputs, then shutting down"
    try { Rescue-UnuploadedOutputs } catch { }
    try { Save-InstanceEvent 'shutdown' ([ordered]@{ why = "asked by the licence server: $($Request.reason)"; idleMinutes = $idle; jobsRun = [int]$script:JobsRun }) } catch { }
    try { Invoke-AwsQuiet s3 rm "s3://$Bucket/$($Request.key)" --only-show-errors | Out-Null } catch { }
    try { Stop-Computer -Force } catch { Log "Stop-Computer failed: $($_.Exception.Message)" }
    exit
}

# About once a minute, from the idle branch of the main loop only: is there a stop request for
# this machine? If so it is obeyed. Never called while a job runs.
function Test-StopRequest($IdleSince = $null) {
    try {
        if (((Get-Date) - $script:StopCheckAt).TotalSeconds -lt 60) { return }
        $script:StopCheckAt = Get-Date
        $req = Read-StopRequest
        if (-not $req) { return }
        Invoke-StopRequest $req $IdleSince
    } catch { }
}

# The remote command channel (agent-shell.ps1) is how this box is reached without Remote Desktop,
# and it is the ONLY way in when something has gone wrong. It has its own repeating trigger, but
# a channel that is down cannot be used to bring itself back up — so the worker, which is the
# other thing always running here, checks on it. Cheap, and it costs nothing when the channel is
# healthy. (Written after stopping the channel's scheduled task from inside a command sent
# THROUGH that channel, which cut the branch off behind me.)
function Restore-AgentChannel {
    try {
        $t = Get-ScheduledTask -TaskName 'SmartDroneAgentShell' -ErrorAction SilentlyContinue
        if (-not $t) { return }
        if ($t.State -eq 'Running') { return }
        Start-ScheduledTask -TaskName 'SmartDroneAgentShell' -ErrorAction Stop
        Log 'Command channel was not running - restarted it'
    } catch {
        Log "Could not restart the command channel: $($_.Exception.Message)"
    }
}

# ---- Self-update ------------------------------------------------------------------------------
# Every start looks for a NEWER script in two places and installs the newest it finds:
#   1. the public release feed (worker-latest) — republished by CI on every app-repo build, so a
#      merged worker change deploys itself with no AWS hands involved at all;
#   2. the S3 slot — the original channel, kept as fallback and healed from the feed (below), so
#      the refresh flow and any feed outage still converge on the newest script.
# Judged by the ScriptVersion INSIDE the file, never by hash: with two sources a hash-compare
# would flip-flop between them; a strict newer-than compare converges. (Field pain that built the
# original: three stale-script incidents in two days.)
# A RAW file on the releases repo, deliberately NOT a release asset: a rolling release entry
# hijacked the app's update feed (electron-updater takes the newest releases.atom entry).
$WorkerFeedUrl = 'https://raw.githubusercontent.com/bobby500/smart-drone-releases/main/worker/smartdrone-worker.ps1'

function Get-WorkerVersionFrom($Path) {
    try {
        $m = Select-String -Path $Path -Pattern "ScriptVersion = '(\d{4}-\d{2}-\d{2})\.(\d+)'" | Select-Object -First 1
        if (-not $m) { return $null }
        return @{ date = $m.Matches[0].Groups[1].Value; rev = [int]$m.Matches[0].Groups[2].Value
                  text = "$($m.Matches[0].Groups[1].Value).$($m.Matches[0].Groups[2].Value)" }
    } catch { return $null }
}

# 1 when $a is newer than $b; -1 older; 0 same or unknowable. Date first, then revision AS A
# NUMBER (a string compare would call .100 older than .97).
function Compare-WorkerVersion($a, $b) {
    if (-not $a -or -not $b) { return 0 }
    if ($a.date -ne $b.date) { if ($a.date -gt $b.date) { return 1 } else { return -1 } }
    if ($a.rev -ne $b.rev)  { if ($a.rev -gt $b.rev)   { return 1 } else { return -1 } }
    return 0
}

function Update-Self {
    $self = Join-Path $ConfigDir 'smartdrone-worker.ps1'
    $mine = Get-WorkerVersionFrom $self
    $feedTmp = Join-Path $TempDir 'smartdrone-worker.feed.ps1'
    $s3Tmp = Join-Path $TempDir 'smartdrone-worker.s3.ps1'
    try {
        $best = $null; $bestPath = $null; $bestSource = ''
        try {
            Invoke-WebRequest $WorkerFeedUrl -OutFile $feedTmp -UseBasicParsing -TimeoutSec 30
            $v = Get-WorkerVersionFrom $feedTmp
            if ($v) { $best = $v; $bestPath = $feedTmp; $bestSource = 'release feed' }
        } catch { Log "Self-update: release feed unreachable ($($_.Exception.Message)) - trying S3" }
        if ((Invoke-AwsQuiet s3 cp "s3://$Bucket/worker/smartdrone-worker.ps1" $s3Tmp --only-show-errors) -eq 0 -and (Test-Path $s3Tmp)) {
            $v = Get-WorkerVersionFrom $s3Tmp
            if ($v -and ((Compare-WorkerVersion $v $best) -gt 0 -or -not $best)) { $best = $v; $bestPath = $s3Tmp; $bestSource = 'S3' }
        }
        if (-not $best) { return }
        if ((Compare-WorkerVersion $best $mine) -le 0 -and $mine) {
            # Already current — but if the FEED is ahead of S3, heal the S3 copy quietly so the
            # refresh flow and airgapped paths serve the newest script too.
            if ($bestSource -eq 'release feed' -and (Test-Path $s3Tmp)) {
                $s3v = Get-WorkerVersionFrom $s3Tmp
                if ((Compare-WorkerVersion $best $s3v) -gt 0) {
                    Invoke-AwsQuiet s3 cp $bestPath "s3://$Bucket/worker/smartdrone-worker.ps1" --only-show-errors | Out-Null
                    Log "Self-update: S3 copy was behind the feed - healed to $($best.text)"
                }
            }
            return
        }
        Copy-Item $bestPath $self -Force
        Log "Self-update: $($best.text) installed from $bestSource (was $(if ($mine) { $mine.text } else { 'unknown' })) - restarting the task into it"
        if ($bestSource -eq 'release feed') {
            Invoke-AwsQuiet s3 cp $self "s3://$Bucket/worker/smartdrone-worker.ps1" --only-show-errors | Out-Null
        }
        Start-Process powershell -WindowStyle Hidden -ArgumentList '-NoProfile', '-Command', 'Start-Sleep 4; Start-ScheduledTask -TaskName SmartDroneWorker'
        exit
    } catch {
        Log "Self-update check failed: $($_.Exception.Message)"
    } finally {
        Remove-Item $feedTmp, $s3Tmp -Force -ErrorAction SilentlyContinue
    }
}
Update-Self

# ---- Main loop --------------------------------------------------------------------------------
# Only ever ONE worker per machine. Two pollers double-claim the same job (S3 delete-as-claim
# returns success for both) and their concurrent photo syncs + cleanups trample each other —
# observed in the field as two 'Claimed job' lines one second apart, then a wrecked download.
# A named machine-wide mutex is the definitive guard: any second copy (scheduled task plus a
# stray manually-started window) logs and exits immediately.
$script:SingleInstance = New-Object System.Threading.Mutex($false, 'Global\SmartDroneWorker')
if (-not $script:SingleInstance.WaitOne(0)) {
    Log "Another worker instance is already running on this machine - this copy (script $ScriptVersion) is exiting"
    exit
}
$SessionId = try { (Get-Process -Id $PID).SessionId } catch { -1 }
# DISABLE CONSOLE QUICKEDIT.
#
# With QuickEdit on (the Windows default), a single click or drag inside the console window puts
# it in selection mode — the title gains a "Select" prefix — and Windows SUSPENDS the process the
# moment its output buffer fills. The worker then stops dead: no status writes, no watchdog beat,
# CPU to zero, while the last message sits on screen looking like work in progress.
#
# That is exactly what happened to job-202608062342-c40c: someone clicked in the window to read
# the log, and thirty minutes later the render had not moved. Nothing in the worker could detect
# it, because the code doing the detecting was itself suspended.
#
# ENABLE_EXTENDED_FLAGS (0x0080) must be set in the same call, or clearing QUICK_EDIT (0x0040) is
# ignored. INSERT (0x0020) goes too — it is the other half of the same mouse behaviour. Wrapped
# in try/catch and skipped when there is no console at all (the normal scheduled-task case).
try {
    if (-not ('SmartDrone.Con' -as [type])) {
        Add-Type -Namespace SmartDrone -Name Con -MemberDefinition @'
[System.Runtime.InteropServices.DllImport("kernel32.dll")]
public static extern System.IntPtr GetStdHandle(int n);
[System.Runtime.InteropServices.DllImport("kernel32.dll")]
public static extern bool GetConsoleMode(System.IntPtr h, out uint m);
[System.Runtime.InteropServices.DllImport("kernel32.dll")]
public static extern bool SetConsoleMode(System.IntPtr h, uint m);
'@ -ErrorAction Stop
    }
    $hIn = [SmartDrone.Con]::GetStdHandle(-10)   # STD_INPUT_HANDLE
    $mode = [uint32]0
    if ($hIn -ne [IntPtr]::Zero -and $hIn -ne [IntPtr](-1) -and [SmartDrone.Con]::GetConsoleMode($hIn, [ref]$mode)) {
        $new = ($mode -band (-bnot 0x0040) -band (-bnot 0x0020)) -bor 0x0080
        if ($new -ne $mode -and [SmartDrone.Con]::SetConsoleMode($hIn, $new)) {
            Log 'Console QuickEdit disabled - clicking in this window can no longer freeze the worker'
        }
    }
} catch { Log "Could not disable console QuickEdit: $($_.Exception.Message)" }

# ---- Idle settings ------------------------------------------------------------------------------
# The fleet-wide settings CI publishes beside this script. Changing them is a commit to
# worker/fleet-settings.json in the app repo: every machine picks the new values up at its next
# start, with no hands on any box.
$FleetSettingsUrl = 'https://raw.githubusercontent.com/bobby500/smart-drone-releases/main/worker/fleet-settings.json'

# The parsed fleet settings, or $null when they cannot be read (no network, no file yet, not
# JSON). A short timeout: a slow answer must not hold up the first poll.
function Read-FleetSettings {
    try {
        $r = Invoke-WebRequest $FleetSettingsUrl -UseBasicParsing -TimeoutSec 10
        return ($r.Content | ConvertFrom-Json)
    } catch {
        return $null
    }
}

# The trimmed text of worker/<Name> in the jobs bucket, or $null when there is no such object.
function Read-S3Setting($Name) {
    $tmp = Join-Path $TempDir ('sd-setting-' + $Name)
    try {
        Remove-Item $tmp -Force -ErrorAction SilentlyContinue
        if ((Invoke-AwsQuiet s3 cp "s3://$Bucket/worker/$Name" $tmp --no-progress) -eq 0 -and (Test-Path $tmp)) {
            return ((Get-Content $tmp -Raw) + '').Trim()
        }
    } catch { }
    finally { Remove-Item $tmp -Force -ErrorAction SilentlyContinue }
    return $null
}

# One idle setting from its sources, highest first. Each candidate is @{ value; source }; the first
# whose value reads as a number within [Min, Max] wins. A value outside the bounds is skipped and
# named in .skipped - a typo can neither bill all night nor shut a machine down between the jobs
# of one batch. Nothing usable gives the default.
function Select-IdleSetting($Candidates, $Min, $Max, $Default) {
    $skipped = @()
    foreach ($c in $Candidates) {
        if ($null -eq $c.value) { continue }
        $text = ("" + $c.value).Trim()
        if ($text -eq '') { continue }
        $v = 0.0
        $ok = [double]::TryParse($text, [Globalization.NumberStyles]::Float, [Globalization.CultureInfo]::InvariantCulture, [ref]$v)
        if ($ok -and $v -ge $Min -and $v -le $Max) {
            return @{ value = $v; source = $c.source; skipped = $skipped }
        }
        $skipped += ($c.source + ' (' + $text + ')')
    }
    return @{ value = $Default; source = 'default'; skipped = $skipped }
}

# Idle shutdown 2-240 minutes, Remote Desktop grace 5-240, quiet shutdown 1-60, pending-marker
# freshness 3-60: the S3 override, then the fleet settings, then config.json, then the defaults
# above. Logged with where each value came from, and carried on the boot record and every job
# record so the costs page can set the idle tail against the setting in force. A failure here keeps
# the defaults: the settings must never stop the worker.
try {
    $fleet = Read-FleetSettings
    $fleetIdle = $null
    $fleetRdp = $null
    $fleetQuiet = $null
    $fleetFresh = $null
    if ($fleet) {
        $fleetIdle = $fleet.idleShutdownMinutes
        $fleetRdp = $fleet.rdpGraceMinutes
        $fleetQuiet = $fleet.quietShutdownMinutes
        $fleetFresh = $fleet.pendingFreshMinutes
    }
    $idleCandidates = @(
        @{ value = (Read-S3Setting 'idle-minutes.txt'); source = 'S3 override' },
        @{ value = $fleetIdle; source = 'fleet settings' },
        @{ value = $Config.idleShutdownMinutes; source = 'config.json' }
    )
    $rdpCandidates = @(
        @{ value = (Read-S3Setting 'rdp-grace-minutes.txt'); source = 'S3 override' },
        @{ value = $fleetRdp; source = 'fleet settings' },
        @{ value = $Config.rdpGraceMinutes; source = 'config.json' }
    )
    $quietCandidates = @(
        @{ value = (Read-S3Setting 'quiet-minutes.txt'); source = 'S3 override' },
        @{ value = $fleetQuiet; source = 'fleet settings' },
        @{ value = $Config.quietShutdownMinutes; source = 'config.json' }
    )
    $freshCandidates = @(
        @{ value = (Read-S3Setting 'pending-fresh-minutes.txt'); source = 'S3 override' },
        @{ value = $fleetFresh; source = 'fleet settings' },
        @{ value = $Config.pendingFreshMinutes; source = 'config.json' }
    )
    $idlePick = Select-IdleSetting $idleCandidates 2 240 3
    $rdpPick = Select-IdleSetting $rdpCandidates 5 240 15
    $quietPick = Select-IdleSetting $quietCandidates 1 60 1
    $freshPick = Select-IdleSetting $freshCandidates 3 60 8
    $IdleShutdownMinutes = $idlePick.value
    $IdleSource = $idlePick.source
    $RdpGraceMinutes = $rdpPick.value
    $RdpGraceSource = $rdpPick.source
    $QuietShutdownMinutes = $quietPick.value
    $QuietSource = $quietPick.source
    $PendingFreshMinutes = $freshPick.value
    $PendingFreshSource = $freshPick.source
    $ignored = @($idlePick.skipped) + @($rdpPick.skipped) + @($quietPick.skipped) + @($freshPick.skipped)
    Log ("Idle settings: shutdown after ${IdleShutdownMinutes} min idle ($IdleSource), Remote Desktop grace ${RdpGraceMinutes} min ($RdpGraceSource), quiet shutdown after ${QuietShutdownMinutes} min with nothing coming ($QuietSource), upload markers fresh for ${PendingFreshMinutes} min ($PendingFreshSource)" + $(if ($ignored.Count) { '; out of bounds and ignored: ' + ($ignored -join ', ') } else { '' }))
} catch {
    Log "Idle settings could not be resolved ($($_.Exception.Message)) - using ${IdleShutdownMinutes} min idle, ${RdpGraceMinutes} min Remote Desktop grace, ${QuietShutdownMinutes} min quiet shutdown and ${PendingFreshMinutes} min upload-marker freshness"
}

# Also on STARTUP, not just before shutdown. A worker RESTART leaves the scratch disk intact
# but abandons whatever the previous run was partway through - and the pre-shutdown rescue does
# not fire, because nothing shut down. That hole was found by falling through it: a restart to
# pick up a new script left a finished 1518 MB ortho and 791 MB DSM sitting on disk, uploaded
# afterwards only because someone happened to check. Sweeping here means an interrupted run's
# outputs are recovered by the next one automatically.
Rescue-UnuploadedOutputs

# A clean slate to start from: RealityScan's cache and any job scratch left by a previous run.
# On a box with an instance store this is usually a no-op (the drive is wiped on stop/start); on
# one that only ever reboots it is the difference between running and filling up.
Clear-RsCache | Out-Null
Clear-OldJobDirs

Log "Worker started (script $ScriptVersion, bucket $Bucket, session $SessionId, workDir $WorkDir [$(Get-FreeGB $WorkDir) GB free, C: $(Get-FreeGB 'C:\') GB free], RealityScan cache $RsTempDir, poll ${PollSeconds}s, idle shutdown ${IdleShutdownMinutes}m, Remote Desktop grace ${RdpGraceMinutes}m, quiet shutdown ${QuietShutdownMinutes}m, upload markers fresh ${PendingFreshMinutes}m)"
Sync-SettingsFiles
Restore-AgentChannel
# First entry in this boot's timeline for the admin diagnostics feed (see Save-InstanceEvent),
# with the idle settings this boot runs under.
Save-InstanceEvent 'boot' ([ordered]@{ idleShutdownMinutes = $IdleShutdownMinutes; rdpGraceMinutes = $RdpGraceMinutes; quietShutdownMinutes = $QuietShutdownMinutes; pendingFreshMinutes = $PendingFreshMinutes })
# The first heartbeat: the GPU check below can install a driver and reboot, and the licence server
# gives a machine in 'gpu-check' 20 minutes before it counts it as idle.
Write-Heartbeat 'gpu-check' $null $script:WorkerStartedAt
# CAN THIS MACHINE RENDER? Asked before the loop can claim a single job, because a box with no
# usable GPU cannot do the work and the failure is otherwise invisible until RealityScan is
# already up and waiting behind a modal error box. A missing driver is installed and the machine
# reboots into it; see Confirm-GpuOrRepair.
$gpuState = Confirm-GpuOrRepair -AllowReboot
if ($gpuState.ok) {
    Log "GPU ready: $($gpuState.name) (driver $($gpuState.driver))"
} else {
    Log "WARNING: this machine has NO USABLE GPU ($($gpuState.reason)). Jobs it claims will be failed immediately with that reason rather than left to hang - its NVIDIA driver needs reinstalling by hand."
}
if ($SessionId -eq 0) {
    Log "WARNING: this worker is running in Windows session 0 (non-interactive). RealityScan is a GPU/GUI application and will HANG there with no window and no GPU. Run fix-session.ps1 to switch the task to an interactive logon session."
}
$lastWork = Get-Date
while ($true) {
    try {
        $jobId = Get-NextJob
        if ($jobId) {
            Log "Claimed job $jobId"
            Invoke-Job $jobId
            $script:JobsRun = [int]$script:JobsRun + 1
            $lastWork = Get-Date
            $script:RdpHoldLogged = $false
            Restore-AgentChannel   # a long render is plenty of time for the channel to die
        } else {
            $idleMin = ((Get-Date) - $lastWork).TotalMinutes
            $idleState = 'idle'
            # Which clock applies depends on what might be coming. Nothing queued (this poll found
            # no job) and no fresh pending marker anywhere: the QUIET shutdown, after
            # QuietShutdownMinutes. A fresh marker (a job uploading its photos): held while the
            # marker stays fresh, and never stopped before IdleShutdownMinutes. Someone on Remote
            # Desktop: RdpGraceMinutes. The first decision therefore comes at the shorter of the
            # quiet and idle settings.
            $firstCheckMin = [Math]::Min($QuietShutdownMinutes, $IdleShutdownMinutes)
            if ($AutoShutdownOn -and $idleMin -ge $firstCheckMin) {
                # Someone working over Remote Desktop gets a GRACE PERIOD, not an indefinite
                # reprieve — an RDP session left open used to keep a $2/h machine alive all
                # night. quser writes 'No User exists for *' to stderr when nobody is logged
                # in; under the Stop preference that became a loop error that skipped the
                # whole idle check, so it stays EA-relaxed here.
                $rdpActive = $null
                try {
                    $ErrorActionPreference = 'Continue'
                    $rdpActive = (quser 2>$null | Select-String 'Active')
                } finally {
                    $ErrorActionPreference = 'Stop'
                }
                if ($rdpActive -and $idleMin -lt $RdpGraceMinutes) {
                    $idleState = 'holding-rdp'
                    if (-not $script:RdpHoldLogged) {
                        $script:RdpHoldLogged = $true
                        Log "Idle for $([int]$idleMin) min but someone is on Remote Desktop - holding the shutdown until $RdpGraceMinutes min idle"
                    }
                } else {
                    # A job mid-upload is not idleness. Checked here, at the last moment, rather
                    # than in the poll loop - one S3 list per shutdown decision, not per poll.
                    $pending = Get-PendingJobs
                    if ($pending.Count) {
                        $idleState = 'holding-upload'
                        if (-not $script:PendingHoldLogged) {
                            $script:PendingHoldLogged = $true
                            Log "Idle for $([int]$idleMin) min but $($pending.Count) job(s) are still uploading photos - holding the shutdown while the upload marker stays fresh"
                        }
                    } elseif ($rdpActive -or $idleMin -ge $QuietShutdownMinutes) {
                        $script:PendingHoldLogged = $false
                        $why = "idle $([int]$idleMin) min"
                        if ($rdpActive) { $why = "idle $([int]$idleMin) min (past the ${RdpGraceMinutes}m Remote Desktop grace)" }
                        elseif ($idleMin -lt $IdleShutdownMinutes) { $why = "idle $([int]$idleMin) min with nothing queued or uploading (quiet shutdown after ${QuietShutdownMinutes}m)" }
                        Rescue-UnuploadedOutputs
                        Log "Shutting down to stop billing - $why"
                        # Last entry in this boot's timeline: why it stopped, and what it did.
                        Save-InstanceEvent 'shutdown' ([ordered]@{ why = $why; idleMinutes = [int]$idleMin; jobsRun = [int]$script:JobsRun })
                        Stop-Computer -Force
                        exit
                    }
                }
            }
            # What this machine is doing, for the licence server, and whether it has been asked to
            # stop. Both at most once a minute; neither can throw.
            Write-Heartbeat $idleState $null $lastWork
            Test-StopRequest $lastWork
        }
        $script:LoopErrors = 0
    } catch {
        # DEAD-MAN FOR A WORKER THAT CANNOT WORK. A loop error here is infrastructure-level (S3
        # unreachable, auth broken, disk gone) — Invoke-Job catches its own failures. One error is
        # a blip; forty in a row (~10 min) is a machine that can neither take a job nor run its
        # idle check, and until now that state billed indefinitely because the shutdown decision
        # lived INSIDE the try that kept throwing. Rescue what's on disk, then stop the box; the
        # app restarts it when there is real work and a working worker.
        $script:LoopErrors = [int]$script:LoopErrors + 1
        Log "Loop error ($($script:LoopErrors) in a row): $($_.Exception.Message)"
        if ($AutoShutdownOn -and $script:LoopErrors -ge 40) {
            Log 'Forty consecutive loop errors - this worker cannot work or judge idleness. Shutting down to stop billing.'
            try { Rescue-UnuploadedOutputs } catch { }
            # Guarded twice over: this runs inside the catch, and a throw here would skip the
            # shutdown the whole block exists to guarantee.
            try {
                Save-InstanceEvent 'shutdown' ([ordered]@{ why = 'forty consecutive loop errors'; idleMinutes = [int]((Get-Date) - $lastWork).TotalMinutes; jobsRun = [int]$script:JobsRun })
            } catch { }
            Stop-Computer -Force
            exit
        }
    }
    Start-Sleep -Seconds $PollSeconds
}
