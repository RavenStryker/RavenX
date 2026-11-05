<#
.SYNOPSIS
    Aligns release output filenames and metadata with the rebrand.

.DESCRIPTION
    After the rebrand, the Inno Setup installer comes out as RavenX-<ver>-setup.exe,
    because OutputBaseFilename in the .iss derives from MyAppName. Everything else
    still says ShareX: the portable zip and the other output names are hardcoded in
    ShareX.Setup\Program.cs, and the workflow uploads and release assets all look
    for Output\ShareX-*. That mismatch is why the Setup artifact upload fails with
    "No files were found".

    This makes all of them agree on the app name, and fixes two things that would
    bite on the first tagged release.

      1. ShareX.Setup\Program.cs
         Output folder and archive names -> <AppName>-*.
         Leaves CompileISSFile("ShareX-setup.iss") alone: that is a real filename
         on disk, not a product name.

      2. .github\workflows\build.yml
         Artifact paths and release titles -> <AppName>-*.

      3. Release body changelog link
         Points at your releases page instead of getsharex.com/changelog, which
         documents 22.x.

      4. Release (Stable) token
         Upstream gates this on a CUSTOM_GITHUB_TOKEN secret because they publish
         dev builds to a separate repo. You publish to your own and the job already
         has contents: write, so this switches to the automatic GITHUB_TOKEN.
         Without this the step silently skips and a tag produces no release.

.PARAMETER RepoRoot
    Path to the repo. Defaults to the current directory.

.EXAMPLE
    .\Fix-OutputNames.ps1 -WhatIf

.EXAMPLE
    .\Fix-OutputNames.ps1
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [string] $RepoRoot = '.',
    [string] $AppName = 'RavenX',
    [string] $GitHubOwner = 'RavenStryker',
    [string] $GitHubRepo = 'RavenX'
)

$ErrorActionPreference = 'Stop'
$RepoRoot = (Resolve-Path $RepoRoot).Path

$Q = [string][char]34
$applied = 0
$skipped = 0

function Join-Lines {
    param([string[]] $Lines, [string] $Newline)
    return [string]::Join($Newline, $Lines)
}

function Invoke-Replace {
    param(
        [string] $Path,
        [string] $Find,
        [string] $Replace,
        [string] $Label,
        [int] $Expect = 1
    )

    $full = Join-Path $RepoRoot $Path
    if (-not (Test-Path $full)) {
        throw ('Missing file: ' + $Path + '. Run this from the root of your checkout.')
    }

    $text = [System.IO.File]::ReadAllText($full)
    $count = ([regex]::Matches($text, [regex]::Escape($Find))).Count

    if ($count -eq 0) {
        if ($text.Contains($Replace)) {
            Write-Host ('  already  ' + $Label) -ForegroundColor DarkGray
            $script:skipped++
            return
        }
        throw ('Not found in ' + $Path + ': ' + $Find)
    }

    if ($count -ne $Expect) {
        throw ('Expected ' + $Expect + ' matches in ' + $Path + ' but found ' + $count + ' for: ' + $Label)
    }

    $text = $text.Replace($Find, $Replace)

    if ($PSCmdlet.ShouldProcess($Path, $Label)) {
        [System.IO.File]::WriteAllText($full, $text, (New-Object System.Text.UTF8Encoding($false)))
    }

    $script:applied++
    Write-Host ('  ok       ' + $Label + '  (' + $count + 'x)') -ForegroundColor Green
}

function Get-Newline {
    param([string] $Path)
    $text = [System.IO.File]::ReadAllText((Join-Path $RepoRoot $Path))
    if ($text.Contains("`r`n")) { return "`r`n" } else { return "`n" }
}

$progPath = 'ShareX.Setup\Program.cs'
$ymlPath = '.github\workflows\build.yml'

Write-Host ''
Write-Host ('Aligning output names with ' + $AppName) -ForegroundColor Cyan
Write-Host ''

# --- 1. Setup builder output names ----------------------------------------

