param(
    [switch]$SelfContained = $true,
    [switch]$SkipZip = $false,
    [switch]$SkipInstaller = $false,
    [switch]$SyncIcons = $false,
    [string]$OutDir = ""
)

$ErrorActionPreference = "Stop"

$RootDir = Split-Path -Parent $PSScriptRoot

# Auto-augment PATH with user-space Rust, .NET, and WinGet LLVM-MinGW if installed
$extraPaths = @()
if (Test-Path "$env:USERPROFILE\.dotnet") { $extraPaths += "$env:USERPROFILE\.dotnet" }
if (Test-Path "$env:USERPROFILE\.cargo\bin") { $extraPaths += "$env:USERPROFILE\.cargo\bin" }

$wingetLlvm = Get-ChildItem -Path "$env:LOCALAPPDATA\Microsoft\WinGet\Packages\MartinStorsjo.LLVM-MinGW*" -Directory -ErrorAction SilentlyContinue |
    ForEach-Object { Get-ChildItem -Path $_.FullName -Filter "llvm-mingw-*" -Directory -ErrorAction SilentlyContinue } |
    Select-Object -Last 1
if ($wingetLlvm -and (Test-Path (Join-Path $wingetLlvm.FullName "bin"))) {
    $extraPaths += (Join-Path $wingetLlvm.FullName "bin")
}

if ($extraPaths.Count -gt 0) {
    $env:PATH = ($extraPaths -join ";") + ";" + $env:PATH
}

# Load optional .env.local
$envLocal = Join-Path $RootDir ".env.local"
if (Test-Path $envLocal) {
    Get-Content $envLocal | ForEach-Object {
        $line = $_.Trim()
        if ($line -and -not $line.StartsWith("#") -and $line.Contains("=")) {
            $parts = $line.Split("=", 2)
            [Environment]::SetEnvironmentVariable($parts[0].Trim(), $parts[1].Trim().Trim('"').Trim("'"))
        }
    }
}

$iconPath = Join-Path $RootDir "apps\windows\OpenUUApp\Resources\AppIcon.ico"
if ($SyncIcons -or -not (Test-Path $iconPath)) {
    Write-Host "==> Syncing official OpenUU brand icons for Windows..."
    & (Join-Path $PSScriptRoot "sync-windows-icons.ps1")
}

$nativeOutDir = Join-Path $RootDir "build\native-win-x64"
New-Item -ItemType Directory -Force -Path $nativeOutDir | Out-Null

Write-Host "==> 1/5 Building openuu-core (Rust release cdylib) & openuu-cli..."
cargo rustc --manifest-path (Join-Path $RootDir "Cargo.toml") -p openuu-core --release --lib --crate-type cdylib
if ($LASTEXITCODE -ne 0) { throw "cargo rustc openuu-core failed with exit code $LASTEXITCODE" }

cargo build --manifest-path (Join-Path $RootDir "Cargo.toml") -p openuu-cli --release
if ($LASTEXITCODE -ne 0) { throw "cargo build openuu-cli failed with exit code $LASTEXITCODE" }

$coreDllSrc = Join-Path $RootDir "target\release\openuu_core.dll"
if (-not (Test-Path $coreDllSrc)) {
    throw "Expected Rust cdylib not found at $coreDllSrc"
}
Copy-Item -Force $coreDllSrc (Join-Path $nativeOutDir "openuu_core.dll")

Write-Host "==> 2/5 Building openuu_win_media.dll (Media Foundation & DXGI/DWM helper)..."
$cppSrc = Join-Path $RootDir "apps\windows\native\openuu_win_media.cpp"
$mediaDllOut = Join-Path $nativeOutDir "openuu_win_media.dll"

$mingwClang = Get-Command "x86_64-w64-mingw32-clang++.exe" -ErrorAction SilentlyContinue
$clang = Get-Command "clang++.exe" -ErrorAction SilentlyContinue
$msvcCl = Get-Command "cl.exe" -ErrorAction SilentlyContinue

