<#
.SYNOPSIS
    Validates and publishes Get-AutopilotDeviceAssociation.ps1 to the PowerShell Gallery.

.DESCRIPTION
    Wrapper around Test-ScriptFileInfo + Publish-Script so the upload is a single command.
    It runs three checks before publishing:
      1. Test-ScriptFileInfo  - the PSScriptInfo / .DESCRIPTION block is complete.
      2. Parser check         - the .ps1 has no syntax errors.
      3. Version check        - the version is not already on the Gallery (skipped offline).
    Only then does it call Publish-Script with the API key you pass in.

.PARAMETER NuGetApiKey
    Your PowerShell Gallery API key (https://www.powershellgallery.com/account/apikeys).

.PARAMETER Path
    Path to the script. Defaults to the copy sitting next to this wrapper.

.PARAMETER Repository
    Target repository name. Default: PSGallery.

.PARAMETER WhatIf
    Runs every validation step and prints the Publish-Script call without sending anything.

.EXAMPLE
    .\Publish-ToPSGallery.ps1 -NuGetApiKey $env:PSGALLERY_KEY -WhatIf

.EXAMPLE
    .\Publish-ToPSGallery.ps1 -NuGetApiKey 'oy2xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx'
#>
[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [Parameter(Mandatory)]
    [string] $NuGetApiKey,

    [string] $Path = (Join-Path $PSScriptRoot 'Get-AutopilotDeviceAssociation.ps1'),

    [string] $Repository = 'PSGallery'
)

$ErrorActionPreference = 'Stop'

# The PowerShell Gallery requires TLS 1.2. Windows PowerShell 5.1 defaults to TLS 1.0
# and fails with "Could not create SSL/TLS secure channel". 3072 = Tls12 as a literal so
# this also works on .NET versions whose enum lacks the Tls12 member.
[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor 3072

# PowerShellGet 1.0.0.1 (in-box on 5.1) publishes via an out-of-process nuget.exe that
# ignores the setting above and still fails TLS. 2.x publishes in-process and works.
# A stale session can already have 1.0.0.1 loaded, so force the newest available >= 2.x.
$loaded = Get-Module PowerShellGet
if (-not $loaded -or $loaded.Version -lt [version]'2.0.0') {
    $best = Get-Module PowerShellGet -ListAvailable |
        Where-Object Version -ge ([version]'2.0.0') |
        Sort-Object Version -Descending | Select-Object -First 1
    if ($best) {
        Remove-Module PowerShellGet -Force -ErrorAction SilentlyContinue
        Import-Module PowerShellGet -MinimumVersion $best.Version -Force
        Write-Host "Loaded PowerShellGet $((Get-Module PowerShellGet).Version)." -ForegroundColor DarkGray
    } else {
        Write-Warning 'Only PowerShellGet 1.0.0.1 is available; publish will likely fail with an SSL/TLS error.'
        Write-Warning 'In an elevated session run:  Install-Module PowerShellGet -Force -AllowClobber  then retry in a new session.'
    }
}

if (-not (Test-Path -LiteralPath $Path)) { throw "Script not found: $Path" }

Write-Host "1/3  Test-ScriptFileInfo" -ForegroundColor Cyan
$info = Test-ScriptFileInfo -Path $Path
$info | Format-List Name, Version, Guid, Author, CompanyName, Tags, ProjectUri, LicenseUri, Description
if (-not $info.Description) { throw 'Description is empty - Publish-Script will reject the file.' }
if (-not $info.LicenseUri)  { Write-Warning 'No .LICENSEURI set. The Gallery accepts the upload but shows a "no license" notice.' }

Write-Host "2/3  Parser check" -ForegroundColor Cyan
$tokens = $errors = $null
[System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$tokens, [ref]$errors) | Out-Null
if ($errors) {
    $errors | ForEach-Object { Write-Error ('{0} (line {1})' -f $_.Message, $_.Extent.StartLineNumber) }
    throw 'Fix the syntax errors above before publishing.'
}
Write-Host '     Parse OK.' -ForegroundColor Green

Write-Host "3/3  Version check against $Repository" -ForegroundColor Cyan
try {
    $published = Find-Script -Name $info.Name -Repository $Repository -ErrorAction Stop
    if ($published.Version -ge $info.Version) {
        throw "$($info.Name) $($published.Version) is already on $Repository. Bump .VERSION and `$DL_SCRIPT_VERSION above $($published.Version)."
    }
    Write-Host "     Highest on gallery: $($published.Version). Publishing $($info.Version)." -ForegroundColor Green
} catch [System.Exception] {
    if ($_.Exception.Message -match 'already on') { throw }
    Write-Warning "     Could not query $Repository (first publish or offline): $($_.Exception.Message)"
}

if ($PSCmdlet.ShouldProcess("$($info.Name) $($info.Version)", "Publish-Script to $Repository")) {
    Publish-Script -Path $Path -NuGetApiKey $NuGetApiKey -Repository $Repository -Verbose
    Write-Host "Published $($info.Name) $($info.Version) to $Repository." -ForegroundColor Green
    Write-Host "It appears at https://www.powershellgallery.com/packages/$($info.Name)/$($info.Version) within a few minutes." -ForegroundColor Green
} else {
    Write-Host "WhatIf: would run Publish-Script -Path '$Path' -NuGetApiKey <hidden> -Repository $Repository" -ForegroundColor Yellow
}
