<#PSScriptInfo
.VERSION 1.3.0
.GUID f21910f3-6fff-442b-9d35-5731d01e5af8
.AUTHOR Rudy Ooms
.COMPANYNAME Patch My PC
.COPYRIGHT (c) 2026 Rudy Ooms. All rights reserved.
.TAGS Windows Autopilot Intune DeviceAssociation DeviceLink Autopilot-Device-Preparation OOBE
.PROJECTURI https://patchmypc.com/blog/windows-autopilot-device-association/
.RELEASENOTES
Version 1.3.0 renames the script and published command to Get-AutopilotDeviceAssociation and adds a .DESCRIPTION block for PowerShell Gallery publishing. Export, Inspect, Upload, Discover, Link, ReadAssociation and RemoveAssociation behaviour is unchanged; the console banner, work folder and diagnostic file names are unchanged.
Version 1.2.0 keeps the normal console concise, moves diagnostic events to -Verbose, and selects the first returned Device Preparation policy when no policy ID or name is supplied.
#>

<#
.SYNOPSIS
    One tool for the whole Autopilot "device link" pipeline:
      Export   - produce the genuine TPM-signed *.devicelink.csv (WinRT DeviceLinkUtilities)
      Inspect  - decode a CSV, recover the real PSS salt, check the signature field matches
      Upload   - pre-associate the device in Intune via Graph (importTenantAssociatedDevice)
      Discover - RequestDiscoveryUrlAsync (health check: is the pre-association live?)
      Link     - Discover + ConfigureDeviceLinkAsync (the OOBE "Next" button; see note)
      ReadAssociation   - read hashes/status of known Device Link UEFI variables
      RemoveAssociation - delete and verify the Device Link association variables; optionally delete the Intune association record
      Sync     - Export + Upload + wait until preassociated
      Full     - Export + Inspect + Upload + wait until preassociated + Link

.DESCRIPTION
    Get-AutopilotDeviceAssociation is a PowerShell toolkit for the whole Windows Autopilot
    device association lifecycle. It exports the genuine TPM-backed DeviceLink identity
    package that Windows produces (WinRT DeviceLinkUtilities), inspects that package and
    recovers the real RSA-PSS salt length, imports the unchanged Data value into Intune
    through the Microsoft Graph beta importTenantAssociatedDevice endpoint, polls the record
    until it is pre-associated, runs native Windows discovery and link calls, reads the local
    Device Link UEFI markers by hash and status only, and removes the association locally and
    - with an explicit switch - in Intune after verified local removal.

    The exported Data value is uploaded exactly as Windows produced it; the script does not
    fabricate, alter or re-sign identities, and HTTP mutations have zero automatic retries.
    It supports interactive device-code sign-in by default and certificate or client-secret
    app-only authentication for unattended runs. This is a diagnostic and lab toolkit that
    calls Windows DeviceLink interfaces and Microsoft Graph beta endpoints that can change;
    test it before using it in an operational workflow.

.NOTES
    Native association is intended for the Device Association OOBE flow. A missing maaJwt
    response indicates missing attestation material; HRESULT 0x8103C00F alone does not prove
    its cause. This logger captures this script's REST calls, not Windows' internal traffic.
    Diagnostic files omit credentials and full device identity data. They are redacted
    application logs, not a raw packet capture. Review them before sharing.
    Full remains the original default. Use -Action Upload to investigate an existing CSV
    without exporting again or attempting local association. Add -Verbose for safe decision,
    timing and substep details. The underlying web cmdlets' verbose/debug streams stay disabled
    so credentials and request bodies are not written to the console. Review logs before sharing.

.PARAMETER LogFolder     Parent directory for separate per-run diagnostic folders (default: WorkFolder\Logs).
.PARAMETER HttpTimeoutSec HTTP timeout in seconds. Upload POST requests are not automatically retried.
.PARAMETER Action        Full (default) | Sync | Export | Inspect | Upload | Discover | Link | ReadAssociation | RemoveAssociation
.PARAMETER CsvPath       existing *.devicelink.csv (else newest in -WorkFolder, else -Export makes one)
.PARAMETER Online        shorthand for Upload when Action is omitted; when Action is supplied, the explicit action takes precedence
.PARAMETER Version       display the toolkit version without creating logs or performing an action
.PARAMETER TenantId/ClientId  optional custom Entra tenant and app for delegated sign-in; required for app-only authentication
.PARAMETER ClientSecret/CertificateThumbprint   app-only Graph credentials (Upload/Sync/Full or online removal)
.PARAMETER InteractiveLogin  explicitly select delegated device-code sign-in; retained for backward compatibility because this is now the default
.PARAMETER DevicePreparationPolicyId | PolicyName | FirstPolicy    target APDP policy; the first returned policy is the default
.PARAMETER Verbose       add safe substep, decision, timing and HTTP metadata to the console; diagnostic files are always written
.PARAMETER DeleteCloudAssociation  after verified UEFI removal, delete the matching Intune Device Association record
.PARAMETER TenantAssociatedDeviceId optional exact Intune Device Association record ID; it must still match this computer

.EXAMPLE
    # device, fully unattended (elevated / SYSTEM):
    .\Get-AutopilotDeviceAssociation.ps1 -Action Full -TenantId t -ClientId c -CertificateThumbprint th

    .\Get-AutopilotDeviceAssociation.ps1 -Action Export
    .\Get-AutopilotDeviceAssociation.ps1 -Action Inspect -CsvPath C:\...\PC1.devicelink.csv
    .\Get-AutopilotDeviceAssociation.ps1 -Action Upload -TenantId t -ClientId c -ClientSecret s -CsvPath \\srv\share\PC1.devicelink.csv -PolicyName "apdp test"
    .\Get-AutopilotDeviceAssociation.ps1 -Action Upload -TenantId t -ClientId c -ClientSecret s -CsvPath C:\...\PC1.devicelink.csv -Verbose
    .\Get-AutopilotDeviceAssociation.ps1 -Online -CsvPath C:\...\PC1.devicelink.csv -PolicyName "apdp test" -Verbose
    .\Get-AutopilotDeviceAssociation.ps1 -Version
    .\Get-AutopilotDeviceAssociation.ps1 -Action Discover

    # Elevated PowerShell; no network request:
    .\Get-AutopilotDeviceAssociation.ps1 -Action ReadAssociation
    .\Get-AutopilotDeviceAssociation.ps1 -Action RemoveAssociation
    .\Get-AutopilotDeviceAssociation.ps1 -Action RemoveAssociation -WhatIf
    .\Get-AutopilotDeviceAssociation.ps1 -Action RemoveAssociation -DeleteCloudAssociation -TenantId t -ClientId c -CertificateThumbprint th -Verbose