if ($mingwClang) {
    & $mingwClang.Source -O3 -std=c++17 -shared -DUNICODE -D_UNICODE `
        $cppSrc -o $mediaDllOut `
        -lmfplat -lmf -lmfuuid -ld3d11 -ldxgi -ldwmapi -lgdi32 -luser32 -lole32 -loleaut32 -lstrmiids -lwinmm -luuid `
        "-static-libgcc" "-static-libstdc++" "-Wl,-Bstatic" "-lwinpthread" "-Wl,-Bdynamic"
    if ($LASTEXITCODE -ne 0) { throw "x86_64-w64-mingw32-clang++ failed with exit code $LASTEXITCODE" }
}
elseif ($msvcCl) {
    Push-Location $nativeOutDir
    try {
        & $msvcCl.Source /nologo /O2 /EHsc /std:c++17 /DUNICODE /D_UNICODE /LD $cppSrc `
            /Fe:$mediaDllOut `
            mfplat.lib mf.lib mfuuid.lib d3d11.lib dxgi.lib dwmapi.lib gdi32.lib user32.lib ole32.lib oleaut32.lib strmiids.lib winmm.lib uuid.lib
        if ($LASTEXITCODE -ne 0) { throw "MSVC cl.exe failed with exit code $LASTEXITCODE" }
    }
    finally {
        Pop-Location
    }
}
elseif ($clang) {
    & $clang.Source -O3 -std=c++17 -shared -DUNICODE -D_UNICODE `
        $cppSrc -o $mediaDllOut `
        -lmfplat -lmf -lmfuuid -ld3d11 -ldxgi -ldwmapi -lgdi32 -luser32 -lole32 -loleaut32 -lstrmiids -lwinmm -luuid
    if ($LASTEXITCODE -ne 0) { throw "clang++ failed with exit code $LASTEXITCODE" }
}
else {
    throw "No C++17 compiler found (install LLVM-MinGW or Visual Studio Build Tools)."
}

$csprojPath = Join-Path $RootDir "apps\windows\OpenUUApp\OpenUUApp.csproj"
[xml]$csprojXml = Get-Content $csprojPath -Encoding UTF8
$appVersion = ($csprojXml.Project.PropertyGroup.Version | Select-Object -First 1)
if (-not $appVersion) { $appVersion = "0.6.2" }

function Test-PublishDirLocked([string]$Dir) {
    if (-not (Test-Path $Dir)) { return $false }
    $probeFiles = @("OpenUU.exe", "OpenUU.dll", "openuu_core.dll", "openuu_win_media.dll", "coreclr.dll")
    foreach ($name in $probeFiles) {
        $fp = Join-Path $Dir $name
        if (Test-Path $fp) {
            try {
                $fs = [System.IO.File]::Open($fp, [System.IO.FileMode]::Open, [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::None)
                $fs.Close()
            }
            catch {
                return $true
            }
        }
    }
    return $false
}

$publishDir = if ($OutDir) { $OutDir } else { Join-Path $RootDir "build\OpenUU-Windows" }
if (Test-PublishDirLocked $publishDir) {
    $candidates = @(
        (Join-Path $RootDir "build\OpenUU-Windows-v$appVersion"),
        (Join-Path $RootDir "build\OpenUU-Windows-v$appVersion-stage")
    )
    $chosen = $candidates | Where-Object { -not (Test-PublishDirLocked $_) } | Select-Object -First 1
    if (-not $chosen) {
        throw "All candidate publish directories are locked by running OpenUU.exe processes. Please close OpenUU first."
    }
    Write-Host "==> Note: $publishDir is currently in use by a running OpenUU.exe; leaving it intact and publishing to $chosen ..."
    $publishDir = $chosen
}

if (Test-Path $publishDir) {
    Remove-Item -Recurse -Force $publishDir
}

$scValue = if ($SelfContained) { "true" } else { "false" }
Write-Host "==> 3/5 Publishing OpenUUApp v$appVersion (.NET 8 WPF win-x64, self-contained=$scValue)..."
dotnet publish $csprojPath `
    -c Release `
    -r win-x64 `
    --self-contained $scValue `
    -p:PublishSingleFile=false `
    -p:DebugType=embedded `
    -o $publishDir
if ($LASTEXITCODE -ne 0) { throw "dotnet publish failed with exit code $LASTEXITCODE" }

Copy-Item -Force (Join-Path $nativeOutDir "openuu_core.dll") (Join-Path $publishDir "openuu_core.dll")
Copy-Item -Force (Join-Path $nativeOutDir "openuu_win_media.dll") (Join-Path $publishDir "openuu_win_media.dll")

# Optional Authenticode signing if configured
if ($env:OPENUU_WINDOWS_CERT_SHA1) {
    $signtool = Get-Command "signtool.exe" -ErrorAction SilentlyContinue
    if ($signtool) {
        Write-Host "==> Signing binaries with certificate $($env:OPENUU_WINDOWS_CERT_SHA1)..."
        & $signtool.Source sign /sha1 $env:OPENUU_WINDOWS_CERT_SHA1 /fd SHA256 `
            (Join-Path $publishDir "openuu_core.dll") `
            (Join-Path $publishDir "openuu_win_media.dll") `
            (Join-Path $publishDir "OpenUU.exe")
    }
}

