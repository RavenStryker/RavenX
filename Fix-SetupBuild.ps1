<#
.SYNOPSIS
    Fixes the three reasons a RavenX release build can finish green without
    producing an installer.

.DESCRIPTION
    Run this from the repo root, after the rebrand and after the
    DownloadExifTool patch. It edits files in place, so your rebrand and any
    other local changes are left alone.

      1. ShareX.Setup\InnoSetup\ShareX-setup.iss
         The exiftool_files include is unconditional, so Inno Setup aborts
         when ExifTool was skipped. Adds skipifsourcedoesntexist.

      2. ShareX.Setup\Program.cs
         Inno Setup's exit code is never checked, so a failed compile prints
         "Setup file compiled" and exits 0. Adds the check.

      3. .github\workflows\build.yml
         The Setup artifact upload defaults to if-no-files-found: warn, so a
         missing installer is a warning rather than a failure. Sets it to error.

    Safe to re-run. Each fix detects whether it is already in place.

.PARAMETER RepoRoot
    Path to the repo. Defaults to the current directory.

.EXAMPLE
    .\Fix-SetupBuild.ps1 -WhatIf

.EXAMPLE
    .\Fix-SetupBuild.ps1
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [string] $RepoRoot = '.'
)

$ErrorActionPreference = 'Stop'
$RepoRoot = (Resolve-Path $RepoRoot).Path

# Single-quoted strings and concatenation throughout, no backtick escapes.
$Q = [string][char]34

$applied = 0
$skipped = 0

# ReadAllText preserves CRLF exactly as it is on disk. That matters for the
# patterns below: in .NET multiline mode, $ matches before \n only, so on a
# CRLF file a pattern ending in [^\r\n]*$ can never match, because the \r
# sits between the last character and the \n. Every pattern here ends with
# an explicit (?=\r?\n|\Z) lookahead instead of $, and uses [ \t]* rather
# than \s* so indentation matching cannot wander across line breaks.
function Read-File {
    param([string] $Path)
    $full = Join-Path $RepoRoot $Path
    if (-not (Test-Path $full)) {
        throw ('Missing file: ' + $Path + '. Run this from the root of your checkout.')
    }
    return [System.IO.File]::ReadAllText($full)
}

function Write-File {
    param([string] $Path, [string] $Content, [string] $Label)
    $full = Join-Path $RepoRoot $Path
    if ($PSCmdlet.ShouldProcess($Path, $Label)) {
        [System.IO.File]::WriteAllText($full, $Content, (New-Object System.Text.UTF8Encoding($false)))
    }
    $script:applied++
    Write-Host ('  ok       ' + $Label + '  (' + $Path + ')') -ForegroundColor Green
}

function Skip-Item {
    param([string] $Label)
    $script:skipped++
    Write-Host ('  already  ' + $Label) -ForegroundColor DarkGray
}

function Get-Newline {
    param([string] $Text)
    if ($Text.Contains("`r`n")) { return "`r`n" } else { return "`n" }
}

Write-Host ''
Write-Host ('Fixing setup build in ' + $RepoRoot) -ForegroundColor Cyan
Write-Host ''

# --- 1. Inno Setup: tolerate a missing exiftool_files directory ------------

Write-Host 'Inno Setup' -ForegroundColor Yellow

$issPath = 'ShareX.Setup\InnoSetup\ShareX-setup.iss'
$iss = Read-File $issPath
$issLabel = 'skipifsourcedoesntexist on exiftool_files'

$issPattern = '(?m)^(Source: ' + $Q + '\{#MyAppOutputDirectory\}\\exiftool_files\\\*' + $Q + ';[^\r\n]*?recursesubdirs)([^\r\n]*)(?=\r?\n|\Z)'
$issMatch = [regex]::Match($iss, $issPattern)

if (-not $issMatch.Success) {
    throw ('Could not find the exiftool_files Source line in ' + $issPath)
}

if ($issMatch.Value.Contains('skipifsourcedoesntexist')) {
    Skip-Item $issLabel
}
else {
    $iss = [regex]::Replace($iss, $issPattern, '$1$2 skipifsourcedoesntexist', 1)
    Write-File $issPath $iss $issLabel
}

