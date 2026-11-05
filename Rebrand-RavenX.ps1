<#
.SYNOPSIS
    Rebrands a ShareX v19.0.2 checkout as RavenX.

.DESCRIPTION
    Applies the identity changes a hard fork needs: display name, install GUIDs,
    update-check target, installer metadata, assembly name, and project links.

    This deliberately does NOT rename namespaces, project folders, or the .sln.
    Those are invisible to users and renaming them across a 19-year codebase buys
    nothing but merge pain when you pull upstream security fixes.

    Every replacement is checked. If an expected string isn't found, the script
    stops rather than silently skipping it — a no-op rebrand that looks like it
    worked is the worst outcome here.

.PARAMETER RepoRoot
    Path to the repo. Defaults to the current directory.

.PARAMETER AppName
    User-visible application name. Default: RavenX

.PARAMETER Publisher
    Publisher string shown in Add/Remove Programs.

.PARAMETER GitHubOwner
    GitHub account that hosts your releases. Update checks hit this.

.PARAMETER GitHubRepo
    Repository name that hosts your releases.

.PARAMETER Website
    Your project homepage. Used for the About dialog.

.PARAMETER CallbackUrl
    OAuth redirect URI. Must match what you register with each OAuth provider.
    A GitHub Pages path works fine.

.PARAMETER RenameAssembly
    Also rename the output binary to <AppName>.exe. Default: on.
    Pass -RenameAssembly:$false to keep ShareX.exe.

.PARAMETER WhatIf
    Show what would change without writing anything.

.EXAMPLE
    .\Rebrand-RavenX.ps1 -WhatIf

.EXAMPLE
    .\Rebrand-RavenX.ps1 -GitHubOwner RavenStryker -GitHubRepo RavenX
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [string]$RepoRoot     = ".",
    [string]$AppName      = "RavenX",
    [string]$Publisher    = "RavenStryker",
    [string]$GitHubOwner  = "RavenStryker",
    [string]$GitHubRepo   = "RavenX",
    [string]$Website      = "https://github.com/RavenStryker/RavenX",
    [string]$CallbackUrl  = "https://ravenstryker.github.io/RavenX/callback/",
    [bool]$RenameAssembly = $true
)

$ErrorActionPreference = "Stop"

# ShareX's install GUID. Shared by the mutex, the Inno Setup AppId, and the
# Steam launcher's running-instance check. Leaving it in place means your
# installer claims upstream ShareX's uninstall entry and the two can never
# run at the same time.
$UpstreamGuid = "82E6AC09-0FEF-4390-AD9F-0DD3F5561EFC"
$NewGuid      = [guid]::NewGuid().ToString().ToUpper()

$RepoRoot = (Resolve-Path $RepoRoot).Path
$script:Changes = 0
$script:Files   = @{}

function Edit-File {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Find,
        [Parameter(Mandatory)][string]$Replace,
        [string]$Label,
        [switch]$All,
        [switch]$Optional
    )

    $full = Join-Path $RepoRoot $Path
    if (-not (Test-Path $full)) {
        if ($Optional) { Write-Host "  skip  $Path (not present)" -ForegroundColor DarkGray; return }
        throw "Missing file: $Path`nAre you sure this is a ShareX v19.0.2 checkout?"
    }

    $content = [System.IO.File]::ReadAllText($full)

    if ($content -notmatch [regex]::Escape($Find)) {
        if ($Optional) { Write-Host "  skip  $Path :: $Label (already applied?)" -ForegroundColor DarkGray; return }
        throw "Expected string not found in $Path`n  Looking for: $Find`nThe source may have drifted from v19.0.2. Fix this before continuing."
    }

    $count = ([regex]::Matches($content, [regex]::Escape($Find))).Count
    if (-not $All -and $count -gt 1) {
        throw "Found $count matches for a single-match replacement in $Path. Refusing to guess."
    }

    $updated = if ($All) {
        $content -replace [regex]::Escape($Find), $Replace.Replace('$', '$$')
    } else {
        [regex]::new([regex]::Escape($Find)).Replace($content, $Replace.Replace('$', '$$'), 1)
    }

    if ($PSCmdlet.ShouldProcess($Path, $Label)) {
        [System.IO.File]::WriteAllText($full, $updated, [System.Text.UTF8Encoding]::new($false))
    }

    $script:Changes += $count
    $script:Files[$Path] = $true
    Write-Host ("  ok    {0,-46} {1}" -f $Path, $Label) -ForegroundColor Green
}