$zipPath = Join-Path $RootDir "build\OpenUU-Windows-x64.zip"
if (-not $SkipZip) {
    Write-Host "==> 4/5 Creating portable archive $zipPath ..."
    if (Test-Path $zipPath) {
        Remove-Item -Force $zipPath
    }
    Compress-Archive -Path (Join-Path $publishDir "*") -DestinationPath $zipPath -CompressionLevel Optimal
}

$setupPath = Join-Path $RootDir "build\OpenUU-Windows-x64-Setup.exe"
$installerBuilt = $false
if (-not $SkipInstaller) {
    $isccCmd = Get-Command "ISCC.exe" -ErrorAction SilentlyContinue
    $isccPath = if ($isccCmd) {
        $isccCmd.Source
    }
    else {
        @(
            "$env:LOCALAPPDATA\Programs\Inno Setup 6\ISCC.exe",
            "C:\Program Files (x86)\Inno Setup 6\ISCC.exe",
            "C:\Program Files\Inno Setup 6\ISCC.exe"
        ) | Where-Object { Test-Path $_ } | Select-Object -First 1
    }

    if ($isccPath) {
        Write-Host "==> 5/5 Building Windows Setup installer $setupPath (Inno Setup)..."
        $issFile = Join-Path $RootDir "apps\windows\installer\OpenUU.iss"
        $outBuildDir = Join-Path $RootDir "build"
        & $isccPath "/Q" "/DMyAppVersion=$appVersion" "/DPublishDir=$publishDir" "/DOutputDir=$outBuildDir" $issFile
        if ($LASTEXITCODE -ne 0) { throw "ISCC.exe failed with exit code $LASTEXITCODE" }
        $installerBuilt = $true

        if ($env:OPENUU_WINDOWS_CERT_SHA1) {
            $signtool = Get-Command "signtool.exe" -ErrorAction SilentlyContinue
            if ($signtool) {
                & $signtool.Source sign /sha1 $env:OPENUU_WINDOWS_CERT_SHA1 /fd SHA256 $setupPath
            }
        }
    }
    else {
        Write-Warning "ISCC.exe (Inno Setup 6) not found; skipping Setup.exe installer. Install via: winget install JRSoftware.InnoSetup"
    }
}

Write-Host "==> Done! Standalone Windows app created at:"
Write-Host "    Executable  : $publishDir\OpenUU.exe"
if (-not $SkipZip) {
    Write-Host "    Portable ZIP: $zipPath"
}
if ($installerBuilt) {
    Write-Host "    Installer   : $setupPath"
}
