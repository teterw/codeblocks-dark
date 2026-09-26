#Requires -Version 5.1
<#
.SYNOPSIS
    End-to-end check: does Code::Blocks itself accept the theme we splice in?

.DESCRIPTION
    The unit tests prove the XML we write matches what Code::Blocks writes.
    They cannot prove Code::Blocks agrees. This does.

    Given a directory holding Code::Blocks binaries (an extracted installer is
    fine -- no install needed), it runs Code::Blocks in portable mode against a
    throwaway config, applies a theme, then lets Code::Blocks load and rewrite
    that config. If the theme node and ACTIVE_COLOUR_SET survive the round trip,
    Code::Blocks parsed and kept them. If it had rejected them, its own rewrite
    would have dropped them.

    A Code::Blocks window appears briefly and is then closed cleanly -- the
    clean exit is the point, because that is when it writes its config back.

.PARAMETER CodeBlocksDir
    Directory containing CbLauncher.exe and codeblocks.exe.

.PARAMETER ThemeSlug
    Theme slug to verify. Defaults to dracula. Named ThemeSlug rather than
    Theme because dot-sourcing install.ps1 brings its own -Theme parameter
    into scope and would blank this one out.

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File tools\Verify-EndToEnd.ps1 -CodeBlocksDir C:\temp\cbx
#>
param(
    [Parameter(Mandatory = $true)][string]$CodeBlocksDir,
    [string]$ThemeSlug = 'dracula',
    [int]$StartupSeconds = 25,
    [int]$ShutdownSeconds = 30
)

$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
. (Join-Path $root 'install.ps1')

function Say($m, $c = 'Gray') { Write-Host "  $m" -ForegroundColor $c }

