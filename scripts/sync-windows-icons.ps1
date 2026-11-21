$ErrorActionPreference = "Stop"

$RootDir = Split-Path -Parent $PSScriptRoot
$SrcIcon = Join-Path $RootDir "apps\macos\Resources\AppIcon.png"
$OutDir  = Join-Path $RootDir "apps\windows\OpenUUApp\Resources"

if (-not (Test-Path $SrcIcon)) {
    throw "Source AppIcon.png not found at $SrcIcon"
}

New-Item -ItemType Directory -Force -Path $OutDir | Out-Null

Add-Type -AssemblyName System.Drawing

$srcBmp = [System.Drawing.Bitmap]::FromFile($SrcIcon)
try {
    # Crop 100..924 on 1024x1024 canvas (824x824 squircle body, identical to macOS IconCompositor & sync-brand-icons.swift)
    $scaleX = $srcBmp.Width / 1024.0
    $scaleY = $srcBmp.Height / 1024.0
    $cropX = [int][Math]::Round(100.0 * $scaleX)
    $cropY = [int][Math]::Round(100.0 * $scaleY)
    $cropW = [int][Math]::Round(824.0 * $scaleX)
    $cropH = [int][Math]::Round(824.0 * $scaleY)
    $srcRect = New-Object System.Drawing.Rectangle($cropX, $cropY, $cropW, $cropH)

    function New-ResizedPngBytes([int]$size) {
        $dst = New-Object System.Drawing.Bitmap($size, $size, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
        try {
            $g = [System.Drawing.Graphics]::FromImage($dst)
            try {
                $g.Clear([System.Drawing.Color]::Transparent)
                $g.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
                $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::HighQuality
                $g.PixelOffsetMode = [System.Drawing.Drawing2D.PixelOffsetMode]::HighQuality
                $dstRect = New-Object System.Drawing.Rectangle(0, 0, $size, $size)
                $g.DrawImage($srcBmp, $dstRect, $srcRect, [System.Drawing.GraphicsUnit]::Pixel)
            } finally {
                $g.Dispose()
            }
            $ms = New-Object System.IO.MemoryStream
            $dst.Save($ms, [System.Drawing.Imaging.ImageFormat]::Png)
            return $ms.ToArray()
        } finally {
            $dst.Dispose()
        }
    }

    # 1. Save 256x256 squircle AppIcon.png for in-app UI & badge compositing
    $png256 = New-ResizedPngBytes 256
    $outPngPath = Join-Path $OutDir "AppIcon.png"
    [System.IO.File]::WriteAllBytes($outPngPath, $png256)
    Write-Host "  -> Wrote $outPngPath ($($png256.Length) bytes)"

    # 2. Build multi-resolution Windows .ico (16, 24, 32, 48, 64, 128, 256) with embedded RGBA PNG payloads
    $sizes = @(16, 24, 32, 48, 64, 128, 256)
    $payloads = New-Object 'System.Collections.Generic.List[byte[]]'
    foreach ($sz in $sizes) {
        $payloads.Add((New-ResizedPngBytes $sz))
    }

    $icoStream = New-Object System.IO.MemoryStream
    $bw = New-Object System.IO.BinaryWriter($icoStream)
    # ICONDIR: Reserved(0), Type(1 = ICO), Count
    $bw.Write([uint16]0)
    $bw.Write([uint16]1)
    $bw.Write([uint16]$sizes.Count)

    $offset = 6 + (16 * $sizes.Count)
    for ($i = 0; $i -lt $sizes.Count; $i++) {
        $sz = $sizes[$i]
        $bytes = $payloads[$i]
        $dimByte = if ($sz -ge 256) { [byte]0 } else { [byte]$sz }
        $bw.Write($dimByte)              # bWidth
        $bw.Write($dimByte)              # bHeight
        $bw.Write([byte]0)               # bColorCount
        $bw.Write([byte]0)               # bReserved
        $bw.Write([uint16]1)             # wPlanes
        $bw.Write([uint16]32)            # wBitCount
        $bw.Write([uint32]$bytes.Length) # dwBytesInRes
        $bw.Write([uint32]$offset)       # dwImageOffset
        $offset += $bytes.Length
    }
    for ($i = 0; $i -lt $sizes.Count; $i++) {
        $bw.Write($payloads[$i])
    }
    $bw.Flush()

    $outIcoPath = Join-Path $OutDir "AppIcon.ico"
    [System.IO.File]::WriteAllBytes($outIcoPath, $icoStream.ToArray())
    Write-Host "  -> Wrote $outIcoPath ($($icoStream.Length) bytes, sizes: $($sizes -join ','))"
} finally {
    $srcBmp.Dispose()
}
