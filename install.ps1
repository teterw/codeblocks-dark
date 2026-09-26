#Requires -Version 5.1
<#
.SYNOPSIS
    Installs a dark colour theme into Code::Blocks on Windows, with live previews.

.DESCRIPTION
    Code::Blocks keeps its colour themes inside %APPDATA%\CodeBlocks\default.conf.
    The supported way to add one is a manual trip through cb_share_config.exe.
    This script performs the same splice directly, after taking a backup.

    It can also fetch the experimental full-dark portable build, which is the
    only way to get dark menus and panels on Windows: stock Code::Blocks is
    built against wxWidgets 3.2, whose Win32 controls ignore dark mode.

.PARAMETER Theme
    Theme slug to install without prompting, e.g. 'dracula'. See -List.

.PARAMETER Mode
    theme    - theme the installed Code::Blocks (default)
    portable - only fetch the full-dark portable build
    both     - do both

.PARAMETER List
    Print the available themes and exit.

.PARAMETER NoPreview
    Skip the colour previews and use a plain numbered menu.

.EXAMPLE
    .\install.ps1

.EXAMPLE
    .\install.ps1 -Theme dracula -Mode both
#>
# No [CmdletBinding()] and no validation attributes on these parameters.
# `irm ... | iex` executes this text in the caller's scope, where param() is not
# parameter binding at all -- it declares variables and attaches the attributes
# right away. A [ValidateSet] on $Mode would then validate its empty default and
# throw before the script ran. -Mode is checked by hand further down instead.
param(
    [string]$Theme,
    [string]$Mode,
    [switch]$List,
    [switch]$NoPreview
)

$ErrorActionPreference = 'Stop'

$ValidModes = @('theme', 'portable', 'both')

$RepoRaw  = 'https://raw.githubusercontent.com/teterw/codeblocks-dark/main'
$CbConfig = Join-Path $env:APPDATA 'CodeBlocks\default.conf'

# The only prebuilt full-dark Code::Blocks (adbrt/codeblocks-dark-mode-msw).
# Single release, 26 Nov 2023. Hash pinned so a swapped asset cannot slip by.
$PortableUrl    = 'https://github.com/adbrt/codeblocks-dark-mode-msw/releases/download/release/CodeBlocks_DarkMode-MSW_26nov2023a.zip'
$PortableSha256 = '79e17b92f9045de88d528e4e1678a41980aacf23c9699c2aa11ce5db2e083520'
$PortableDir    = Join-Path $env:LOCALAPPDATA 'CodeBlocksDark'

# Siblings of the theme nodes inside <colour_sets> that are not themes.
$NonTheme = @('ACTIVE_COLOUR_SET', 'ACTIVE_LANG')

#region console --------------------------------------------------------------

$script:Vt = $false
$script:Unicode = $false
$ESC = [char]27

function Initialize-Console {
    # Box-drawing characters need a UTF-8 console.
    try {
        [Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false)
        $script:Unicode = $true
    } catch {
        $script:Unicode = $false
    }

    # Windows Terminal always speaks 24-bit colour. Older conhost needs
    # ENABLE_VIRTUAL_TERMINAL_PROCESSING (0x0004) switched on by hand.
    if ($env:WT_SESSION) { $script:Vt = $true; return }
    try {
        if (-not ('Vt.Native' -as [type])) {
            Add-Type -Namespace Vt -Name Native -MemberDefinition @"
[DllImport("kernel32.dll", SetLastError=true)]
public static extern IntPtr GetStdHandle(int nStdHandle);
[DllImport("kernel32.dll", SetLastError=true)]
public static extern bool GetConsoleMode(IntPtr hConsoleHandle, out uint lpMode);
[DllImport("kernel32.dll", SetLastError=true)]
public static extern bool SetConsoleMode(IntPtr hConsoleHandle, uint dwMode);
"@
        }
        $handle = [Vt.Native]::GetStdHandle(-11)
        $mode = 0
        if ([Vt.Native]::GetConsoleMode($handle, [ref]$mode)) {
            $script:Vt = [Vt.Native]::SetConsoleMode($handle, $mode -bor 0x0004)
        }
    } catch {
        $script:Vt = $false
    }
}

function Get-Fg([int[]]$c) { if ($script:Vt) { "$ESC[38;2;$($c[0]);$($c[1]);$($c[2])m" } else { '' } }
function Get-Bg([int[]]$c) { if ($script:Vt) { "$ESC[48;2;$($c[0]);$($c[1]);$($c[2])m" } else { '' } }
function Get-Reset         { if ($script:Vt) { "$ESC[0m" } else { '' } }

