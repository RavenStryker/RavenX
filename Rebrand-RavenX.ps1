<#
.SYNOPSIS
    Rebrands a ShareX v19.0.2 checkout as RavenX.

.DESCRIPTION
    Applies the identity changes a hard fork needs: display name, install GUIDs,
    update-check target, installer metadata, assembly name, and project links.

    This deliberately does NOT rename namespaces, project folders, or the .sln.
    Those are invisible to users and renaming them across a 19-year codebase buys
    nothing but merge pain when you pull upstream security fixes.

    Every replacement is checked. If an expected string is not found, the script
    stops rather than silently skipping it. Already-applied edits are detected
    and reported, so the script is safe to re-run.

.PARAMETER RepoRoot
    Path to the repo. Defaults to the current directory.

.PARAMETER Guid
    Pin the install GUID instead of generating a fresh one. Pass the GUID from
    your first run whenever you re-run this, or your installer gets a new
    identity and stops recognizing its own previous installs.

.EXAMPLE
    .\Rebrand-RavenX.ps1 -WhatIf

.EXAMPLE
    .\Rebrand-RavenX.ps1 -Guid D752E42E-A4CB-4657-8943-639AB27060AB
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [string] $RepoRoot = '.',
    [string] $AppName = 'RavenX',
    [string] $Publisher = 'RavenStryker',
    [string] $GitHubOwner = 'RavenStryker',
    [string] $GitHubRepo = 'RavenX',
    [string] $Website = 'https://github.com/RavenStryker/RavenX',
    [string] $CallbackUrl = 'https://ravenstryker.github.io/RavenX/callback/',
    [bool]   $RenameAssembly = $true,
    [string] $Guid = ''
)

$ErrorActionPreference = 'Stop'

# Everything below uses single-quoted strings and concatenation on purpose.
# No backtick escapes, no backtick line continuations: one stray backtick in
# either turns the rest of the file into an unterminated string.
$Q = [string][char]34

# ShareX's install GUID. Shared by the mutex, the Inno Setup AppId, and the
# Steam launcher's running-instance check. Leaving it in place means your
# installer claims upstream ShareX's uninstall entry and the two can never
# run at the same time.
$UpstreamGuid = '82E6AC09-0FEF-4390-AD9F-0DD3F5561EFC'

if ($Guid -ne '') {
    $parsed = [System.Guid]::Empty
    if (-not [System.Guid]::TryParse($Guid, [ref] $parsed)) {
        throw ('Not a valid GUID: ' + $Guid)
    }
    $NewGuid = $parsed.ToString().ToUpper()
    if ($NewGuid -eq $UpstreamGuid) {
        throw 'That is upstream ShareX GUID. Using it would claim their uninstall entry.'
    }
    $GuidSource = 'pinned'
}
else {
    $NewGuid = [System.Guid]::NewGuid().ToString().ToUpper()
    $GuidSource = 'generated'
}

$RepoRoot = (Resolve-Path $RepoRoot).Path
$Repo = 'https://github.com/' + $GitHubOwner + '/' + $GitHubRepo

Write-Host ''
Write-Host ('Rebranding ShareX 19.0.2 -> ' + $AppName) -ForegroundColor Cyan
Write-Host ('  repo      ' + $RepoRoot)
Write-Host ('  updates   ' + $Repo)
Write-Host ('  GUID      ' + $NewGuid + ' (' + $GuidSource + ')')
Write-Host ''

$iss = 'ShareX.Setup\InnoSetup\ShareX-setup.iss'
$links = 'ShareX.HelpersLib\Links.cs'
$prog = 'ShareX\Program.cs'

$edits = @()

function New-Edit {
    param($Path, $Find, $Replace, $Label, $Group, [switch] $All, [switch] $Optional)
    return [pscustomobject] @{
        Path = $Path; Find = $Find; Replace = $Replace; Label = $Label
        Group = $Group; All = [bool] $All; Optional = [bool] $Optional
    }
}

# --- Identity -------------------------------------------------------------

