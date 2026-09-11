# Exodisc
"exodus" + disc, Migrating photos and files off old media

`Import-FromDisc.ps1` watches an optical drive for discs (designed for old
Photo Center CDs, circa 2000-2015) and copies photo files off each one into
its own dated destination folder, ignoring the proprietary viewer app /
database files that are typically also on the disc. Files are renamed based
on their EXIF "date taken" when available.

Every copied file is verified by comparing SHA256 hashes for the source and
destination. Hash mismatches are retained for inspection (not deleted) and
logged with a `HASH_MISMATCH` status, so a disc showing signs of corruption
can be re-scanned. Read/copy errors (common on aging CD-Rs) are also logged
rather than stopping the whole run.

## Prerequisites

- **PowerShell** 5.1 or later (Windows PowerShell or PowerShell 7+).
- **ExifTool** (optional, recommended) — used to read the "date taken" EXIF
  field for accurate file naming. Download from https://exiftool.org and put
  `exiftool.exe` somewhere on `PATH`. If it isn't found, the script falls back
  to each file's last-write time.
- **Pester** 5 or later — only needed if you want to run the test suite, not
  for normal use of the script.

## Usage

Run the script and leave it running while you swap discs in and out of the
drive; it polls the drive letter continuously until you stop it with
`Ctrl+C`:

```powershell
./Import-FromDisc.ps1
```

This uses the defaults: reads from drive `D:`, writes to
`C:\Photos\Import`, and copies `*.jpg`, `*.jpeg`, `*.tif`, `*.tiff`, and
`*.png` files.

To customize the source drive, destination folder, or file types:

```powershell
./Import-FromDisc.ps1 -DriveLetter "E:" -Target "D:\PhotoImports" -Extensions "*.jpg", "*.png"
```

### Parameters

| Parameter      | Default                                              | Description                                  |
| -------------- | ----------------------------------------------------- | --------------------------------------------- |
| `-Target`      | `C:\Photos\Import`                                    | Destination root folder for imported photos.  |
| `-DriveLetter` | `D:`                                                   | Drive letter to watch for discs.               |
| `-Extensions`  | `*.jpg`, `*.jpeg`, `*.tif`, `*.tiff`, `*.png`          | File patterns to copy from each disc.          |

### While it's running

- Each disc is copied into its own folder under `-Target`, named
  `<VolumeLabel>_<yyyyMMdd_HHmmss>`.
- Copied files are renamed to their photo date (`yyyy-MM-dd_HHmmss`), with a
  `_NN` suffix appended if multiple photos share the same timestamp.
- After a disc finishes copying, eject it and insert the next one — the
  script keeps watching the same drive letter.
- Every action is appended to `_import_log.csv` in the target folder, with a
  `Status` of `OK`, `HASH_MISMATCH`, `ERROR`, or `EMPTY` (no matching files
  found on the disc).

## Testing

Use `-EstimatedDiscCount` to show estimated session completion while files are
copied:

```powershell
.\Import-FromDisc.ps1 -Target "C:\Photos\Import" -DriveLetter "D:" -EstimatedDiscCount 20
```

Without an estimate, progress still shows the current or completed disc count,
total imported photos, and total errors without a percentage.

Run the tests with Pester 5 or later:

```powershell
$config = New-PesterConfiguration -Hashtable (Import-PowerShellDataFile ./PesterConfiguration.psd1)
Invoke-Pester -Configuration $config
```
