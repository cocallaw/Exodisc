# Exodisc

PowerShell tool for migrating photos off old optical media (CDs/DVDs from ~2000-2015). `Import-FromDisc.ps1` watches a drive letter, and for each disc detected, copies photo files into a dated destination folder while verifying every copy via SHA256 hash comparison.

## Testing

Uses Pester 5+. Run all tests with:

```powershell
$config = New-PesterConfiguration -Hashtable (Import-PowerShellDataFile ./PesterConfiguration.psd1)
Invoke-Pester -Configuration $config
```

To run a single test/Describe block, pass `-FullNameFilter` or filter by tag, e.g.:

```powershell
Invoke-Pester -Path ./tests/Import-FromDisc.Tests.ps1 -FullNameFilter "*returns both hashes*"
```

Tests dot-source `Import-FromDisc.ps1` (`. (Join-Path $PSScriptRoot ".." "Import-FromDisc.ps1")`) to load its functions without running the main watch loop — the script guards its top-level execution with `if ($MyInvocation.InvocationName -eq '.') { return }` right after the function definitions, so dot-sourcing only exposes `Write-Log`, `Get-PhotoDate`, `Copy-VerifiedFile`, and `Get-DiscPhotoFiles` for testing. When adding new functions intended for reuse/testing, define them above that guard.

## Architecture

Single-script design (`Import-FromDisc.ps1`) with four core functions plus a top-level watch loop:

- `Get-PhotoDate` — resolves a file's "date taken" via ExifTool (`-DateTimeOriginal`) if available on PATH, falling back to `LastWriteTime`. Used to build the destination filename (`yyyy-MM-dd_HHmmss`).
- `Copy-VerifiedFile` — copies a file, then hashes both source and destination (SHA256) and returns a result object (`SourceHash`, `DestinationHash`, `IsMatch`). Errors during hashing must propagate (not be swallowed) so the main loop can log them as failures — see the "surfaces hashing errors" test.
- `Get-DiscPhotoFiles` — enumerates photo files for a disc. With no `-IncludePaths`, recurses the whole drive (default, backward compatible). With `-IncludePaths` (subfolders relative to the drive root), recurses only those subtrees, unions/dedupes results by `FullName` (so overlapping/nested paths aren't double-counted), and returns any missing include paths as `Warnings` (logged/skipped, not fatal) alongside `Files` and `EnumerationErrors`.
- `Write-Log` — appends a CSV row (Timestamp, Disc, SourceFile, DestFile, Status, Detail) to `_import_log.csv` in the target directory. Status values used: `OK`, `HASH_MISMATCH`, `ERROR`, `WARN`, `EMPTY`.
- Main loop polls `Test-Path $DriveLetter` to detect a disc, builds a per-disc destination folder named `<VolumeLabel>_<timestamp>`, enumerates image files via `Get-DiscPhotoFiles` (`*.jpg`, `*.jpeg`, `*.tif`, `*.tiff`, `*.png` by default, optionally scoped by `-IncludePaths`), copies+verifies each via `Copy-VerifiedFile`, then waits for the disc to be ejected before resuming the poll loop.

Filename collisions (multiple photos with the same computed timestamp) are disambiguated with a `_NN` suffix tracked in a `$usedNames` hashtable per disc.

## Conventions

- `$ErrorActionPreference = "Continue"` in the main script body — individual copy/hash failures are caught and logged per-file rather than aborting the whole run; do not change this to `Stop` without adjusting the surrounding try/catch handling.
- Hash mismatches are intentionally *not* deleted — the mismatched destination file is retained for manual inspection.
- `-IncludePaths` applies globally to every disc processed in a run (folder layout is assumed consistent across the batch); run the script again with a different value for discs with a different layout.
