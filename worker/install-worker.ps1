# Smart Drone GPU worker installer — run ONCE on the cloud GPU machine (as Administrator).
# Sets up: AWS CLI (if missing), C:\SmartDroneWorker\{config.json, smartdrone-worker.ps1},
# and a scheduled task that starts the worker at every boot. After this, the machine processes
# photogrammetry jobs from the Smart Drone app completely hands-off and powers itself down
# when idle.

$ErrorActionPreference = 'Stop'
$ConfigDir = 'C:\SmartDroneWorker'
New-Item -ItemType Directory -Force -Path $ConfigDir | Out-Null

Write-Host ''
Write-Host '=== Smart Drone GPU worker setup ===' -ForegroundColor Green
Write-Host 'Paste the same AWS keys used in the Smart Drone app (View > AI Detection > Cloud processing).'
$accessKey = Read-Host 'AWS Access Key ID'
$secretKey = Read-Host 'AWS Secret Access Key'
if (-not $accessKey -or -not $secretKey) { throw 'Both keys are required.' }

# ---- AWS CLI ---------------------------------------------------------------------------------
if (-not (Get-Command aws -ErrorAction SilentlyContinue)) {
    Write-Host 'Installing AWS CLI v2...'
    $msi = Join-Path $env:TEMP 'AWSCLIV2.msi'
    Invoke-WebRequest 'https://awscli.amazonaws.com/AWSCLIV2.msi' -OutFile $msi
    Start-Process msiexec.exe -ArgumentList "/i `"$msi`" /qn" -Wait
    $env:Path = [Environment]::GetEnvironmentVariable('Path', 'Machine')
    if (-not (Get-Command aws -ErrorAction SilentlyContinue)) { throw 'AWS CLI install failed - install it manually then re-run.' }
}

# ---- Config ----------------------------------------------------------------------------------
$config = [ordered]@{
    accessKeyId = $accessKey
    secretAccessKey = $secretKey
    region = 'ap-southeast-2'
    bucket = 'smartdrone-jobs-232812966415'
    workDir = 'C:\SmartDroneJobs'
    pollSeconds = 15
    idleShutdownMinutes = 10
    autoShutdown = $true
    rsExe = 'auto'
}
$configPath = Join-Path $ConfigDir 'config.json'
$config | ConvertTo-Json | Set-Content -Path $configPath -Encoding UTF8
# Keys inside — lock the folder down to Administrators + SYSTEM.
icacls $ConfigDir /inheritance:r /grant 'Administrators:(OI)(CI)F' /grant 'SYSTEM:(OI)(CI)F' | Out-Null

# ---- Worker script ---------------------------------------------------------------------------
# Installed from the same S3 bucket (uploaded by the Smart Drone build); keeps a local copy.
$env:AWS_ACCESS_KEY_ID = $accessKey
$env:AWS_SECRET_ACCESS_KEY = $secretKey
$env:AWS_DEFAULT_REGION = $config.region
aws s3 cp "s3://$($config.bucket)/worker/smartdrone-worker.ps1" (Join-Path $ConfigDir 'smartdrone-worker.ps1') --no-progress
if ($LASTEXITCODE -ne 0) { throw 'Could not download the worker script from S3 - check the keys.' }

# ---- GDAL (optional, best-effort) ------------------------------------------------------------
# With GDAL present the worker converts RealityScan's exports into ready-to-use Cloud Optimized
# GeoTIFFs BEFORE upload, so the app imports them with a plain file copy instead of minutes of
# local processing. If this step fails the pipeline still works — the app just optimises locally.
if (-not (Test-Path 'C:\OSGeo4W\OSGeo4W.bat')) {
    try {
        Write-Host 'Installing GDAL (OSGeo4W, ~200 MB - a few minutes)...'
        $o4w = Join-Path $env:TEMP 'osgeo4w-setup.exe'
        Invoke-WebRequest 'https://download.osgeo.org/osgeo4w/v2/osgeo4w-setup.exe' -OutFile $o4w
        Start-Process $o4w -ArgumentList '--quiet-mode','--no-desktop','--advanced','--arch','x86_64','--site','https://download.osgeo.org/osgeo4w/v2','--only-site','--packages','gdal','--root','C:\OSGeo4W' -Wait
        if (Test-Path 'C:\OSGeo4W\OSGeo4W.bat') { Write-Host 'GDAL installed.' }
        else { Write-Host 'GDAL install did not complete - the app will optimise imagery locally instead.' -ForegroundColor Yellow }
    } catch {
        Write-Host "GDAL install skipped ($($_.Exception.Message)) - the app will optimise imagery locally instead." -ForegroundColor Yellow
    }
}

# ---- Scheduled task: start at boot, restart if it dies ---------------------------------------
# The task MUST run as the Administrator USER (not SYSTEM): RealityScan's Epic sign-in, its
# alignment settings and the saved/last-used export settings are all per-Windows-user — under
# SYSTEM the CLI would run unlicensed with factory defaults. Running as the user that configured
# RealityScan makes the automation inherit exactly the settings calibrated in the UI.
Write-Host ''
Write-Host 'The worker runs as Administrator so RealityScan keeps your sign-in and settings.'
$winPw = Read-Host 'Windows password for Administrator (for the scheduled task)'
$action = New-ScheduledTaskAction -Execute 'powershell.exe' `
    -Argument "-NoProfile -ExecutionPolicy Bypass -File `"$ConfigDir\smartdrone-worker.ps1`""
$trigger = New-ScheduledTaskTrigger -AtStartup
$settings = New-ScheduledTaskSettingsSet -RestartCount 999 -RestartInterval (New-TimeSpan -Minutes 2) `
    -ExecutionTimeLimit (New-TimeSpan -Days 0) -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries
Unregister-ScheduledTask -TaskName 'SmartDroneWorker' -Confirm:$false -ErrorAction SilentlyContinue
Register-ScheduledTask -TaskName 'SmartDroneWorker' -Action $action -Trigger $trigger `
    -User 'Administrator' -Password $winPw -RunLevel Highest -Settings $settings | Out-Null
Start-ScheduledTask -TaskName 'SmartDroneWorker'

Write-Host ''
Write-Host 'Done. The worker is running and will auto-start on every boot.' -ForegroundColor Green
Write-Host "Log: $ConfigDir\worker.log"
Write-Host 'NOTE: the machine now shuts itself down after 10 idle minutes (unless someone is'
Write-Host 'active over Remote Desktop). The Smart Drone app powers it back up per job.'
