#Requires -Version 5.1
<#
    Renders the picker frame for every theme without any key handling.
    Handy for eyeballing layout and colours, and for grabbing README shots.

    powershell -ExecutionPolicy Bypass -File tools\Show-Previews.ps1
    powershell -ExecutionPolicy Bypass -File tools\Show-Previews.ps1 -Index 3
#>
param([int]$Index = -1, [switch]$ForceColour)

$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
. (Join-Path $root 'install.ps1')

Initialize-Console
# Piping this script's output leaves stdout as a pipe, where SetConsoleMode
# cannot enable VT. -ForceColour emits the sequences anyway so they can be
# inspected, which is the only way to check them from a redirected shell.
if ($ForceColour) { $script:Vt = $true; $script:Unicode = $true }

$themes = Read-ThemeIndex (Join-Path $root 'themes\index.json')
$pals = @{}
foreach ($t in $themes) { $pals[$t.slug] = Get-ThemePalette (Join-Path $root "themes\$($t.slug).conf") }

$targets = 0..($themes.Count - 1)
if ($Index -ge 0) { $targets = @($Index) }

foreach ($i in $targets) {
    Write-Host ''
    Write-Host ("  === {0} ({1}) ===" -f $themes[$i].name, $themes[$i].slug) -ForegroundColor Cyan
    foreach ($line in (Get-PickerFrame $themes $pals $i)) { Write-Host $line }
}
Write-Host ''
Write-Host ("  vt={0}  unicode={1}" -f $script:Vt, $script:Unicode) -ForegroundColor DarkGray
Write-Host ''
