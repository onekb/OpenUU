param(
    [string]$AppExe = "",
    [string]$MockBin = "",
    [string]$ArtifactDir = ""
)

$ErrorActionPreference = "Stop"
$RootDir = Split-Path -Parent $PSScriptRoot

# Allow unattended headless E2E runs from non-elevated shells without triggering interactive UAC prompts
$isCurrentShellAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isCurrentShellAdmin) {
    $env:__COMPAT_LAYER = "RunAsInvoker"
}

if (-not $AppExe) {
    $candidates = @(
        (Join-Path $RootDir "build\OpenUU-Windows-v0.7.4-stage\OpenUU.exe"),
        (Join-Path $RootDir "build\OpenUU-Windows-v0.7.4\OpenUU.exe"),
        (Join-Path $RootDir "build\OpenUU-Windows\OpenUU.exe")
    ) | Where-Object { Test-Path $_ } | Sort-Object { (Get-Item $_).LastWriteTime } -Descending
    $AppExe = $candidates | Select-Object -First 1
}
if (-not $MockBin) { $MockBin = Join-Path $RootDir "target\release\openuu-cli.exe" }
if (-not $ArtifactDir) { $ArtifactDir = Join-Path $RootDir "build\e2e-artifacts" }

if (-not (Test-Path $AppExe)) { throw "OpenUU.exe not found at $AppExe (run scripts\build-windows.ps1 first)" }
if (-not (Test-Path $MockBin)) { throw "openuu-cli.exe not found at $MockBin" }

New-Item -ItemType Directory -Force -Path $ArtifactDir | Out-Null

$TmpRoot = Join-Path $env:TEMP "openuu-win-e2e"
if (Test-Path $TmpRoot) {
    Remove-Item -Recurse -Force $TmpRoot -ErrorAction SilentlyContinue
}
New-Item -ItemType Directory -Force -Path $TmpRoot | Out-Null

$spawnedPids = New-Object 'System.Collections.Generic.List[int]'

function Stop-SpawnedProcesses {
    foreach ($pidVal in $spawnedPids) {
        try {
            $p = Get-Process -Id $pidVal -ErrorAction SilentlyContinue
            if ($p -and -not $p.HasExited) {
                Stop-Process -Id $pidVal -Force -ErrorAction SilentlyContinue
            }
        }
        catch {}
    }
    $spawnedPids.Clear()
}

$script:FailCount = 0
function Assert-Check([string]$Label, [bool]$Condition) {
    if ($Condition) {
        Write-Host "    [PASS] $Label" -ForegroundColor Green
    }
    else {
        Write-Host "    [FAIL] $Label" -ForegroundColor Red
        $script:FailCount++
    }
}

