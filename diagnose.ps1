#Requires -Version 5.1
<#
.SYNOPSIS
    Works out why a Code::Blocks dark theme "installed fine" but did not show up.

.DESCRIPTION
    Prints every config Code::Blocks might be reading, which theme each one has
    active, and whether the full dark build is installed. Ends with a verdict.

    Run it and send the output to whoever is helping you.

.EXAMPLE
    .\diagnose.ps1
.EXAMPLE
    irm https://raw.githubusercontent.com/teterw/codeblocks-dark/main/diagnose.ps1 | iex
#>
param()

$ErrorActionPreference = 'Continue'

$CbConfigDir = Join-Path $env:APPDATA 'CodeBlocks'
$CbConfig    = Join-Path $CbConfigDir 'default.conf'
$PortableDir = Join-Path $env:LOCALAPPDATA 'CodeBlocksDark'

function Head($t) { Write-Host ''; Write-Host "  $t" -ForegroundColor Cyan }
function Line($t) { Write-Host "    $t" }
function Good($t) { Write-Host "    [ok] $t" -ForegroundColor Green }
function Warn($t) { Write-Host "    [!]  $t" -ForegroundColor Yellow }
function Bad($t)  { Write-Host "    [x]  $t" -ForegroundColor Red }

function Get-Active([string]$Path) {
    try {
        $d = New-Object System.Xml.XmlDocument
        $d.Load($Path)
        $n = $d.SelectSingleNode('/CodeBlocksConfig/editor/colour_sets/ACTIVE_COLOUR_SET/str')
        if ($n) { return $n.InnerText.Trim() }
        return '(no ACTIVE_COLOUR_SET)'
    } catch {
        return "(unreadable: $($_.Exception.Message))"
    }
}

function Get-ThemeList([string]$Path) {
    try {
        $d = New-Object System.Xml.XmlDocument
        $d.Load($Path)
        $sets = $d.SelectSingleNode('/CodeBlocksConfig/editor/colour_sets')
        if (-not $sets) { return @() }
        $out = @()
        foreach ($n in $sets.ChildNodes) {
            if ($n.NodeType -eq 'Element' -and @('ACTIVE_COLOUR_SET', 'ACTIVE_LANG') -notcontains $n.get_Name()) {
                $out += $n.get_Name()
            }
        }
        return $out
    } catch {
        return @()
    }
}

