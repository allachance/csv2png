$ErrorActionPreference = 'Stop'

function Get-Sha256([string]$Path) {
    $sha256 = [Security.Cryptography.SHA256]::Create()
    $stream = $null
    try {
        $stream = [IO.File]::OpenRead((Convert-Path -LiteralPath $Path))
        return [Convert]::ToBase64String($sha256.ComputeHash($stream))
    } finally {
        if ($null -ne $stream) {
            $stream.Dispose()
        }
        $sha256.Dispose()
    }
}

Push-Location $PSScriptRoot
try {
    $files = @(Get-ChildItem -LiteralPath 'csv' -Filter '*.csv' -File | Sort-Object Name)
    if ($files.Count -eq 0) {
        throw 'No CSV files found in the examples/csv folder.'
    }

    New-Item -ItemType Directory -Path 'png', 'restored' -Force | Out-Null
    foreach ($file in $files) {
        $png = Join-Path 'png' ($file.BaseName + '.png')
        $restored = Join-Path 'restored' ($file.BaseName + '.restored.csv')

        foreach ($output in @($png, $restored)) {
            if (Test-Path -LiteralPath $output) {
                Remove-Item -LiteralPath $output -Force
            }
        }

        ..\csv2png.exe $file.FullName -o $png
        if ($LASTEXITCODE -ne 0) {
            throw "Failed to encode $($file.Name) (exit code $LASTEXITCODE)."
        }

        ..\csv2png.exe $png -o $restored
        if ($LASTEXITCODE -ne 0) {
            throw "Failed to restore $($file.Name) (exit code $LASTEXITCODE)."
        }

        $originalHash = Get-Sha256 $file.FullName
        $restoredHash = Get-Sha256 $restored
        if ($originalHash -ne $restoredHash) {
            throw "Round-trip verification failed for $($file.Name)."
        }
        Write-Host "Verified: $($file.Name)"
    }
    Write-Host "Successfully round-tripped $($files.Count) CSV files."
} finally {
    Pop-Location
}