#>
[CmdletBinding(SupportsShouldProcess=$true, ConfirmImpact='Medium')]
param(
    [ValidateSet('Full','Sync','Export','Inspect','Upload','Discover','Link','ReadAssociation','RemoveAssociation')]
    [string] $Action = 'Full',

    [switch] $Online,
    [switch] $Version,

    [string] $CsvPath,
    [string] $DeviceLinkBase64,
    [string] $WorkFolder = "$env:ProgramData\DeviceLink",
    [int]    $Format     = 33,          # DeviceLinkFormatFlags Json(1)|Base64(32)
    [int]    $TimeoutSec = 300,
    [ValidateRange(1,3600)][int] $HttpTimeoutSec = 180,
    [string] $LogFolder,

    [string] $TenantId,
    [string] $ClientId,
    [string] $ClientSecret,
    [string] $CertificateThumbprint,
    [switch] $InteractiveLogin,

    [switch] $DeleteCloudAssociation,
    [string] $TenantAssociatedDeviceId,

    [string] $DevicePreparationPolicyId,
    [string] $PolicyName,
    [switch] $FirstPolicy,

    [string] $GraphBase = 'https://graph.microsoft.com/beta'
)
$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$DL_SCRIPT_VERSION = '1.3.0'
$DL_DEFAULT_PUBLIC_CLIENT_ID = '14d82eec-204b-4c2f-b7e8-296a70dab67e'
$DL_DEFAULT_AUTHORITY_TENANT = 'organizations'
$APDP_TEMPLATE_ID = '70d256b3-6120-4f88-9e00-0972ec64fc83_1'
function Resolve-DLRequestedAction {
    param(
        [string]$RequestedAction,
        [bool]$ActionWasExplicit,
        [bool]$OnlineWasRequested
    )
    if (-not $OnlineWasRequested) { return $RequestedAction }
    if (-not $ActionWasExplicit) { return 'Upload' }
    return $RequestedAction
}
if ($Version) {
    Write-Output "DeviceLink toolkit $DL_SCRIPT_VERSION"
    return
}
$Action = Resolve-DLRequestedAction -RequestedAction $Action -ActionWasExplicit $PSBoundParameters.ContainsKey('Action') `
    -OnlineWasRequested ([bool]$Online)
# Explicit logs replace Start-Transcript: transcripts can capture credentials in command lines.
function Add-DLRedaction([string]$Value) {
    if ([string]::IsNullOrEmpty($Value)) { return }
    if (-not $script:DLRedactions) {
        $script:DLRedactions = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
    }
    [void]$script:DLRedactions.Add($Value)
    [void]$script:DLRedactions.Add([Uri]::EscapeDataString($Value))
    [void]$script:DLRedactions.Add([Uri]::EscapeDataString($Value).Replace('%20','+'))
    $quoted = ConvertTo-Json -InputObject $Value -Compress
    if ($quoted.Length -gt 2) { [void]$script:DLRedactions.Add($quoted.Substring(1,$quoted.Length-2)) }
}
function Protect-DLText([AllowNull()][string]$Text) {
    if ($null -eq $Text) { return '' }
    foreach ($secret in @($script:DLRedactions | Sort-Object Length -Descending)) {
        if ($secret.Length -ge 4) { $Text = $Text.Replace($secret,'[REDACTED]') }
    }
    $fields = 'authorization|proxy-authorization|client_secret|client_assertion|access_token|refresh_token|id_token|password|secret|token|deviceLink|deviceLinkInfo|deviceLinkJson|maaJwt|KeyPub|DeviceInfoSignature|SerialNumber|SmbiosUuid|LinkId|TpmKeyId|TenantId|ClientId|TenantAssociatedDeviceId|ManagedDeviceId|id|DiscoveryUrl|Cookie|Set-Cookie'
    $Text = [regex]::Replace($Text, '(?i)("(?:' + $fields + ')"\s*:\s*)"(?:\\.|[^"\\])*"', '$1"[REDACTED]"')
    $Text = [regex]::Replace($Text, '(?i)\b(Bearer\s+)[^\s"<>]+', '$1[REDACTED]')
    $Text = [regex]::Replace($Text, '(?i)((?:client_secret|client_assertion|access_token|refresh_token|id_token|password)=)[^&\s"<>\\]+', '$1[REDACTED]')
    $Text = [regex]::Replace($Text, '(?i)\b(tenantId|linkId|deviceLink|deviceLinkInfo|deviceLinkJson|maaJwt|discoveryUrl)=([^;\s]+)', '$1=[REDACTED]')
    $Text = [regex]::Replace($Text, '(?<![A-Za-z0-9_-])eyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+', '[JWT REDACTED]')
    $Text = [regex]::Replace($Text, '[A-Za-z0-9+/_-]{160,}={0,2}', '[LONG ENCODED VALUE REDACTED]')
    return $Text
}
function Protect-DLObject($Value) {
    if ($null -eq $Value) { return $null }
    if ($Value -is [string]) { return (Protect-DLText $Value) }
    if ($Value -is [DateTime]) { return $Value.ToString('o') }
    if ($Value -is [ValueType]) { return $Value }
    $sensitive = '^(?i:authorization|proxy-authorization|client_secret|client_assertion|access_token|refresh_token|id_token|password|secret|token|deviceLink|deviceLinkInfo|deviceLinkJson|maaJwt|KeyPub|DeviceInfoSignature|SerialNumber|SmbiosUuid|LinkId|TpmKeyId|TenantId|ClientId|TenantAssociatedDeviceId|ManagedDeviceId|id|DiscoveryUrl|Cookie|Set-Cookie)$'
    if ($Value -is [Collections.IDictionary]) {
        $safe = [ordered]@{}
        foreach ($key in $Value.Keys) {
            $safe[[string]$key] = if ([string]$key -match $sensitive) {'[REDACTED]'} else {Protect-DLObject $Value[$key]}
        }
        return $safe
    }
    if ($Value -is [Collections.IEnumerable]) {
        $items = @($Value | ForEach-Object { Protect-DLObject $_ })
        return ,$items
    }
    $safe = [ordered]@{}
    foreach ($property in $Value.PSObject.Properties) {
        $safe[$property.Name] = if ($property.Name -match $sensitive) {'[REDACTED]'} else {Protect-DLObject $property.Value}
    }
    return $safe
}
function Get-DLSha256([byte[]]$Bytes) {
    $hash = [Security.Cryptography.SHA256]::Create()
    try { return ([BitConverter]::ToString($hash.ComputeHash($Bytes))).Replace('-','').ToLowerInvariant() }
    finally { $hash.Dispose() }
}
function Get-DLAuthenticationMethod {
    if ($CertificateThumbprint) { return 'Certificate' }
    if ($ClientSecret) { return 'Client secret' }
    if ($ClientId) { return 'Custom interactive device code' }
    return 'Default Microsoft Graph Command Line Tools interactive device code when Graph is requested'
}
function Initialize-DLLogging {
    $script:DLRunId = [Guid]::NewGuid().ToString()
    $script:DLRequestNumber = 0
    $script:DLLogWriteFailed = $false
    $script:DLUtf8 = New-Object Text.UTF8Encoding($false)
    if (-not $LogFolder) { $LogFolder = Join-Path $WorkFolder 'Logs' }
    $name = '{0}-{1}-{2}' -f [DateTime]::UtcNow.ToString('yyyyMMdd-HHmmssfff'),$Action,$script:DLRunId.Substring(0,8)
    $script:DLRunFolder = Join-Path $LogFolder $name
    [void][IO.Directory]::CreateDirectory($script:DLRunFolder)
    $script:DLTextLog = Join-Path $script:DLRunFolder 'DeviceLink.log'
    $script:DLJsonLog = Join-Path $script:DLRunFolder 'events.jsonl'
    foreach ($v in @($ClientSecret,$TenantId,$ClientId,$DeviceLinkBase64,$TenantAssociatedDeviceId)) { Add-DLRedaction $v }
    Write-Host "DeviceLink toolkit $DL_SCRIPT_VERSION" -ForegroundColor Cyan
    if ($VerbosePreference -ne 'SilentlyContinue') {
        Write-Host "Diagnostic logs: $script:DLRunFolder" -ForegroundColor DarkGray
    }
    Write-DLLog 'RunStart' "Action: $Action" ([ordered]@{
        ScriptVersion = $DL_SCRIPT_VERSION
        PowerShell = $PSVersionTable.PSVersion.ToString()
        Edition = $PSVersionTable.PSEdition
        OS = [Environment]::OSVersion.VersionString
        Process64Bit = [Environment]::Is64BitProcess
        Format = $Format
        HttpTimeoutSeconds = $HttpTimeoutSec
        AutomaticHttpRetries = 0
        VerboseEnabled = ($VerbosePreference -ne 'SilentlyContinue')
        InputSource = $(if ($DeviceLinkBase64) {'DeviceLinkBase64 parameter'} elseif ($CsvPath) {'CsvPath parameter'} else {'Action default/discovery'})
        AuthenticationMethod = Get-DLAuthenticationMethod
        DeleteCloudAssociation = [bool]$DeleteCloudAssociation
        ExplicitAssociationRecordId = [bool]$TenantAssociatedDeviceId
        PolicySelection = $(if ($DevicePreparationPolicyId) {'Policy ID'} elseif ($PolicyName) {'Policy name'} elseif ($FirstPolicy) {'First policy (explicit)'} else {'First policy (default)'})
        ScriptSha256 = $(if ($PSCommandPath) { Get-DLSha256 ([IO.File]::ReadAllBytes($PSCommandPath)) } else { $null })
    })
}
function Write-DLLog {
    param([string]$Event, [string]$Message, $Data = $null, [string]$Level = 'INFO', [switch]$NoHost)
    $stamp = [DateTime]::UtcNow.ToString('o')
    $safeMessage = Protect-DLText $Message
    $safeData = $null
    if ($null -ne $Data) {
        $safeObject = Protect-DLObject $Data
        $safeData = ConvertTo-Json -InputObject $safeObject -Depth 32 -Compress
    }
    $line = '[{0}] [{1}] {2}: {3}' -f $stamp,$Level,$Event,$safeMessage
    if (-not $NoHost) {
        if ($VerbosePreference -ne 'SilentlyContinue') {
            Write-Host $line -ForegroundColor $(if ($Level -eq 'ERROR') {'Red'} elseif ($Level -eq 'WARN') {'Yellow'} else {'DarkGray'})
        } elseif ($Level -eq 'WARN' -or ($Level -eq 'ERROR' -and $Event -in 'RunFailed','AssociationNotConfirmed')) {
            Write-Host ("{0}: {1}" -f $Level,$safeMessage) -ForegroundColor $(if ($Level -eq 'ERROR') {'Red'} else {'Yellow'})
        }
    }
    try {
        $entry = [ordered]@{ TimestampUtc=$stamp; RunId=$script:DLRunId; Level=$Level; Event=$Event; Message=$safeMessage }
        if ($safeData) { $entry.Data = $safeObject }
        [IO.File]::AppendAllText($script:DLTextLog, $line + [Environment]::NewLine + $(if ($safeData) {$safeData + [Environment]::NewLine}), $script:DLUtf8)
        [IO.File]::AppendAllText($script:DLJsonLog, (ConvertTo-Json -InputObject $entry -Depth 40 -Compress) + [Environment]::NewLine, $script:DLUtf8)
    } catch {
        # A disk error must not turn a completed HTTP POST into an apparent retryable HTTP failure.
        $script:DLLogWriteFailed = $true
        Write-Warning 'Could not append the diagnostic log. Check the log folder and free disk space.'
    }
}
function Write-DLVerboseLog {
    param([string]$Event, [string]$Message, $Data = $null)
    if ($VerbosePreference -eq 'SilentlyContinue') { return }
    $safeMessage = Protect-DLText $Message
    Write-Verbose $safeMessage
    Write-DLLog $Event $safeMessage $Data 'VERBOSE' -NoHost
}
function Get-DLActionPlan([string]$SelectedAction) {
    switch ($SelectedAction) {
        'ReadAssociation'   { @('Read and report the known Device Link UEFI markers') }
        'RemoveAssociation' {
            if ($DeleteCloudAssociation) {
                @(
                    'Resolve and verify the Intune Device Association record',
                    'Read, remove and verify the known Device Link UEFI markers',
                    'Delete the Intune Device Association record',
                    'Verify the cloud deletion result'
                )
            } else { @('Read, remove and verify the known Device Link UEFI markers') }
        }
        'Export'            { @('Ask Windows to export a genuine DeviceLink CSV','Inspect the exported identity package') }
        'Inspect'           { @('Read and inspect the selected DeviceLink CSV') }
        'Upload'            { @('Load the DeviceLink identity package','Submit the device import to Intune','Wait for the pre-associated state') }
        'Sync'              { @('Ask Windows to export a genuine DeviceLink CSV','Read the exported identity package','Submit the device import to Intune','Wait for the pre-associated state') }
        'Discover'          { @('Load the DeviceLink identity package','Ask Windows to discover the tenant association') }
        'Link'              { @('Load the DeviceLink identity package','Discover and apply the tenant association') }
        'Full'              { @('Ask Windows to export a genuine DeviceLink CSV','Inspect and load the exported identity package','Submit the device import to Intune','Wait for the pre-associated state','Discover and apply the tenant association') }
        default             { throw "No step plan is defined for action '$SelectedAction'." }
    }
}
function Initialize-DLStepPlan {
    $script:DLStepPlan = @(Get-DLActionPlan $Action)
    $script:DLCompletedSteps = 0
    $script:DLCurrentStepNumber = $null
    $script:DLCurrentStepName = $null
    Write-Host "`nAction plan: $Action" -ForegroundColor Cyan
    for ($i=0; $i -lt $script:DLStepPlan.Count; $i++) {
        Write-Host ('  [{0}/{1}] {2}' -f ($i+1),$script:DLStepPlan.Count,$script:DLStepPlan[$i]) -ForegroundColor DarkGray
    }
    Write-DLLog 'RunPlan' "Planned $($script:DLStepPlan.Count) step(s) for $Action." @{
        Action=$Action; TotalSteps=$script:DLStepPlan.Count; Steps=$script:DLStepPlan
    }
}
function Invoke-DLStep {
    [CmdletBinding()]
    param([Parameter(Mandatory)][int]$Number,[Parameter(Mandatory)][scriptblock]$Operation)
    if (-not $script:DLStepPlan -or $Number -lt 1 -or $Number -gt $script:DLStepPlan.Count) {
        throw "Step $Number is outside the action plan."
    }
    $name = [string]$script:DLStepPlan[$Number-1]
    $script:DLCurrentStepNumber = $Number
    $script:DLCurrentStepName = $name
    Write-Host "`n[STEP $Number/$($script:DLStepPlan.Count)] $name" -ForegroundColor Cyan
    Write-DLLog 'StepStart' $name @{ Step=$Number; TotalSteps=$script:DLStepPlan.Count; Action=$Action }
    $timer = [Diagnostics.Stopwatch]::StartNew()
    try {
        $result = & $Operation
        $timer.Stop()
        $script:DLCompletedSteps = $Number
        Write-DLLog 'StepCompleted' $name @{ Step=$Number; TotalSteps=$script:DLStepPlan.Count; ElapsedMilliseconds=$timer.ElapsedMilliseconds }
        return $result
    } catch {
        $timer.Stop()
        Write-DLLog 'StepFailed' (Protect-DLText $_.Exception.Message) @{
            Step=$Number; TotalSteps=$script:DLStepPlan.Count; Name=$name; ElapsedMilliseconds=$timer.ElapsedMilliseconds
            ExceptionType=$_.Exception.GetType().FullName; HResult=('0x{0:X8}' -f ($_.Exception.HResult -band 0xffffffffL))
            ErrorId=$_.FullyQualifiedErrorId; Line=$_.InvocationInfo.ScriptLineNumber
        } 'ERROR'
        throw
    }
}
function ConvertTo-DLHeaders($Headers) {
    $result = [ordered]@{}
    if ($null -eq $Headers) { return $result }
    if ($Headers -is [Collections.Specialized.NameValueCollection]) {
        foreach ($key in $Headers.AllKeys) { $result[$key] = $Headers[$key] }
    } elseif ($Headers -is [Collections.IDictionary]) {
        foreach ($key in $Headers.Keys) { $result[[string]$key] = (@($Headers[$key]) -join ', ') }
    } else {
        foreach ($item in $Headers) {
            if ($null -ne $item.Key) { $result[[string]$item.Key] = (@($item.Value) -join ', ') }
        }
    }
    foreach ($key in @($result.Keys)) {
        if ($key -match '^(?i:Authorization|Proxy-Authorization|Cookie|Set-Cookie)$') { $result[$key] = '[REDACTED]' }
        else { $result[$key] = Protect-DLText ([string]$result[$key]) }
    }
    return $result
}
function ConvertTo-DLBodyLog($Body, [switch]$Suppress) {
    if ($Suppress) { return [ordered]@{ Text='[Authentication body omitted]'; Truncated=$false } }
    if ($null -eq $Body) { return [ordered]@{ Text=''; Truncated=$false; OriginalCharacters=0 } }
    $raw = if ($Body -is [string]) { $Body } else { ConvertTo-Json -InputObject $Body -Depth 40 -Compress }
    $safe = Protect-DLText $raw
    $limit = 262144
    $truncated = $safe.Length -gt $limit
    if ($truncated) { $safe = $safe.Substring(0,$limit) + "`n[TRUNCATED]" }
    return [ordered]@{ Text=$safe; Truncated=$truncated; OriginalCharacters=$raw.Length; Redacted=$true }
}
function Get-DLHttpFailure($Record) {
    $status = $null; $headers = [ordered]@{}; $body = ''; $bodySource = 'Unavailable'
    $response = $Record.Exception.Response
    if ($null -ne $response) {
        try { $status = [int]$response.StatusCode } catch {}
        try { $headers = ConvertTo-DLHeaders $response.Headers } catch {}
        if ($response.PSObject.Properties['Content'] -and $response.Content) {
            try {
                $contentHeaders = ConvertTo-DLHeaders $response.Content.Headers
                foreach ($key in $contentHeaders.Keys) { $headers[$key] = $contentHeaders[$key] }
                $body = $response.Content.ReadAsStringAsync().GetAwaiter().GetResult()
                if ($body) { $bodySource = 'HttpResponseMessage.Content' }
            } catch {}
        }
        if (-not $body -and $response.PSObject.Methods['GetResponseStream']) {
            try {
                $stream = $response.GetResponseStream()
                if ($stream) {
                    $reader = New-Object IO.StreamReader($stream)
                    try { $body = $reader.ReadToEnd() } finally { $reader.Dispose() }
                    if ($body) { $bodySource = 'WebResponse.GetResponseStream' }
                }
            } catch {}
        }
    }
    if (-not $body -and $Record.ErrorDetails -and $Record.ErrorDetails.Message) {
        $body = $Record.ErrorDetails.Message; $bodySource = 'PowerShell.ErrorDetails.Message'
    }
    if ($null -eq $status -and $Record.Exception.Data.Contains('HttpStatusCode')) {
        $status = $Record.Exception.Data['HttpStatusCode']
    }
    return [pscustomobject]@{ StatusCode=$status; Headers=$headers; Body=$body; BodySource=$bodySource; ExceptionType=$Record.Exception.GetType().FullName }
}
function Save-DLHttpRecord($Record) {
    $label = $Record.Operation -replace '[^A-Za-z0-9_-]','_'
    $status = if ($null -eq $Record.Response.StatusCode) {'no-status'} else {[string]$Record.Response.StatusCode}
    $path = Join-Path $script:DLRunFolder ('http-{0:D3}-{1}-{2}.json' -f $Record.Sequence,$label,$status)
    try {
        $safe = ConvertTo-Json -InputObject (Protect-DLObject $Record) -Depth 48
        [IO.File]::WriteAllText($path,$safe,$script:DLUtf8)
        return $path
    } catch {
        $script:DLLogWriteFailed = $true
        Write-Warning 'Could not save the HTTP diagnostic file; the HTTP request will not be repeated.'
        return $null
    }
}
function Invoke-DLRestMethod {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Operation,
        [Parameter(Mandatory)][string]$Uri,
        [ValidateSet('GET','POST','DELETE')][string]$Method = 'GET',
        [Collections.IDictionary]$Headers = @{},
        $Body,
        [string]$ContentType,
        [switch]$AuthenticationRequest,
        [int[]]$AcceptedStatusCodes = @(),
        [switch]$ReturnAcceptedResponseBody
    )
    $script:DLRequestNumber++
    $requestId = [Guid]::NewGuid().ToString()
    $requestHeaders = @{}
    foreach ($key in $Headers.Keys) {
        $requestHeaders[$key] = $Headers[$key]
        if ($key -ieq 'Authorization') { Add-DLRedaction ([string]$Headers[$key]); Add-DLRedaction (([string]$Headers[$key]) -replace '^(?i:Bearer)\s+','') }
    }
    if ($Body -is [Collections.IDictionary]) {
        foreach ($key in $Body.Keys) {
            if ($key -match '^(?i:client_secret|client_assertion|access_token|password)$') { Add-DLRedaction ([string]$Body[$key]) }
        }
    }
    $requestHeaders['client-request-id'] = $requestId
    $requestHeaders['return-client-request-id'] = 'true'
    $requestHeaders['Accept'] = 'application/json'
    $requestBodyText = if ($null -eq $Body) { '' } elseif ($Body -is [string]) { $Body } else { ConvertTo-Json -InputObject $Body -Depth 40 -Compress }
    $requestBodyHash = if ($AuthenticationRequest -or -not $requestBodyText) { $null } else { Get-DLSha256 ([Text.Encoding]::UTF8.GetBytes($requestBodyText)) }
    $record = [ordered]@{
        RunId=$script:DLRunId; Sequence=$script:DLRequestNumber; Operation=$Operation
        StartedUtc=[DateTime]::UtcNow.ToString('o'); ClientRequestId=$requestId
        Request=[ordered]@{ Method=$Method; Uri=(Protect-DLText $Uri); Headers=(ConvertTo-DLHeaders $requestHeaders); ContentType=$ContentType; Body=(ConvertTo-DLBodyLog $Body -Suppress:$AuthenticationRequest) }
        Response=$null; ElapsedMilliseconds=$null; AutomaticRetries=0
    }
    Write-DLLog 'HttpStart' "$Operation $Method $Uri" @{ ClientRequestId=$requestId; Sequence=$record.Sequence }
    Write-DLVerboseLog 'HttpPrepared' "Prepared HTTP request $($record.Sequence): $Operation." @{
        Sequence=$record.Sequence; Operation=$Operation; Method=$Method; Uri=(Protect-DLText $Uri)
        ClientRequestId=$requestId; TimeoutSeconds=$HttpTimeoutSec; AutomaticRetries=0
        HeaderNames=@($requestHeaders.Keys | ForEach-Object {[string]$_} | Sort-Object)
        ContentType=$ContentType; RequestBodyCharacters=$requestBodyText.Length
        RequestBodySha256=$requestBodyHash; AuthenticationBodyOmitted=[bool]$AuthenticationRequest
    }
    $argsForRest = @{ Uri=$Uri; Method=$Method; Headers=$requestHeaders; ErrorAction='Stop'; Verbose=$false; Debug=$false }
    if ($PSBoundParameters.ContainsKey('Body')) { $argsForRest.Body = $Body }
    if ($ContentType) { $argsForRest.ContentType = $ContentType }
    $parameters = (Get-Command 'Microsoft.PowerShell.Utility\Invoke-RestMethod').Parameters
    if ($parameters.ContainsKey('TimeoutSec')) { $argsForRest.TimeoutSec = $HttpTimeoutSec }
    else {
        if ($parameters.ContainsKey('ConnectionTimeoutSeconds')) { $argsForRest.ConnectionTimeoutSeconds = $HttpTimeoutSec }
        if ($parameters.ContainsKey('OperationTimeoutSeconds')) { $argsForRest.OperationTimeoutSeconds = $HttpTimeoutSec }
    }
    if ($parameters.ContainsKey('MaximumRetryCount')) { $argsForRest.MaximumRetryCount = 0 }
    if ($parameters.ContainsKey('UseBasicParsing')) { $argsForRest.UseBasicParsing = $true }
    $dlResponseHeaders = $null; $dlResponseStatus = $null
    if ($parameters.ContainsKey('ResponseHeadersVariable')) { $argsForRest.ResponseHeadersVariable = 'dlResponseHeaders' }
    if ($parameters.ContainsKey('StatusCodeVariable')) { $argsForRest.StatusCodeVariable = 'dlResponseStatus' }
    $timer = [Diagnostics.Stopwatch]::StartNew()
    try {
        $result = Microsoft.PowerShell.Utility\Invoke-RestMethod @argsForRest
    } catch {
        $timer.Stop()
        $caughtRecord = $_
        $failure = Get-DLHttpFailure $_
        if ($null -ne $failure.StatusCode -and $AcceptedStatusCodes -contains [int]$failure.StatusCode) {
            $record.ElapsedMilliseconds = $timer.ElapsedMilliseconds
            $record.Response = [ordered]@{
                Outcome='AcceptedStatus'; StatusCode=$failure.StatusCode; Headers=$failure.Headers
                Body=(ConvertTo-DLBodyLog $failure.Body -Suppress:$AuthenticationRequest); BodySource=$failure.BodySource
                ExceptionType=$failure.ExceptionType; Message=(Protect-DLText $_.Exception.Message)
            }
            $artifact = Save-DLHttpRecord $record
            Write-DLLog 'HttpAcceptedStatus' "$Operation returned the expected HTTP $($failure.StatusCode)." @{
                ClientRequestId=$requestId; ElapsedMilliseconds=$timer.ElapsedMilliseconds; HttpLog=$artifact
                StatusCode=$failure.StatusCode
            }
            Write-DLVerboseLog 'HttpAcceptedStatusDetails' "$Operation returned expected status $($failure.StatusCode) after $($timer.ElapsedMilliseconds) ms." @{
                Sequence=$record.Sequence; ClientRequestId=$requestId; StatusCode=$failure.StatusCode; HttpLog=$artifact
            }
            return [pscustomobject]@{
                DLExpectedHttpStatus=[int]$failure.StatusCode
                DLResponseBody=$(if ($ReturnAcceptedResponseBody) {[string]$failure.Body} else {$null})
            }
        }
        $record.ElapsedMilliseconds = $timer.ElapsedMilliseconds
        $record.Response = [ordered]@{
            Outcome='Failed'; StatusCode=$failure.StatusCode; Headers=$failure.Headers
            Body=(ConvertTo-DLBodyLog $failure.Body); BodySource=$failure.BodySource
            ExceptionType=$failure.ExceptionType; Message=(Protect-DLText $_.Exception.Message)
            FailureDetails=[ordered]@{
                HResult=('0x{0:X8}' -f ($_.Exception.HResult -band 0xffffffffL))
                FullyQualifiedErrorId=(Protect-DLText $_.FullyQualifiedErrorId)
                ErrorCategory=$_.CategoryInfo.Category.ToString()
                ScriptLineNumber=$_.InvocationInfo.ScriptLineNumber
                ScriptStackTrace=(Protect-DLText $_.ScriptStackTrace)
            }
        }
        $artifact = Save-DLHttpRecord $record
        Write-DLLog 'HttpFailed' "$Operation failed; HTTP $($failure.StatusCode); no automatic retry." @{
            ClientRequestId=$requestId; ElapsedMilliseconds=$timer.ElapsedMilliseconds; HttpLog=$artifact
            StatusCode=$failure.StatusCode; ResponseHeaders=$failure.Headers; ResponseBody=$record.Response.Body
        } 'ERROR'
        if ($record.Response.Body.Text) {
            $preview = $record.Response.Body.Text
            if ($preview.Length -gt 1600) { $preview = $preview.Substring(0,1600) + ' [see HTTP log]' }
            Write-Host $preview -ForegroundColor Yellow
        }
        Write-DLVerboseLog 'HttpFailureDetails' "$Operation returned a failure after $($timer.ElapsedMilliseconds) ms." @{
            Sequence=$record.Sequence; ClientRequestId=$requestId; StatusCode=$failure.StatusCode
            ExceptionType=$failure.ExceptionType; HResult=('0x{0:X8}' -f ($caughtRecord.Exception.HResult -band 0xffffffffL))
            FullyQualifiedErrorId=(Protect-DLText $caughtRecord.FullyQualifiedErrorId)
            ResponseBodyCharacters=$record.Response.Body.OriginalCharacters; ResponseBodyTruncated=$record.Response.Body.Truncated
            ResponseHeaderNames=@($failure.Headers.Keys | ForEach-Object {[string]$_} | Sort-Object); HttpLog=$artifact
        }
        $message = "$Operation failed (HTTP $($failure.StatusCode)). Client request ID: $requestId. Details: $artifact"
        $exception = New-Object System.Exception($message)
        if ($null -ne $failure.StatusCode) { $exception.Data['HttpStatusCode'] = $failure.StatusCode }
        $exception.Data['ClientRequestId'] = $requestId
        if ($artifact) { $exception.Data['HttpLog'] = $artifact }
        $errorRecord = New-Object Management.Automation.ErrorRecord($exception,'DeviceLink.HttpFailure',[Management.Automation.ErrorCategory]::InvalidOperation,$Operation)
        $PSCmdlet.ThrowTerminatingError($errorRecord)
    }
    $timer.Stop()
    if ($AuthenticationRequest -and $result.access_token) { Add-DLRedaction ([string]$result.access_token) }
    $record.ElapsedMilliseconds = $timer.ElapsedMilliseconds
    $record.Response = [ordered]@{
        Outcome='Succeeded'; StatusCode=$dlResponseStatus; Headers=(ConvertTo-DLHeaders $dlResponseHeaders)
        Body=(ConvertTo-DLBodyLog $result -Suppress:$AuthenticationRequest)
        BodySource='Invoke-RestMethod deserialized result'
        MetadataNote=$(if (-not $parameters.ContainsKey('StatusCodeVariable')) {'This Invoke-RestMethod version does not expose the status of successful responses. No status was assumed.'} else {$null})
    }
    $artifact = Save-DLHttpRecord $record
    Write-DLLog 'HttpSucceeded' "$Operation completed." @{ ClientRequestId=$requestId; HttpStatus=$dlResponseStatus; ElapsedMilliseconds=$timer.ElapsedMilliseconds; HttpLog=$artifact }
    Write-DLVerboseLog 'HttpSuccessDetails' "$Operation returned successfully after $($timer.ElapsedMilliseconds) ms." @{
        Sequence=$record.Sequence; ClientRequestId=$requestId; StatusCode=$dlResponseStatus
        ResponseBodyCharacters=$record.Response.Body.OriginalCharacters; ResponseBodyTruncated=$record.Response.Body.Truncated
        ResponseHeaderNames=@($record.Response.Headers.Keys | ForEach-Object {[string]$_} | Sort-Object); HttpLog=$artifact
    }
    return $result
}
function Write-DLExportSummary([string]$Base64) {
    Add-DLRedaction $Base64
    try {
        $decoded = [Convert]::FromBase64String($Base64)
        $data = [Text.Encoding]::UTF8.GetString($decoded) | ConvertFrom-Json
        foreach ($property in $data.DeviceInfo.PSObject.Properties) {
            if ($property.Name -match '(?i)serial|uuid|linkid|keyid|tenantid') { Add-DLRedaction ([string]$property.Value) }
        }
        foreach ($key in @($data.DeviceInfo.DeviceIdKeyList)) { Add-DLRedaction ([string]$key.KeyPub) }
        $signing = $data.DeviceLinkKeyData
        Add-DLRedaction ([string]$signing.DeviceInfoSignature)
        $signatureBytes = if ($signing.DeviceInfoSignature) { [Convert]::FromBase64String($signing.DeviceInfoSignature).Length } else {$null}
        Write-DLLog 'ExportPayload' 'Decoded export summary; the Data value will be uploaded unchanged.' ([ordered]@{
            DataCharacters=$Base64.Length
            DataSha256=(Get-DLSha256 ([Text.Encoding]::UTF8.GetBytes($Base64)))
            DecodedJsonBytes=$decoded.Length; DecodedJsonSha256=(Get-DLSha256 $decoded)
            Version=$data.Version; Manufacturer=$data.DeviceInfo.Manufacturer; Model=$data.DeviceInfo.ModelName
            SigningAlgorithm=$signing.DeviceInfoSigningAlgorithm; SigningKeyName=$signing.DeviceInfoSigningKeyName
            PssHashAlgorithm=$signing.DeviceInfoSignaturePssHashSchemeAlgorithm
            DeclaredPssSaltBytes=$signing.DeviceInfoSignaturePssSaltLength; SignatureBytes=$signatureBytes
            SignatureValidation='Not performed by this summary; salt metadata is reported, not changed.'
        })
    } catch {
        Write-DLLog 'ExportPayload' 'Could not decode the export summary. Upload data has not been modified.' @{ Error=(Protect-DLText $_.Exception.Message) } 'WARN'
    }
}
function Invoke-DLExport {
    Write-DLLog 'ExportStart' 'Requesting the Windows DeviceLink CSV export.' @{ Format=$Format }
    Write-DLVerboseLog 'ExportDetails' 'Calling the Windows DeviceLink export API.' @{
        Format=$Format; WorkFolder=$WorkFolder; TimeoutSeconds=$TimeoutSec; ExistingCsvCount=@(Get-ChildItem $WorkFolder -Filter *.devicelink.csv -ErrorAction SilentlyContinue).Count
    }
    $timer = [Diagnostics.Stopwatch]::StartNew()
    $path = [DLKit2.Native]::ExportCsv($WorkFolder, $Format, $TimeoutSec)
    $timer.Stop()
    Write-DLLog 'ExportComplete' 'Windows returned an exported CSV.' @{ CsvFile=[IO.Path]::GetFileName($path); ElapsedMilliseconds=$timer.ElapsedMilliseconds }
    Write-DLVerboseLog 'ExportResult' 'Windows completed the DeviceLink export.' @{
        CsvFile=[IO.Path]::GetFileName($path); ElapsedMilliseconds=$timer.ElapsedMilliseconds; Exists=[IO.File]::Exists($path)
    }
    return $path
}
function Invoke-DLLink([string]$Base64, [bool]$DiscoverOnly) {
    Add-DLRedaction $Base64
    Write-DLLog 'NativeAssociationStart' 'Calling the native DeviceLink manager.' @{ DiscoveryOnly=$DiscoverOnly }
    Write-DLVerboseLog 'NativeAssociationDetails' 'Passing the unchanged identity package to the Windows DeviceLink manager.' @{
        DiscoveryOnly=$DiscoverOnly; InputCharacters=$Base64.Length; InputSha256=(Get-DLSha256 ([Text.Encoding]::UTF8.GetBytes($Base64))); TimeoutSeconds=$TimeoutSec
        NativeTrafficCapturedByRestLogger=$false
    }
    $timer = [Diagnostics.Stopwatch]::StartNew()
    $result = [DLKit2.Native]::Link($Base64, $DiscoverOnly, $TimeoutSec)
    $timer.Stop()
    Write-DLLog 'NativeAssociationResult' 'Native operation returned.' @{ Result=$result; ElapsedMilliseconds=$timer.ElapsedMilliseconds; Note='Native Windows HTTP traffic is not intercepted by this REST logger.' }
    return $result
}