function Get-InstallDir {
    foreach ($key in @(
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\Code::Blocks',
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\Code::Blocks')) {
        try {
            $v = (Get-ItemProperty -Path $key -ErrorAction Stop).InstallLocation
            if ($v -and (Test-Path $v)) { return $v }
        } catch { }
    }
    foreach ($p in @("$env:ProgramFiles\CodeBlocks", "${env:ProgramFiles(x86)}\CodeBlocks")) {
        if (Test-Path (Join-Path $p 'codeblocks.exe')) { return $p }
    }
    return $null
}

Write-Host ''
Write-Host '  Code::Blocks Dark - diagnosis' -ForegroundColor Cyan
Write-Host '  ================================================' -ForegroundColor DarkGray

$problems = @()

# --- is it running right now -------------------------------------------------

Head 'Is Code::Blocks running?'
$running = @(Get-Process -Name 'codeblocks' -ErrorAction SilentlyContinue)
if ($running.Count -gt 0) {
    Bad "yes - $($running.Count) process(es)"
    foreach ($p in $running) { Line "pid $($p.Id)  $($p.Path)" }
    Warn 'Code::Blocks rewrites its config when it closes. If it was open while'
    Warn 'you installed, closing it wiped the theme back out.'
    $problems += 'Code::Blocks is running; close it, then install again.'
} else {
    Good 'no'
}

# --- the roaming configs -----------------------------------------------------

Head "Configs in $CbConfigDir"
if (-not (Test-Path $CbConfigDir)) {
    Bad 'that folder does not exist - Code::Blocks has never been run for this user'
    $problems += 'No Code::Blocks config at all. Start Code::Blocks once, then install.'
} else {
    $confs = @(Get-ChildItem -Path $CbConfigDir -Filter '*.conf' -ErrorAction SilentlyContinue |
               Where-Object { $_.Name -notlike '*.bak-*' })
    if ($confs.Count -eq 0) {
        Bad 'no .conf files found'
    }
    foreach ($c in $confs) {
        $active = Get-Active $c.FullName
        $themes = Get-ThemeList $c.FullName
        $tag = ''
        if ($c.Name -eq 'default.conf') { $tag = '  <- the one the installer writes' }
        Line ''
        Line "$($c.Name)$tag"
        Line "  active theme : $active"
        Line "  themes in it : $(if ($themes.Count) { $themes -join ', ' } else { '(none)' })"
        Line "  last written : $($c.LastWriteTime)"
    }

    $others = @($confs | Where-Object { $_.Name -ne 'default.conf' })
    if ($others.Count -gt 0) {
        Warn ''
        Warn "There are $($others.Count) other personality file(s) here. If Code::Blocks is"
        Warn 'launched with --personality=<name> it reads that file, not default.conf.'
        $problems += 'Other personality configs exist; check which one your shortcut uses.'
    }

    $backups = @(Get-ChildItem -Path $CbConfigDir -Filter 'default.conf.bak-*' -ErrorAction SilentlyContinue)
    Line ''
    Line "backups from this installer: $($backups.Count)"
}

# --- a portable install would override all of that ---------------------------

Head 'Installed Code::Blocks'
$appDir = Get-InstallDir
if (-not $appDir) {
    Warn 'could not find an installed Code::Blocks (registry or Program Files)'
} else {
    Line "location : $appDir"
    $exe = Join-Path $appDir 'codeblocks.exe'
    if (Test-Path $exe) {
        Line "version  : $((Get-Item $exe).VersionInfo.ProductVersion)"
    }
    $portableFound = $false
    foreach ($rel in @('AppData\codeblocks\default.conf', 'default.conf')) {
        $p = Join-Path $appDir $rel
        if (Test-Path $p) {
            $portableFound = $true
            Bad "portable config found: $p"
            Line "  active theme : $(Get-Active $p)"
            Warn 'Code::Blocks reads THIS file and ignores the one in %APPDATA%.'
            $problems += "Portable config at $p is what Code::Blocks actually reads."
        }
    }
    if (-not $portableFound) { Good 'no portable config overriding %APPDATA%' }
}

# --- the full dark build -----------------------------------------------------

Head 'Full dark build'
if (Test-Path $PortableDir) {
    $launcher = Get-ChildItem -Path $PortableDir -Filter 'CbLauncher.exe' -Recurse -ErrorAction SilentlyContinue |
                Select-Object -First 1
    if ($launcher) {
        Good "installed at $($launcher.Directory.FullName)"
        $pc = Join-Path $launcher.Directory.FullName 'AppData\codeblocks\default.conf'
        if (Test-Path $pc) { Line "its active theme : $(Get-Active $pc)" }
    } else {
        Bad "$PortableDir exists but has no CbLauncher.exe - reinstall with -Reinstall"
        $problems += 'Full dark build looks broken; rerun install.ps1 -Reinstall.'
    }
    $lnk = Join-Path ([Environment]::GetFolderPath('Desktop')) 'CodeBlocks Dark.lnk'
    if (Test-Path $lnk) { Good 'desktop shortcut present' } else { Warn 'no desktop shortcut' }
} else {
    Line 'not installed'
    Line 'This is the only way to get dark menus, toolbars and panels.'
}

# --- verdict -----------------------------------------------------------------

Write-Host ''
Write-Host '  Verdict' -ForegroundColor Cyan
Write-Host '  ================================================' -ForegroundColor DarkGray
if ($problems.Count -eq 0) {
    $active = if (Test-Path $CbConfig) { Get-Active $CbConfig } else { '(none)' }
    if ($active -and $active -ne 'default' -and $active -notlike '(*') {
        Good "The theme '$active' is installed and active."
        Line ''
        Line 'If the window still looks light, that is expected: a theme only colours'
        Line 'the code area. Menus, toolbars and panels stay grey because Code::Blocks'
        Line 'is built on wxWidgets 3.2, which has no dark mode on Windows.'
        Line 'For a fully dark window, run install.ps1 and pick option 1.'
    } else {
        Warn 'No dark theme is active in default.conf. Run install.ps1 again.'
    }
} else {
    foreach ($p in $problems) { Bad $p }
}
Write-Host ''
