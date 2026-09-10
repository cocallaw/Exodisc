BeforeAll {
    . (Join-Path $PSScriptRoot ".." "Import-FromDisc.ps1")
}

Describe "Copy-VerifiedFile" {
    It "copies a file and returns matching SHA256 hashes" {
        $source = Join-Path $TestDrive "source.bin"
        $destination = Join-Path $TestDrive "destination.bin"
        [System.IO.File]::WriteAllBytes($source, [byte[]](0..255))

        $result = Copy-VerifiedFile -SourcePath $source -DestinationPath $destination

        $result.IsMatch | Should -BeTrue
        $result.SourceHash | Should -Be $result.DestinationHash
        Test-Path -LiteralPath $destination | Should -BeTrue
    }

    It "returns both hashes when verification finds a mismatch" {
        $source = Join-Path $TestDrive "source.bin"
        $destination = Join-Path $TestDrive "destination.bin"
        Set-Content -LiteralPath $source -Value "photo data"
        Mock Get-FileHash {
            if ($LiteralPath -eq $source) {
                return [pscustomobject]@{ Hash = "SOURCE_HASH" }
            }

            [pscustomobject]@{ Hash = "DESTINATION_HASH" }
        }

        $result = Copy-VerifiedFile -SourcePath $source -DestinationPath $destination

        $result.IsMatch | Should -BeFalse
        $result.SourceHash | Should -Be "SOURCE_HASH"
        $result.DestinationHash | Should -Be "DESTINATION_HASH"
        Should -Invoke Get-FileHash -Times 2 -Exactly
    }

    It "surfaces hashing errors instead of reporting success" {
        $source = Join-Path $TestDrive "source.bin"
        $destination = Join-Path $TestDrive "destination.bin"
        Set-Content -LiteralPath $source -Value "photo data"
        Mock Get-FileHash { throw "hash failed" }

        { Copy-VerifiedFile -SourcePath $source -DestinationPath $destination } |
            Should -Throw "*hash failed*"
    }
}