# On a machine with no compiler, Code::Blocks opens a modal "Compilers
# auto-detection" dialog on first run, which blocks CloseMainWindow and so
# blocks the config write we are trying to observe. Post WM_CLOSE straight to
# the dialog's handle: no focus stealing and no SendKeys into whatever the user
# happens to have in front of them.
if (-not ('Win.Dlg' -as [type])) {
    Add-Type -Namespace Win -Name Dlg -MemberDefinition @"
[DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc cb, IntPtr p);
[DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
[DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
[DllImport("user32.dll")] public static extern IntPtr PostMessage(IntPtr h, uint msg, IntPtr w, IntPtr l);
[DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern int GetWindowTextW(IntPtr h, System.Text.StringBuilder s, int n);
public delegate bool EnumProc(IntPtr h, IntPtr p);
"@
}

function Get-ProcessWindows([int]$ProcessId) {
    $found = New-Object System.Collections.ArrayList
    $cb = [Win.Dlg+EnumProc] {
        param($h, $p)
        $owner = 0
        [void][Win.Dlg]::GetWindowThreadProcessId($h, [ref]$owner)
        if ($owner -eq $ProcessId -and [Win.Dlg]::IsWindowVisible($h)) {
            $sb = New-Object System.Text.StringBuilder 512
            [void][Win.Dlg]::GetWindowTextW($h, $sb, $sb.Capacity)
            [void]$found.Add([pscustomobject]@{ Handle = $h; Title = $sb.ToString() })
        }
        return $true
    }
    [void][Win.Dlg]::EnumWindows($cb, [IntPtr]::Zero)
    return $found
}

function Close-BlockingDialogs($Process) {
    $closed = @()
    foreach ($w in (Get-ProcessWindows $Process.Id)) {
        if ($w.Handle -eq $Process.MainWindowHandle) { continue }
        [void][Win.Dlg]::PostMessage($w.Handle, 0x0010, [IntPtr]::Zero, [IntPtr]::Zero)  # WM_CLOSE
        $closed += $(if ($w.Title) { $w.Title } else { '(untitled)' })
    }
    return $closed
}

$launcher = Join-Path $CodeBlocksDir 'CbLauncher.exe'
if (-not (Test-Path $launcher)) { throw "CbLauncher.exe not found in $CodeBlocksDir" }

# Portable mode: CbLauncher points Code::Blocks at .\AppData\codeblocks
$confDir = Join-Path $CodeBlocksDir 'AppData\codeblocks'
$conf = Join-Path $confDir 'default.conf'
if (-not (Test-Path $confDir)) { New-Item -ItemType Directory -Path $confDir -Force | Out-Null }
Copy-Item -LiteralPath (Join-Path $root 'test\real-default.conf') -Destination $conf -Force

Write-Host ''
Write-Host 'Code::Blocks Dark - end-to-end verification' -ForegroundColor Cyan
Write-Host '-------------------------------------------'
Say "Code::Blocks : $CodeBlocksDir"
Say "config       : $conf"
Say "theme        : $ThemeSlug"
Write-Host ''

Say 'Splicing the theme in...'
$slug = Install-Theme $conf (Join-Path $root 'themes' | Join-Path -ChildPath "$ThemeSlug.conf")
Say "wrote theme '$slug'" 'Green'

$sizeBefore = (Get-Item $conf).Length
$stampBefore = (Get-Item $conf).LastWriteTimeUtc

Say 'Starting Code::Blocks (a window will open, then close by itself)...'
$null = Start-Process -FilePath $launcher -WorkingDirectory $CodeBlocksDir -PassThru

# CbLauncher spawns codeblocks.exe and exits, so wait for the real process.
$cb = $null
$deadline = (Get-Date).AddSeconds($StartupSeconds)
while ((Get-Date) -lt $deadline) {
    $cb = Get-Process -Name 'codeblocks' -ErrorAction SilentlyContinue |
          Where-Object { $_.Path -and $_.Path.StartsWith($CodeBlocksDir, 'OrdinalIgnoreCase') } |
          Select-Object -First 1
    if ($cb -and $cb.MainWindowHandle -ne 0) { break }
    Start-Sleep -Milliseconds 500
}
if (-not $cb) { throw 'Code::Blocks never started.' }
Say "running as PID $($cb.Id)" 'Green'

# Let it finish loading plugins, clearing any dialog it puts up on the way.
for ($i = 0; $i -lt 8; $i++) {
    Start-Sleep -Seconds 2
    $cb.Refresh()
    if ($cb.HasExited) { break }
    $dismissed = Close-BlockingDialogs $cb
    if ($dismissed.Count -gt 0) { Say ("dismissed dialog: {0}" -f ($dismissed -join ', ')) 'DarkGray' }
}

Say 'Asking it to close (this is when it writes its config back)...'
$cb.Refresh()
[void]$cb.CloseMainWindow()

# A confirm-on-exit prompt would block the shutdown the same way.
for ($i = 0; $i -lt 6; $i++) {
    Start-Sleep -Seconds 2
    $cb.Refresh()
    if ($cb.HasExited) { break }
    $dismissed = Close-BlockingDialogs $cb
    if ($dismissed.Count -gt 0) { Say ("dismissed dialog: {0}" -f ($dismissed -join ', ')) 'DarkGray' }
    [void]$cb.CloseMainWindow()
}
if (-not $cb.WaitForExit($ShutdownSeconds * 1000)) {
    Say 'It did not close on its own - a dialog is probably blocking it.' 'Yellow'
    Say 'Killing it; the round-trip result below is not trustworthy.' 'Yellow'
    try { $cb.Kill() } catch { }
    $cb.WaitForExit(5000) | Out-Null
    $forced = $true
} else {
    $forced = $false
    Say 'closed cleanly' 'Green'
}

$stampAfter = (Get-Item $conf).LastWriteTimeUtc
$rewritten = $stampAfter -gt $stampBefore

Write-Host ''
Write-Host '  Result' -ForegroundColor Cyan
Say ("config rewritten by Code::Blocks : {0}" -f $(if ($rewritten) { 'yes' } else { 'no' }))
Say ("size before / after              : {0} / {1} bytes" -f $sizeBefore, (Get-Item $conf).Length)

$sets = (New-Object System.Xml.XmlDocument)
$sets.Load($conf)
$colourSets = $sets.SelectSingleNode('/CodeBlocksConfig/editor/colour_sets')
$names = @()
foreach ($n in $colourSets.ChildNodes) {
    if ($n.NodeType -eq 'Element' -and @('ACTIVE_COLOUR_SET', 'ACTIVE_LANG') -notcontains $n.get_Name()) {
        $names += $n.get_Name()
    }
}
$activeNode = $colourSets.SelectSingleNode('ACTIVE_COLOUR_SET/str')
$active = if ($activeNode) { $activeNode.InnerText.Trim() } else { '(none)' }

Say ("themes in config                 : {0}" -f ($names -join ', '))
Say ("active colour set                : {0}" -f $active)

$ok = $rewritten -and ($names -contains $slug) -and ($active -eq $slug) -and (-not $forced)
Write-Host ''
if ($ok) {
    Write-Host '  PASS - Code::Blocks loaded the theme, kept it, and left it active.' -ForegroundColor Green
    Write-Host ''
    exit 0
}
if (-not $rewritten) {
    Write-Host '  INCONCLUSIVE - Code::Blocks never rewrote the config, so it cannot' -ForegroundColor Yellow
    Write-Host '  be said whether it accepted the theme.' -ForegroundColor Yellow
    Write-Host ''
    exit 2
}
Write-Host '  FAIL - Code::Blocks rewrote the config and the theme did not survive.' -ForegroundColor Red
Write-Host ''
exit 1
