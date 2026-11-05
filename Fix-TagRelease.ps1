<#
.SYNOPSIS
    Makes a tagged release a two-command operation.

.DESCRIPTION
    Two changes to .github\workflows\build.yml.

      1. Version comes from the tag.
         The workflow already rewrites the version in Directory.build.props for
         develop builds. This extends the same trick to tags: on a push of
         v19.1.0 it writes 19.1.0 into the props before building, so the binary
         version, the artifact names, the release title and the tag can never
         disagree. Nothing to edit by hand before tagging.

      2. prerelease: false on Release (Stable).
         GitHub's /releases/latest endpoint skips prereleases, and that is the
         endpoint the default update channel checks (UpdateChannel.Release sets
         IncludePreRelease = false). Left at true, nobody on the default channel
         would ever be offered an update. Upstream relies on a maintainer
         manually unticking the flag after verifying each build; this publishes
         tagged releases as final instead.

    Safe to re-run.

.PARAMETER RepoRoot
    Path to the repo. Defaults to the current directory.

.EXAMPLE
    .\Fix-TagRelease.ps1 -WhatIf

.EXAMPLE
    .\Fix-TagRelease.ps1
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [string] $RepoRoot = '.'
)

$ErrorActionPreference = 'Stop'
$RepoRoot = (Resolve-Path $RepoRoot).Path

$ymlPath = '.github\workflows\build.yml'
$full = Join-Path $RepoRoot $ymlPath

if (-not (Test-Path $full)) {
    throw ('Missing file: ' + $ymlPath + '. Run this from the root of your checkout.')
}

$applied = 0
$skipped = 0

$text = [System.IO.File]::ReadAllText($full)
if ($text.Contains("`r`n")) { $nl = "`r`n" } else { $nl = "`n" }

function Join-Lines {
    param([string[]] $Lines)
    return [string]::Join($nl, $Lines)
}

Write-Host ''
Write-Host ('Simplifying tagged releases in ' + $RepoRoot) -ForegroundColor Cyan
Write-Host ''

# --- 1. Derive the version from the tag -----------------------------------

Write-Host 'Version' -ForegroundColor Yellow

$findVersion = Join-Lines @(
    '          if ($env:GITHUB_REF -eq "refs/heads/develop") {'
    '            $version = "$version.$env:GITHUB_RUN_NUMBER"'
    '            $content = [regex]::Replace($content, $pattern, "<Version>$version</Version>")'
    '            Set-Content -Path "${{ env.ASSEMBLY_INFO_PATH }}" -Value "$content" -NoNewline'
    '          }'
)

$replaceVersion = Join-Lines @(
    '          if ($env:GITHUB_REF.StartsWith("refs/tags/v")) {'
    "            `$version = `$env:GITHUB_REF_NAME -replace '^v', ''"
    '            $content = [regex]::Replace($content, $pattern, "<Version>$version</Version>")'
    '            Set-Content -Path "${{ env.ASSEMBLY_INFO_PATH }}" -Value "$content" -NoNewline'
    '          }'
    '          elseif ($env:GITHUB_REF -eq "refs/heads/develop") {'
    '            $version = "$version.$env:GITHUB_RUN_NUMBER"'
    '            $content = [regex]::Replace($content, $pattern, "<Version>$version</Version>")'
    '            Set-Content -Path "${{ env.ASSEMBLY_INFO_PATH }}" -Value "$content" -NoNewline'
    '          }'
)

if ($text.Contains('$env:GITHUB_REF.StartsWith("refs/tags/v")) {' + $nl + "            `$version")) {
    Write-Host '  already  version derived from tag' -ForegroundColor DarkGray
    $skipped++
}
elseif (-not $text.Contains($findVersion)) {
    throw ('Could not find the develop version block in ' + $ymlPath)
}
else {
    $text = $text.Replace($findVersion, $replaceVersion)
    $applied++
    Write-Host '  ok       version derived from tag' -ForegroundColor Green
}

# --- 2. Publish tagged releases as final ----------------------------------

Write-Host 'Release' -ForegroundColor Yellow

$count = ([regex]::Matches($text, [regex]::Escape('prerelease: true'))).Count

if ($count -eq 0) {
    Write-Host '  already  tagged releases publish as final' -ForegroundColor DarkGray
    $skipped++
}
elseif ($count -gt 1) {
    throw ('Expected one "prerelease: true" but found ' + $count + '. Refusing to guess.')
}
else {
    $text = $text.Replace('prerelease: true', 'prerelease: false')
    $applied++
    Write-Host '  ok       tagged releases publish as final' -ForegroundColor Green
}

# --- Write ----------------------------------------------------------------

if ($applied -gt 0) {
    if ($PSCmdlet.ShouldProcess($ymlPath, 'simplify tagged releases')) {
        [System.IO.File]::WriteAllText($full, $text, (New-Object System.Text.UTF8Encoding($false)))
    }
}

Write-Host ''
Write-Host ($applied.ToString() + ' applied, ' + $skipped.ToString() + ' already in place.') -ForegroundColor Cyan
Write-Host ''
Write-Host 'Cutting a release is now:' -ForegroundColor Yellow
Write-Host '  git tag v19.1.0'
Write-Host '  git push origin v19.1.0'
Write-Host ''
Write-Host 'Note that Directory.build.props still reads 19.0.2 in the repo. The'
Write-Host 'rewrite happens on the runner, so the committed value no longer'
Write-Host 'decides anything for a tagged build. Bump it when you feel like it,'
Write-Host 'or leave it; the tag wins either way.'
Write-Host ''
