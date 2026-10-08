$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $MyInvocation.MyCommand.Path
$binCandidates = @(
    (Join-Path $root 'tools\winlibs\extract\mingw64\bin'),
    (Join-Path $root 'tools\winlibs\winlibs\extract\mingw64\bin')
)
$bin = $binCandidates | Where-Object { Test-Path -LiteralPath (Join-Path $_ 'g++.exe') } | Select-Object -First 1
if (-not $bin) { throw "g++ not found in bundled winlibs directories" }
$gxx = Join-Path $bin 'g++.exe'
$gcc = Join-Path $bin 'gcc.exe'
$output = Join-Path $root 'dush.exe'
$stagedOutput = Join-Path $root 'dush.building.exe'
$everythingObject = Join-Path $root 'build\everything-dush.o'
$everythingSource = Join-Path $root 'tools\Everything\SDK\src\Everything.c'

& $gcc -O2 -DUNICODE -D_UNICODE -c -o $everythingObject $everythingSource
if ($LASTEXITCODE -ne 0) { throw "Everything SDK compile failed: $LASTEXITCODE" }

& $gxx -O2 -std=c++17 -municode -static-libgcc -static-libstdc++ -pthread `
    -o $stagedOutput `
    (Join-Path $root 'src\dush_native.cpp') `
    $everythingObject `
    -ladvapi32 -lshell32
if ($LASTEXITCODE -ne 0) { throw "compile failed: $LASTEXITCODE" }
[System.IO.File]::Copy($stagedOutput, $output, $true)
Remove-Item -LiteralPath $stagedOutput -Force
Remove-Item -LiteralPath $everythingObject -Force

$dll = Join-Path $bin 'libwinpthread-1.dll'
if (Test-Path $dll) {
    Copy-Item $dll (Join-Path $root 'libwinpthread-1.dll') -Force
}
Write-Host "Built $output"