function Write-Step ($m) { Write-Host "  $m" }
function Write-Good ($m) { Write-Host "  [ok] $m" -ForegroundColor Green }
function Write-Note ($m) { Write-Host "  [!]  $m" -ForegroundColor Yellow }

#endregion

#region theme loading --------------------------------------------------------

function Get-ThemeStore {
    # Themes sit next to the script in a checkout or the zip. Piped through
    # `irm | iex` there is no script root, so fetch them instead.
    $local = $null
    if ($PSScriptRoot) { $local = Join-Path $PSScriptRoot 'themes' }
    if ($local -and (Test-Path (Join-Path $local 'index.json'))) {
        return [pscustomobject]@{ Path = $local; Remote = $false }
    }

    $tmp = Join-Path ([System.IO.Path]::GetTempPath()) ('cbdark-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
    New-Item -ItemType Directory -Path $tmp -Force | Out-Null
    Write-Step 'Fetching themes...'
    $old = $ProgressPreference
    $ProgressPreference = 'SilentlyContinue'
    try {
        Invoke-WebRequest -Uri "$RepoRaw/themes/index.json" -OutFile (Join-Path $tmp 'index.json') -UseBasicParsing
        foreach ($t in (Read-ThemeIndex (Join-Path $tmp 'index.json'))) {
            Invoke-WebRequest -Uri "$RepoRaw/themes/$($t.slug).conf" -OutFile (Join-Path $tmp "$($t.slug).conf") -UseBasicParsing
        }
    } finally {
        $ProgressPreference = $old
    }
    return [pscustomobject]@{ Path = $tmp; Remote = $true }
}

function Read-ThemeIndex([string]$Path) {
    # Windows PowerShell 5.1 hands the decoded JSON array to the pipeline as a
    # single object, so @(...) around it yields one Object[] element rather than
    # one element per theme. ForEach-Object forces the enumeration, and still
    # returns a real array when the index holds a single theme.
    $decoded = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
    return @($decoded | ForEach-Object { $_ })
}

function Get-ThemeNode($SetsNode) {
    # get_Name() rather than .Name: PowerShell's XML adapter exposes child
    # elements as properties and is case-insensitive, so $node.Name returns the
    # theme's <NAME> child element instead of the node's own name.
    foreach ($n in $SetsNode.ChildNodes) {
        if ($n.NodeType -ne 'Element') { continue }
        if ($NonTheme -contains $n.get_Name()) { continue }
        return $n
    }
    return $null
}

function Get-ThemePalette([string]$ThemePath) {
    $x = New-Object System.Xml.XmlDocument
    $x.Load($ThemePath)
    $sets = $x.SelectSingleNode('/CodeBlocksConfig/editor/colour_sets')
    if (-not $sets) { throw "No colour_sets in $ThemePath" }
    $theme = Get-ThemeNode $sets
    if (-not $theme) { throw "No theme node in $ThemePath" }

    $lex = $theme.SelectSingleNode('cc')
    if (-not $lex) { $lex = $theme.SelectSingleNode('java') }
    if (-not $lex) { throw "No C/C++ lexer in $ThemePath" }

    # Map by each style's own NAME label rather than by style index: the
    # numbering differs between lexers and between theme authors.
    $pal = @{}
    foreach ($st in $lex.ChildNodes) {
        if ($st.NodeType -ne 'Element') { continue }
        $nameNode = $st.SelectSingleNode('NAME/str')
        if (-not $nameNode) { continue }
        $nm = $nameNode.InnerText.Trim()
        if ($nm -eq '' -or $pal.ContainsKey($nm)) { continue }
        $entry = @{ Fore = $null; Back = $null }
        $f = $st.SelectSingleNode('FORE/colour')
        if ($f) { $entry.Fore = @([int]$f.r, [int]$f.g, [int]$f.b) }
        $b = $st.SelectSingleNode('BACK/colour')
        if ($b) { $entry.Back = @([int]$b.r, [int]$b.g, [int]$b.b) }
        $pal[$nm] = $entry
    }
    return $pal
}

#endregion

#region preview --------------------------------------------------------------

# Each row is a list of (token, literal text) pairs.
$Snippet = @(
    @(, @('Preprocessor', '#include <stdio.h>')),
    @(),
    @(, @('Comment', '// dark mode, finally')),
    @(@('Keyword', 'int'), @('Default', ' main'), @('Operator', '() {')),
    @(@('Default', '    printf'), @('Operator', '('), @('String', '"hello"'), @('Operator', ');')),
    @(@('Keyword', '    return'), @('Number', ' 0'), @('Operator', ';')),
    @(, @('Operator', '}'))
)

# Not every theme defines every style. dark_gray, for one, has no
# "Comment (normal)" at all -- only "Comment line (documentation)". Each token
# walks its candidates in order and takes the first the theme actually sets.
$StyleAliases = @{
    'Default'      = @('Default')
    'Keyword'      = @('Keyword', 'User keyword')
    'String'       = @('String', 'Character')
    'Number'       = @('Number')
    'Operator'     = @('Operator', 'Default')
    'Preprocessor' = @('Preprocessor', 'Keyword')
    'Comment'      = @('Comment (normal)', 'Comment line (normal)', 'Comment',
                       'Comment (documentation)', 'Comment line (documentation)',
                       'Comment (inactive)')
}

function Get-PalColour($Pal, [string]$Token, $Fallback) {
    $names = @($Token)
    if ($StyleAliases.ContainsKey($Token)) { $names = $StyleAliases[$Token] }
    foreach ($n in $names) {
        if ($Pal.ContainsKey($n) -and $Pal[$n].Fore) { return $Pal[$n].Fore }
    }
    return $Fallback
}

function Get-BaseColours($Pal) {
    $fg = @(220, 220, 220)
    $bg = @(30, 30, 30)
    if ($Pal.ContainsKey('Default')) {
        if ($Pal['Default'].Fore) { $fg = $Pal['Default'].Fore }
        if ($Pal['Default'].Back) { $bg = $Pal['Default'].Back }
    }
    return @{ Fore = $fg; Back = $bg }
}

function Get-PreviewLines($Pal, [int]$Width) {
    $base = Get-BaseColours $Pal
    $lines = @()
    foreach ($row in $Snippet) {
        $painted = ''
        $plain = ''
        foreach ($tok in $row) {
            $colour = Get-PalColour $Pal $tok[0] $base.Fore
            $painted += (Get-Fg $colour) + $tok[1]
            $plain += $tok[1]
        }
        $pad = $Width - $plain.Length
        if ($pad -lt 0) { $pad = 0 }
        $lines += (Get-Bg $base.Back) + ' ' + $painted + (' ' * $pad) + (Get-Reset)
    }
    return $lines
}

function Get-Swatch($Pal) {
    $block = '#'
    if ($script:Unicode) { $block = [string][char]0x2588 }
    $base = Get-BaseColours $Pal
    $out = ''
    foreach ($n in @('Keyword', 'String', 'Number')) {
        $c = Get-PalColour $Pal $n $base.Fore
        $out += (Get-Bg $base.Back) + (Get-Fg $c) + $block
    }
    return $out + (Get-Reset)
}

function Get-PickerFrame($Themes, $Pals, [int]$Index, [int]$CardWidth = 30) {
    # Returns the whole screen as an array of lines: theme list down the left,
    # a live preview of the highlighted theme on the right.
    $nameW = 0
    foreach ($t in $Themes) { if ($t.name.Length -gt $nameW) { $nameW = $t.name.Length } }
    $leftW = $nameW + 11   # "  > " + name + "  " + 3 swatch blocks + "  "

    if ($script:Unicode) {
        $tl = [char]0x250C; $tr = [char]0x2510
        $bl = [char]0x2514; $br = [char]0x2518
        $hz = [char]0x2500; $vt = [char]0x2502
    } else {
        $tl = '+'; $tr = '+'; $bl = '+'; $br = '+'; $hz = '-'; $vt = '|'
    }

    $preview = Get-PreviewLines $Pals[$Themes[$Index].slug] $CardWidth
    # Content rows are one leading space plus text padded to $CardWidth, so the
    # horizontal rule has to be $CardWidth + 1 for the edges to line up.
    $bar = [string]$hz * ($CardWidth + 1)
    $rows = [Math]::Max($Themes.Count, $preview.Count + 2)
    $out = @()

    for ($r = 0; $r -lt $rows; $r++) {
        if ($r -lt $Themes.Count) {
            $marker = ' '
            if ($r -eq $Index) { $marker = '>' }
            $left = "  $marker " + $Themes[$r].name.PadRight($nameW) + '  ' + (Get-Swatch $Pals[$Themes[$r].slug]) + '  '
        } else {
            $left = ' ' * $leftW
        }

        $right = ''
        if ($r -eq 0) { $right = "$tl$bar$tr" }
        elseif ($r -eq $preview.Count + 1) { $right = "$bl$bar$br" }
        elseif ($r -le $preview.Count) { $right = "$vt" + $preview[$r - 1] + "$vt" }

        $out += ($left + $right)
    }
    return $out
}

function Show-Picker($Themes, $Store) {
    $pals = @{}
    foreach ($t in $Themes) {
        $pals[$t.slug] = Get-ThemePalette (Join-Path $Store.Path "$($t.slug).conf")
    }

    $i = 0
    while ($true) {
        Clear-Host
        Write-Host ''
        Write-Host '  Code::Blocks Dark' -ForegroundColor Cyan -NoNewline
        Write-Host '    up/down move   Enter install   Esc cancel' -ForegroundColor DarkGray
        Write-Host ''

        foreach ($line in (Get-PickerFrame $Themes $pals $i)) { Write-Host $line }

        $sel = $Themes[$i]
        Write-Host ''
        Write-Host "  $($sel.name)" -ForegroundColor White -NoNewline
        Write-Host "   background $($sel.background)   slug $($sel.slug)" -ForegroundColor DarkGray

        $key = [Console]::ReadKey($true)
        switch ($key.Key) {
            'UpArrow'   { $i = ($i - 1 + $Themes.Count) % $Themes.Count }
            'DownArrow' { $i = ($i + 1) % $Themes.Count }
            'Home'      { $i = 0 }
            'End'       { $i = $Themes.Count - 1 }
            'Enter'     { Clear-Host; return $sel }
            'Escape'    { Clear-Host; return $null }
        }
    }
}

function Show-PlainPicker($Themes) {
    Write-Host ''
    for ($n = 0; $n -lt $Themes.Count; $n++) {
        Write-Host ("   {0,2}. {1,-26} background {2}" -f ($n + 1), $Themes[$n].name, $Themes[$n].background)
    }
    Write-Host ''
    while ($true) {
        $answer = Read-Host '  Theme number (blank to cancel)'
        if (-not $answer) { return $null }
        $num = 0
        if ([int]::TryParse($answer, [ref]$num) -and $num -ge 1 -and $num -le $Themes.Count) {
            return $Themes[$num - 1]
        }
        Write-Note 'Not a valid number.'
    }
}

#endregion

#region config splice --------------------------------------------------------

function Save-XmlNoBom($Doc, [string]$Path) {
    # Code::Blocks writes UTF-8 with no BOM and TinyXML is happier without one.
    # Write to a sibling temp file first so a failure cannot truncate a config.
    $settings = New-Object System.Xml.XmlWriterSettings
    $settings.Encoding = New-Object System.Text.UTF8Encoding($false)
    $settings.Indent = $false
    $tmp = "$Path.tmp"
    $writer = [System.Xml.XmlWriter]::Create($tmp, $settings)
    try {
        $Doc.Save($writer)
    } finally {
        $writer.Dispose()
    }
    Move-Item -LiteralPath $tmp -Destination $Path -Force
}

function Install-Theme([string]$ConfigPath, [string]$ThemePath) {
    $src = New-Object System.Xml.XmlDocument
    $src.Load($ThemePath)
    $srcSets = $src.SelectSingleNode('/CodeBlocksConfig/editor/colour_sets')
    if (-not $srcSets) { throw "No colour_sets in $ThemePath" }
    $srcTheme = Get-ThemeNode $srcSets
    if (-not $srcTheme) { throw "No theme node in $ThemePath" }
    $slug = $srcTheme.get_Name()

    $doc = New-Object System.Xml.XmlDocument
    $doc.PreserveWhitespace = $true   # keep CB's comment header and layout
    $doc.Load($ConfigPath)

    $root = $doc.DocumentElement
    if (-not $root -or $root.get_Name() -ne 'CodeBlocksConfig') {
        throw "$ConfigPath is not a Code::Blocks config"
    }

    $editor = $root.SelectSingleNode('editor')
    if (-not $editor) { $editor = $root.AppendChild($doc.CreateElement('editor')) }
    $sets = $editor.SelectSingleNode('colour_sets')
    if (-not $sets) { $sets = $editor.AppendChild($doc.CreateElement('colour_sets')) }

    $imported = $doc.ImportNode($srcTheme, $true)
    $existing = $null
    foreach ($n in $sets.ChildNodes) {
        if ($n.NodeType -eq 'Element' -and $n.get_Name() -eq $slug) { $existing = $n; break }
    }
    if ($existing) { [void]$sets.ReplaceChild($imported, $existing) }
    else { [void]$sets.AppendChild($imported) }

    $active = $sets.SelectSingleNode('ACTIVE_COLOUR_SET')
    if (-not $active) {
        $active = $doc.CreateElement('ACTIVE_COLOUR_SET')
        if ($sets.FirstChild) { [void]$sets.InsertBefore($active, $sets.FirstChild) }
        else { [void]$sets.AppendChild($active) }
    }
    $str = $active.SelectSingleNode('str')
    if (-not $str) { $str = $active.AppendChild($doc.CreateElement('str')) }
    $str.RemoveAll()
    [void]$str.AppendChild($doc.CreateCDataSection($slug))

    Save-XmlNoBom $doc $ConfigPath
    return $slug
}

function Backup-Config([string]$ConfigPath) {
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $bak = "$ConfigPath.bak-$stamp"
    Copy-Item -LiteralPath $ConfigPath -Destination $bak -Force
    return $bak
}

function Assert-CodeBlocksClosed {
    $running = @(Get-Process -Name 'codeblocks' -ErrorAction SilentlyContinue)
    if ($running.Count -eq 0) { return }
    Write-Note 'Code::Blocks is running. It rewrites default.conf when it exits,'
    Write-Note 'which would wipe the theme straight back out again.'
    [void](Read-Host '  Close Code::Blocks, then press Enter')
    $running = @(Get-Process -Name 'codeblocks' -ErrorAction SilentlyContinue)
    if ($running.Count -gt 0) {
        throw 'Code::Blocks is still running - stopping so nothing is lost.'
    }
}

#endregion

#region portable build -------------------------------------------------------

function Install-Portable([string]$ThemeConf) {
    Write-Step 'Downloading the full-dark portable build (~36 MB)...'
    $zip = Join-Path ([System.IO.Path]::GetTempPath()) 'cb-darkmode.zip'
    $old = $ProgressPreference
    $ProgressPreference = 'SilentlyContinue'
    try {
        Invoke-WebRequest -Uri $PortableUrl -OutFile $zip -UseBasicParsing
    } finally {
        $ProgressPreference = $old
    }

    $hash = (Get-FileHash -Path $zip -Algorithm SHA256).Hash.ToLower()
    if ($hash -ne $PortableSha256.ToLower()) {
        Remove-Item $zip -Force -ErrorAction SilentlyContinue
        throw "Checksum mismatch. Expected $PortableSha256 but got $hash. Download rejected."
    }
    Write-Good 'Checksum verified.'

    if (Test-Path $PortableDir) { Remove-Item $PortableDir -Recurse -Force }
    New-Item -ItemType Directory -Path $PortableDir -Force | Out-Null
    Expand-Archive -Path $zip -DestinationPath $PortableDir -Force
    Remove-Item $zip -Force -ErrorAction SilentlyContinue

    $launcher = Get-ChildItem -Path $PortableDir -Filter 'CbLauncher.exe' -Recurse | Select-Object -First 1
    if (-not $launcher) { throw 'CbLauncher.exe not found inside the archive.' }
    $appRoot = $launcher.Directory.FullName

    # The portable build keeps its config beside the exe, so theming it never
    # touches the real Code::Blocks install.
    $portConf = Join-Path $appRoot 'AppData\codeblocks\default.conf'
    $portDir = Split-Path $portConf -Parent
    if (-not (Test-Path $portDir)) { New-Item -ItemType Directory -Path $portDir -Force | Out-Null }
    if (Test-Path $portConf) { [void](Install-Theme $portConf $ThemeConf) }
    else { Copy-Item -LiteralPath $ThemeConf -Destination $portConf -Force }

    $lnk = Join-Path ([Environment]::GetFolderPath('Desktop')) 'CodeBlocks Dark.lnk'
    $shell = New-Object -ComObject WScript.Shell
    $shortcut = $shell.CreateShortcut($lnk)
    $shortcut.TargetPath = $launcher.FullName
    $shortcut.WorkingDirectory = $appRoot
    $shortcut.Description = 'Code::Blocks with a full dark UI (experimental build)'
    $shortcut.Save()

    return [pscustomobject]@{ Root = $appRoot; Launcher = $launcher.FullName; Shortcut = $lnk }
}

#endregion

#region main -----------------------------------------------------------------

function Invoke-CbDark {

Initialize-Console
Write-Host ''
Write-Host '  Code::Blocks Dark' -ForegroundColor Cyan
Write-Host '  ------------------------------------------------' -ForegroundColor DarkGray

$store = Get-ThemeStore
$themes = Read-ThemeIndex (Join-Path $store.Path 'index.json')

if ($List) {
    foreach ($t in $themes) { Write-Host ("   {0,-26} {1}" -f $t.slug, $t.name) }
    return
}

$hasCb = Test-Path $CbConfig
if (-not $hasCb) {
    Write-Note "No Code::Blocks config found at $CbConfig"
    Write-Note 'Start Code::Blocks once so it writes one, or choose the portable build.'
}

if ($Mode -and $ValidModes -notcontains $Mode) {
    throw "Unknown -Mode '$Mode'. Use one of: $($ValidModes -join ', ')."
}

if (-not $Mode) {
    Write-Host ''
    Write-Host '  What should this install?' -ForegroundColor White
    Write-Host '    1. Dark theme for my Code::Blocks     (recommended)'
    Write-Host '    2. Full-dark portable Code::Blocks    (~36 MB, 2023 build)'
    Write-Host '    3. Both'
    Write-Host ''
    $choice = Read-Host '  Choice [1]'
    switch ($choice) {
        '2'     { $Mode = 'portable' }
        '3'     { $Mode = 'both' }
        default { $Mode = 'theme' }
    }
}

if (($Mode -eq 'theme' -or $Mode -eq 'both') -and -not $hasCb) {
    throw "Cannot theme Code::Blocks: $CbConfig does not exist. Start Code::Blocks once first."
}

$chosen = $null
if ($Theme) {
    $chosen = $themes | Where-Object { $_.slug -eq $Theme } | Select-Object -First 1
    if (-not $chosen) { throw "Unknown theme '$Theme'. Run with -List to see the slugs." }
} elseif ($NoPreview -or -not $script:Vt) {
    if (-not $script:Vt) { Write-Note 'This console has no 24-bit colour; using a plain list.' }
    $chosen = Show-PlainPicker $themes
} else {
    $chosen = Show-Picker $themes $store
}

if (-not $chosen) {
    Write-Step 'Cancelled. Nothing was changed.'
    return
}

$themeConf = Join-Path $store.Path "$($chosen.slug).conf"
$done = @()
$bak = $null

if ($Mode -eq 'theme' -or $Mode -eq 'both') {
    Assert-CodeBlocksClosed
    $bak = Backup-Config $CbConfig
    Write-Good "Backed up your config to $(Split-Path $bak -Leaf)"
    $slug = Install-Theme $CbConfig $themeConf
    Write-Good "Installed '$slug' into $CbConfig"
    $done += 'Start Code::Blocks - the theme is already active.'
}

if ($Mode -eq 'portable' -or $Mode -eq 'both') {
    $portable = Install-Portable $themeConf
    Write-Good "Portable build unpacked to $($portable.Root)"
    Write-Good "Desktop shortcut created: $(Split-Path $portable.Shortcut -Leaf)"
    $done += 'Open the "CodeBlocks Dark" desktop shortcut for the full dark UI.'
}

if ($store.Remote) {
    Remove-Item $store.Path -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host ''
Write-Host '  Done.' -ForegroundColor Green
foreach ($line in $done) { Write-Host "    - $line" }
Write-Host ''

# Run from the zip there is an uninstall.ps1 sitting right here. Run through
# `irm | iex` there is not, so point at the backup instead of a file that
# does not exist on this machine.
if ($bak) { Write-Host "  Backup: $bak" -ForegroundColor DarkGray }
$localUninstall = $null
if ($PSScriptRoot) { $localUninstall = Join-Path $PSScriptRoot 'uninstall.ps1' }
if ($localUninstall -and (Test-Path $localUninstall)) {
    Write-Host '  To undo, run uninstall.ps1' -ForegroundColor DarkGray
} elseif ($bak) {
    Write-Host '  To undo, restore that backup over default.conf:' -ForegroundColor DarkGray
    Write-Host "    Copy-Item '$bak' '$CbConfig' -Force" -ForegroundColor DarkGray
} else {
    Write-Host '  To undo, delete the folder and shortcut listed above.' -ForegroundColor DarkGray
}
Write-Host ''

}

# Dot-sourcing (". .\install.ps1") loads the functions without running anything,
# which is how the test suite exercises the config splice.
if ($MyInvocation.InvocationName -ne '.') { Invoke-CbDark }

#endregion