$DLFirmwareNamespace = '{B3DE75DA-819C-4FD5-9F01-C3D49E8CBBD7}'
$DLFirmwareVariables = @(
    # Current names observed on this Windows build.
    'DeviceLinkJwtCompressed'
    'DeviceLinkJwtLastWrite'
    # Microsoft-documented names, including the identifier common to both forms.
    'DeviceLinkId'
    'DeviceLinkBlob'
    'DeviceLinkUtc'
)

function Initialize-DLFirmwareInterop {
    if ('DLKit4.FirmwareEnvironment' -as [type]) { return }
    $firmwareSource = @'
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;

namespace DLKit4
{
    public sealed class FirmwareState
    {
        public byte[] Data = new byte[0];
        public uint Attributes;
        public int ErrorCode;
    }

    public static class FirmwareEnvironment
    {
        [StructLayout(LayoutKind.Sequential)] private struct Luid { public uint Low; public int High; }
        [StructLayout(LayoutKind.Sequential)] private struct TokenPrivileges
        {
            public uint Count;
            public Luid Luid;
            public uint Attributes;
        }

        [DllImport("kernel32.dll", SetLastError=true)] private static extern IntPtr GetCurrentProcess();
        [DllImport("advapi32.dll", SetLastError=true)] private static extern bool OpenProcessToken(IntPtr process, uint access, out IntPtr token);
        [DllImport("advapi32.dll", CharSet=CharSet.Unicode, SetLastError=true)] private static extern bool LookupPrivilegeValue(string system, string name, out Luid luid);
        [DllImport("advapi32.dll", SetLastError=true)] private static extern bool AdjustTokenPrivileges(IntPtr token, bool disableAll, ref TokenPrivileges state, uint size, out TokenPrivileges previous, out uint returned);
        [DllImport("advapi32.dll", EntryPoint="AdjustTokenPrivileges", SetLastError=true)]
        private static extern bool RestoreTokenPrivileges(IntPtr token, bool disableAll, ref TokenPrivileges state, uint size, IntPtr previous, IntPtr returned);
        [DllImport("kernel32.dll", SetLastError=true)] private static extern bool CloseHandle(IntPtr handle);
        [DllImport("kernel32.dll", EntryPoint="GetFirmwareEnvironmentVariableExW", CharSet=CharSet.Unicode, SetLastError=true)]
        private static extern uint ReadFirmware(string name, string vendor, byte[] value, uint size, out uint attributes);
        [DllImport("kernel32.dll", EntryPoint="SetFirmwareEnvironmentVariableW", CharSet=CharSet.Unicode, SetLastError=true)]
        private static extern bool DeleteFirmware(string name, string vendor, IntPtr value, uint size);

        private static IntPtr EnableFirmwarePrivilege(out TokenPrivileges previous, out bool restore)
        {
            IntPtr token;
            if (!OpenProcessToken(GetCurrentProcess(), 0x0028, out token))
                throw new Win32Exception(Marshal.GetLastWin32Error());
            restore = false;
            previous = new TokenPrivileges();
            try
            {
                Luid luid;
                if (!LookupPrivilegeValue(null, "SeSystemEnvironmentPrivilege", out luid))
                    throw new Win32Exception(Marshal.GetLastWin32Error());
                TokenPrivileges enable = new TokenPrivileges { Count=1, Luid=luid, Attributes=2 };
                uint returned;
                if (!AdjustTokenPrivileges(token, false, ref enable,
                    (uint)Marshal.SizeOf(typeof(TokenPrivileges)), out previous, out returned))
                    throw new Win32Exception(Marshal.GetLastWin32Error());
                int error = Marshal.GetLastWin32Error();
                if (error != 0) throw new Win32Exception(error,
                    "Cannot enable SeSystemEnvironmentPrivilege (Win32 error " + error + "). Run PowerShell as administrator.");
                restore = true;
                return token;
            }
            catch { CloseHandle(token); throw; }
        }

        private static void RestoreFirmwarePrivilege(IntPtr token, ref TokenPrivileges previous, bool restore)
        {
            int error = 0;
            if (restore)
            {
                // We are applying the state captured by the enable call. We do not need the
                // state that this restore operation replaces, so PreviousState and ReturnLength
                // must both be null. Passing an output buffer together with size 0 can fail with
                // ERROR_INSUFFICIENT_BUFFER even when the firmware read itself succeeded.
                if (!RestoreTokenPrivileges(token, false, ref previous, 0, IntPtr.Zero, IntPtr.Zero))
                    error = Marshal.GetLastWin32Error();
            }
            CloseHandle(token);
            if (error != 0) throw new Win32Exception(error,
                "Could not restore the process privilege (Win32 error " + error + "). Close this PowerShell session.");
        }

        public static FirmwareState Read(string name, string vendor)
        {
            TokenPrivileges previous; bool restore;
            IntPtr token = EnableFirmwarePrivilege(out previous, out restore);
            try
            {
                for (int size=4096; size<=1048576; size*=2)
                {
                    byte[] buffer = new byte[size]; uint attributes;
                    uint count = ReadFirmware(name, vendor, buffer, (uint)buffer.Length, out attributes);
                    if (count != 0)
                    {
                        byte[] data = new byte[count]; Buffer.BlockCopy(buffer,0,data,0,(int)count);
                        return new FirmwareState { Data=data, Attributes=attributes, ErrorCode=0 };
                    }
                    int error = Marshal.GetLastWin32Error();
                    if (error == 122) continue;
                    return new FirmwareState { ErrorCode=error };
                }
                return new FirmwareState { ErrorCode=122 };
            }
            finally { RestoreFirmwarePrivilege(token, ref previous, restore); }
        }

        public static int Delete(string name, string vendor)
        {
            TokenPrivileges previous; bool restore;
            IntPtr token = EnableFirmwarePrivilege(out previous, out restore);
            try
            {
                // This matches the Microsoft-recommended UEFI PowerShell module path:
                // SetFirmwareEnvironmentVariable with a null value and size zero deletes
                // the variable without supplying an attribute mask.
                if (DeleteFirmware(name, vendor, IntPtr.Zero, 0)) return 0;
                return Marshal.GetLastWin32Error();
            }
            finally { RestoreFirmwarePrivilege(token, ref previous, restore); }
        }
    }
}
'@
    Add-Type -TypeDefinition $firmwareSource -Language CSharp
}

