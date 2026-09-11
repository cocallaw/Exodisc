BeforeAll {
    $originalErrorActionPreference = $ErrorActionPreference
    $ErrorActionPreference = "Stop"
    . (Join-Path $PSScriptRoot ".." "Import-FromDisc.ps1")
    $errorActionPreferenceAfterDotSource = $ErrorActionPreference
    $ErrorActionPreference = $originalErrorActionPreference
}

Describe "Copy-VerifiedFile" {
    It "does not change the caller error preference when dot-sourced" {
        $errorActionPreferenceAfterDotSource | Should -Be "Stop"
    }

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
        Test-Path -LiteralPath $destination | Should -BeTrue
        Should -Invoke Get-FileHash -Times 2 -Exactly
    }

    It "surfaces hashing errors instead of reporting success" {
        $source = Join-Path $TestDrive "source.bin"
        $destination = Join-Path $TestDrive "destination.bin"
        Set-Content -LiteralPath $source -Value "photo data"
        Mock Get-FileHash { throw "hash failed" }

        { Copy-VerifiedFile -SourcePath $source -DestinationPath $destination } |
            Should -Throw "*hash failed*"
        Test-Path -LiteralPath $destination | Should -BeTrue
    }
}

Describe "Get-DiscPhotoFiles" {
    BeforeEach {
        $driveRoot = Join-Path $TestDrive "disc"
        New-Item -ItemType Directory -Path $driveRoot -Force | Out-Null
        New-Item -ItemType Directory -Path (Join-Path $driveRoot "Originals") -Force | Out-Null
        New-Item -ItemType Directory -Path (Join-Path $driveRoot "Originals\Sub") -Force | Out-Null
        New-Item -ItemType Directory -Path (Join-Path $driveRoot "Web") -Force | Out-Null

        Set-Content -LiteralPath (Join-Path $driveRoot "Originals\photo1.jpg") -Value "a"
        Set-Content -LiteralPath (Join-Path $driveRoot "Originals\Sub\photo2.jpg") -Value "b"
        Set-Content -LiteralPath (Join-Path $driveRoot "Web\photo1_lowres.jpg") -Value "c"

        $extensions = @("*.jpg")
    }

    It "scans the whole disc recursively when no IncludePaths are given (default behavior)" {
        $result = Get-DiscPhotoFiles -DriveLetter $driveRoot -Extensions $extensions -IncludePaths @()

        $result.Files.Count | Should -Be 3
        $result.Warnings.Count | Should -Be 0
    }

    It "only returns files under a single include path, recursively" {
        $result = Get-DiscPhotoFiles -DriveLetter $driveRoot -Extensions $extensions -IncludePaths @("Originals")

        $result.Files.Count | Should -Be 2
        ($result.Files.FullName | Sort-Object) | Should -Be (
            (Join-Path $driveRoot "Originals\Sub\photo2.jpg"),
            (Join-Path $driveRoot "Originals\photo1.jpg") | Sort-Object
        )
        $result.Warnings.Count | Should -Be 0
    }

    It "unions files from multiple include paths without duplicates" {
        $result = Get-DiscPhotoFiles -DriveLetter $driveRoot -Extensions $extensions `
            -IncludePaths @("Originals", "Web")

        $result.Files.Count | Should -Be 3
        $result.Warnings.Count | Should -Be 0
    }

    It "warns and skips an include path that does not exist, but still scans valid paths" {
        $result = Get-DiscPhotoFiles -DriveLetter $driveRoot -Extensions $extensions `
            -IncludePaths @("Originals", "DoesNotExist")

        $result.Files.Count | Should -Be 2
        $result.Warnings.Count | Should -Be 1
        $result.Warnings[0] | Should -Match "DoesNotExist"
    }

    It "does not double-count files when include paths overlap/nest" {
        $result = Get-DiscPhotoFiles -DriveLetter $driveRoot -Extensions $extensions `
            -IncludePaths @("Originals", "Originals\Sub")

        $result.Files.Count | Should -Be 2
        $result.Warnings.Count | Should -Be 0
    }
}

Describe "Write-SessionProgress" {
    BeforeEach {
        Mock Write-Progress
    }

    It "shows useful totals without an estimated disc count" {
        Write-SessionProgress -CompletedDiscs 2 -ImportedPhotos 1240 -Errors 3

        Should -Invoke Write-Progress -Times 1 -Exactly -ParameterFilter {
            $Status -eq "2 discs completed, 1240 photos imported, 3 errors" -and
            $PercentComplete -eq -1
        }
    }

    It "includes current file progress in the estimated percentage" {
        Write-SessionProgress -CompletedDiscs 1 -ImportedPhotos 150 -Errors 2 `
            -CurrentFile 5 -CurrentFileCount 10 -EstimatedDiscCount 4

        Should -Invoke Write-Progress -Times 1 -Exactly -ParameterFilter {
            $Status -eq "Disc 2 of ~4, file 5 of 10, 150 photos imported, 2 errors" -and
            $PercentComplete -eq 37
        }
    }

    It "caps progress when the actual disc count exceeds the estimate" {
        Write-SessionProgress -CompletedDiscs 5 -ImportedPhotos 2000 -Errors 4 -EstimatedDiscCount 4

        Should -Invoke Write-Progress -Times 1 -Exactly -ParameterFilter {
            $Status -eq "Disc 5 of ~4, 2000 photos imported, 4 errors" -and
            $PercentComplete -eq 100
        }
    }
}