# --- 2. ShareX.Setup: fail when Inno Setup fails ---------------------------

Write-Host 'Setup builder' -ForegroundColor Yellow

$progPath = 'ShareX.Setup\Program.cs'
$prog = Read-File $progPath
$progLabel = 'check Inno Setup exit code'

if ($prog.Contains('Inno Setup failed with exit code')) {
    Skip-Item $progLabel
}
else {
    # Anchored on the compile block specifically. There is a second
    # WaitForExit() elsewhere in this file at a different indent level, which
    # is why the trailing Console.WriteLine is part of the match.
    $progPattern = 'process\.WaitForExit\(\);\r?\n([ \t]*)\}\r?\n\r?\n([ \t]*)Console\.WriteLine\(' + $Q + 'Setup file compiled: ' + $Q + ' \+ fileName\);'

    $progMatch = [regex]::Match($prog, $progPattern)
    if (-not $progMatch.Success) {
        throw ('Could not find the Inno Setup compile block in ' + $progPath)
    }

    $nl = Get-Newline $prog
    $inner = $progMatch.Groups[1].Value
    $outer = $progMatch.Groups[2].Value

    $new = 'process.WaitForExit();' + $nl
    $new = $new + $nl
    $new = $new + $inner + '    if (process.ExitCode != 0)' + $nl
    $new = $new + $inner + '    {' + $nl
    $new = $new + $inner + '        throw new Exception($' + $Q + 'Inno Setup failed with exit code {process.ExitCode}: {fileName}' + $Q + ');' + $nl
    $new = $new + $inner + '    }' + $nl
    $new = $new + $inner + '}' + $nl
    $new = $new + $nl
    $new = $new + $outer + 'Console.WriteLine(' + $Q + 'Setup file compiled: ' + $Q + ' + fileName);'

    $i = $progMatch.Index
    $prog = $prog.Substring(0, $i) + $new + $prog.Substring($i + $progMatch.Length)
    Write-File $progPath $prog $progLabel
}

# --- 3. Workflow: a missing installer should fail the job ------------------

Write-Host 'Workflow' -ForegroundColor Yellow

$ymlPath = '.github\workflows\build.yml'
$yml = Read-File $ymlPath
$ymlLabel = 'if-no-files-found: error on Setup upload'

# Only the Windows-path upload in the build job. The release job references
# the same filename with forward slashes and is left alone.
$ymlPattern = '(?m)^([ \t]*)name: Setup\r?\n([ \t]*)path: Output\\ShareX-\$\{\{ env\.APP_VERSION \}\}-setup\.exe([^\r\n]*)(?=\r?\n|\Z)'
$ymlMatch = [regex]::Match($yml, $ymlPattern)

if (-not $ymlMatch.Success) {
    throw ('Could not find the Setup artifact upload in ' + $ymlPath)
}

$after = $yml.Substring($ymlMatch.Index + $ymlMatch.Length)

if ($after -match '^\r?\n[ \t]*if-no-files-found:') {
    Skip-Item $ymlLabel
}
else {
    $nl = Get-Newline $yml
    $indent = $ymlMatch.Groups[2].Value
    $insert = $ymlMatch.Value + $nl + $indent + 'if-no-files-found: error'
    $i = $ymlMatch.Index
    $yml = $yml.Substring(0, $i) + $insert + $yml.Substring($i + $ymlMatch.Length)
    Write-File $ymlPath $yml $ymlLabel
}

# --- Done ------------------------------------------------------------------

Write-Host ''
Write-Host ($applied.ToString() + ' applied, ' + $skipped.ToString() + ' already in place.') -ForegroundColor Cyan
Write-Host ''

if ($applied -gt 0) {
    Write-Host 'Next: commit, push, and confirm the run uploads BOTH a Setup and a' -ForegroundColor Yellow
    Write-Host 'Portable artifact. Seeing this in the log is expected now and no' -ForegroundColor Yellow
    Write-Host 'longer stops the installer being built:' -ForegroundColor Yellow
    Write-Host '  ExifTool download produced no file, skipping.'
    Write-Host ''
}
