# Get-AutopilotDeviceAssociation

[![PowerShell Gallery](https://img.shields.io/powershellgallery/v/Get-AutopilotDeviceAssociation?label=PowerShell%20Gallery)](https://www.powershellgallery.com/packages/Get-AutopilotDeviceAssociation)
[![Downloads](https://img.shields.io/powershellgallery/dt/Get-AutopilotDeviceAssociation?label=downloads)](https://www.powershellgallery.com/packages/Get-AutopilotDeviceAssociation)

One command for the whole **Windows Autopilot device association** lifecycle: export the device's TPM-backed identity, register it in Intune, apply the tenant-signed association, check whether it is still valid, and remove it again.

Classic Autopilot has `Get-WindowsAutopilotInfo`. Device Association did not have an equivalent — this is it.

---

## Install

```powershell
Install-Script -Name Get-AutopilotDeviceAssociation
```

From OOBE (Shift+F10), where nothing is set up yet:

```powershell
Set-ExecutionPolicy -Scope Process Bypass -Force
[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor 3072
Install-Script Get-AutopilotDeviceAssociation -Force
Get-AutopilotDeviceAssociation
```

`Install-Script` puts it on `PATH`, so afterwards you just type the command. Update with `Update-Script Get-AutopilotDeviceAssociation`.

No Microsoft Graph modules are required — the script talks to Graph over REST directly.

---

## The four things you will actually run

```powershell
# 1. Will this device even work?
Get-AutopilotDeviceAssociation -Action CheckRequirements -Online

# 2. Associate it end to end (export, import, wait, link)
Get-AutopilotDeviceAssociation -Action Full

# 3. Is the association real, in date, and bound to this machine?
Get-AutopilotDeviceAssociation -Action ReadAssociation -Validate -Online

# 4. Take it off again, locally and in Intune
Get-AutopilotDeviceAssociation -Action RemoveAssociation -DeleteCloudAssociation -WhatIf
```

`-Action` defaults to `Full`, so a bare `Get-AutopilotDeviceAssociation` does the whole pipeline.

---

## All actions

| Action | Network | Changes state |
|---|---|---|
| `CheckRequirements` | none, or endpoint tests with `-Online` | no |
| `Inspect` | none | no — decodes a `*.devicelink.csv` |
| `Export` | native Windows | writes a CSV |
| `Upload` | Microsoft identity + Graph | creates the Intune record, polls its state |
| `Sync` | both | export + upload + wait |
| `Discover` | native DeviceLink | no — health check only |
| `Link` | native DeviceLink | applies the association to UEFI |
| `Full` *(default)* | both | export, inspect, upload, wait, discover, link |
| `ReadAssociation` | none | no — presence, size, attributes, SHA-256 |
| `ReadAssociation -Validate` | none, or `-Online` to verify the signature | no |
| `RemoveAssociation` | none | deletes the local UEFI variables |
| `RemoveAssociation -DeleteCloudAssociation` | Graph | also deletes the Intune record |

---

## Requirements

Run `-Action CheckRequirements` and it will tell you. [Microsoft's documented list](https://learn.microsoft.com/autopilot/device-preparation/device-association/requirements):

- A **physical device** — virtual machines are not supported
- **Windows 11 24H2 (`26100.9278`)** or **25H2 (`26200.9278`)**, KB5120998 or later
- Pro, Pro Education, Pro for Workstations, Enterprise, Education, or Enterprise LTSC
- **TPM 2.0**, enabled, not in Reduced Functionality Mode — attestation is enforced
- UEFI firmware, since the association lives in a UEFI variable
- HTTPS to `ztd.dds.microsoft.com` and the `peapdamaa*.attest.azure.net` endpoints
- An elevated 64-bit PowerShell session, and an Intune Device Preparation policy

The device-side actions run this check first. If the device does not qualify they show what is wrong and ask before continuing; `-Force` skips the prompt.

---

## Authentication

| Mode | When |
|---|---|
| **Device code** *(default)* | Nothing to configure. You get a code, you sign in, the token stays in the process and never touches disk. |
| **Certificate** | `-TenantId -ClientId -CertificateThumbprint`. Use this for unattended runs. |
| **Client secret** | `-TenantId -ClientId -ClientSecret`. Works, but a secret on a command line lands in PowerShell history. Prefer the certificate. |

Delegated permissions for the default path: `DeviceManagementConfiguration.Read.All`, `DeviceManagementConfiguration.ReadWrite.All`, `DeviceManagementServiceConfig.Read.All`, `DeviceManagementServiceConfig.ReadWrite.All`.

---

## Checking whether an association is still good

`ReadAssociation` reports presence, byte count, attributes and a SHA-256 — never the contents. But the association **has an expiry date**, so a device can look perfectly associated and quietly not be.

`-Validate` decodes `DeviceLinkJwtCompressed` and checks:

- it is a well-formed RS256 JWT
- it is inside its `iat`/`exp` window, with days remaining
- its `linkId` matches the `DeviceLinkId` UEFI variable
- the tenant, serial number, manufacturer and model claims match this machine

Add `-Online` to fetch the issuer's published signing key and verify the signature. Add `-ShowClaims` to print the decoded header and payload to the **console only** — never to the log files.

---

## Removing an association

```powershell
Get-AutopilotDeviceAssociation -Action RemoveAssociation -DeleteCloudAssociation -WhatIf
```

Local removal reads every known Device Link variable first and stops without touching anything if any read fails, deletes only what is present, then reads each one back and fails if anything survived.

`-DeleteCloudAssociation` matches the Intune record on serial number or SMBIOS UUID, refuses to continue unless **exactly one** record matches, and sends its single `DELETE` only *after* local removal is verified.

> Removing the association does **not** unenroll the device, clear the TPM, or delete the Intune managed-device or Entra objects. If the machine is still MDM-managed, its provider can associate it again.

---

## When it goes wrong

Every run writes a redacted diagnostic folder under `C:\ProgramData\DeviceLink\Logs\` — a readable log, one JSON event per line, and one artifact per REST call. Tokens, secrets, device identifiers and the DeviceLink payload are redacted.

Common native HRESULTs, which the script now annotates for you:

| Code | Meaning |
|---|---|
| `0x80004001` | `E_NOTIMPL` — this Windows build has no DeviceLink API. Install KB5120998. |
| `0x8103C00F` | Windows could not obtain attestation material. Check TPM health, firmware, and the `attest.azure.net` endpoints. |
| `0x80090029` | `NTE_NOT_SUPPORTED` — the TPM refused to create the association key. Usually needs an OEM TPM firmware update. |
| `0x80070005` | Not elevated. |

---

## What it deliberately does not do

- It never fabricates, edits or re-signs an identity — the exported `Data` value is uploaded byte for byte
- `Inspect` is a structural check, not full cryptographic verification
- HTTP mutations have **zero** automatic retries
- It does not turn a virtual machine into supported hardware
- It does not intercept Windows' own DeviceLink traffic — only its own REST calls are logged
- It targets Microsoft Graph **beta**, and beta contracts change

---

## Links

- **Source and full reference:** <https://github.com/call4cloud-code/Autopilot-Device-Association-Script>
- **How the flow works:** [Windows Autopilot Device Association — the complete 12-step flow](https://patchmypc.com/blog/windows-autopilot-device-association/)
- **Microsoft requirements:** [Requirements for Windows Autopilot device association](https://learn.microsoft.com/autopilot/device-preparation/device-association/requirements)

---

> **This is a diagnostic and lab toolkit.** It calls Windows DeviceLink interfaces and Microsoft Graph beta endpoints that can change without notice, and removal genuinely changes UEFI state. Test it somewhere you do not mind breaking first.
