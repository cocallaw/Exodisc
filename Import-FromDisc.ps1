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
    [string[]]$Extensions = @("*.jpg", "*.jpeg", "*.tif", "*.tiff", "*.png"),
    [ValidateRange(1, [int]::MaxValue)]
    [int]$EstimatedDiscCount
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

function Write-SessionProgress {
    param(
        [int]$CompletedDiscs,
        [int]$ImportedPhotos,
        [int]$Errors,
        [int]$CurrentFile,
        [int]$CurrentFileCount,
        [int]$EstimatedDiscCount
    )

    $percentComplete = -1
    $discText = "$CompletedDiscs discs completed"
    $fileText = ""

    if ($CurrentFileCount -gt 0) {
        $currentDisc = $CompletedDiscs + 1
        $discText = "Disc $currentDisc in progress"
        $fileText = ", file $CurrentFile of $CurrentFileCount"
    }

    if ($EstimatedDiscCount -gt 0) {
        $discProgress = if ($CurrentFileCount -gt 0) { $CurrentFile / $CurrentFileCount } else { 0 }
        $currentDisc = if ($CurrentFileCount -gt 0) { $CompletedDiscs + 1 } else { $CompletedDiscs }
        $discText = "Disc $currentDisc of ~$EstimatedDiscCount"
        $percentComplete = [Math]::Min(
            100,
            [Math]::Floor((($CompletedDiscs + $discProgress) / $EstimatedDiscCount) * 100)
        )
    }

    $status = "$discText$fileText, $ImportedPhotos photos imported, $Errors errors"
    Write-Progress -Activity "Importing discs" -Status $status -PercentComplete $percentComplete
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

$completedDiscs = 0
$totalImported = 0
$totalErrors = 0
Write-SessionProgress -CompletedDiscs $completedDiscs -ImportedPhotos $totalImported `
    -Errors $totalErrors -EstimatedDiscCount $EstimatedDiscCount

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

        $count = 0
        $errorCount = 0
        $usedNames = @{}
        $files = @()
        $enumerationErrors = @()
        foreach ($ext in $Extensions) {
            try {
                $files += Get-ChildItem -Path $DriveLetter -Recurse -Filter $ext -File `
                    -ErrorAction SilentlyContinue -ErrorVariable +enumerationErrors
            } catch {
                $enumerationErrors += $_
            }
        }

        $enumerationErrors = $enumerationErrors |
            Sort-Object -Property { $_.Exception.Message } -Unique
        foreach ($enumerationError in $enumerationErrors) {
            Write-Log -Disc $discFolderName -SourceFile "(enumeration)" -DestFile "" `
                -Status "ERROR" -Detail $enumerationError.Exception.Message
            $errorCount++
            $totalErrors++
        }

        if ($files.Count -eq 0) {
            Write-Host "  No photo files found on this disc (check it's the right disc)." -ForegroundColor Yellow
            Write-Log -Disc $discFolderName -SourceFile "" -DestFile "" -Status "EMPTY" -Detail "No matching files found"
        }

        $processedFiles = 0

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
                    $totalErrors++
                    continue
                }

                Write-Log -Disc $discFolderName -SourceFile $file.FullName -DestFile $destPath -Status "OK" -Detail ""
                $count++
                $totalImported++
            } catch {
                Write-Log -Disc $discFolderName -SourceFile $file.FullName -DestFile $destPath -Status "ERROR" -Detail $_.Exception.Message
                Write-Host "  FAILED to copy or verify: $($file.FullName)  -  $($_.Exception.Message)" -ForegroundColor Red
                $errorCount++
                $totalErrors++
            } finally {
                $processedFiles++
                Write-SessionProgress -CompletedDiscs $completedDiscs -ImportedPhotos $totalImported `
                    -Errors $totalErrors -CurrentFile $processedFiles -CurrentFileCount $files.Count `
                    -EstimatedDiscCount $EstimatedDiscCount
            }
        }

        Write-Host "  Copied $count file(s), $errorCount error(s)." -ForegroundColor Cyan
        if ($errorCount -gt 0) {
            Write-Host "  Errors were logged to $logPath - this disc may be degraded. Consider re-scanning." -ForegroundColor Yellow
        }

        $completedDiscs++
        Write-SessionProgress -CompletedDiscs $completedDiscs -ImportedPhotos $totalImported `
            -Errors $totalErrors -EstimatedDiscCount $EstimatedDiscCount

        Write-Host "  Eject the disc and insert the next one (or Ctrl+C to stop)..." -ForegroundColor Cyan
        do { Start-Sleep -Seconds 2 } while (Test-Path $DriveLetter)
    }
    Start-Sleep -Seconds 2
}