try {
    # =========================================================================
    # SUITE A: Windows Client <-> openuu-cli mock-host E2E
    # =========================================================================
    $MockPort = 39485
    $MockPin = "123456"
    $MockCfg = Join-Path $TmpRoot "mock-cfg"
    $MockOut = Join-Path $TmpRoot "mock.out.log"
    $MockErr = Join-Path $TmpRoot "mock.err.log"

    Write-Host "==> [1/6] Starting openuu-cli mock-host on port $MockPort (pin=$MockPin)..."
    $mockProc = Start-Process -FilePath $MockBin `
        -ArgumentList @("mock-host", "--port", "$MockPort", "--pin", $MockPin, "--config-dir", $MockCfg) `
        -RedirectStandardOutput $MockOut `
        -RedirectStandardError $MockErr `
        -WindowStyle Hidden `
        -PassThru
    $spawnedPids.Add($mockProc.Id)

    $readyLine = ""
    for ($i = 0; $i -lt 60; $i++) {
        if ($mockProc.HasExited) {
            throw "mock-host exited prematurely: $(Get-Content $MockErr -Raw -ErrorAction SilentlyContinue)"
        }
        if (Test-Path $MockOut) {
            $match = Select-String -Path $MockOut -Pattern "MOCK_HOST_READY" | Select-Object -First 1
            if ($match) {
                $readyLine = $match.Line
                break
            }
        }
        Start-Sleep -Milliseconds 250
    }
    if (-not $readyLine) { throw "Timed out waiting for MOCK_HOST_READY" }
    Write-Host "    $readyLine"

    $mockTicket = ""
    if ($readyLine -match "ticket=(\S+)") {
        $mockTicket = $Matches[1]
    }

    $ClientCfg = Join-Path $TmpRoot "client-cfg"
    $ClientLogDir = Join-Path $TmpRoot "client-logs"
    $ClientLogFile = Join-Path $ClientLogDir "openuu.log"

    Write-Host "==> [2/6] Launching OpenUU.exe Windows Client E2E auto-test against mock-host..."
    $clientProc = Start-Process -FilePath $AppExe -ArgumentList @(
        "--config-dir", $ClientCfg,
        "--log-dir", $ClientLogDir,
        "--e2e-target", "127.0.0.1:$MockPort",
        "--e2e-pin", $MockPin,
        "--e2e-app", "com.tencent.xinWeChat",
        "--e2e-autotest",
        "--e2e-screenshot-dir", $ArtifactDir
    ) -PassThru
    $spawnedPids.Add($clientProc.Id)

    for ($i = 0; $i -lt 70; $i++) {
        if ($clientProc.HasExited) {
            throw "OpenUU.exe exited unexpectedly with code $($clientProc.ExitCode)"
        }
        if ((Test-Path $ClientLogFile) -and (Select-String -Path $ClientLogFile -Pattern "FINAL_STATS" -Quiet)) {
            Start-Sleep -Milliseconds 900
            break
        }
        Start-Sleep -Milliseconds 300
    }

    $clientLog = if (Test-Path $ClientLogFile) { Get-Content $ClientLogFile -Raw -Encoding UTF8 } else { "" }
    $mockLog = if (Test-Path $MockOut) { Get-Content $MockOut -Raw -Encoding UTF8 } else { "" }

    Assert-Check "Client alive during E2E run" (-not $clientProc.HasExited)
    Assert-Check "Client connected (connected to host)" ($clientLog -match "connected to host:")
    Assert-Check "App list received (list_apps_resp)" ($clientLog -match "list_apps_resp count=")
    Assert-Check "start_session received by mock-host" ($mockLog -match '"type":"start_session"')
    Assert-Check "window_topology received (101,102)" ($clientLog -match "window_topology.*101,102")
    Assert-Check "right-click popover topology received (201)" ($clientLog -match "window_topology.*201")
    Assert-Check "Media Foundation decoded_frames >= 5" ($clientLog -match "decoded_frames=([5-9]|[1-9][0-9]+)")
    Assert-Check "E2E_ALL_SENT logged" ($clientLog -match "E2E_ALL_SENT")
    Assert-Check "mock-host MOCK_EVENT audio_control" ($mockLog -match 'MOCK_EVENT.*"type":"audio_control"')
    Assert-Check "mock-host MOCK_EVENT mouse" ($mockLog -match 'MOCK_EVENT.*"type":"mouse"')
    Assert-Check "mock-host MOCK_EVENT drag (event_type:3)" ($mockLog -match 'MOCK_EVENT.*"type":"mouse".*"event_type":3')
    Assert-Check "mock-host MOCK_EVENT right-click (button:1)" ($mockLog -match 'MOCK_EVENT.*"type":"mouse".*"button":1')
    Assert-Check "mock-host MOCK_EVENT scroll" ($mockLog -match 'MOCK_EVENT.*"type":"scroll"')
    Assert-Check "mock-host MOCK_EVENT text_commit (Windows Chinese IME)" ($mockLog -match 'MOCK_EVENT.*"type":"text_commit".*OpenUU Windows')
    Assert-Check "mock-host MOCK_EVENT key (key_code:8, modifiers:8)" ($mockLog -match 'MOCK_EVENT.*"type":"key".*"key_code":8.*"modifiers":8')
    Assert-Check "mock-host MOCK_EVENT clipboard_sync" ($mockLog -match 'MOCK_EVENT.*"type":"clipboard_sync".*Hello from Windows E2E')
    Assert-Check "Zero unhandled UI crash in OpenUU log" (-not ($clientLog -match "\[CRASH\]"))
    Assert-Check "Screenshot windows_01_home.png saved" ((Test-Path (Join-Path $ArtifactDir "windows_01_home.png")) -and ((Get-Item (Join-Path $ArtifactDir "windows_01_home.png")).Length -gt 2048))
    Assert-Check "Screenshot windows_02_connected_workspace.png saved" ((Test-Path (Join-Path $ArtifactDir "windows_02_connected_workspace.png")) -and ((Get-Item (Join-Path $ArtifactDir "windows_02_connected_workspace.png")).Length -gt 2048))
    Assert-Check "Screenshot windows_03_proxy_window.png saved" ((Test-Path (Join-Path $ArtifactDir "windows_03_proxy_window.png")) -and ((Get-Item (Join-Path $ArtifactDir "windows_03_proxy_window.png")).Length -gt 2048))

    Stop-Process -Id $clientProc.Id -Force -ErrorAction SilentlyContinue
    Start-Sleep -Milliseconds 600

    # =========================================================================
    # [3/6] Passwordless Trusted Peer Reconnect
    # =========================================================================
    Write-Host "==> [3/6] Testing passwordless Trusted Peer reconnect (empty PIN)..."
    $ReconnLogDir = Join-Path $TmpRoot "reconn-logs"
    $ReconnLogFile = Join-Path $ReconnLogDir "openuu.log"
    $reconnProc = Start-Process -FilePath $AppExe -ArgumentList @(
        "--config-dir", $ClientCfg,
        "--log-dir", $ReconnLogDir,
        "--e2e-target", "127.0.0.1:$MockPort",
        "--e2e-pin", '""'
    ) -PassThru
    $spawnedPids.Add($reconnProc.Id)

    $reconnOk = $false
    for ($i = 0; $i -lt 40; $i++) {
        if ((Test-Path $ReconnLogFile) -and (Select-String -Path $ReconnLogFile -Pattern "connected to host:" -Quiet)) {
            $reconnOk = $true
            break
        }
        Start-Sleep -Milliseconds 250
    }
    Assert-Check "Passwordless Trusted Peer reconnect succeeded" $reconnOk
    Stop-Process -Id $reconnProc.Id -Force -ErrorAction SilentlyContinue
    Start-Sleep -Milliseconds 500

    # =========================================================================
    # [4/6] Iroh WAN Ticket Connect (openuu://...)
    # =========================================================================
    Write-Host "==> [4/6] Testing Iroh WAN ticket connect..."
    if ($mockTicket) {
        $WanLogDir = Join-Path $TmpRoot "wan-logs"
        $WanLogFile = Join-Path $WanLogDir "openuu.log"
        $wanProc = Start-Process -FilePath $AppExe -ArgumentList @(
            "--config-dir", (Join-Path $TmpRoot "wan-client-cfg"),
            "--log-dir", $WanLogDir,
            "--e2e-target", $mockTicket,
            "--e2e-pin", $MockPin
        ) -PassThru
        $spawnedPids.Add($wanProc.Id)

        $wanConnected = $false
        for ($i = 0; $i -lt 50; $i++) {
            if ($wanProc.HasExited) { break }
            if ((Test-Path $WanLogFile) -and (Select-String -Path $WanLogFile -Pattern "connected to host:" -Quiet)) {
                $wanConnected = $true
                break
            }
            Start-Sleep -Milliseconds 300
        }
        Assert-Check "Iroh WAN openuu:// ticket connect succeeded with zero crash" ($wanConnected -and (-not $wanProc.HasExited))
        Stop-Process -Id $wanProc.Id -Force -ErrorAction SilentlyContinue
    }
    Stop-Process -Id $mockProc.Id -Force -ErrorAction SilentlyContinue
    Start-Sleep -Milliseconds 500

    # =========================================================================
    # SUITE B: Live Windows Host (OpenUU.exe) <-> Windows Client (OpenUU.exe)
    # =========================================================================
    Write-Host "==> [5/6] Starting real Win32 target window + OpenUU.exe in Windows Host Mode..."
    $TargetAppScript = Join-Path $TmpRoot "target-window.ps1"
    Set-Content -Path $TargetAppScript -Encoding UTF8 -Value @'
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
$form = New-Object System.Windows.Forms.Form
$form.Text = "OpenUU E2E Sample Window"
$form.Size = New-Object System.Drawing.Size(760, 520)
$form.StartPosition = "Manual"
$form.Location = New-Object System.Drawing.Point(120, 120)
$form.BackColor = [System.Drawing.Color]::FromArgb(15, 23, 42)
$lbl = New-Object System.Windows.Forms.Label
$lbl.Text = "OpenUU Windows Native Host -> Live H.264 Stream"
$lbl.ForeColor = [System.Drawing.Color]::FromArgb(56, 189, 248)
$lbl.Font = New-Object System.Drawing.Font("Segoe UI", 18, [System.Drawing.FontStyle]::Bold)
$lbl.AutoSize = $true
$lbl.Location = New-Object System.Drawing.Point(40, 60)
$form.Controls.Add($lbl)
$clock = New-Object System.Windows.Forms.Label
$clock.ForeColor = [System.Drawing.Color]::White
$clock.Font = New-Object System.Drawing.Font("Consolas", 22, [System.Drawing.FontStyle]::Bold)
$clock.AutoSize = $true
$clock.Location = New-Object System.Drawing.Point(40, 140)
$clock.Text = [DateTime]::Now.ToString("HH:mm:ss.fff")
$form.Controls.Add($clock)
$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = 50
$timer.Add_Tick({ $clock.Text = "LIVE FRAME TICK: " + [DateTime]::Now.ToString("HH:mm:ss.fff") })
$timer.Start()
[System.Windows.Forms.Application]::Run($form)
'@

    $targetWinProc = Start-Process -FilePath "powershell.exe" `
        -ArgumentList @("-NoProfile", "-ExecutionPolicy", "Bypass", "-WindowStyle", "Hidden", "-File", $TargetAppScript) `
        -PassThru
    $spawnedPids.Add($targetWinProc.Id)
    Start-Sleep -Milliseconds 1200

    $HostPort = 39585
    $HostPin = "654321"
    $HostCfg = Join-Path $TmpRoot "live-host-cfg"
    $HostLogDir = Join-Path $TmpRoot "live-host-logs"
    $HostLogFile = Join-Path $HostLogDir "openuu.log"
    $HostReadyFile = Join-Path $TmpRoot "host-ready.txt"

    $hostProc = Start-Process -FilePath $AppExe -ArgumentList @(
        "--config-dir", $HostCfg,
        "--log-dir", $HostLogDir,
        "--e2e-host-port", "$HostPort",
        "--e2e-host-pin", $HostPin,
        "--e2e-ready-file", $HostReadyFile
    ) -PassThru
    $spawnedPids.Add($hostProc.Id)

    for ($i = 0; $i -lt 50; $i++) {
        if ($hostProc.HasExited) {
            throw "Windows Host OpenUU.exe exited unexpectedly!"
        }
        if (Test-Path $HostReadyFile) { break }
        Start-Sleep -Milliseconds 250
    }
    Assert-Check "Windows Host OpenUU.exe started & listening on port $HostPort" (Test-Path $HostReadyFile)

    # =========================================================================
    # [6/6] Live Windows Client -> Live Windows Host (Single-App + Full Desktop)
    # =========================================================================
    Write-Host "==> [6/6] Connecting Windows Client to Live Windows Host (Single-App & Full Desktop)..."

    # Test 6A: Single-App Seamless Window capture of real Win32 window (win.app.powershell)
    $LiveSingleShotDir = Join-Path $TmpRoot "shots-single"
    $LiveSingleLogDir = Join-Path $TmpRoot "live-client-single-logs"
    $LiveSingleLogFile = Join-Path $LiveSingleLogDir "openuu.log"
    $liveSingleClient = Start-Process -FilePath $AppExe -ArgumentList @(
        "--config-dir", (Join-Path $TmpRoot "live-client-single-cfg"),
        "--log-dir", $LiveSingleLogDir,
        "--e2e-target", "127.0.0.1:$HostPort",
        "--e2e-pin", $HostPin,
        "--e2e-app", "win.app.powershell",
        "--e2e-autotest",
        "--e2e-screenshot-dir", $LiveSingleShotDir
    ) -PassThru
    $spawnedPids.Add($liveSingleClient.Id)

    for ($i = 0; $i -lt 70; $i++) {
        if ($liveSingleClient.HasExited) { break }
        if ((Test-Path $LiveSingleLogFile) -and (Select-String -Path $LiveSingleLogFile -Pattern "FINAL_STATS" -Quiet)) {
            Start-Sleep -Milliseconds 900
            break
        }
        Start-Sleep -Milliseconds 300
    }

    $singleClientLog = if (Test-Path $LiveSingleLogFile) { Get-Content $LiveSingleLogFile -Raw -Encoding UTF8 } else { "" }
    Assert-Check "Live Windows Host -> Client single-app connected & listed real Windows apps" ($singleClientLog -match "list_apps_resp count=")
    Assert-Check "Live Windows Host -> Client single-app received window_topology" ($singleClientLog -match "window_topology count=[1-9]")
    Assert-Check "Live Windows Host DWM PrintWindow + MF H.264 encode -> Client decoded_frames >= 5" ($singleClientLog -match "decoded_frames=([5-9]|[1-9][0-9]+)")
    Assert-Check "Live Windows Host QUIC Audio (0x02) + MF AAC-LC encode/decode -> decoded_audio_frames >= 3" ($singleClientLog -match "decoded_audio_frames=([3-9]|[1-9][0-9]+)")
    if (Test-Path (Join-Path $LiveSingleShotDir "windows_03_proxy_window.png")) {
        Copy-Item -Force (Join-Path $LiveSingleShotDir "windows_03_proxy_window.png") (Join-Path $ArtifactDir "windows_04_live_host_single_app.png")
    }
    Assert-Check "Screenshot windows_04_live_host_single_app.png saved" ((Test-Path (Join-Path $ArtifactDir "windows_04_live_host_single_app.png")) -and ((Get-Item (Join-Path $ArtifactDir "windows_04_live_host_single_app.png")).Length -gt 2048))

    Stop-Process -Id $liveSingleClient.Id -Force -ErrorAction SilentlyContinue
    Start-Sleep -Milliseconds 600

    # Test 6B: Full Desktop DXGI/GDI capture (__openuu_full_desktop__)
    $LiveDeskShotDir = Join-Path $TmpRoot "shots-desk"
    $LiveDeskLogDir = Join-Path $TmpRoot "live-client-desk-logs"
    $LiveDeskLogFile = Join-Path $LiveDeskLogDir "openuu.log"
    $liveDeskClient = Start-Process -FilePath $AppExe -ArgumentList @(
        "--config-dir", (Join-Path $TmpRoot "live-client-desk-cfg"),
        "--log-dir", $LiveDeskLogDir,
        "--e2e-target", "127.0.0.1:$HostPort",
        "--e2e-pin", $HostPin,
        "--e2e-app", "__openuu_full_desktop__",
        "--e2e-autotest",
        "--e2e-screenshot-dir", $LiveDeskShotDir
    ) -PassThru
    $spawnedPids.Add($liveDeskClient.Id)

    for ($i = 0; $i -lt 70; $i++) {
        if ($liveDeskClient.HasExited) { break }
        if ((Test-Path $LiveDeskLogFile) -and (Select-String -Path $LiveDeskLogFile -Pattern "FINAL_STATS" -Quiet)) {
            Start-Sleep -Milliseconds 900
            break
        }
        Start-Sleep -Milliseconds 300
    }

    $deskClientLog = if (Test-Path $LiveDeskLogFile) { Get-Content $LiveDeskLogFile -Raw -Encoding UTF8 } else { "" }
    $hostLog = if (Test-Path $HostLogFile) { Get-Content $HostLogFile -Raw -Encoding UTF8 } else { "" }

    Assert-Check "Live Windows Host DXGI Full Desktop capture started" ($hostLog -match "started full_desktop")
    Assert-Check "Live Windows Host Full Desktop -> Client received window_topology (2147483392)" ($deskClientLog -match "window_topology.*2147483392")
    Assert-Check "Live Windows Host Full Desktop -> Client decoded_frames >= 5" ($deskClientLog -match "decoded_frames=([5-9]|[1-9][0-9]+)")
    if (Test-Path (Join-Path $LiveDeskShotDir "windows_03_proxy_window.png")) {
        Copy-Item -Force (Join-Path $LiveDeskShotDir "windows_03_proxy_window.png") (Join-Path $ArtifactDir "windows_05_live_host_desktop.png")
    }
    Assert-Check "Screenshot windows_05_live_host_desktop.png saved" ((Test-Path (Join-Path $ArtifactDir "windows_05_live_host_desktop.png")) -and ((Get-Item (Join-Path $ArtifactDir "windows_05_live_host_desktop.png")).Length -gt 2048))

    if ($script:FailCount -gt 0) {
        Write-Host ""
        Write-Host "=== DIAGNOSTIC EXCERPT (clientLog) ===" -ForegroundColor Yellow
        Write-Host $clientLog
        Write-Host "=== DIAGNOSTIC EXCERPT (hostLog) ===" -ForegroundColor Yellow
        Write-Host $hostLog
        throw "$($script:FailCount) E2E check(s) failed!"
    }

    Write-Host ""
    Write-Host "============================================================" -ForegroundColor Cyan
    Write-Host " ALL WINDOWS CLIENT & HOST E2E ACCEPTANCE CHECKS PASSED!" -ForegroundColor Green
    Write-Host " Screenshots:"
    Write-Host "   - $ArtifactDir\windows_01_home.png"
    Write-Host "   - $ArtifactDir\windows_02_connected_workspace.png"
    Write-Host "   - $ArtifactDir\windows_03_proxy_window.png"
    Write-Host "   - $ArtifactDir\windows_04_live_host_single_app.png"
    Write-Host "   - $ArtifactDir\windows_05_live_host_desktop.png"
    Write-Host "============================================================" -ForegroundColor Cyan
}
finally {
    Stop-SpawnedProcesses
}
