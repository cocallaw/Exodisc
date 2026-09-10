<#
.SYNOPSIS
    Watches an optical drive for discs and copies photo files off each one into
    its own dated folder, renaming files based on EXIF "date taken" when available.

.DESCRIPTION
    Designed for old Photo Center CDs (circa 2000-2015). Ignores the
    proprietary viewer app / database files on the disc and only copies image
    files. Each disc gets its own destination folder. Read errors (common on
    aging CD-Rs) are logged to a CSV.

.NOTES
    - Uses ExifTool if it's installed and on PATH (recommended, most accurate).
      Download: https://exiftool.org  (just needs to be exiftool.exe somewhere on PATH)
    - Falls back to file LastWriteTime if ExifTool isn't found or a file has no EXIF date.
    - Safe to leave running unattended - swap discs as each one finishes.
#>

param(
    [string]$Target = "C:\Photos\Import",
    [string]$DriveLetter = "D:",
    [string[]]$Extensions = @("*.jpg", "*.jpeg", "*.tif", "*.tiff", "*.png")
)

function Write-Log {
    param($Disc, $SourceFile, $DestFile, $Status, $Detail)
    $line = '"{0}","{1}","{2}","{3}","{4}","{5}"' -f `
        (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), $Disc, $SourceFile, $DestFile, $Status, $Detail
    Add-Content -Path $logPath -Value $line
}

function Get-PhotoDate {
    param([string]$FilePath)

    if ($exifToolAvailable) {
        try {
            $raw = exiftool -DateTimeOriginal -s3 -d "%Y-%m-%d_%H%M%S" "$FilePath" 2>$null
            if ($raw -and $raw.Trim()) {
                return $raw.Trim()
            }
        } catch { }
    }

    # Fallback: file's last-write time (best we can do without EXIF)
    return (Get-Item $FilePath).LastWriteTime.ToString("yyyy-MM-dd_HHmmss")
}

function Copy-VerifiedFile {
    param(
        [string]$SourcePath,
        [string]$DestinationPath
    )

    Copy-Item -LiteralPath $SourcePath -Destination $DestinationPath -ErrorAction Stop

    $sourceHash = (Get-FileHash -LiteralPath $SourcePath -Algorithm SHA256 -ErrorAction Stop).Hash
    $destinationHash = (Get-FileHash -LiteralPath $DestinationPath -Algorithm SHA256 -ErrorAction Stop).Hash

    [pscustomobject]@{
        SourceHash      = $sourceHash
        DestinationHash = $destinationHash
        IsMatch         = $sourceHash -eq $destinationHash
    }
}

if ($MyInvocation.InvocationName -eq '.') {
    return
}

$ErrorActionPreference = "Continue"
$logPath = Join-Path $Target "_import_log.csv"
$exifToolAvailable = $null -ne (Get-Command exiftool.exe -ErrorAction SilentlyContinue) -or
                     $null -ne (Get-Command exiftool -ErrorAction SilentlyContinue)
New-Item -ItemType Directory -Path $Target -Force | Out-Null

if (-not (Test-Path $logPath)) {
    "Timestamp,Disc,SourceFile,DestFile,Status,Detail" | Out-File -FilePath $logPath -Encoding UTF8
}

if (-not $exifToolAvailable) {
    Write-Host "NOTE: ExifTool not found on PATH - falling back to file modified-date for naming." -ForegroundColor Yellow
    Write-Host "      For accurate 'date taken' renaming, install it from https://exiftool.org" -ForegroundColor Yellow
}

Write-Host "Watching $DriveLetter for discs. Press Ctrl+C to stop." -ForegroundColor Cyan

while ($true) {
    if (Test-Path $DriveLetter) {
        Start-Sleep -Seconds 2  # let the drive finish spinning up / mounting

        $volLabel = "UnknownDisc"
        try {
            $vol = Get-Volume -DriveLetter $DriveLetter.TrimEnd(':') -ErrorAction Stop
            if ($vol.FileSystemLabel) { $volLabel = $vol.FileSystemLabel }
        } catch { }

        $safeLabel = ($volLabel -replace '[\\/:*?"<>|]', '_')
        $stamp = Get-Date -Format "yyyyMMdd_HHmmss"
        $discFolderName = "${safeLabel}_${stamp}"
        $destRoot = Join-Path $Target $discFolderName
        New-Item -ItemType Directory -Path $destRoot -Force | Out-Null

        Write-Host "`nDisc detected: $volLabel  ->  $destRoot" -ForegroundColor Green

        $files = @()
        foreach ($ext in $Extensions) {
            try {
                $files += Get-ChildItem -Path $DriveLetter -Recurse -Filter $ext -File -ErrorAction SilentlyContinue
            } catch {
                Write-Log -Disc $discFolderName -SourceFile "(enumeration)" -DestFile "" -Status "ERROR" -Detail $_.Exception.Message
            }
        }

        if ($files.Count -eq 0) {
            Write-Host "  No photo files found on this disc (check it's the right disc)." -ForegroundColor Yellow
            Write-Log -Disc $discFolderName -SourceFile "" -DestFile "" -Status "EMPTY" -Detail "No matching files found"
        }

        $count = 0
        $errorCount = 0
        $usedNames = @{}

        foreach ($file in $files) {
            $destPath = ""

            try {
                $dateStr = Get-PhotoDate -FilePath $file.FullName
                $ext = $file.Extension.ToLower()
                $baseName = "$dateStr$ext"

                # Avoid collisions when multiple photos share the same second/timestamp
                if ($usedNames.ContainsKey($baseName)) {
                    $usedNames[$baseName]++
                    $baseName = "{0}_{1:D2}{2}" -f $dateStr, $usedNames[$baseName], $ext
                } else {
                    $usedNames[$baseName] = 0
                }

                $destPath = Join-Path $destRoot $baseName
                $verification = Copy-VerifiedFile -SourcePath $file.FullName -DestinationPath $destPath

                if (-not $verification.IsMatch) {
                    $detail = "SourceHash=$($verification.SourceHash); DestinationHash=$($verification.DestinationHash)"
                    Write-Log -Disc $discFolderName -SourceFile $file.FullName -DestFile $destPath -Status "HASH_MISMATCH" -Detail $detail
                    Write-Host "  HASH MISMATCH: $($file.FullName)  ->  $destPath" -ForegroundColor Red
                    Write-Host "    Source:      $($verification.SourceHash)" -ForegroundColor Red
                    Write-Host "    Destination: $($verification.DestinationHash)" -ForegroundColor Red
                    $errorCount++
                    continue
                }

                Write-Log -Disc $discFolderName -SourceFile $file.FullName -DestFile $destPath -Status "OK" -Detail ""
                $count++
            } catch {
                Write-Log -Disc $discFolderName -SourceFile $file.FullName -DestFile $destPath -Status "ERROR" -Detail $_.Exception.Message
                Write-Host "  FAILED to copy or verify: $($file.FullName)  -  $($_.Exception.Message)" -ForegroundColor Red
                $errorCount++
            }
        }

        Write-Host "  Copied $count file(s), $errorCount error(s)." -ForegroundColor Cyan
        if ($errorCount -gt 0) {
            Write-Host "  Errors were logged to $logPath - this disc may be degraded. Consider re-scanning." -ForegroundColor Yellow
        }

        Write-Host "  Eject the disc and insert the next one (or Ctrl+C to stop)..." -ForegroundColor Cyan
        do { Start-Sleep -Seconds 2 } while (Test-Path $DriveLetter)
    }
    Start-Sleep -Seconds 2
}