Write-Host ""
Write-Host "Rebranding ShareX 19.0.2 -> $AppName" -ForegroundColor Cyan
Write-Host "  repo       $RepoRoot"
Write-Host "  updates    github.com/$GitHubOwner/$GitHubRepo"
Write-Host "  new GUID   $NewGuid"
Write-Host ""

# --- Identity -------------------------------------------------------------
Write-Host "Application identity" -ForegroundColor Yellow

Edit-File -Path "ShareX\Program.cs" `
    -Find    'public const string AppName = "ShareX";' `
    -Replace "public const string AppName = `"$AppName`";" `
    -Label   "AppName"

# Drives the personal folder (Documents\<AppName>), the pipe name, and the
# single-instance mutex. Changing it is what isolates your config from an
# existing ShareX install.
Edit-File -Path "ShareX\Program.cs" `
    -Find    "public const string MutexName = `"$UpstreamGuid`";" `
    -Replace "public const string MutexName = `"$NewGuid`";" `
    -Label   "single-instance mutex"

Edit-File -Path "ShareX.Steam\Launcher.cs" `
    -Find     "Helpers.IsRunning(`"$UpstreamGuid`")" `
    -Replace  "Helpers.IsRunning(`"$NewGuid`")" `
    -Label    "Steam launcher instance check" `
    -Optional

# --- Update target --------------------------------------------------------
Write-Host ""
Write-Host "Update checks" -ForegroundColor Yellow

# Without this, your build offers every user an 'update' straight to upstream
# 22.x, which is the whole thing you forked to avoid.
Edit-File -Path "ShareX\ShareXUpdateManager.cs" `
    -Find    'new GitHubUpdateChecker("ShareX", "ShareX")' `
    -Replace "new GitHubUpdateChecker(`"$GitHubOwner`", `"$GitHubRepo`")" `
    -Label   "release channel"

Edit-File -Path "ShareX\ShareXUpdateManager.cs" `
    -Find    'new GitHubUpdateChecker("ShareX", "DevBuilds")' `
    -Replace "new GitHubUpdateChecker(`"$GitHubOwner`", `"$GitHubRepo`")" `
    -Label   "dev channel"

Edit-File -Path "ShareX\TaskHelpers.cs" `
    -Find    'new GitHubUpdateChecker("ShareX", "DevBuilds")' `
    -Replace "new GitHubUpdateChecker(`"$GitHubOwner`", `"$GitHubRepo`")" `
    -Label   "dev build download"

# NOTE: ShareX.MediaLib\FFmpegGitHubDownloader.cs points at ShareX/FFmpeg.
# That is upstream's mirror of FFmpeg *binaries*, not ShareX itself. Left
# alone on purpose — repoint it only if you mirror FFmpeg yourself.

# --- Installer ------------------------------------------------------------
Write-Host ""
Write-Host "Installer" -ForegroundColor Yellow

$iss = "ShareX.Setup\InnoSetup\ShareX-setup.iss"

# MyAppReleaseDirectory and MyAppFileName are derived from MyAppName, but the
# project FOLDER stays "ShareX". Split the two apart or the installer hunts for
# a build output path that doesn't exist.
Edit-File -Path $iss `
    -Find    '#define MyAppName "ShareX"' `
    -Replace "#define MyAppName `"$AppName`"`r`n#define MyProjectName `"ShareX`"" `
    -Label   "display name + project name split"

Edit-File -Path $iss `
    -Find    '#define MyAppReleaseDirectory MyAppRootDirectory + "\" + MyAppName + "\bin\Release\win-x64"' `
    -Replace '#define MyAppReleaseDirectory MyAppRootDirectory + "\" + MyProjectName + "\bin\Release\win-x64"' `
    -Label   "build output path"

if (-not $RenameAssembly) {
    Edit-File -Path $iss `
        -Find    '#define MyAppFileName MyAppName + ".exe"' `
        -Replace '#define MyAppFileName MyProjectName + ".exe"' `
        -Label   "executable name (kept as ShareX.exe)"
}

Edit-File -Path $iss `
    -Find    '#define MyAppPublisher "ShareX Team"' `
    -Replace "#define MyAppPublisher `"$Publisher`"" `
    -Label   "publisher"

Edit-File -Path $iss `
    -Find    '#define MyAppURL "https://getsharex.com"' `
    -Replace "#define MyAppURL `"$Website`"" `
    -Label   "publisher URL"

Edit-File -Path $iss `
    -Find    "#define MyAppId `"$UpstreamGuid`"" `
    -Replace "#define MyAppId `"$NewGuid`"" `
    -Label   "AppId / uninstall entry"