Write-Host 'Setup builder' -ForegroundColor Yellow

# Both anchored on Path.Combine(OutputDir, so CompileISSFile("ShareX-setup.iss")
# is untouched. The two forms are disjoint: one is a plain string literal, the
# other interpolated.
Invoke-Replace -Path $progPath -Expect 5 -Label 'output folder names' `
    -Find  ('Path.Combine(OutputDir, ' + $Q + 'ShareX-') `
    -Replace ('Path.Combine(OutputDir, ' + $Q + $AppName + '-')

Invoke-Replace -Path $progPath -Expect 6 -Label 'archive and installer names' `
    -Find  ('Path.Combine(OutputDir, $' + $Q + 'ShareX-') `
    -Replace ('Path.Combine(OutputDir, $' + $Q + $AppName + '-')

# --- 2. Workflow artifact paths and titles --------------------------------

Write-Host 'Workflow' -ForegroundColor Yellow

# Covers both the Windows-path uploads and the forward-slash release files.
Invoke-Replace -Path $ymlPath -Expect 14 -Label 'artifact and release asset paths' `
    -Find  'ShareX-${{ env.APP_VERSION }}' `
    -Replace ($AppName + '-${{ env.APP_VERSION }}')

# The Dev title is the same string plus " Dev", so one replacement covers both.
Invoke-Replace -Path $ymlPath -Expect 2 -Label 'release titles' `
    -Find  'name: ShareX ${{ env.APP_VERSION }}' `
    -Replace ('name: ' + $AppName + ' ${{ env.APP_VERSION }}')

# --- 3. Changelog link in the release body --------------------------------

Invoke-Replace -Path $ymlPath -Expect 1 -Label 'changelog link' `
    -Find  'https://getsharex.com/changelog#$env:GITHUB_REF_NAME' `
    -Replace ('https://github.com/' + $GitHubOwner + '/' + $GitHubRepo + '/releases/tag/$env:GITHUB_REF_NAME')

# --- 4. Release (Stable) uses the automatic token -------------------------

Write-Host 'Release' -ForegroundColor Yellow

$nl = Get-Newline $ymlPath

$findLines = @(
    '      - name: Release (Stable)'
    '        env:'
    '          CUSTOM_GITHUB_TOKEN: ${{ secrets.CUSTOM_GITHUB_TOKEN }}'
    "        if: env.CUSTOM_GITHUB_TOKEN != '' && startsWith(github.ref, 'refs/tags/v')"
    '        uses: softprops/action-gh-release@v2'
    '        with:'
    '          repository: ${{ github.repository }}'
    '          token: ${{ env.CUSTOM_GITHUB_TOKEN }}'
)

$replaceLines = @(
    '      - name: Release (Stable)'
    "        if: startsWith(github.ref, 'refs/tags/v')"
    '        uses: softprops/action-gh-release@v2'
    '        with:'
    '          repository: ${{ github.repository }}'
    '          token: ${{ secrets.GITHUB_TOKEN }}'
)

Invoke-Replace -Path $ymlPath -Expect 1 -Label 'stable release uses GITHUB_TOKEN' `
    -Find (Join-Lines $findLines $nl) `
    -Replace (Join-Lines $replaceLines $nl)

# --- Done ------------------------------------------------------------------

Write-Host ''
Write-Host ($applied.ToString() + ' applied, ' + $skipped.ToString() + ' already in place.') -ForegroundColor Cyan
Write-Host ''
Write-Host 'Worth knowing:' -ForegroundColor Yellow
Write-Host ('  - The installer script is still the file ShareX-setup.iss on disk.')
Write-Host ('    That is a filename, not a product name, and nothing user facing')
Write-Host ('    reads it. Renaming it means touching CompileISSFile too.')
Write-Host ('  - Release (Stable) still sets prerelease: true, inherited from')
Write-Host ('    upstream. Flip it to false in build.yml if you want tagged')
Write-Host ('    releases to publish as final.')
Write-Host ''
