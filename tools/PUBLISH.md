# Publish `Get-AutopilotDeviceAssociation` to the PowerShell Gallery

This folder is a self-contained upload package. Nothing here reads your API key from
disk — you pass it on the command line when you publish.

```
publish\
  Get-AutopilotDeviceAssociation.ps1   the script to publish (copy of Script\ in the repo)
  Publish-ToPSGallery.ps1              validate + Publish-Script wrapper
  PUBLISH.md                           this file
```

## 1. One-time machine prerequisites

```powershell
# Elevated PowerShell, once per machine
Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Force
Install-Module -Name PowerShellGet -Force -AllowClobber
Import-Module PowerShellGet
```

`Publish-Script` ships with `PowerShellGet`. Windows PowerShell 5.1 is enough.

## 2. Get an API key

<https://www.powershellgallery.com/account/apikeys> — create a key scoped to
**Push new packages and package versions**. Glob `Get-AutopilotDeviceAssociation` if you
want to lock the key to this one script.

## 3. Dry run (no upload)

```powershell
cd "<path>\publish"
.\Publish-ToPSGallery.ps1 -NuGetApiKey 'PASTE-KEY' -WhatIf
```

This runs `Test-ScriptFileInfo`, a parser check and a "is this version already on the
Gallery?" check, then prints the `Publish-Script` call it *would* run.

## 4. Publish

```powershell
.\Publish-ToPSGallery.ps1 -NuGetApiKey 'PASTE-KEY'
```

or straight from the built-in cmdlet:

```powershell
Publish-Script -Path .\Get-AutopilotDeviceAssociation.ps1 -NuGetApiKey 'PASTE-KEY'
```

The package goes live at
`https://www.powershellgallery.com/packages/Get-AutopilotDeviceAssociation/1.3.0`
within a few minutes. After that, users install it with:

```powershell
Install-Script -Name Get-AutopilotDeviceAssociation
```

## Metadata being published

| Field | Value |
|---|---|
| Name | `Get-AutopilotDeviceAssociation` (from the file name) |
| Version | `1.3.0` |
| GUID | `f21910f3-6fff-442b-9d35-5731d01e5af8` (unchanged from the previous name) |
| Author | Rudy Ooms |
| CompanyName | Patch My PC |
| ProjectUri | https://patchmypc.com/blog/windows-autopilot-device-association/ |
| LicenseUri | *not set* — Gallery shows a "no license" notice but still accepts the upload |

## Notes

- **Version bumps:** the Gallery rejects a re-publish of an existing version. Raise both
  `.VERSION` in the `<#PSScriptInfo#>` block **and** `$DL_SCRIPT_VERSION` in the script body
  before the next publish; the wrapper checks they are ahead of what is already live.
- **GUID:** kept the same so the Gallery treats this as the same script lineage under a new
  name. If you would rather start a fresh listing, replace the `.GUID` line with a new
  `[guid]::NewGuid()` value before the first publish.
- **License:** add `.LICENSEURI https://...` to the `<#PSScriptInfo#>` block (e.g. a link to
  a `LICENSE` file in the repo) to clear the notice.
- The script name uses the `Get-` verb while the toolkit also uploads, links and removes.
  That mirrors Microsoft's own `Get-WindowsAutopilotInfo -Online`; keep it in mind if
  `PSScriptAnalyzer` verb rules come up later.