function Get-DLFirmwareVariable([string]$Name) {
    Initialize-DLFirmwareInterop
    $native = [DLKit4.FirmwareEnvironment]::Read($Name,$DLFirmwareNamespace)
    $status = if ($native.Data.Length) {'Present'} elseif ($native.ErrorCode -eq 203) {'NotFound'} elseif ($native.ErrorCode -eq 0) {'NoData'} else {'ReadFailed'}
    $hash = $null
    if ($native.Data.Length) { $hash = Get-DLSha256 $native.Data }
    $result = [pscustomobject][ordered]@{
        Variable=$Name; Namespace=$DLFirmwareNamespace; Status=$status
        Bytes=$(if ($native.Data.Length) {$native.Data.Length} else {$null})
        SHA256=$hash; Attributes=$(if ($native.Data.Length) {'0x{0:X8}' -f $native.Attributes} else {$null})
        Win32Error=$native.ErrorCode
    }
    Write-DLVerboseLog 'FirmwareVariableRead' "UEFI variable $Name returned $status." @{
        Variable=$Name; Status=$status; Bytes=$result.Bytes; SHA256=$hash; Attributes=$result.Attributes; Win32Error=$native.ErrorCode; RawValueCaptured=$false
    }
    return $result
}

function Clear-DLFirmwareVariable([string]$Name) {
    Initialize-DLFirmwareInterop
    Write-DLVerboseLog 'FirmwareDeleteMethod' "Deleting UEFI variable $Name through SetFirmwareEnvironmentVariableW with a zero-size value." @{ Variable=$Name; Api='SetFirmwareEnvironmentVariableW'; ValueBytes=0 }
    [DLKit4.FirmwareEnvironment]::Delete($Name,$DLFirmwareNamespace)
}

function Get-DLFirmwareAssociationState {
    $result = @($DLFirmwareVariables | ForEach-Object { Get-DLFirmwareVariable $_ })
    Write-DLLog 'FirmwareAssociationRead' 'Read the known Device Link variables without returning their contents.' @{
        Namespace=$DLFirmwareNamespace
        Variables=@($result | Select-Object Variable,Status,Bytes,SHA256,Attributes,Win32Error)
        RawValuesCaptured=$false
    }
    return $result
}

function Remove-DLFirmwareAssociation {
    $before = @(Get-DLFirmwareAssociationState)
    $unreadable = @($before | Where-Object Status -in 'ReadFailed','NoData')
    if ($unreadable.Count) {
        throw ('Could not safely read every known Device Link variable; nothing was deleted. Errors: ' + (($unreadable | ForEach-Object { '{0}={1}' -f $_.Variable,$_.Win32Error }) -join ', '))
    }
    $report = @()
    foreach ($item in $before) {
        if ($item.Status -eq 'NotFound') {
            Write-DLVerboseLog 'FirmwareVariableRemoval' "UEFI variable $($item.Variable) is already absent." @{ Variable=$item.Variable; DeleteAttempted=$false; Result='AlreadyAbsent' }
            $report += [pscustomobject][ordered]@{ Variable=$item.Variable; Before='NotFound'; DeleteAttempted=$false; DeleteError=$null; After='NotFound'; Result='AlreadyAbsent' }
            continue
        }
        Write-DLVerboseLog 'FirmwareVariableRemoval' "Deleting UEFI variable $($item.Variable), then reading it again for verification." @{ Variable=$item.Variable; Before=$item.Status; BeforeBytes=$item.Bytes; BeforeSha256=$item.SHA256 }
        $deleteError = Clear-DLFirmwareVariable $item.Variable
        $after = Get-DLFirmwareVariable $item.Variable
        $result = if ($deleteError -ne 0) {'DeleteFailed'} elseif ($after.Status -eq 'NotFound') {'Removed'} else {'VerificationFailed'}
        Write-DLVerboseLog 'FirmwareVariableVerification' "UEFI variable $($item.Variable) verification result: $result." @{ Variable=$item.Variable; DeleteError=$deleteError; After=$after.Status; Result=$result }
        $report += [pscustomobject][ordered]@{
            Variable=$item.Variable; Before=$item.Status; DeleteAttempted=$true
            DeleteError=$deleteError; After=$after.Status; Result=$result
        }
    }
    Write-DLLog 'FirmwareAssociationRemoval' 'Attempted removal and verified every known Device Link variable.' @{
        Namespace=$DLFirmwareNamespace; Results=$report
        TpmChanged=$false; CloudRecordHandledByThisFunction=$false; EntraRecordDeleted=$false; DeviceUnenrolled=$false
    } $(if (@($report | Where-Object Result -in 'DeleteFailed','VerificationFailed').Count) {'ERROR'} else {'INFO'})
    $report
    $failures = @($report | Where-Object Result -in 'DeleteFailed','VerificationFailed')
    if ($failures.Count) {
        throw ('The association was not completely removed. Review: ' + (($failures | ForEach-Object { '{0}={1}/Win32:{2}' -f $_.Variable,$_.Result,$_.DeleteError }) -join ', '))
    }
}

