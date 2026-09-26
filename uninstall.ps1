#Requires -Version 5.1
<#
.SYNOPSIS
    Undoes install.ps1: restores a backed-up Code::Blocks config and removes
    the portable dark build.

.DESCRIPTION
    install.ps1 copies default.conf to default.conf.bak-<timestamp> before it
    changes anything. This restores one of those, newest first.

.PARAMETER Backup
    Full path to a specific backup to restore. Otherwise you get a list.

.PARAMETER Latest
    Restore the newest backup without asking.

.PARAMETER KeepPortable
    Leave the portable dark build and its desktop shortcut alone.

.EXAMPLE
    .\uninstall.ps1
.EXAMPLE
    .\uninstall.ps1 -Latest
#>
[CmdletBinding()]
param(
    [string]$Backup,
    [switch]$Latest,
    [switch]$KeepPortable
)

$ErrorActionPreference = 'Stop'

$CbConfig    = Join-Path $env:APPDATA 'CodeBlocks\default.conf'
$PortableDir = Join-Path $env:LOCALAPPDATA 'CodeBlocksDark'
$Shortcut    = Join-Path ([Environment]::GetFolderPath('Desktop')) 'CodeBlocks Dark.lnk'

function Write-Step ($m) { Write-Host "  $m" }
function Write-Good ($m) { Write-Host "  [ok] $m" -ForegroundColor Green }
function Write-Note ($m) { Write-Host "  [!]  $m" -ForegroundColor Yellow }

Write-Host ''
Write-Host '  Code::Blocks Dark - uninstall' -ForegroundColor Cyan
Write-Host '  ------------------------------------------------' -ForegroundColor DarkGray

# --- restore the config -----------------------------------------------------

$backups = @(Get-ChildItem -Path (Split-Path $CbConfig -Parent) -Filter 'default.conf.bak-*' -ErrorAction SilentlyContinue |
             Sort-Object LastWriteTime -Descending)

if ($backups.Count -eq 0) {
    Write-Note 'No backups found, so the Code::Blocks config is left untouched.'
    Write-Note 'You can also switch theme by hand:'
    Write-Note 'Settings > Editor > Syntax highlighting > Colour theme.'
} else {
    $pick = $null
    if ($Backup) {
        if (-not (Test-Path $Backup)) { throw "No such backup: $Backup" }
        $pick = Get-Item $Backup
    } elseif ($Latest -or $backups.Count -eq 1) {
        $pick = $backups[0]
    } else {
        Write-Host ''
        Write-Host '  Backups found:' -ForegroundColor White
        for ($i = 0; $i -lt $backups.Count; $i++) {
            Write-Host ("   {0,2}. {1}   {2}" -f ($i + 1), $backups[$i].LastWriteTime, $backups[$i].Name)
        }
        Write-Host ''
        $answer = Read-Host '  Restore which? (blank to skip)'
        if ($answer) {
            $num = 0
            if ([int]::TryParse($answer, [ref]$num) -and $num -ge 1 -and $num -le $backups.Count) {
                $pick = $backups[$num - 1]
            } else {
                Write-Note 'Not a valid number; leaving the config alone.'
            }
        }
    }

    if ($pick) {
        $running = @(Get-Process -Name 'codeblocks' -ErrorAction SilentlyContinue)
        if ($running.Count -gt 0) {
            Write-Note 'Code::Blocks is running and would overwrite the restore on exit.'
            [void](Read-Host '  Close Code::Blocks, then press Enter')
            $running = @(Get-Process -Name 'codeblocks' -ErrorAction SilentlyContinue)
            if ($running.Count -gt 0) { throw 'Code::Blocks is still running - stopping.' }
        }
        Copy-Item -LiteralPath $pick.FullName -Destination $CbConfig -Force
        Write-Good "Restored $($pick.Name)"
    }
}

# --- remove the portable build ----------------------------------------------

if (-not $KeepPortable) {
    if (Test-Path $PortableDir) {
        Remove-Item $PortableDir -Recurse -Force
        Write-Good "Removed $PortableDir"
    }
    if (Test-Path $Shortcut) {
        Remove-Item $Shortcut -Force
        Write-Good 'Removed the desktop shortcut'
    }
}

Write-Host ''
Write-Host '  Done.' -ForegroundColor Green
Write-Host ''
