# Exodisc
"exodus" + disc, Migrating photos and files off old media

`Import-FromDisc.ps1` verifies every copied file by comparing SHA256 hashes for
the source and destination. Hash mismatches are retained for inspection and
logged with a `HASH_MISMATCH` status.

Run the tests with Pester 5 or later:

```powershell
$config = New-PesterConfiguration -Hashtable (Import-PowerShellDataFile ./PesterConfiguration.psd1)
Invoke-Pester -Configuration $config
```
