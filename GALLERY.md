# Get-AutopilotDeviceAssociation

One command for the whole **Windows Autopilot device association** lifecycle: export the device's TPM-backed identity, register it in Intune, apply the tenant-signed association, check whether it is still valid, and remove it again.

Classic Autopilot has `Get-WindowsAutopilotInfo`. Device association did not have an equivalent — this is it. Different artifact, different endpoint, so the two are not interchangeable.

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

`Install-Script` puts it on `PATH`. Update with `Update-Script Get-AutopilotDeviceAssociation`. No Microsoft Graph modules needed — it talks to Graph over REST directly.

## The four commands you will actually run

```powershell
# 1. Will this device even work?
Get-AutopilotDeviceAssociation -Action CheckRequirements -Online

# 2. Associate it end to end (export, import, wait, link, confirm)
Get-AutopilotDeviceAssociation -Action Full

# 3. Is the association real, in date, and bound to this machine?
Get-AutopilotDeviceAssociation -Action ReadAssociation -Validate -Online

# 4. Take it off again - UEFI and the Intune record
Get-AutopilotDeviceAssociation -Action RemoveAssociation -WhatIf
```

`-Action` defaults to `Full`, so a bare `Get-AutopilotDeviceAssociation` runs the whole pipeline.

## Start here: does this device qualify?

```text
Check                            Result  Detail
-----                            ------  ------
Physical device                  Pass    Dell Inc. Latitude 5480
Windows version                  Pass    Windows 11 25H2, build 26200.9278
Windows edition                  Pass    Enterprise
TPM 2.0 present                  Pass    SpecVersion 2.0 - Nuvoton, discrete
TPM ready (not RFM)              Pass    IsReadyInformation = 0
UEFI firmware                    Pass    Booted in UEFI mode
TPM supports the association key Fail    The TPM refused to create
                                         DEVICEASSOCIATION_TACK_RSA with
                                         NTE_NOT_SUPPORTED. Check for an OEM
                                         TPM firmware update.

Requirements: 1 requirement(s) not met
```

That last check matters. A device can pass every documented requirement and still fail, because its TPM firmware cannot create the key device association needs. Without it you get a bare `0x8103C00F` after a two-minute hang.

## All actions

| Action | Does |
|---|---|
| `CheckRequirements` | Verify the device qualifies. Read-only. |
| `Export` / `Inspect` | Produce and decode the `*.devicelink.csv`. |
| `Upload` / `Sync` | Import into Intune and wait for pre-association. |
| `Discover` / `Link` | Native tenant discovery, then apply the association. |
| `Full` *(default)* | All of the above, then confirm Intune reports `associated`. |
| `ReadAssociation` | Report the UEFI markers; `-Validate` checks the token. |
| `RemoveAssociation` | Clear UEFI **and** the Intune record. |

## Requirements

Run `-Action CheckRequirements` and it will tell you. [Microsoft's list](https://learn.microsoft.com/autopilot/device-preparation/device-association/requirements):

- A **physical device** — virtual machines are not supported
- **Windows 11 24H2 (`26100.9278`)** or **25H2 (`26200.9278`)**, KB5120998 or later
- Pro, Pro Education, Pro for Workstations, Enterprise, Education or Enterprise LTSC
- **TPM 2.0** — discrete, firmware or **Microsoft Pluton** — enabled, not in Reduced Functionality Mode; attestation is enforced
- UEFI firmware, since the association lives in a UEFI variable
- HTTPS to `ztd.dds.microsoft.com` and the `peapdamaa*.attest.azure.net` endpoints
- An elevated 64-bit session, and an Intune Device Preparation policy

The device-side actions run this check first. If the device does not qualify they show what is wrong and ask before continuing; `-Force` skips the prompt.

## Authentication

Device-code sign-in is the default — nothing to configure, and the token never touches disk. For unattended runs use a certificate (`-TenantId -ClientId -CertificateThumbprint`). Client secrets work but land in PowerShell history; prefer the certificate.

## Is the association still good?

`ReadAssociation` reports presence, size, attributes and a SHA-256 — never the contents. But the association **has an expiry date**, so a device can look perfectly associated and quietly not be.

`-Validate` decodes the token and checks that it is a well-formed RS256 JWT, inside its validity window, with a `linkId` matching the `DeviceLinkId` UEFI variable and tenant and device claims matching this machine. `-Online` verifies the signature against the issuer's published key. `-ShowClaims` prints the decoded header and payload to the **console only**.

## Removing an association

`RemoveAssociation` clears the local UEFI variables **and** deletes the matching Intune record. Add `-KeepCloudAssociation` (alias `-LocalOnly`) to clear UEFI only.

Local removal reads every known variable first and stops without touching anything if any read fails, deletes only what is present, then reads each one back and fails if anything survived. The cloud record must match this computer **exactly and uniquely** — zero or ambiguous matches abort before anything is touched — and a single `DELETE` is sent only after local removal is verified.

> Removal does **not** unenroll the device, clear the TPM, or delete the Intune managed-device or Entra objects. If the machine is still MDM-managed, its provider can associate it again.

## When it goes wrong

Every run writes a diagnostic folder under `C:\ProgramData\DeviceLink\Logs\`, with one artifact per REST call. Tokens, secrets, device identifiers, UEFI contents and the DeviceLink payload are redacted, so the folder is safe to attach to a support case.

| Code | Meaning |
|---|---|
| `0x80004001` | `E_NOTIMPL` — this build has no DeviceLink API. Install KB5120998. |
| `0x8103C00F` | No attestation material. Check TPM health, firmware, and the attest endpoints. |
| `0x80090029` | The TPM refused to create the association key. Usually needs an OEM TPM firmware update. |
| `0x80070005` | Not elevated. |

## Exit codes

`0` success, `1` error, `2` the device does not meet the requirements — so `CheckRequirements` works as a gate in a task sequence.

## Deliberate limits

It never fabricates, edits or re-signs an identity — the exported `Data` value is uploaded byte for byte. HTTP mutations have **zero** automatic retries. It does not make a virtual machine into supported hardware, does not intercept Windows' own DeviceLink traffic, and targets Microsoft Graph **beta**, whose contracts change.

## Links

- **Source and full reference:** <https://github.com/call4cloud-code/Autopilot-Device-Association-Script>
- **How the flow works:** [The complete 12-step flow](https://patchmypc.com/blog/windows-autopilot-device-association/)

> **A diagnostic and lab toolkit.** It calls Windows DeviceLink interfaces and Graph beta endpoints that can change, and removal genuinely changes UEFI state. Test it somewhere you do not mind breaking first.