[void][IO.Directory]::CreateDirectory($WorkFolder)
Initialize-DLLogging
$script:DLRunSucceeded = $false
try {
if ($InteractiveLogin -and ($ClientSecret -or $CertificateThumbprint)) {
    throw '-InteractiveLogin cannot be combined with -ClientSecret or -CertificateThumbprint.'
}
if ($InteractiveLogin -and $Action -notin 'Upload','Sync','Full','RemoveAssociation') {
    throw '-InteractiveLogin is valid only with Upload, Sync, Full, or RemoveAssociation with -DeleteCloudAssociation.'
}
if ($InteractiveLogin -and $Action -eq 'RemoveAssociation' -and -not $DeleteCloudAssociation) {
    throw '-InteractiveLogin has no Graph operation to authorize unless RemoveAssociation also uses -DeleteCloudAssociation.'
}
if ($DeleteCloudAssociation -and $Action -ne 'RemoveAssociation') {
    throw '-DeleteCloudAssociation is valid only with -Action RemoveAssociation.'
}
if ($TenantAssociatedDeviceId -and -not $DeleteCloudAssociation) {
    throw '-TenantAssociatedDeviceId is valid only together with -DeleteCloudAssociation.'
}
Initialize-DLStepPlan
Write-DLVerboseLog 'InteropInitialization' 'Loading the native Windows interop definitions used by this script.' @{ NativeTypeAlreadyLoaded=[bool]('DLKit2.Native' -as [type]); FirmwareTypeAlreadyLoaded=[bool]('DLKit4.FirmwareEnvironment' -as [type]) }
# =====================================================================  WinRT interop (export + link)
if (-not ("DLKit2.Native" -as [type])) {
Add-Type @'
using System;
using System.IO;
using System.Runtime.InteropServices;

namespace DLKit2
{
    [ComImport, Guid("6410BEE7-60A9-5627-9EB2-FEDA7518A4EB"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IDeviceLinkUtilities {
        [PreserveSig] int GetIids(out int c, out IntPtr p);
        [PreserveSig] int GetRuntimeClassName(out IntPtr n);
        [PreserveSig] int GetTrustLevel(out int l);
        [PreserveSig] int ExportDeviceLinkInfoCsvAsync(IntPtr folder, int format, out IntPtr op);   // 6
        [PreserveSig] int GetDeviceLinkInfoAsync(int format, out IntPtr op);                          // 7
        [PreserveSig] int GetIdkKeyInfoAsync(out IntPtr op);                                          // 8
    }
    [ComImport, Guid("1F79101B-A792-5008-A82A-A4B232229026"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IDeviceLinkManager {
        [PreserveSig] int GetIids(out int c, out IntPtr p);
        [PreserveSig] int GetRuntimeClassName(out IntPtr n);
        [PreserveSig] int GetTrustLevel(out int l);
        [PreserveSig] int GetDiscoveryUrlRequestInfo(out IntPtr info);                                // 6
        [PreserveSig] int RequestDiscoveryUrlAsync(IntPtr deviceLinkInfo, out IntPtr op);             // 7
        [PreserveSig] int GetConfigureDeviceLinkResult(out int result);                               // 8
        [PreserveSig] int ConfigureDeviceLinkAsync(IntPtr url, IntPtr tenant, IntPtr headers, out IntPtr op); // 9
    }
    [ComImport, Guid("B93C372F-472F-4BEA-B90B-9FAA9BDC178F"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IDiscoveryUrlRequestInfo {
        [PreserveSig] int GetIids(out int c, out IntPtr p);
        [PreserveSig] int GetRuntimeClassName(out IntPtr n);
        [PreserveSig] int GetTrustLevel(out int l);
        [PreserveSig] int get_DiscoveryUrl(out IntPtr h);                    // 6
        [PreserveSig] int get_TenantId(out IntPtr h);                       // 7
        [PreserveSig] int get_DiscoveryUrlRequestResultValue(out int v);    // 8
    }
    [ComImport, Guid("00000036-0000-0000-C000-000000000046"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IAsyncInfo {
        [PreserveSig] int GetIids(out int c, out IntPtr p);
        [PreserveSig] int GetRuntimeClassName(out IntPtr n);
        [PreserveSig] int GetTrustLevel(out int l);
        [PreserveSig] int get_Id(out uint id);
        [PreserveSig] int get_Status(out int status);
        [PreserveSig] int get_ErrorCode(out int hr);
        [PreserveSig] int Cancel();
        [PreserveSig] int Close();
    }
    [UnmanagedFunctionPointer(CallingConvention.StdCall)]
    delegate int GetResultsFn(IntPtr thisPtr, out IntPtr result);
    [UnmanagedFunctionPointer(CallingConvention.StdCall)]
    delegate int GetResultsIntFn(IntPtr thisPtr, out int result);

    public static class Native
    {
        [DllImport("combase.dll")] static extern int RoInitialize(int t);
        [DllImport("combase.dll", CharSet = CharSet.Unicode)] static extern int WindowsCreateString(string s, int len, out IntPtr h);
        [DllImport("combase.dll")] static extern int WindowsDeleteString(IntPtr h);
        [DllImport("combase.dll")] static extern IntPtr WindowsGetStringRawBuffer(IntPtr h, out uint len);
        [DllImport("combase.dll", CharSet = CharSet.Unicode)] static extern int RoActivateInstance(IntPtr id, out IntPtr inst);

        static void Hr(string w, int hr) { if (hr < 0) throw new Exception(w + " -> 0x" + hr.ToString("X8")); }
        static string S(IntPtr h) { if (h == IntPtr.Zero) return ""; uint n; var p = WindowsGetStringRawBuffer(h, out n); return Marshal.PtrToStringUni(p, (int)n); }
        static IntPtr Activate(string cls) { RoInitialize(1); IntPtr h; Hr("WindowsCreateString", WindowsCreateString(cls, cls.Length, out h)); IntPtr o; int hr = RoActivateInstance(h, out o); WindowsDeleteString(h); Hr("RoActivateInstance(" + cls + ")", hr); return o; }
        static IntPtr VtblResult(IntPtr p, int slot) { IntPtr v = Marshal.ReadIntPtr(p); IntPtr fn = Marshal.ReadIntPtr(v, slot * IntPtr.Size); var d = (GetResultsFn)Marshal.GetDelegateForFunctionPointer(fn, typeof(GetResultsFn)); IntPtr r; Hr("GetResults(slot " + slot + ")", d(p, out r)); return r; }
        static int VtblResultInt(IntPtr p, int slot) { IntPtr v = Marshal.ReadIntPtr(p); IntPtr fn = Marshal.ReadIntPtr(v, slot * IntPtr.Size); var d = (GetResultsIntFn)Marshal.GetDelegateForFunctionPointer(fn, typeof(GetResultsIntFn)); int r; int hr = d(p, out r); if (hr < 0) return -1; return r; }
        static int Wait(IAsyncInfo ai, int sec, string what, bool reportOnly)
        {
            var end = DateTime.UtcNow.AddSeconds(sec); int st;
            do { System.Threading.Thread.Sleep(250); Hr(what + ".Status", ai.get_Status(out st));
                 if (DateTime.UtcNow > end) throw new Exception(what + " timed out (status " + st + ")."); } while (st == 0);
            if (st == 3) { int ec; ai.get_ErrorCode(out ec); if (reportOnly) return ec; throw new Exception(what + " error 0x" + ec.ToString("X8")); }
            if (st == 2) { if (reportOnly) return -1; throw new Exception(what + " canceled."); }
            return 0;
        }

        public static string ExportCsv(string folder, int format, int timeoutSec)
        {
            var dlu = (IDeviceLinkUtilities)Marshal.GetObjectForIUnknown(Activate("ModernDeployment.Autopilot.Core.DeviceLinkUtilities"));
            var before = new System.Collections.Generic.HashSet<string>();
            foreach (var f in Directory.GetFiles(folder, "*.devicelink.csv")) before.Add(f);
            IntPtr hF; Hr("WindowsCreateString(folder)", WindowsCreateString(folder, folder.Length, out hF));
            IntPtr op; Hr("ExportDeviceLinkInfoCsvAsync", dlu.ExportDeviceLinkInfoCsvAsync(hF, format, out op)); WindowsDeleteString(hF);
            Wait((IAsyncInfo)Marshal.GetObjectForIUnknown(op), timeoutSec, "ExportDeviceLinkInfoCsvAsync", false);
            string newest = null; DateTime nt = DateTime.MinValue;
            foreach (var f in Directory.GetFiles(folder, "*.devicelink.csv")) { var t = File.GetLastWriteTimeUtc(f); if (t >= nt) { nt = t; newest = f; } }
            if (newest == null) throw new Exception("Export succeeded but no *.devicelink.csv in " + folder);
            return newest;
        }

        // "alreadyLinked=..;discoveryResult=..;discoveryUrl=..;tenantId=..;configureResult=..;configureHResult=0x.."
        public static string Link(string deviceLinkBase64, bool discoverOnly, int timeoutSec)
        {
            var mgr = (IDeviceLinkManager)Marshal.GetObjectForIUnknown(Activate("ModernDeployment.Autopilot.Core.DeviceLinkManager"));
            int already; Hr("GetConfigureDeviceLinkResult", mgr.GetConfigureDeviceLinkResult(out already));

            IntPtr hB; Hr("WindowsCreateString(blob)", WindowsCreateString(deviceLinkBase64, deviceLinkBase64.Length, out hB));
            IntPtr op; Hr("RequestDiscoveryUrlAsync", mgr.RequestDiscoveryUrlAsync(hB, out op)); WindowsDeleteString(hB);
            Wait((IAsyncInfo)Marshal.GetObjectForIUnknown(op), timeoutSec, "RequestDiscoveryUrlAsync", false);
            IntPtr pInfo = VtblResult(op, 8);
            if (pInfo == IntPtr.Zero) throw new Exception("RequestDiscoveryUrlAsync returned null result.");
            var info = (IDiscoveryUrlRequestInfo)Marshal.GetObjectForIUnknown(pInfo);
            IntPtr hU, hT; int dres;
            Hr("get_DiscoveryUrl", info.get_DiscoveryUrl(out hU));
            Hr("get_TenantId", info.get_TenantId(out hT));
            Hr("get_ResultValue", info.get_DiscoveryUrlRequestResultValue(out dres));
            string url = S(hU), tid = S(hT); WindowsDeleteString(hU); WindowsDeleteString(hT);

            string r = "alreadyLinked=" + already + ";discoveryResult=" + dres + ";discoveryUrl=" + url + ";tenantId=" + tid + ";configureResult=";
            if (discoverOnly) return r + "(skipped);configureHResult=(skipped)";
            if (already == 1) return r + "1(already-linked);configureHResult=0x0";
            if ((dres != 1 && dres != 2) || string.IsNullOrEmpty(url))
                throw new Exception("Discovery failed (result " + dres + "). 3 = NotPreAssociated -> pre-associate first.");

            IntPtr hU2, hT2; Hr("WindowsCreateString(url)", WindowsCreateString(url, url.Length, out hU2));
            Hr("WindowsCreateString(tid)", WindowsCreateString(tid, tid.Length, out hT2));
            IntPtr op2; Hr("ConfigureDeviceLinkAsync", mgr.ConfigureDeviceLinkAsync(hU2, hT2, IntPtr.Zero, out op2));
            WindowsDeleteString(hU2); WindowsDeleteString(hT2);
            int aerr = Wait((IAsyncInfo)Marshal.GetObjectForIUnknown(op2), timeoutSec, "ConfigureDeviceLinkAsync", true);
            // real result: IAsyncOperationWithProgress<ConfigureDeviceLinkResult,..>::GetResults() is vtable slot 10 (enum by value)
            int cres = -1;
            if (aerr == 0) { cres = VtblResultInt(op2, 10); }
            if (cres <= 0) { int c2; if (mgr.GetConfigureDeviceLinkResult(out c2) >= 0 && c2 > 0) cres = c2; }
            return r + cres + ";configureHResult=0x" + (aerr != 0 ? aerr.ToString("X8") : "0");
        }
    }
}
'@
}

# =====================================================================  helpers
function Get-BlobFromCsv([string]$path) {
    Write-DLVerboseLog 'CsvReadDetails' 'Opening the selected DeviceLink CSV.' @{ CsvFile=[IO.Path]::GetFileName($path); Exists=[IO.File]::Exists($path) }
    $bytes = [IO.File]::ReadAllBytes($path)
    if ($bytes.Length -ge 2 -and $bytes[0] -eq 0xFF -and $bytes[1] -eq 0xFE) {
        $csvText = [Text.Encoding]::Unicode.GetString($bytes); $encoding = 'UTF-16LE'
    } elseif ($bytes.Length -ge 2 -and $bytes[0] -eq 0xFE -and $bytes[1] -eq 0xFF) {
        $csvText = [Text.Encoding]::BigEndianUnicode.GetString($bytes); $encoding = 'UTF-16BE'
    } elseif ($bytes.Length -ge 2 -and $bytes[1] -eq 0) {
        $csvText = [Text.Encoding]::Unicode.GetString($bytes); $encoding = 'UTF-16LE without BOM'
    } else {
        $csvText = [Text.Encoding]::UTF8.GetString($bytes); $encoding = 'UTF-8'
    }
    $rows = @($csvText.TrimStart([char]0xFEFF) | ConvertFrom-Csv)
    if ($rows.Count -ne 1) { throw 'Expected exactly one device row in the CSV.' }
    $b64 = [string]$rows[0].Data
    if ([string]::IsNullOrWhiteSpace($b64)) { throw 'The CSV must have a nonempty Data column.' }
    Add-DLRedaction $b64
    foreach ($field in @('SerialNumber','LinkId')) { Add-DLRedaction ([string]$rows[0].$field) }
    Write-DLLog 'CsvRead' 'Read one device row using the Data column.' @{
        CsvFile=[IO.Path]::GetFileName($path); FileBytes=$bytes.Length; Encoding=$encoding
        FileSha256=(Get-DLSha256 $bytes); Columns=@($rows[0].PSObject.Properties.Name)
    }
    Write-DLVerboseLog 'CsvParsed' 'The CSV contains one row and a nonempty Data field.' @{
        CsvFile=[IO.Path]::GetFileName($path); Encoding=$encoding; RowCount=$rows.Count; DataCharacters=$b64.Length
        DataSha256=(Get-DLSha256 ([Text.Encoding]::UTF8.GetBytes($b64)))
    }
    Write-DLExportSummary $b64
    return $b64
}
function Resolve-Csv {
    if ($CsvPath) {
        Write-DLVerboseLog 'CsvSelection' 'Using the CSV path supplied by the caller.' @{ Source='CsvPath parameter'; CsvFile=[IO.Path]::GetFileName($CsvPath) }
        return $CsvPath
    }
    $files = @(Get-ChildItem $WorkFolder -Filter *.devicelink.csv -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending)
    $selected = $files | Select-Object -First 1 -Expand FullName
    Write-DLVerboseLog 'CsvSelection' 'Searched the work folder and selected the newest DeviceLink CSV.' @{
        Source='Newest CSV in WorkFolder'; CandidateCount=$files.Count; CsvFile=$(if ($selected) {[IO.Path]::GetFileName($selected)} else {$null})
    }
    return $selected
}
function Get-DLDelegatedGraphScopes {
    @(
        'DeviceManagementConfiguration.Read.All'
        'DeviceManagementConfiguration.ReadWrite.All'
        'DeviceManagementServiceConfig.Read.All'
        'DeviceManagementServiceConfig.ReadWrite.All'
    )
}
function Get-DLInteractiveGraphToken {
    if ($ClientSecret -or $CertificateThumbprint) {
        throw 'Interactive sign-in cannot be combined with -ClientSecret or -CertificateThumbprint.'
    }
    if ($ClientId -and -not $TenantId) {
        throw 'A custom -ClientId for interactive sign-in also requires -TenantId.'
    }
    $authClientId = if ($ClientId) { $ClientId } else { $DL_DEFAULT_PUBLIC_CLIENT_ID }
    $authTenant = if ($TenantId) { $TenantId } else { $DL_DEFAULT_AUTHORITY_TENANT }
    $clientProfile = if ($ClientId) { 'Custom public-client application' } else { 'Microsoft Graph Command Line Tools public client' }
    $scopes = @(Get-DLDelegatedGraphScopes)
    $scopeText = $scopes -join ' '
    $deviceCodeUri = "https://login.microsoftonline.com/$authTenant/oauth2/v2.0/devicecode"
    $tokenUri = "https://login.microsoftonline.com/$authTenant/oauth2/v2.0/token"
    Write-DLLog 'InteractiveAuthenticationStart' 'Requesting a Microsoft device-code sign-in prompt.' @{
        Flow='OAuth 2.0 device authorization grant'; DelegatedScopes=$scopes; ClientIdLogged=$false; TenantIdLogged=$false
        ClientProfile=$clientProfile; DefaultPublicClient=(-not [bool]$ClientId)
        ClientSecretUsed=$false; CertificateUsed=$false; AutomaticHttpRetries=0
    }
    $deviceCode = Invoke-DLRestMethod -Operation 'RequestInteractiveDeviceCode' -Method POST -Uri $deviceCodeUri `
        -Body @{client_id=$authClientId;scope=$scopeText} -ContentType 'application/x-www-form-urlencoded' -AuthenticationRequest
    if (-not $deviceCode.device_code -or -not $deviceCode.user_code -or -not $deviceCode.verification_uri) {
        throw 'Microsoft did not return a complete device-code sign-in response.'
    }
    Add-DLRedaction ([string]$deviceCode.device_code)
    Add-DLRedaction ([string]$deviceCode.user_code)
    Add-DLRedaction ([string]$deviceCode.message)
    Write-Host "`nMicrosoft Graph sign-in" -ForegroundColor Cyan
    Write-Host ([string]$deviceCode.message) -ForegroundColor Yellow
    Write-Host "`nWaiting for sign-in..." -ForegroundColor DarkGray
    Write-DLLog 'InteractiveAuthenticationPrompt' 'Displayed the Microsoft device-login instructions on the console. The user code was not written to the diagnostic log.' @{
        VerificationHost=([Uri]$deviceCode.verification_uri).Host; UserCodeLogged=$false; DeviceCodeLogged=$false
        ExpiresInSeconds=[int]$deviceCode.expires_in; PollIntervalSeconds=[int]$deviceCode.interval
    }
    $interval = [Math]::Max(1,[int]$deviceCode.interval)
    $deadline = [DateTime]::UtcNow.AddSeconds([int]$deviceCode.expires_in)
    $attempt = 0
    do {
        Start-Sleep -Seconds $interval
        $attempt++
        $poll = Invoke-DLRestMethod -Operation 'PollInteractiveGraphToken' -Method POST -Uri $tokenUri `
            -Body @{grant_type='urn:ietf:params:oauth:grant-type:device_code';client_id=$authClientId;device_code=$deviceCode.device_code} `
            -ContentType 'application/x-www-form-urlencoded' -AuthenticationRequest -AcceptedStatusCodes 400 -ReturnAcceptedResponseBody
        if ($poll.access_token) {
            Add-DLRedaction ([string]$poll.access_token)
            $grantedScopes = @(([string]$poll.scope -split '\s+') | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
            $missingScopes = if ($grantedScopes.Count) { @($scopes | Where-Object { $_ -notin $grantedScopes }) } else { @() }
            if ($missingScopes.Count) {
                Write-DLLog 'InteractiveAuthenticationScopeCheck' 'The delegated token response omitted one or more requested Graph scopes.' @{
                    ScopeMetadataReturned=$true; GrantedScopes=$grantedScopes; MissingScopes=$missingScopes
                } 'ERROR'
                throw ('Microsoft authenticated the user but the delegated token response omitted required Graph scopes: ' + ($missingScopes -join ', '))
            }
            Write-DLLog 'InteractiveAuthenticationScopeCheck' 'Checked the delegated scopes returned with the token response.' @{
                ScopeMetadataReturned=[bool]$grantedScopes.Count; GrantedScopes=$grantedScopes; MissingScopes=$missingScopes
            }
            Write-DLLog 'InteractiveAuthenticationComplete' 'Microsoft returned a delegated Graph access token for this process.' @{
                Attempts=$attempt; DelegatedScopesRequested=$scopes; AccessTokenLogged=$false; RefreshTokenRequested=$false
            }
            return [string]$poll.access_token
        }
        $oauthError = $null
        if ($poll.DLExpectedHttpStatus -eq 400 -and $poll.DLResponseBody) {
            try { $oauthError = ([string]$poll.DLResponseBody | ConvertFrom-Json).error } catch {}
        }
        switch ([string]$oauthError) {
            'authorization_pending' {
                Write-DLVerboseLog 'InteractiveAuthenticationPending' "Waiting for interactive sign-in (poll $attempt)." @{Attempt=$attempt;NextPollSeconds=$interval}
                continue
            }
            'slow_down' {
                $interval += 5
                Write-DLVerboseLog 'InteractiveAuthenticationSlowDown' 'Microsoft asked the client to reduce the token polling rate.' @{Attempt=$attempt;NextPollSeconds=$interval}
                continue
            }
            'authorization_declined' { throw 'The interactive Microsoft Graph sign-in was declined.' }
            'expired_token' { throw 'The Microsoft device-login code expired before sign-in completed.' }
            'bad_verification_code' { throw 'Microsoft rejected the device-login code.' }
            'access_denied' { throw 'The signed-in account or tenant denied the requested Microsoft Graph delegated permissions.' }
            default {
                if ($poll.DLExpectedHttpStatus -eq 400) { throw "Interactive Microsoft Graph sign-in failed with OAuth error '$oauthError'." }
            }
        }
    } while ([DateTime]::UtcNow -lt $deadline)
    throw 'The Microsoft device-login prompt expired before sign-in completed.'
}
function Get-GraphToken {
    if (-not $ClientSecret -and -not $CertificateThumbprint) {
        Write-DLVerboseLog 'AuthenticationSelection' 'Using delegated Microsoft Graph device-code sign-in because no app-only credential was supplied.' @{
            Method=$(if ($ClientId) {'Custom public client'} else {'Microsoft Graph Command Line Tools public client'})
            TenantSelection=$(if ($TenantId) {'Explicit tenant'} else {'Organizations account chosen during sign-in'})
        }
        return (Get-DLInteractiveGraphToken)
    }
    if ($ClientSecret -and $CertificateThumbprint) {
        throw 'Choose either -ClientSecret or -CertificateThumbprint for app-only authentication, not both.'
    }
    if (-not $TenantId -or -not $ClientId) {
        throw 'App-only Microsoft Graph authentication requires -TenantId and -ClientId together with the secret or certificate.'
    }
    $uri = "https://login.microsoftonline.com/$TenantId/oauth2/v2.0/token"
    if ($CertificateThumbprint) {
        Write-DLVerboseLog 'AuthenticationSelection' 'Using certificate-based client credentials for Microsoft Graph.' @{ Method='Certificate'; CertificateValueLogged=$false }
        $c = Get-ChildItem Cert:\CurrentUser\My,Cert:\LocalMachine\My -EA SilentlyContinue |
             Where-Object Thumbprint -eq ($CertificateThumbprint -replace '\s','') | Select-Object -First 1
        if (-not $c) { throw "Cert $CertificateThumbprint not found." }
        Write-DLVerboseLog 'CertificateResolved' 'Found the requested certificate with an accessible public certificate object.' @{
            NotAfter=$c.NotAfter.ToUniversalTime().ToString('o'); HasPrivateKey=$c.HasPrivateKey; SubjectLogged=$false; ThumbprintLogged=$false
        }
        function U([byte[]]$b){ [Convert]::ToBase64String($b).TrimEnd('=').Replace('+','-').Replace('/','_') }
        $now=[DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
        $h=U ([Text.Encoding]::UTF8.GetBytes((@{alg='RS256';typ='JWT';x5t=(U $c.GetCertHash())}|ConvertTo-Json -Compress)))
        $p=U ([Text.Encoding]::UTF8.GetBytes((@{aud=$uri;iss=$ClientId;sub=$ClientId;jti=[Guid]::NewGuid().ToString();nbf=$now;exp=$now+600}|ConvertTo-Json -Compress)))
        $rsa=[System.Security.Cryptography.X509Certificates.RSACertificateExtensions]::GetRSAPrivateKey($c)
        $s=U ($rsa.SignData([Text.Encoding]::ASCII.GetBytes("$h.$p"),[System.Security.Cryptography.HashAlgorithmName]::SHA256,[System.Security.Cryptography.RSASignaturePadding]::Pkcs1))
        $body=@{client_id=$ClientId;scope='https://graph.microsoft.com/.default';grant_type='client_credentials';client_assertion_type='urn:ietf:params:oauth:client-assertion-type:jwt-bearer';client_assertion="$h.$p.$s"}
    } elseif ($ClientSecret) {
        Write-DLVerboseLog 'AuthenticationSelection' 'Using client-secret credentials for Microsoft Graph.' @{ Method='Client secret'; SecretLogged=$false }
        $body=@{client_id=$ClientId;scope='https://graph.microsoft.com/.default';grant_type='client_credentials';client_secret=$ClientSecret}
    } else { throw 'No Microsoft Graph authentication method was selected.' }
    (Invoke-DLRestMethod -Operation 'AcquireGraphToken' -Method POST -Uri $uri -Body $body -ContentType 'application/x-www-form-urlencoded' -AuthenticationRequest).access_token
}
function Invoke-Inspect([string]$path) {
    Write-DLVerboseLog 'InspectionStart' 'Decoding the CSV Data field and inspecting its RSA-PSS salt structure.' @{ CsvFile=[IO.Path]::GetFileName($path); FullSignatureVerification=$false }
    $b64 = Get-BlobFromCsv $path
    $json = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($b64))
    $o = $json | ConvertFrom-Json
    Write-Host "`n--- DeviceInfo ---" -ForegroundColor Cyan
    $o.DeviceInfo | Select-Object Manufacturer,ModelName,SerialNumber,SmbiosUuid,LinkId,LinkIdCreationTimeUtc | Format-List
    $idk = $o.DeviceInfo.DeviceIdKeyList | Where-Object KeyName -eq $o.DeviceLinkKeyData.DeviceInfoSigningKeyName
    $blob = [Convert]::FromBase64String($idk.KeyPub)
    $br = New-Object IO.BinaryReader (New-Object IO.MemoryStream (,$blob))
    $null=$br.ReadBytes(4);$null=$br.ReadInt32();$cbE=$br.ReadInt32();$cbM=$br.ReadInt32();$null=$br.ReadInt32();$null=$br.ReadInt32()
    $e=$br.ReadBytes($cbE);$m=$br.ReadBytes($cbM)
    function BI([byte[]]$be){ $le=$be.Clone();[Array]::Reverse($le);$le+=[byte]0;[System.Numerics.BigInteger]::new($le) }
    $sig=[Convert]::FromBase64String($o.DeviceLinkKeyData.DeviceInfoSignature)
    $mb=([System.Numerics.BigInteger]::ModPow((BI $sig),(BI $e),(BI $m))).ToByteArray();[Array]::Reverse($mb)
    $emLen=$m.Length;$hLen=32
    if($mb.Length -lt $emLen){$mb=([byte[]](,0)*($emLen-$mb.Length))+$mb}elseif($mb.Length -gt $emLen){$mb=$mb[($mb.Length-$emLen)..($mb.Length-1)]}
    $sha=[System.Security.Cryptography.SHA256]::Create()
    $H=[byte[]]($mb[($emLen-$hLen-1)..($emLen-2)]);$mdb=[byte[]]($mb[0..($emLen-$hLen-2)])
    $mask=@();$c=0;while($mask.Length -lt $mdb.Length){$cb=[BitConverter]::GetBytes([uint32]$c);[Array]::Reverse($cb);$mask+=$sha.ComputeHash($H+$cb);$c++}
    $DB=New-Object byte[] $mdb.Length;for($i=0;$i -lt $DB.Length;$i++){$DB[$i]=$mdb[$i] -bxor $mask[$i]}
    $DB[0]=$DB[0] -band 0x7F
    $sep=[Array]::IndexOf($DB,[byte]1)
    $actual = if($sep -ge 0){ $DB.Length-1-$sep } else { -1 }
    $claimed = [int]$o.DeviceLinkKeyData.DeviceInfoSignaturePssSaltLength
    $inspection = [pscustomobject]@{
        SigningKey            = $o.DeviceLinkKeyData.DeviceInfoSigningKeyName
        Algorithm             = $o.DeviceLinkKeyData.DeviceInfoSigningAlgorithm
        PssTrailer_0xBC       = ($mb[-1] -eq 0xBC)
        SaltLength_claimed    = $claimed
        SaltLength_inSignature= $actual
        FieldMatchesSignature = ($actual -eq $claimed)
        ValidationScope       = 'Salt structure only; the inventory message digest has not been verified.'
    }
    Write-DLLog 'SaltInspection' 'Compared declared and recovered salt lengths.' $inspection
    Write-DLVerboseLog 'InspectionResult' 'Completed the structural RSA-PSS salt inspection.' $inspection
    $inspection | Format-List
    if ($mb[-1] -eq 0xBC -and $actual -ne $claimed) {
        Write-Warning "INVALID: field says $claimed but signature used salt $actual. Do not edit the field as a workaround; preserve the original export for investigation."
    } elseif ($mb[-1] -eq 0xBC) { Write-Host "OK: salt field matches signature." -ForegroundColor Green }
}
function Graph-Headers {
    if (-not $script:GH) {
        if ($InteractiveLogin -and ($ClientSecret -or $CertificateThumbprint)) {
            throw '-InteractiveLogin cannot be combined with -ClientSecret or -CertificateThumbprint.'
        }
        if ($ClientSecret -and $CertificateThumbprint) {
            throw 'Choose either -ClientSecret or -CertificateThumbprint, not both.'
        }
        if (($ClientSecret -or $CertificateThumbprint) -and (-not $TenantId -or -not $ClientId)) {
            throw 'App-only Microsoft Graph authentication requires -TenantId and -ClientId.'
        }
        if (-not $ClientSecret -and -not $CertificateThumbprint -and $ClientId -and -not $TenantId) {
            throw 'A custom -ClientId for interactive sign-in also requires -TenantId.'
        }
        $authMode = Get-DLAuthenticationMethod
        Write-DLVerboseLog 'GraphHeaderCache' 'No cached Graph authorization header exists for this run; acquiring a token now.' @{ Cached=$false; AuthenticationMode=$authMode }
        $script:GH = @{ Authorization = "Bearer $(Get-GraphToken)" }
        Write-Host "Microsoft Graph authentication completed." -ForegroundColor Green
        Write-DLVerboseLog 'GraphHeaderCache' 'Stored the Graph authorization header in memory for this run.' @{ Cached=$true; TokenLogged=$false; AuthenticationMode=$authMode }
    } else {
        Write-DLVerboseLog 'GraphHeaderCache' 'Reusing the in-memory Graph authorization header for this run.' @{ Cached=$true; TokenLogged=$false }
    }
    $script:GH
}
function Get-DLIdentifierHash([AllowNull()][string]$Value) {
    if ([string]::IsNullOrWhiteSpace($Value)) { return $null }
    Get-DLSha256 ([Text.Encoding]::UTF8.GetBytes($Value.Trim()))
}
function ConvertTo-DLNormalizedUuid([AllowNull()][string]$Value) {
    if ([string]::IsNullOrWhiteSpace($Value)) { return $null }
    $parsed = [Guid]::Empty
    if ([Guid]::TryParse($Value.Trim().Trim('{','}'),[ref]$parsed)) { return $parsed.ToString('D') }
    return $Value.Trim().Trim('{','}').ToLowerInvariant()
}
function Get-DLLocalDeviceIdentity {
    $bios = Get-CimInstance -ClassName Win32_BIOS -ErrorAction Stop
    $product = Get-CimInstance -ClassName Win32_ComputerSystemProduct -ErrorAction Stop
    $serial = ([string]$bios.SerialNumber).Trim()
    $uuid = ConvertTo-DLNormalizedUuid ([string]$product.UUID)
    if ([string]::IsNullOrWhiteSpace($serial) -and [string]::IsNullOrWhiteSpace($uuid)) {
        throw 'Could not read a BIOS serial number or SMBIOS UUID. Cloud deletion was stopped before changing UEFI.'
    }
    Add-DLRedaction $serial
    Add-DLRedaction $uuid
    Write-DLVerboseLog 'LocalDeviceIdentity' 'Read the local identifiers used only for exact association-record matching.' @{
        SerialAvailable=[bool]$serial; SmbiosUuidAvailable=[bool]$uuid
        SerialSha256=(Get-DLIdentifierHash $serial); SmbiosUuidSha256=(Get-DLIdentifierHash $uuid)
        RawIdentifiersLogged=$false
    }
    [pscustomobject]@{ SerialNumber=$serial; SmbiosUuid=$uuid }
}
function Test-DLAssociationRecordMatch($Record,$Identity) {
    $recordSerial = ([string]$Record.serialNumber).Trim()
    $recordUuid = ConvertTo-DLNormalizedUuid ([string]$Record.smbiosUuid)
    $serialMatch = (-not [string]::IsNullOrWhiteSpace($Identity.SerialNumber)) -and
                   (-not [string]::IsNullOrWhiteSpace($recordSerial)) -and
                   [string]::Equals($Identity.SerialNumber.Trim(),$recordSerial,[StringComparison]::OrdinalIgnoreCase)
    $uuidMatch = (-not [string]::IsNullOrWhiteSpace($Identity.SmbiosUuid)) -and
                 (-not [string]::IsNullOrWhiteSpace($recordUuid)) -and
                 [string]::Equals($Identity.SmbiosUuid,$recordUuid,[StringComparison]::OrdinalIgnoreCase)
    [pscustomobject]@{ Matches=($serialMatch -or $uuidMatch); SerialMatch=$serialMatch; SmbiosUuidMatch=$uuidMatch }
}
function Assert-DLCloudRemovalParameters {
    if ($ClientSecret -and $CertificateThumbprint) {
        throw 'Choose either -ClientSecret or -CertificateThumbprint, not both.'
    }
    if (($ClientSecret -or $CertificateThumbprint) -and (-not $TenantId -or -not $ClientId)) {
        throw 'App-only cloud removal requires -TenantId and -ClientId.'
    }
    if (-not $ClientSecret -and -not $CertificateThumbprint -and $ClientId -and -not $TenantId) {
        throw 'A custom -ClientId for interactive cloud removal also requires -TenantId.'
    }
    if ($TenantAssociatedDeviceId) {
        $parsed = [Guid]::Empty
        if (-not [Guid]::TryParse($TenantAssociatedDeviceId,[ref]$parsed)) {
            throw '-TenantAssociatedDeviceId must be the GUID of an Intune Device Association record.'
        }
    }
}
function Resolve-DLCloudAssociation {
    param($Identity,[Collections.IDictionary]$Headers)
    $select = 'id,serialNumber,smbiosUuid,associationState,managedDeviceId'
    $candidates = @()
    $selectionMode = if ($TenantAssociatedDeviceId) {'Explicit record ID'} else {'BIOS serial lookup plus exact local match'}
    if ($TenantAssociatedDeviceId) {
        $uri = "$GraphBase/deviceManagement/tenantAssociatedDevices/${TenantAssociatedDeviceId}?`$select=$select"
        try { $candidates = @(Invoke-DLRestMethod -Operation 'GetTenantAssociatedDevice' -Headers $Headers -Uri $uri) }
        catch {
            if ($_.Exception.Data['HttpStatusCode'] -eq 404) {
                throw 'The supplied Intune Device Association record was not found. UEFI was not changed.'
            }
            throw
        }
    } else {
        if ([string]::IsNullOrWhiteSpace($Identity.SerialNumber)) {
            throw 'Automatic cloud lookup needs a BIOS serial number. Supply -TenantAssociatedDeviceId for a strict record lookup.'
        }
        $escapedSerial = $Identity.SerialNumber.Replace("'","''")
        $filter = "contains(serialNumber,'$escapedSerial')"
        $uri = "$GraphBase/deviceManagement/tenantAssociatedDevices?`$select=$select&`$top=100&`$filter=$([Uri]::EscapeDataString($filter))"
        $response = Invoke-DLRestMethod -Operation 'FindTenantAssociatedDevices' -Headers $Headers -Uri $uri
        $candidates = @($response.value)
    }
    $matches = @()
    foreach ($candidate in $candidates) {
        if ($null -eq $candidate) { continue }
        $match = Test-DLAssociationRecordMatch $candidate $Identity
        if ($match.Matches) {
            $matches += [pscustomobject]@{ Record=$candidate; SerialMatch=$match.SerialMatch; SmbiosUuidMatch=$match.SmbiosUuidMatch }
        }
    }
    if ($matches.Count -eq 0) {
        throw "No Intune Device Association record matched this computer's BIOS serial number or SMBIOS UUID. UEFI was not changed."
    }
    if ($matches.Count -gt 1) {
        $uuidMatches = @($matches | Where-Object SmbiosUuidMatch)
        if ($uuidMatches.Count -eq 1) { $matches = $uuidMatches }
        else { throw "More than one Intune Device Association record matched this computer. UEFI was not changed. Supply -TenantAssociatedDeviceId to select and revalidate one record." }
    }
    $selected = $matches[0]
    $recordId = [string]$selected.Record.id
    $parsedId = [Guid]::Empty
    if (-not [Guid]::TryParse($recordId,[ref]$parsedId)) {
        throw 'The matched Intune Device Association record did not contain a valid GUID. UEFI was not changed.'
    }
    Add-DLRedaction $recordId
    Add-DLRedaction ([string]$selected.Record.managedDeviceId)
    $result = [pscustomobject][ordered]@{
        Id=$recordId
        AssociationState=[string]$selected.Record.associationState
        ManagedDeviceId=[string]$selected.Record.managedDeviceId
        SelectionMode=$selectionMode
        SerialMatch=[bool]$selected.SerialMatch
        SmbiosUuidMatch=[bool]$selected.SmbiosUuidMatch
    }
    Write-DLLog 'CloudAssociationResolved' 'Resolved exactly one Intune Device Association record and verified it against this computer.' @{
        SelectionMode=$selectionMode; CandidateCount=$candidates.Count; ExactMatchCount=$matches.Count
        AssociationState=$result.AssociationState; SerialMatch=$result.SerialMatch; SmbiosUuidMatch=$result.SmbiosUuidMatch
        RecordIdSha256=(Get-DLIdentifierHash $recordId); ManagedDevicePresent=(-not [string]::IsNullOrWhiteSpace($result.ManagedDeviceId))
        RawIdentifiersLogged=$false
    }
    if (-not [string]::IsNullOrWhiteSpace($result.ManagedDeviceId)) {
        Write-Warning 'This association record is connected to an enrolled Intune device. Deleting the association record does not unenroll or delete that managed device, and its MDM provider can attempt association again.'
    }
    return $result
}
function Invoke-DLCloudAssociationDelete {
    param($Target,[Collections.IDictionary]$Headers)
    $uri = "$GraphBase/deviceManagement/tenantAssociatedDevices/$($Target.Id)"
    Write-DLLog 'CloudAssociationDeleteStart' 'Sending one DELETE for the verified Intune Device Association record.' @{
        RecordIdSha256=(Get-DLIdentifierHash $Target.Id); Endpoint='deviceManagement/tenantAssociatedDevices/{record-id}'
        AutomaticRetries=0; ManagedDeviceDeleted=$false; EntraDeviceDeleted=$false; DeviceUnenrolled=$false
    }
    $deleteResponse = Invoke-DLRestMethod -Operation 'DeleteTenantAssociatedDevice' -Method DELETE -Headers $Headers -Uri $uri -AcceptedStatusCodes 404
    if ($deleteResponse.DLExpectedHttpStatus -eq 404) {
        Write-DLLog 'CloudAssociationAlreadyAbsent' 'The verified record disappeared before DELETE completed; Graph returned 404. Verification will confirm it remains absent.' @{
            RecordIdSha256=(Get-DLIdentifierHash $Target.Id); DeleteRequestsSent=1; AutomaticRetries=0
        }
    } else {
        Write-DLLog 'CloudAssociationDeleteAccepted' 'Microsoft Graph accepted the DELETE request. The record will now be checked without resending the delete.' @{
            RecordIdSha256=(Get-DLIdentifierHash $Target.Id); DeleteRequestsSent=1; AutomaticRetries=0
        }
    }
}
function Wait-DLCloudAssociationDeletion {
    param($Target,[Collections.IDictionary]$Headers,[int]$Seconds)
    $uri = "$GraphBase/deviceManagement/tenantAssociatedDevices/$($Target.Id)?`$select=id,associationState"
    $deadline = (Get-Date).AddSeconds($Seconds)
    $attempt = 0
    do {
        $attempt++
        $record = Invoke-DLRestMethod -Operation 'VerifyTenantAssociatedDeviceDeletion' -Headers $Headers -Uri $uri -AcceptedStatusCodes 404
        if ($record.DLExpectedHttpStatus -eq 404) {
            Write-DLLog 'CloudAssociationDeletionVerified' 'The Intune Device Association record is no longer present.' @{
                Result='Removed'; Attempt=$attempt; DeleteRequestsSent=1
            }
            return 'Removed'
        }
        if ([string]$record.associationState -ieq 'pendingRemoval') {
            Write-DLLog 'CloudAssociationDeletionVerified' 'The Intune Device Association record reports pendingRemoval.' @{
                Result='PendingRemoval'; Attempt=$attempt; DeleteRequestsSent=1
            }
            return 'PendingRemoval'
        }
        Write-DLVerboseLog 'CloudAssociationDeletionPoll' 'The association record is still present; verification will continue without repeating DELETE.' @{
            Attempt=$attempt; AssociationState=[string]$record.associationState; PollIntervalSeconds=5; DeleteRequestsSent=1
        }
        if ((Get-Date) -lt $deadline) { Start-Sleep -Seconds 5 }
    } while ((Get-Date) -lt $deadline)
    throw "Microsoft Graph accepted the delete, but the association record was not removed or pendingRemoval within $Seconds seconds. The DELETE was not repeated."
}
function Wait-PreAssociated([string]$id, [int]$sec) {
    if ([string]::IsNullOrWhiteSpace($id)) {
        throw 'The Device Association import did not return a record ID, so its service-side result cannot be verified.'
    }
    Add-DLRedaction $id
    $H = Graph-Headers
    $deadline = (Get-Date).AddSeconds($sec)
    Write-Host 'Waiting for Intune to report the device as pre-associated...' -ForegroundColor DarkGray
    Write-DLLog 'AssociationWaitStart' 'Waiting for the imported record.' @{ DeviceRecordId=$id; TimeoutSeconds=$sec }
    $attempt = 0
    $lastState = $null
    do {
        $attempt++
        $remaining = [Math]::Max(0,[int][Math]::Ceiling(($deadline-(Get-Date)).TotalSeconds))
        Write-DLVerboseLog 'AssociationPollAttempt' "Polling the imported association record (attempt $attempt)." @{ Attempt=$attempt; RemainingSeconds=$remaining; PollIntervalSeconds=5; DeviceRecordId=$id }
        try {
            $d = Invoke-DLRestMethod -Operation 'PollAssociationState' -Headers $H -Uri "$GraphBase/deviceManagement/tenantAssociatedDevices/$id"
            $lastState = [string]$d.associationState
            Write-DLLog 'AssociationState' $lastState @{ DeviceRecordId=$id; Attempt=$attempt; RemainingSeconds=$remaining }
            if ($lastState -in 'preassociated','associated') {
                Write-DLVerboseLog 'AssociationWaitComplete' "The imported record reached $lastState on attempt $attempt." @{ Attempt=$attempt; AssociationState=$lastState; DeviceRecordId=$id }
                return $lastState
            }
        } catch {
            if ($_.Exception.Data['HttpStatusCode'] -ne 404) { throw }
            Write-DLVerboseLog 'AssociationPollNotFound' 'The imported record is not visible yet; polling will continue.' @{ Attempt=$attempt; HttpStatus=404; DeviceRecordId=$id }
        }
        if ((Get-Date) -lt $deadline) { Start-Sleep -Seconds 5 }
    } while ((Get-Date) -lt $deadline)
    $stateText = if ($lastState) {$lastState} else {'not returned'}
    Write-DLLog 'AssociationWaitTimeout' 'The imported record did not reach preassociated or associated within the wait period.' @{
        DeviceRecordId=$id; Attempts=$attempt; LastAssociationState=$stateText; TimeoutSeconds=$sec
    } 'ERROR'
    throw "Timed out waiting for Device Association to reach preassociated or associated. Last service state: $stateText."
}
function Invoke-Upload([string]$b64) {
    Write-DLExportSummary $b64
    Write-DLVerboseLog 'UploadInput' 'Preparing to upload the unchanged DeviceLink Data value.' @{
        DataCharacters=$b64.Length; DataSha256=(Get-DLSha256 ([Text.Encoding]::UTF8.GetBytes($b64))); DataLogged=$false
    }
    $H = Graph-Headers
    $polId = $DevicePreparationPolicyId
    if (-not $polId) {
        Write-DLVerboseLog 'PolicySelection' 'No policy ID was supplied; listing Device Preparation policies for selection.' @{
            SelectionMode=$(if ($PolicyName) {'Exact name'} elseif ($FirstPolicy) {'First returned policy (explicit)'} else {'First returned policy (default)'})
        }
        $f = "(technologies has 'enrollment') and (platforms eq 'windows10') and (TemplateReference/templateId eq '$APDP_TEMPLATE_ID') and (Templatereference/templateFamily eq 'enrollmentConfiguration')"
        $pols = (Invoke-DLRestMethod -Operation 'ListDevicePreparationPolicies' -Headers $H -Uri ("$GraphBase/deviceManagement/configurationPolicies?`$select=id,name&`$filter=" + [uri]::EscapeDataString($f))).value
        if (-not $pols) { throw "No Autopilot device preparation policies in this tenant." }
        Write-DLVerboseLog 'PolicyListResult' "Microsoft Graph returned $(@($pols).Count) Device Preparation policy/policies." @{ Count=@($pols).Count }
        $sel = if ($PolicyName) { $pols | Where-Object name -eq $PolicyName | Select-Object -First 1 }
               else { $pols | Select-Object -First 1 }
        if (-not $sel) {
            $availableNames = @($pols | ForEach-Object { [string]$_.name }) -join ', '
            Write-DLVerboseLog 'PolicySelectionFailed' 'The requested policy name was not returned by Microsoft Graph.' @{ RequestedName=$PolicyName; AvailablePolicies=$pols }
            throw "No Device Preparation policy named '$PolicyName' was found. Available policies: $availableNames"
        }
        $polId = $sel.id
        Write-Host ("Device Preparation policy: {0}" -f $sel.name) -ForegroundColor DarkGray
        Write-DLVerboseLog 'PolicySelected' 'Selected a Device Preparation policy for the import.' @{ SelectionMode=$(if ($PolicyName) {'Exact name'} elseif ($FirstPolicy) {'First returned policy (explicit)'} else {'First returned policy (default)'}); PolicyId=$polId; PolicyName=$sel.name }
    } else {
        Write-DLVerboseLog 'PolicySelected' 'Using the Device Preparation policy ID supplied by the caller.' @{ SelectionMode='Policy ID parameter'; PolicyId=$polId }
    }
    $payload = @{ deviceLink = $b64; devicePreparationPolicyId = $polId } | ConvertTo-Json
    Write-DLLog 'UploadStart' 'Submitting the existing DeviceLink data without modifying or re-signing it.' @{ PolicyId=$polId; PayloadCharacters=$payload.Length; RetryPolicy='No automatic retry' }
    $resp = Invoke-DLRestMethod -Operation 'ImportTenantAssociatedDevice' -Method POST -Headers $H -ContentType 'application/json' `
            -Uri "$GraphBase/deviceManagement/tenantAssociatedDevices/importTenantAssociatedDevice" -Body $payload
    if ($null -eq $resp -or [string]::IsNullOrWhiteSpace([string]$resp.id)) {
        throw 'Microsoft Graph accepted the import request but did not return a Device Association record ID. The script cannot verify the result; review the HTTP artifact and Intune before retrying.'
    }
    Add-DLRedaction ([string]$resp.id)
    Write-DLLog 'UploadAccepted' 'Microsoft Graph returned a Device Association record that can be polled.' @{
        RecordIdSha256=(Get-DLIdentifierHash ([string]$resp.id)); InitialAssociationState=[string]$resp.associationState
        RecordIdLogged=$false; AutomaticPostRetries=0
    }
    Write-Host "Device Association import accepted." -ForegroundColor Green
    if ($VerbosePreference -ne 'SilentlyContinue') {
        $resp | Select-Object id,serialNumber,manufacturerName,modelName,associationState,devicePreparationPolicyId,preassociationDateTime | Format-List | Out-Host
    }
    $resp
}
function Show-LinkResult([string]$raw, [bool]$discoverOnly) {
    $discoveryResultNames = @{0='Undefined';1='SuccessfullyRetrievedUrl';2='SuccessfullyRetrievedUrlAndReceivedRedirection';3='FailedToRetrieveUrl_NotPreAssociated';4='FailedToRetrieveUrl_NetworkConnectionFailure'}
    $configureResultNames = @{0='Undefined';1='SuccessfullyAppliedLink';2='FailedTpmInitialization';3='FailedDiscovery';4='FailedToTpmAttest';5='FailedToMaaAttest';6='FailedToRetrieveDeviceLinkFromUrl';7='FailedToRetrieveDeviceLinkFromRedirectedUrl';8='FailedToApplyDeviceLinkToDevice';9='FailedToAcknowledgeDeviceLink'}
    $kv=@{}; $raw.Split(';') | ForEach-Object { $p=$_.Split('=',2); if($p.Count -eq 2){ $kv[$p[0]]=$p[1] } }
    $dr=[int]$kv.discoveryResult
    $cr = if ($kv.configureResult -match '-?\d+') { [int]$matches[0] } else { $null }
    $hrOk = ($kv.configureHResult -eq '0x0')
    $crText = if ($cr -eq $null) { $kv.configureResult }
              elseif ($cr -le 0) { if ($hrOk) { "(async OK, result enum unavailable)" } else { "$cr ($($configureResultNames[[Math]::Max($cr,0)]))" } }
              else { "$cr ($($configureResultNames[$cr]))" }
    Write-DLVerboseLog 'NativeAssociationDecoded' 'Decoded the native result into documented client-side result values.' @{
        AlreadyLinked=($kv.alreadyLinked -eq '1'); DiscoveryResult=$dr; DiscoveryResultName=$discoveryResultNames[$dr]
        ConfigureResult=$cr; ConfigureResultText=$crText; ConfigureHResult=$kv.configureHResult
        DiscoveryUrlLogged=$false; TenantIdLogged=$false
    }
    $summary = [pscustomobject]@{
        AlreadyLinked    = ($kv.alreadyLinked -eq '1')
        DiscoveryResult  = "$dr ($($discoveryResultNames[$dr]))"
        DiscoveryUrl     = $kv.discoveryUrl
        TenantId         = $kv.tenantId
        ConfigureResult  = if ($discoverOnly) { '(skipped)' } else { $crText }
        ConfigureHResult = $kv.configureHResult
    }
    if ($VerbosePreference -ne 'SilentlyContinue') { $summary | Format-List | Out-Host }
    if ($discoverOnly) {
        Write-Host ("Discovery result: {0}" -f $summary.DiscoveryResult) -ForegroundColor $(if ($dr -in 1,2) {'Green'} else {'Yellow'})
        return
    }
    if ($cr -eq 1 -and $hrOk) {
        Write-Host 'Device association applied successfully.' -ForegroundColor Green
        Write-DLLog 'AssociationCompleted' 'The native operation reports SuccessfullyAppliedLink. Enrollment is a later operation.' @{ Result=$cr; HResult=$kv.configureHResult }
    } else {
        Write-DLLog 'AssociationNotConfirmed' 'No successful association result was returned. An HRESULT of zero alone does not establish association success.' @{ Result=$cr; ResultText=$crText; HResult=$kv.configureHResult } 'ERROR'
    }
}

# =====================================================================  orchestrate
$blob = $DeviceLinkBase64

switch ($Action) {

  'ReadAssociation' {
      Invoke-DLStep 1 {
          Write-Warning 'This reads only the known Device Link UEFI variables. Run elevated.'
          Get-DLFirmwareAssociationState | Format-Table Variable,Status,Bytes,SHA256,Attributes,Win32Error -AutoSize | Out-Host
      } | Out-Null
  }

  'RemoveAssociation' {
      $cloudTarget = $null
      $cloudHeaders = $null
      $localStep = 1
      if ($DeleteCloudAssociation) {
          $cloudTarget = Invoke-DLStep 1 {
              Assert-DLCloudRemovalParameters
              $identity = Get-DLLocalDeviceIdentity
              $cloudHeaders = Graph-Headers
              Resolve-DLCloudAssociation -Identity $identity -Headers $cloudHeaders
          }
          $cloudHeaders = Graph-Headers
          $localStep = 2
      }
      $target = "$DLFirmwareNamespace : $($DLFirmwareVariables -join ', ')"
      $removeApproved = $PSCmdlet.ShouldProcess($target,'Delete and verify Device Link UEFI association variables')
      $localOutcome = Invoke-DLStep $localStep {
          Write-Warning 'This removes the Device Link tenant association from UEFI. If the device remains MDM-enrolled, its provider can attempt to associate it again.'
          if ($removeApproved) {
              Remove-DLFirmwareAssociation | Format-Table Variable,Before,DeleteAttempted,DeleteError,After,Result -AutoSize | Out-Host
              Write-Host 'The local UEFI association variables are absent. This did not unenroll the device or delete its managed-device or Entra records.' -ForegroundColor Green
              return 'Removed'
          } else {
              Write-DLLog 'FirmwareAssociationRemovalPreview' 'WhatIf/ShouldProcess prevented removal. No firmware values were changed.' @{Namespace=$DLFirmwareNamespace;Variables=$DLFirmwareVariables}
              return 'Preview'
          }
      }
      if ($DeleteCloudAssociation) {
          $cloudDeleteApproved = $false
          if ($localOutcome -eq 'Removed') {
              $cloudDeleteApproved = $PSCmdlet.ShouldProcess('the verified Intune Device Association record','Delete the tenantAssociatedDevices record through Microsoft Graph')
          }
          $deleteOutcome = Invoke-DLStep 3 {
              if ($localOutcome -ne 'Removed') {
                  Write-DLLog 'CloudAssociationDeleteSkipped' 'The cloud record was not deleted because local UEFI removal was not performed.' @{
                      LocalOutcome=$localOutcome; DeleteRequestsSent=0
                  } 'WARN'
                  return 'Skipped'
              }
              if (-not $cloudDeleteApproved) {
                  Write-DLLog 'CloudAssociationDeletePreview' 'WhatIf/ShouldProcess prevented the Graph DELETE. The cloud record was not changed.' @{
                      RecordIdSha256=(Get-DLIdentifierHash $cloudTarget.Id); DeleteRequestsSent=0
                  }
                  return 'Preview'
              }
              Invoke-DLCloudAssociationDelete -Target $cloudTarget -Headers $cloudHeaders
              return 'Requested'
          }
          $cloudOutcome = Invoke-DLStep 4 {
              if ($deleteOutcome -eq 'Requested') {
                  return (Wait-DLCloudAssociationDeletion -Target $cloudTarget -Headers $cloudHeaders -Seconds $TimeoutSec)
              }
              Write-DLLog 'CloudAssociationVerificationSkipped' 'Cloud verification was skipped because no DELETE request was sent.' @{
                  DeleteOutcome=$deleteOutcome; DeleteRequestsSent=0
              }
              return $deleteOutcome
          }
          [pscustomobject][ordered]@{
              LocalUefi=$localOutcome
              IntuneDeviceAssociation=$cloudOutcome
              ManagedDeviceDeleted=$false
              EntraDeviceDeleted=$false
              DeviceUnenrolled=$false
          } | Format-List | Out-Host
      }
  }


  'Export' {
      $csv = Invoke-DLStep 1 { Invoke-DLExport }
      Write-Host "Exported: $csv" -ForegroundColor Green
      Invoke-DLStep 2 { Invoke-Inspect $csv | Out-Host } | Out-Null
      Write-Output $csv
  }

  'Inspect' {
      Invoke-DLStep 1 {
          $p = Resolve-Csv; if (-not $p) { throw "No CSV. Pass -CsvPath or run -Action Export." }
          Write-Host "CSV: $p" -ForegroundColor DarkGray
          Invoke-Inspect $p | Out-Host
      } | Out-Null
  }

  'Upload' {
      $blob = Invoke-DLStep 1 {
          if ($DeviceLinkBase64) {
              Write-DLVerboseLog 'InputSelection' 'Using the DeviceLinkBase64 value supplied by the caller.' @{ Source='DeviceLinkBase64 parameter'; Characters=$DeviceLinkBase64.Length; RawValueLogged=$false }
              return $DeviceLinkBase64
          }
          $p = Resolve-Csv; if (-not $p) { throw "No CSV. Pass -CsvPath / -DeviceLinkBase64." }
          Write-Host "CSV: $p" -ForegroundColor DarkGray
          return (Get-BlobFromCsv $p)
      }
      $r = Invoke-DLStep 2 { Invoke-Upload $blob }
      $state = Invoke-DLStep 3 { Wait-PreAssociated $r.id $TimeoutSec }
      Write-Host "Pre-associated ($state)." -ForegroundColor Green
  }

  'Sync' {
      $csv = Invoke-DLStep 1 { Invoke-DLExport }
      Write-Host "Exported: $csv" -ForegroundColor Green
      $blob = Invoke-DLStep 2 { Get-BlobFromCsv $csv }
      $r = Invoke-DLStep 3 { Invoke-Upload $blob }
      $state = Invoke-DLStep 4 { Wait-PreAssociated $r.id $TimeoutSec }
      Write-Host "Pre-associated ($state)." -ForegroundColor Green
  }

  'Discover' {
      $blob = Invoke-DLStep 1 {
          if ($DeviceLinkBase64) {
              Write-DLVerboseLog 'InputSelection' 'Using the DeviceLinkBase64 value supplied by the caller.' @{ Source='DeviceLinkBase64 parameter'; Characters=$DeviceLinkBase64.Length; RawValueLogged=$false }
              return $DeviceLinkBase64
          }
          $p = Resolve-Csv; if (-not $p) { throw "No CSV. Pass -CsvPath / -DeviceLinkBase64." }
          Write-Host "CSV: $p" -ForegroundColor DarkGray
          return (Get-BlobFromCsv $p)
      }
      Invoke-DLStep 2 { Show-LinkResult (Invoke-DLLink $blob $true) $true }
  }

  'Link' {
      $blob = Invoke-DLStep 1 {
          if ($DeviceLinkBase64) {
              Write-DLVerboseLog 'InputSelection' 'Using the DeviceLinkBase64 value supplied by the caller.' @{ Source='DeviceLinkBase64 parameter'; Characters=$DeviceLinkBase64.Length; RawValueLogged=$false }
              return $DeviceLinkBase64
          }
          $p = Resolve-Csv; if (-not $p) { throw "No CSV. Pass -CsvPath / -DeviceLinkBase64." }
          Write-Host "CSV: $p" -ForegroundColor DarkGray
          return (Get-BlobFromCsv $p)
      }
      Invoke-DLStep 2 { Show-LinkResult (Invoke-DLLink $blob $false) $false }
  }

  'Full' {
      $csv = Invoke-DLStep 1 { Invoke-DLExport }
      Write-Host "Exported: $csv" -ForegroundColor Green
      $b = Invoke-DLStep 2 {
          Invoke-Inspect $csv | Out-Host
          Get-BlobFromCsv $csv
      }
      $r = Invoke-DLStep 3 { Invoke-Upload $b }
      $state = Invoke-DLStep 4 { Wait-PreAssociated $r.id $TimeoutSec }
      Write-Host "Pre-associated ($state)." -ForegroundColor Green
      Write-Host "`nLinking device ..." -ForegroundColor Cyan
      Invoke-DLStep 5 { Show-LinkResult (Invoke-DLLink $b $false) $false }
  }
}

$script:DLRunSucceeded = $true
Write-DLLog 'RunCompleted' 'The selected action finished. Review operation results above.' @{
    Action=$Action; CompletedSteps=$script:DLCompletedSteps; TotalSteps=$script:DLStepPlan.Count
}
} catch {
    $safe = Protect-DLText $_.Exception.Message
    Write-DLLog 'RunFailed' $safe @{
        Action=$Action; CompletedSteps=$script:DLCompletedSteps; CurrentStep=$script:DLCurrentStepNumber; CurrentStepName=$script:DLCurrentStepName
        ExceptionType=$_.Exception.GetType().FullName; HResult=('0x{0:X8}' -f ($_.Exception.HResult -band 0xffffffffL))
        ErrorId=$_.FullyQualifiedErrorId; ErrorCategory=$_.CategoryInfo.Category.ToString(); Line=$_.InvocationInfo.ScriptLineNumber
        ScriptStackTrace=(Protect-DLText $_.ScriptStackTrace)
    } 'ERROR'
    # Do not rethrow a raw web exception whose ErrorDetails may contain echoed secrets.
    throw [Exception]::new($safe)
} finally {
    Write-DLLog 'RunEnd' 'Diagnostic capture finished.' @{ Completed=$script:DLRunSucceeded; LogWriteFailed=$script:DLLogWriteFailed }
    Write-Host "Diagnostic logs: $script:DLRunFolder" -ForegroundColor Cyan
}
