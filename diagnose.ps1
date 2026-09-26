#Requires -Version 5.1
<#
.SYNOPSIS
    Works out why a Code::Blocks dark theme "installed fine" but did not show up.

.DESCRIPTION
    Prints every config Code::Blocks might be reading, which theme each one has
    active, whether the full dark build is installed, and a verdict.

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

function Test-IsCbConfig([string]$Path) {
    # The config folder is full of plugin data that also ends in .conf, such as
    # default.cbKeyBinder20.conf. Only a document rooted at <CodeBlocksConfig>
    # is something Code::Blocks reads settings from, so go by the root element
    # rather than guessing from the filename.
    try {
        $d = New-Object System.Xml.XmlDocument
        $d.Load($Path)
        return ($d.DocumentElement -and $d.DocumentElement.get_Name() -eq 'CodeBlocksConfig')
    } catch {
        return $false
    }
}

function Get-Active([string]$Path) {
    try {
        $d = New-Object System.Xml.XmlDocument
        $d.Load($Path)
        $n = $d.SelectSingleNode('/CodeBlocksConfig/editor/colour_sets/ACTIVE_COLOUR_SET/str')
        if ($n) { return $n.InnerText.Trim() }
        return '(no theme set)'
    } catch {
        return '(unreadable)'
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

function Get-Personalities([string]$Dir) {
    # A personality is a real Code::Blocks config that is not default.conf.
    if (-not (Test-Path $Dir)) { return @() }
    $out = @()
    foreach ($f in (Get-ChildItem -Path $Dir -Filter '*.conf' -ErrorAction SilentlyContinue)) {
        if ($f.Name -like '*.bak-*') { continue }
        if ($f.Name -eq 'default.conf') { continue }
        if (-not (Test-IsCbConfig $f.FullName)) { continue }
        $out += $f
    }
    return $out
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

function Invoke-Diagnose {

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
    $problems += 'Code::Blocks is running. Close it, then install again.'
} else {
    Good 'no'
}

# --- the roaming configs -----------------------------------------------------

Head "Configs in $CbConfigDir"
$activeTheme = $null
if (-not (Test-Path $CbConfigDir)) {
    Bad 'that folder does not exist - Code::Blocks has never been run for this user'
    $problems += 'No Code::Blocks config at all. Start Code::Blocks once, then install.'
} else {
    if (Test-Path $CbConfig) {
        $activeTheme = Get-Active $CbConfig
        Line 'default.conf   <- the one the installer writes'
        Line "  active theme : $activeTheme"
        $themes = Get-ThemeList $CbConfig
        Line "  themes in it : $(if ($themes.Count) { $themes -join ', ' } else { '(none)' })"
        Line "  last written : $((Get-Item $CbConfig).LastWriteTime)"
    } else {
        Bad 'no default.conf'
        $problems += 'No default.conf. Start Code::Blocks once, then install.'
    }

    $others = Get-Personalities $CbConfigDir
    if ($others.Count -gt 0) {
        Line ''
        Warn "$($others.Count) other personality config(s) here:"
        foreach ($o in $others) {
            Line "  $($o.Name)  active theme: $(Get-Active $o.FullName)"
        }
        Warn 'Launched with --personality=<name>, Code::Blocks reads that file'
        Warn 'instead of default.conf.'
        $problems += 'Other personality configs exist; check which one your shortcut uses.'
    }

    $plugins = @(Get-ChildItem -Path $CbConfigDir -Filter '*.conf' -ErrorAction SilentlyContinue |
                 Where-Object { $_.Name -ne 'default.conf' -and $_.Name -notlike '*.bak-*' -and
                                -not (Test-IsCbConfig $_.FullName) })
    if ($plugins.Count -gt 0) {
        Line ''
        Line "plugin data files (ignored): $(($plugins | ForEach-Object { $_.Name }) -join ', ')"
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
    if (Test-Path $exe) { Line "version  : $((Get-Item $exe).VersionInfo.ProductVersion)" }
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
$haveDark = $false
if (Test-Path $PortableDir) {
    $launcher = Get-ChildItem -Path $PortableDir -Filter 'CbLauncher.exe' -Recurse -ErrorAction SilentlyContinue |
                Select-Object -First 1
    if ($launcher) {
        $haveDark = $true
        Good "installed at $($launcher.Directory.FullName)"
        $pc = Join-Path $launcher.Directory.FullName 'AppData\codeblocks\default.conf'
        if (Test-Path $pc) { Line "its active theme : $(Get-Active $pc)" }
        $lnk = Join-Path ([Environment]::GetFolderPath('Desktop')) 'CodeBlocks Dark.lnk'
        if (Test-Path $lnk) { Good 'desktop shortcut present' } else { Warn 'no desktop shortcut' }
    } else {
        Bad "$PortableDir exists but has no CbLauncher.exe"
        $problems += 'Full dark build looks broken. Rerun install.ps1 -Reinstall.'
    }
} else {
    Line 'not installed'
}

# --- verdict -----------------------------------------------------------------

Write-Host ''
Write-Host '  Verdict' -ForegroundColor Cyan
Write-Host '  ================================================' -ForegroundColor DarkGray

$themeOk = $activeTheme -and $activeTheme -ne 'default' -and $activeTheme -notlike '(*'

# Lead with what the person actually wants to know. A stray personality file is
# worth mentioning, but it is not the headline when the real answer is "your
# theme is fine, you just never installed the part that darkens the window".
if ($themeOk) {
    Good "Editor theme '$activeTheme' is installed and active. That part worked."
} elseif (Test-Path $CbConfig) {
    Warn 'No dark theme is active in default.conf. Run install.ps1 again.'
}

if (-not $haveDark) {
    Write-Host ''
    Bad 'The full dark build is NOT installed.'
    Line 'That is why the menus, toolbars and panels are still light grey. A theme'
    Line 'only colours the code area - Code::Blocks is built on wxWidgets 3.2,'
    Line 'which has no dark mode for Windows controls.'
    Line ''
    Line 'To get a fully dark window, run this and choose option 1:'
    Write-Host '      irm https://raw.githubusercontent.com/teterw/codeblocks-dark/main/install.ps1 | iex' -ForegroundColor White
} elseif ($themeOk) {
    Write-Host ''
    Good 'Everything is installed. Open the "CodeBlocks Dark" desktop shortcut'
    Line 'for the fully dark window; the Start Menu one is the stock Code::Blocks.'
}

if ($problems.Count -gt 0) {
    Write-Host ''
    Line 'Other things worth knowing:'
    foreach ($p in $problems) { Warn $p }
}
Write-Host ''

}

# Dot-sourcing loads the helpers without running the report, for the tests.
if ($MyInvocation.InvocationName -ne '.') { Invoke-Diagnose }