$edits += New-Edit -Group 'Identity' -Path $prog -Label 'AppName' `
    -Find ('public const string AppName = ' + $Q + 'ShareX' + $Q + ';') `
    -Replace ('public const string AppName = ' + $Q + $AppName + $Q + ';')

$edits += New-Edit -Group 'Identity' -Path $prog -Label 'single-instance mutex' `
    -Find ('public const string MutexName = ' + $Q + $UpstreamGuid + $Q + ';') `
    -Replace ('public const string MutexName = ' + $Q + $NewGuid + $Q + ';')

$edits += New-Edit -Group 'Identity' -Path 'ShareX.Steam\Launcher.cs' -Optional `
    -Label 'Steam launcher instance check' `
    -Find ('Helpers.IsRunning(' + $Q + $UpstreamGuid + $Q + ')') `
    -Replace ('Helpers.IsRunning(' + $Q + $NewGuid + $Q + ')')

# --- Update target --------------------------------------------------------
# Without this, your build offers every user an update straight to upstream
# 22.x, which is the whole thing you forked to avoid.

$newChecker = 'new GitHubUpdateChecker(' + $Q + $GitHubOwner + $Q + ', ' + $Q + $GitHubRepo + $Q + ')'

$edits += New-Edit -Group 'Update checks' -Path 'ShareX\ShareXUpdateManager.cs' `
    -Label 'release channel' -Replace $newChecker `
    -Find ('new GitHubUpdateChecker(' + $Q + 'ShareX' + $Q + ', ' + $Q + 'ShareX' + $Q + ')')

$edits += New-Edit -Group 'Update checks' -Path 'ShareX\ShareXUpdateManager.cs' `
    -Label 'dev channel' -Replace $newChecker `
    -Find ('new GitHubUpdateChecker(' + $Q + 'ShareX' + $Q + ', ' + $Q + 'DevBuilds' + $Q + ')')

$edits += New-Edit -Group 'Update checks' -Path 'ShareX\TaskHelpers.cs' `
    -Label 'dev build download' -Replace $newChecker `
    -Find ('new GitHubUpdateChecker(' + $Q + 'ShareX' + $Q + ', ' + $Q + 'DevBuilds' + $Q + ')')

# NOTE: ShareX.MediaLib\FFmpegGitHubDownloader.cs points at ShareX/FFmpeg.
# That is upstream's mirror of FFmpeg binaries, not ShareX itself. Left alone
# on purpose: repoint it only if you mirror FFmpeg yourself.

# --- Installer ------------------------------------------------------------
# MyAppReleaseDirectory and MyAppFileName are derived from MyAppName, but the
# project FOLDER stays "ShareX". Split the two apart or the installer hunts
# for a build output path that does not exist.

$edits += New-Edit -Group 'Installer' -Path $iss -Label 'display name + project name split' `
    -Find ('#define MyAppName ' + $Q + 'ShareX' + $Q) `
    -Replace ('#define MyAppName ' + $Q + $AppName + $Q + '%NL%#define MyProjectName ' + $Q + 'ShareX' + $Q)

$edits += New-Edit -Group 'Installer' -Path $iss -Label 'build output path' `
    -Find ('#define MyAppReleaseDirectory MyAppRootDirectory + ' + $Q + '\' + $Q + ' + MyAppName + ' + $Q + '\bin\Release\win-x64' + $Q) `
    -Replace ('#define MyAppReleaseDirectory MyAppRootDirectory + ' + $Q + '\' + $Q + ' + MyProjectName + ' + $Q + '\bin\Release\win-x64' + $Q)

if (-not $RenameAssembly) {
    $edits += New-Edit -Group 'Installer' -Path $iss -Label 'executable name (kept as ShareX.exe)' `
        -Find ('#define MyAppFileName MyAppName + ' + $Q + '.exe' + $Q) `
        -Replace ('#define MyAppFileName MyProjectName + ' + $Q + '.exe' + $Q)
}

$edits += New-Edit -Group 'Installer' -Path $iss -Label 'publisher' `
    -Find ('#define MyAppPublisher ' + $Q + 'ShareX Team' + $Q) `
    -Replace ('#define MyAppPublisher ' + $Q + $Publisher + $Q)

$edits += New-Edit -Group 'Installer' -Path $iss -Label 'publisher URL' `
    -Find ('#define MyAppURL ' + $Q + 'https://getsharex.com' + $Q) `
    -Replace ('#define MyAppURL ' + $Q + $Website + $Q)

$edits += New-Edit -Group 'Installer' -Path $iss -Label 'AppId / uninstall entry' `
    -Find ('#define MyAppId ' + $Q + $UpstreamGuid + $Q) `
    -Replace ('#define MyAppId ' + $Q + $NewGuid + $Q)

# --- Assembly name --------------------------------------------------------

if ($RenameAssembly) {
    $edits += New-Edit -Group 'Assembly name' -Path 'ShareX\ShareX.csproj' `
        -Label ('output binary -> ' + $AppName + '.exe') `
        -Find '<RuntimeIdentifier>win-x64</RuntimeIdentifier>' `
        -Replace ('<RuntimeIdentifier>win-x64</RuntimeIdentifier>%NL%    <AssemblyName>' + $AppName + '</AssemblyName>')

    $edits += New-Edit -Group 'Assembly name' -Path 'ShareX.Setup\Program.cs' `
        -Label 'setup builder exe path' `
        -Find ('Path.Combine(BinDir, ' + $Q + 'ShareX.exe' + $Q + ')') `
        -Replace ('Path.Combine(BinDir, ' + $Q + $AppName + '.exe' + $Q + ')')

    $edits += New-Edit -Group 'Assembly name' -Path 'ShareX.Steam\Launcher.cs' -All -Optional `
        -Label 'Steam launcher exe paths' `
        -Find ($Q + 'ShareX.exe' + $Q) `
        -Replace ($Q + $AppName + '.exe' + $Q)

    $edits += New-Edit -Group 'Assembly name' -Path 'ShareX.NativeMessagingHost\Program.cs' -Optional `
        -Label 'native messaging host exe path' `
        -Find ('FileHelpers.GetAbsolutePath(' + $Q + 'ShareX.exe' + $Q + ')') `
        -Replace ('FileHelpers.GetAbsolutePath(' + $Q + $AppName + '.exe' + $Q + ')')
}

# --- Links ----------------------------------------------------------------

$edits += New-Edit -Group 'Links' -Path $links -Label 'homepage' `
    -Find ('public const string Website = ' + $Q + 'https://getsharex.com' + $Q + ';') `
    -Replace ('public const string Website = ' + $Q + $Website + $Q + ';%NL%        private const string UpstreamWebsite = ' + $Q + 'https://getsharex.com' + $Q + ';')

$edits += New-Edit -Group 'Links' -Path $links -Label 'OAuth redirect URI' `
    -Find ('public const string Callback = Website + ' + $Q + '/callback/' + $Q + ';') `
    -Replace ('public const string Callback = ' + $Q + $CallbackUrl + $Q + ';')

# Upstream's changelog documents 22.x. Pointing your users at it would
# advertise features this build does not have.
$edits += New-Edit -Group 'Links' -Path $links -Label 'changelog -> your releases' `
    -Find ('public const string Changelog = Website + ' + $Q + '/changelog' + $Q + ';') `
    -Replace ('public const string Changelog = ' + $Q + $Repo + '/releases' + $Q + ';')

# These stay on upstream: the reference docs still describe v19 accurately.
foreach ($c in @('Donate', 'PrivacyPolicy', 'ImageEffects', 'Actions')) {
    $edits += New-Edit -Group 'Links' -Path $links -Optional -Label ($c + ' -> upstream') `
        -Find ('public const string ' + $c + ' = Website + ') `
        -Replace ('public const string ' + $c + ' = UpstreamWebsite + ')
}

$edits += New-Edit -Group 'Links' -Path $links -Label 'docs -> upstream' `
    -Find ('private const string Docs = Website + ' + $Q + '/docs' + $Q + ';') `
    -Replace ('private const string Docs = UpstreamWebsite + ' + $Q + '/docs' + $Q + ';')

$edits += New-Edit -Group 'Links' -Path $links -Label 'repo link' `
    -Find ('public const string GitHub = ' + $Q + 'https://github.com/ShareX/ShareX' + $Q + ';') `
    -Replace ('public const string GitHub = ' + $Q + $Repo + $Q + ';')

# --- Apply ----------------------------------------------------------------

$applied = 0
$skipped = 0
$group = ''

foreach ($e in $edits) {
    if ($e.Group -ne $group) {
        $group = $e.Group
        Write-Host $group -ForegroundColor Yellow
    }

    $full = Join-Path $RepoRoot $e.Path

    if (-not (Test-Path $full)) {
        if ($e.Optional) {
            Write-Host ('  skip     ' + $e.Path + ' (not present)') -ForegroundColor DarkGray
            $skipped++
            continue
        }
        throw ('Missing file: ' + $e.Path + '. Run this from the root of your checkout.')
    }

    $text = [System.IO.File]::ReadAllText($full)

    # Match the file's own line endings for any inserted line.
    if ($text.Contains("`r`n")) { $nl = "`r`n" } else { $nl = "`n" }
    $replace = $e.Replace.Replace('%NL%', $nl)

    $count = ([regex]::Matches($text, [regex]::Escape($e.Find))).Count

    # Check Find FIRST. Two edits can share a replacement string (both update
    # checkers become the same call), so testing "is the replacement present"
    # up front would let one edit mask the other and silently leave an
    # upstream reference behind.
    if ($count -eq 0) {
        if ($text.Contains($replace)) {
            Write-Host ('  already  ' + $e.Label) -ForegroundColor DarkGray
            $skipped++
            continue
        }
        if ($e.Optional) {
            Write-Host ('  skip     ' + $e.Label + ' (not found)') -ForegroundColor DarkGray
            $skipped++
            continue
        }
        throw ('Not found in ' + $e.Path + ': ' + $e.Find)
    }

    if (-not $e.All -and $count -gt 1) {
        throw ('Found ' + $count + ' matches for a single-match edit in ' + $e.Path + '. Refusing to guess.')
    }

    if ($e.All) {
        $text = $text.Replace($e.Find, $replace)
    }
    else {
        $i = $text.IndexOf($e.Find)
        $text = $text.Substring(0, $i) + $replace + $text.Substring($i + $e.Find.Length)
    }

    if ($PSCmdlet.ShouldProcess($e.Path, $e.Label)) {
        [System.IO.File]::WriteAllText($full, $text, (New-Object System.Text.UTF8Encoding($false)))
    }

    $applied++
    Write-Host ('  ok       ' + $e.Label + '  (' + $e.Path + ')') -ForegroundColor Green
}

Write-Host ''
Write-Host ($applied.ToString() + ' applied, ' + $skipped.ToString() + ' skipped or already in place.') -ForegroundColor Cyan
Write-Host ''

if ($GuidSource -eq 'generated') {
    Write-Host 'Install GUID for this fork:' -ForegroundColor Yellow
    Write-Host ('  ' + $NewGuid)
    Write-Host 'Committing the rebrand preserves it. To re-run this script later,'
    Write-Host 'pass it back in or you get a different identity:'
    Write-Host ('  .\Rebrand-RavenX.ps1 -Guid ' + $NewGuid)
    Write-Host ''
}

Write-Host 'Still to do by hand:' -ForegroundColor Yellow
Write-Host '  - Links.cs still lists upstream Discord, X, Reddit, Steam and MS Store.'
Write-Host '    Blank them or point them at your own.'
Write-Host '  - IntegrationHelpers.cs keeps the native messaging host ID'
Write-Host '    com.getsharex.sharex. Renaming it breaks the official browser'
Write-Host '    extension with nothing to replace it, so it is left alone.'
Write-Host '  - Add your own copyright line. Do not remove the existing ones.'
Write-Host ''