# --- Assembly name --------------------------------------------------------
if ($RenameAssembly) {
    Write-Host ""
    Write-Host "Assembly name" -ForegroundColor Yellow

    Edit-File -Path "ShareX\ShareX.csproj" `
        -Find    "<RuntimeIdentifier>win-x64</RuntimeIdentifier>" `
        -Replace "<RuntimeIdentifier>win-x64</RuntimeIdentifier>`r`n    <AssemblyName>$AppName</AssemblyName>" `
        -Label   "output binary -> $AppName.exe"

    Edit-File -Path "ShareX.Setup\Program.cs" `
        -Find    'Path.Combine(BinDir, "ShareX.exe")' `
        -Replace "Path.Combine(BinDir, `"$AppName.exe`")" `
        -Label   "setup builder exe path"

    Edit-File -Path "ShareX.Steam\Launcher.cs" `
        -Find    '"ShareX.exe"' `
        -Replace "`"$AppName.exe`"" `
        -Label   "Steam launcher exe paths" `
        -All -Optional

    Edit-File -Path "ShareX.NativeMessagingHost\Program.cs" `
        -Find    'FileHelpers.GetAbsolutePath("ShareX.exe")' `
        -Replace "FileHelpers.GetAbsolutePath(`"$AppName.exe`")" `
        -Label   "native messaging host exe path" `
        -Optional
}

# --- Links ----------------------------------------------------------------
Write-Host ""
Write-Host "Links" -ForegroundColor Yellow

# Docs stay pointed at getsharex.com. Their v19-era docs still describe this
# build accurately, and you almost certainly don't want to rewrite them.
Edit-File -Path "ShareX.HelpersLib\Links.cs" `
    -Find    'public const string Website = "https://getsharex.com";' `
    -Replace "public const string Website = `"$Website`";`r`n        private const string UpstreamWebsite = `"https://getsharex.com`";" `
    -Label   "homepage"

Edit-File -Path "ShareX.HelpersLib\Links.cs" `
    -Find    'public const string Callback = Website + "/callback/";' `
    -Replace "public const string Callback = `"$CallbackUrl`";" `
    -Label   "OAuth redirect URI"

# Upstream's changelog now documents 22.x. Pointing your users at it would
# advertise features this build doesn't have.
Edit-File -Path "ShareX.HelpersLib\Links.cs" `
    -Find    'public const string Changelog = Website + "/changelog";' `
    -Replace "public const string Changelog = `"https://github.com/$GitHubOwner/$GitHubRepo/releases`";" `
    -Label   "changelog -> your releases"

# These stay on upstream: the reference docs still describe v19 accurately and
# you almost certainly don't want to rewrite them.
foreach ($c in @("Donate","PrivacyPolicy","ImageEffects","Actions")) {
    Edit-File -Path "ShareX.HelpersLib\Links.cs" `
        -Find    "public const string $c = Website + " `
        -Replace "public const string $c = UpstreamWebsite + " `
        -Label   "$c -> upstream" `
        -Optional
}

Edit-File -Path "ShareX.HelpersLib\Links.cs" `
    -Find    'private const string Docs = Website + "/docs";' `
    -Replace 'private const string Docs = UpstreamWebsite + "/docs";' `
    -Label   "docs -> upstream"

Edit-File -Path "ShareX.HelpersLib\Links.cs" `
    -Find    'public const string GitHub = "https://github.com/ShareX/ShareX";' `
    -Replace "public const string GitHub = `"https://github.com/$GitHubOwner/$GitHubRepo`";" `
    -Label   "repo link"

# --- Done -----------------------------------------------------------------
Write-Host ""
Write-Host "$($script:Changes) replacements across $($script:Files.Count) files." -ForegroundColor Cyan
Write-Host ""
Write-Host "Record this GUID — you need the same one for every future release," -ForegroundColor Yellow
Write-Host "or your installer stops recognizing its own previous installs:" -ForegroundColor Yellow
Write-Host "  $NewGuid" -ForegroundColor White
Write-Host ""
Write-Host "Still to do by hand:" -ForegroundColor Yellow
Write-Host "  - Links.cs still lists upstream's Discord, X, Reddit, Steam and MS Store."
Write-Host "    Blank them or point them at your own; they currently send your users"
Write-Host "    to a community that doesn't support this build."
Write-Host "  - IntegrationHelpers.cs keeps the native messaging host ID"
Write-Host "    'com.getsharex.sharex'. Renaming it breaks the official browser"
Write-Host "    extension with nothing to replace it, so it is left alone."
Write-Host "  - Add your own copyright line. Do not remove the existing ones."
Write-Host ""
