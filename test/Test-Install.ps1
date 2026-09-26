#Requires -Version 5.1
<#
    Exercises the config splice against real-default.conf -- a genuine
    Code::Blocks-generated default.conf, complete with its comment header,
    CDATA sections and tab indentation.

    Run from the repo root:  powershell -ExecutionPolicy Bypass -File test\Test-Install.ps1
#>
$ErrorActionPreference = 'Stop'

$root = Split-Path $PSScriptRoot -Parent
. (Join-Path $root 'install.ps1')

$fixture = Join-Path $PSScriptRoot 'real-default.conf'
$themes  = Join-Path $root 'themes'
$work    = Join-Path ([System.IO.Path]::GetTempPath()) ('cbdark-test-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Path $work -Force | Out-Null

$script:Pass = 0
$script:Fail = 0

function Test-Case([string]$Name, [scriptblock]$Body) {
    try {
        & $Body
        Write-Host "  PASS  $Name" -ForegroundColor Green
        $script:Pass++
    } catch {
        Write-Host "  FAIL  $Name" -ForegroundColor Red
        Write-Host "        $($_.Exception.Message)" -ForegroundColor DarkRed
        $script:Fail++
    }
}

function Should-Be($Actual, $Expected, [string]$What) {
    if ($Actual -ne $Expected) { throw "$What : expected '$Expected', got '$Actual'" }
}

function New-Work([string]$Name) {
    $p = Join-Path $work "$Name.conf"
    Copy-Item -LiteralPath $fixture -Destination $p -Force
    return $p
}

function Get-Sets([string]$Path) {
    $d = New-Object System.Xml.XmlDocument
    $d.Load($Path)
    return $d.SelectSingleNode('/CodeBlocksConfig/editor/colour_sets')
}

function Get-Active([string]$Path) {
    $a = (Get-Sets $Path).SelectSingleNode('ACTIVE_COLOUR_SET/str')
    if (-not $a) { return $null }
    return $a.InnerText.Trim()
}

function Get-ThemeNames([string]$Path) {
    $out = @()
    foreach ($n in (Get-Sets $Path).ChildNodes) {
        if ($n.NodeType -eq 'Element' -and @('ACTIVE_COLOUR_SET', 'ACTIVE_LANG') -notcontains $n.get_Name()) {
                        $out += $n.get_Name()
        }
    }
    return $out
}

Write-Host ''
Write-Host 'Code::Blocks Dark - splice tests' -ForegroundColor Cyan
Write-Host '---------------------------------'

Test-Case 'fixture is a real CB config with a default theme' {
    $names = Get-ThemeNames $fixture
    if ($names -notcontains 'default') { throw "expected a 'default' theme, got: $($names -join ', ')" }
    Should-Be (Get-Active $fixture) 'default' 'active theme'
}

Test-Case 'installs a theme and makes it active' {
    $c = New-Work 'basic'
    $slug = Install-Theme $c (Join-Path $themes 'dracula.conf')
    Should-Be $slug 'dracula' 'returned slug'
    Should-Be (Get-Active $c) 'dracula' 'active theme'
    $names = Get-ThemeNames $c
    if ($names -notcontains 'dracula') { throw "dracula missing: $($names -join ', ')" }
}

Test-Case 'leaves the pre-existing theme in place' {
    $c = New-Work 'keeps'
    [void](Install-Theme $c (Join-Path $themes 'dracula.conf'))
    $names = Get-ThemeNames $c
    if ($names -notcontains 'default') { throw "clobbered 'default': $($names -join ', ')" }
}

Test-Case 'reinstalling the same theme replaces, never duplicates' {
    $c = New-Work 'dupe'
    [void](Install-Theme $c (Join-Path $themes 'dracula.conf'))
    [void](Install-Theme $c (Join-Path $themes 'dracula.conf'))
    [void](Install-Theme $c (Join-Path $themes 'dracula.conf'))
    $count = @(Get-ThemeNames $c | Where-Object { $_ -eq 'dracula' }).Count
    Should-Be $count 1 'dracula node count after 3 installs'
}

Test-Case 'switching themes keeps both and activates the newest' {
    $c = New-Work 'switch'
    [void](Install-Theme $c (Join-Path $themes 'dracula.conf'))
    [void](Install-Theme $c (Join-Path $themes 'solarized_dark.conf'))
    Should-Be (Get-Active $c) 'solarized_dark' 'active theme'
    $names = Get-ThemeNames $c
    foreach ($want in 'dracula', 'solarized_dark', 'default') {
        if ($names -notcontains $want) { throw "$want missing: $($names -join ', ')" }
    }
}

Test-Case 'every shipped theme installs cleanly' {
    $index = Get-Content (Join-Path $themes 'index.json') -Raw | ConvertFrom-Json
    foreach ($t in $index) {
        $c = New-Work "all-$($t.slug)"
        $slug = Install-Theme $c (Join-Path $themes "$($t.slug).conf")
        Should-Be $slug $t.slug "slug for $($t.slug)"
        Should-Be (Get-Active $c) $t.slug "active for $($t.slug)"
    }
}

Test-Case 'preserves the application-info comment header' {
    $c = New-Work 'comment'
    [void](Install-Theme $c (Join-Path $themes 'dracula.conf'))
    $raw = Get-Content $c -Raw
    if ($raw -notmatch 'application info') { throw 'comment header was dropped' }
}

Test-Case 'preserves unrelated config sections' {
    $before = Get-Sets $fixture
    $c = New-Work 'sections'
    [void](Install-Theme $c (Join-Path $themes 'dracula.conf'))
    $d = New-Object System.Xml.XmlDocument
    $d.Load($c)
    foreach ($section in 'app', 'tools', 'colours', 'code_completion') {
        if (-not $d.SelectSingleNode("/CodeBlocksConfig/$section")) {
            throw "section <$section> was lost"
        }
    }
    if (-not $d.SelectSingleNode('/CodeBlocksConfig/editor/FONT')) { throw 'editor/FONT was lost' }
}

Test-Case 'writes UTF-8 with no BOM, like Code::Blocks does' {
    $c = New-Work 'bom'
    [void](Install-Theme $c (Join-Path $themes 'dracula.conf'))
    $bytes = [System.IO.File]::ReadAllBytes($c)
    if ($bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) {
        throw 'a UTF-8 BOM was written'
    }
}

Test-Case 'writes the active theme as a CDATA section' {
    $c = New-Work 'cdata'
    [void](Install-Theme $c (Join-Path $themes 'dracula.conf'))
    $raw = Get-Content $c -Raw
    if ($raw -notmatch '<!\[CDATA\[dracula\]\]>') { throw 'active theme is not CDATA' }
}

Test-Case 'creates colour_sets when the config has none' {
    $c = Join-Path $work 'bare.conf'
    Set-Content -LiteralPath $c -Encoding Ascii -Value @(
        '<?xml version="1.0" encoding="UTF-8" standalone="yes" ?>'
        '<CodeBlocksConfig version="1">'
        '  <app />'
        '</CodeBlocksConfig>'
    )
    [void](Install-Theme $c (Join-Path $themes 'vim.conf'))
    Should-Be (Get-Active $c) 'vim' 'active theme'
    if (-not (Get-Sets $c)) { throw 'colour_sets was not created' }
}

Test-Case 'refuses a file that is not a Code::Blocks config' {
    $c = Join-Path $work 'bogus.conf'
    Set-Content -LiteralPath $c -Encoding Ascii -Value '<something><else /></something>'
    $threw = $false
    try { [void](Install-Theme $c (Join-Path $themes 'vim.conf')) } catch { $threw = $true }
    if (-not $threw) { throw 'accepted a non-CB config' }
}

Test-Case 'leaves no .tmp file behind' {
    $c = New-Work 'tmp'
    [void](Install-Theme $c (Join-Path $themes 'dracula.conf'))
    if (Test-Path "$c.tmp") { throw 'temp file was left behind' }
}

Test-Case 'every preview token resolves a colour in every theme' {
    $index = Get-Content (Join-Path $themes 'index.json') -Raw | ConvertFrom-Json
    $tokens = 'Default', 'Keyword', 'String', 'Number', 'Comment', 'Operator', 'Preprocessor'
    foreach ($t in $index) {
        $pal = Get-ThemePalette (Join-Path $themes "$($t.slug).conf")
        if (-not $pal['Default'].Back) { throw "$($t.slug) has no background colour" }
        foreach ($tok in $tokens) {
            if (-not (Get-PalColour $pal $tok $null)) { throw "$($t.slug) cannot resolve '$tok'" }
        }
    }
}

Test-Case 'previews are legible: syntax colours differ from plain text' {
    $index = Get-Content (Join-Path $themes 'index.json') -Raw | ConvertFrom-Json
    foreach ($t in $index) {
        $pal = Get-ThemePalette (Join-Path $themes "$($t.slug).conf")
        $base = (Get-BaseColours $pal)
        foreach ($tok in 'Keyword', 'String', 'Number', 'Comment') {
            $c = Get-PalColour $pal $tok $base.Fore
            if (($c -join ',') -eq ($base.Fore -join ',')) {
                throw "$($t.slug): '$tok' is the same colour as plain text, preview would be flat"
            }
        }
    }
}

Test-Case 'preview rows pad to an even width so the card edge stays straight' {
    $pal = Get-ThemePalette (Join-Path $themes 'dracula.conf')
    $plain = @()
    foreach ($line in (Get-PreviewLines $pal 30)) {
        $plain += ($line -replace "$([char]27)\[[0-9;]*m", '')
    }
    $widths = $plain | ForEach-Object { $_.Length } | Sort-Object -Unique
    if (@($widths).Count -ne 1) { throw "ragged preview widths: $($widths -join ', ')" }
}

Test-Case 'theme index enumerates one entry per theme' {
    $index = Read-ThemeIndex (Join-Path $themes 'index.json')
    $files = @(Get-ChildItem -Path $themes -Filter '*.conf')
    Should-Be $index.Count $files.Count 'index entries vs .conf files'
    if ($index[0] -isnot [psobject] -or -not $index[0].slug) {
        throw 'index entries did not enumerate (PS 5.1 ConvertFrom-Json array wrapping)'
    }
}

Test-Case 'picker frame card edges line up' {
    $index = Read-ThemeIndex (Join-Path $themes 'index.json')
    $pals = @{}
    foreach ($t in $index) { $pals[$t.slug] = Get-ThemePalette (Join-Path $themes "$($t.slug).conf") }
    $frame = Get-PickerFrame $index $pals 0
    # Built from code points so this file stays pure ASCII: PowerShell 5.1
    # reads a .ps1 as ANSI unless it carries a BOM.
    $box = ([char]0x2500, [char]0x250C, [char]0x2510, [char]0x2514,
            [char]0x2518, [char]0x2502, '+', '-', '|')
    $widths = @()
    foreach ($line in $frame) {
        $plain = $line -replace "$([char]27)\[[0-9;]*m", ''
        if ($plain.IndexOfAny([char[]]$box) -ge 0) { $widths += $plain.Length }
    }
    $unique = @($widths | Sort-Object -Unique)
    if ($unique.Count -ne 1) { throw "card rows have widths: $($unique -join ', ')" }
}

Test-Case 'picker frame marks exactly one selected row' {
    $index = Read-ThemeIndex (Join-Path $themes 'index.json')
    $pals = @{}
    foreach ($t in $index) { $pals[$t.slug] = Get-ThemePalette (Join-Path $themes "$($t.slug).conf") }
    foreach ($i in 0, 3, ($index.Count - 1)) {
        $frame = Get-PickerFrame $index $pals $i
        $marked = @($frame | Where-Object { ($_ -replace "$([char]27)\[[0-9;]*m", '') -match '^\s{2}>\s' })
        Should-Be $marked.Count 1 "selected rows at index $i"
        if (($marked[0] -replace "$([char]27)\[[0-9;]*m", '') -notmatch [regex]::Escape($index[$i].name)) {
            throw "marker is not on $($index[$i].name)"
        }
    }
}

Test-Case 'backup is a byte-for-byte copy' {
    $c = New-Work 'backup'
    $before = [System.IO.File]::ReadAllBytes($c)
    $bak = Backup-Config $c
    [void](Install-Theme $c (Join-Path $themes 'dracula.conf'))
    $saved = [System.IO.File]::ReadAllBytes($bak)
    Should-Be $saved.Length $before.Length 'backup length'
    for ($i = 0; $i -lt $before.Length; $i++) {
        if ($saved[$i] -ne $before[$i]) { throw "backup differs at byte $i" }
    }
}

Test-Case 'restoring the backup returns the config to its original bytes' {
    $c = New-Work 'restore'
    $before = [System.IO.File]::ReadAllBytes($c)
    $bak = Backup-Config $c
    [void](Install-Theme $c (Join-Path $themes 'kft2.conf'))
    Copy-Item -LiteralPath $bak -Destination $c -Force
    $after = [System.IO.File]::ReadAllBytes($c)
    Should-Be $after.Length $before.Length 'restored length'
    for ($i = 0; $i -lt $before.Length; $i++) {
        if ($after[$i] -ne $before[$i]) { throw "restored file differs at byte $i" }
    }
}

Remove-Item $work -Recurse -Force -ErrorAction SilentlyContinue

Write-Host '---------------------------------'
Write-Host ("  {0} passed, {1} failed" -f $script:Pass, $script:Fail) -ForegroundColor $(if ($script:Fail) { 'Red' } else { 'Green' })
Write-Host ''
if ($script:Fail) { exit 1 }
