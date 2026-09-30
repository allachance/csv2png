$file = 'sample.csv'
$png = 'sample.png'
$restored = 'sample.restored.csv'

Push-Location $PSScriptRoot
try {
    Remove-Item $png, $restored -Force -ErrorAction SilentlyContinue
    ..\csv2png.exe $file -o $png
    ..\csv2png.exe $png -o $restored
} finally {
    Pop-Location
}
