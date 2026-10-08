<#
.SYNOPSIS
Publishes MCP servers described by standard MCP server.json files to Azure API Center.

.DESCRIPTION
For each server.json file, the script creates or updates:

  * the API Center environment that the deployments belong to,
  * an MCP asset (API of kind "mcp"),
  * the asset's version,
  * one deployment per remote, including server.mcpTransportType so the
    API Center MCP registry publishes the declared transport (for example
    "streamable-http") instead of defaulting to "sse".

server.mcpTransportType is not part of the published ARM schema. It is the
property API Center's own Git integration sets, and the registry honours it.

Existing assets:
  * The registry only publishes an API's default version, and a newly created
    version never becomes the default. If the asset already has a default
    version, the script updates that version (its title becomes the
    server.json version) instead of creating a new one.
  * An existing deployment whose runtime URL matches a remote is updated in
    place (portal-created deployments keep their definition link) rather than
    duplicated.
  * Assets managed by a Git integration are skipped.

.PARAMETER Path
A server.json file, or a folder searched recursively for server.json files.

.PARAMETER ApiId
Overrides the generated asset ID. Only valid when Path resolves to one file.
By default the ID is derived from server.json "name", for example
"io.github.contoso/weather" becomes "io-github-contoso-weather".

.PARAMETER VerifyRegistry
After publishing, reads the MCP registry (/v0.1/servers) and reports the
published transport. Requires ClientId and TenantId of an app registration
allowed to call the API Center data plane (for example the
"<api-center>-apic-aad" portal app with public client flows enabled). Uses
the device-code sign-in flow.

.EXAMPLE
.\scripts\publish-api-center-mcp.ps1 `
  -SubscriptionId '<subscription-id>' `
  -ResourceGroup '<resource-group>' `
  -ApiCenterName '<api-center>' `
  -Path .\mcp-servers `
  -WhatIf

.EXAMPLE
.\scripts\publish-api-center-mcp.ps1 `
  -SubscriptionId '<subscription-id>' `
  -ResourceGroup '<resource-group>' `
  -ApiCenterName '<api-center>' `
  -Path .\mcp-servers\weather\server.json `
  -VerifyRegistry -ClientId '<app-client-id>' -TenantId '<tenant-id>'
#>
[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Medium')]
param(
    [Parameter(Mandatory)]
    [ValidatePattern('^[0-9a-fA-F-]{36}$')]
    [string]$SubscriptionId,

    [Parameter(Mandatory)]
    [string]$ResourceGroup,

    [Parameter(Mandatory)]
    [string]$ApiCenterName,

    [Parameter(Mandatory)]
    [string]$Path,

    [ValidatePattern('^[a-zA-Z0-9-]{3,90}$')]
    [string]$ApiId,

    [ValidatePattern('^[a-zA-Z0-9-]{3,90}$')]
    [string]$WorkspaceName = 'default',

    [ValidatePattern('^[a-zA-Z0-9-]{3,90}$')]
    [string]$EnvironmentId = 'mcp-servers',

    [string]$EnvironmentTitle = 'MCP servers',

    [ValidateSet('development', 'testing', 'staging', 'production')]
    [string]$EnvironmentKind = 'production',

    [ValidateSet('design', 'development', 'testing', 'preview', 'production', 'deprecated', 'retired')]
    [string]$LifecycleStage = 'production',

    [switch]$VerifyRegistry,

    [string]$ClientId,

    [string]$TenantId
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$apiVersion = '2024-06-01-preview'
$serviceUri = "https://management.azure.com/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroup/providers/Microsoft.ApiCenter/services/$ApiCenterName"
$workspaceUri = "$serviceUri/workspaces/$WorkspaceName"
$supportedTransports = @('streamable-http', 'sse')
$tempDirectory = Join-Path ([System.IO.Path]::GetTempPath()) "apic-mcp-publish-$([guid]::NewGuid())"

function Invoke-AzureRest {
    param(
        [Parameter(Mandatory)]
        [ValidateSet('get', 'put')]
        [string]$Method,

        [Parameter(Mandatory)]
        [string]$Uri,

        [object]$Body,

        # Returns $null instead of throwing when the resource does not exist.
        [switch]$AllowNotFound
    )

    $arguments = @('rest', '--method', $Method, '--uri', $Uri, '--only-show-errors', '--output', 'json')
    if ($null -ne $Body) {
        # A body file avoids PowerShell-to-az quoting corruption of inline JSON.
        $bodyFile = Join-Path $tempDirectory "$([guid]::NewGuid()).json"
        $Body | ConvertTo-Json -Depth 50 | Set-Content -LiteralPath $bodyFile -Encoding utf8NoBOM -WhatIf:$false
        $arguments += @('--headers', 'Content-Type=application/json', '--body', "@$bodyFile")
    }

    $output = & az @arguments 2>&1
    $text = ($output -join [Environment]::NewLine).Trim()
    if ($LASTEXITCODE -ne 0) {
        if ($AllowNotFound -and $text -match '(?i)(Not ?Found|\b404\b)') {
            return $null
        }
        throw "Azure REST request failed: $($Method.ToUpper()) $Uri`n$text"
    }
    if ($text) {
        return $text | ConvertFrom-Json -Depth 50
    }
}

function Get-AzureCollection {
    param([Parameter(Mandatory)][string]$Uri)

    $items = [System.Collections.Generic.List[object]]::new()
    $nextUri = $Uri
    while ($nextUri) {
        $page = Invoke-AzureRest -Method get -Uri $nextUri
        foreach ($item in @($page.value)) { $items.Add($item) }
        $nextUri = if ($page.PSObject.Properties.Name -contains 'nextLink') { $page.nextLink } else { $null }
    }
    return , $items
}

# Server-managed or link fields that must not be echoed back in a PUT.
function Remove-ReadOnlyProperties {
    param([Parameter(Mandatory)][object]$Properties)

    $copy = $Properties | ConvertTo-Json -Depth 50 | ConvertFrom-Json -Depth 50
    foreach ($name in @('provisioningState', 'isDefault', 'isRecommended', 'recommended', 'apiSourceId', 'source')) {
        if ($copy.PSObject.Properties.Name -contains $name) {
            $copy.PSObject.Properties.Remove($name)
        }
    }
    return $copy
}

function Set-Property {
    param(
        [Parameter(Mandatory)][object]$Object,
        [Parameter(Mandatory)][string]$Name,
        [AllowNull()][object]$Value
    )
    $Object | Add-Member -NotePropertyName $Name -NotePropertyValue $Value -Force
}

# API Center resource names allow only letters, digits and hyphens (3-90 characters).
function ConvertTo-ResourceName {
    param(
        [Parameter(Mandatory)][string]$Value,
        [Parameter(Mandatory)][string]$Prefix
    )

    $name = ($Value.ToLowerInvariant() -replace '[^a-z0-9]+', '-').Trim('-')
    if ($name.Length -lt 3) {
        $name = "$Prefix-$name".Trim('-')
    }
    if ($name.Length -gt 90) {
        $name = $name.Substring(0, 90).TrimEnd('-')
    }
    return $name
}

function Get-Text {
    param([object]$Object, [string]$Name)
    if ($null -ne $Object -and $Object.PSObject.Properties.Name -contains $Name -and $Object.$Name) {
        return [string]$Object.$Name
    }
    return $null
}

function Read-ServerDefinition {
    param([Parameter(Mandatory)][string]$File)

    try {
        $server = Get-Content -LiteralPath $File -Raw | ConvertFrom-Json -Depth 50
    }
    catch {
        throw "$File is not valid JSON: $($_.Exception.Message)"
    }

    $name = Get-Text $server 'name'
    $version = Get-Text $server 'version'
    if (-not $name) { throw "$File is missing 'name'." }
    if (-not $version) { throw "$File is missing 'version'." }

    $remotes = @()
    if ($server.PSObject.Properties.Name -contains 'remotes') {
        $remotes = @($server.remotes)
    }
    if ($remotes.Count -eq 0) {
        throw "$File has no 'remotes'. This script publishes remote MCP servers only."
    }
    if ($server.PSObject.Properties.Name -contains 'packages' -and @($server.packages).Count -gt 0) {
        Write-Warning "$File also declares packages; packages are not published by this script."
    }

    foreach ($remote in $remotes) {
        $type = Get-Text $remote 'type'
        $url = Get-Text $remote 'url'
        if ($type -notin $supportedTransports) {
            throw "$File has remote type '$type'. Supported types: $($supportedTransports -join ', ')."
        }
        $parsed = $null
        if (-not [Uri]::TryCreate($url, [UriKind]::Absolute, [ref]$parsed) -or $parsed.Scheme -ne 'https') {
            throw "$File has an invalid remote URL '$url'. An absolute https URL is required."
        }
        if ($url.Length -gt 200) {
            throw "$File has a remote URL longer than the 200 characters API Center allows."
        }
    }

    $title = Get-Text $server 'title'
    if (-not $title) { $title = $name }
    $description = Get-Text $server 'description'

    return [pscustomobject]@{
        File        = $File
        Name        = $name
        Title       = $title
        Description = $description
        Version     = $version
        Remotes     = $remotes
    }
}

function Publish-Server {
    param(
        [Parameter(Mandatory)][object]$Server,
        [Parameter(Mandatory)][string]$TargetApiId
    )

    $apiUri = "$workspaceUri/apis/$TargetApiId"
    $existingApi = Invoke-AzureRest -Method get -Uri "$apiUri`?api-version=$apiVersion" -AllowNotFound

    if ($existingApi) {
        if ($existingApi.properties.kind -ne 'mcp') {
            throw "Asset '$TargetApiId' exists with kind '$($existingApi.properties.kind)', not 'mcp'."
        }
        if ($existingApi.properties.PSObject.Properties.Name -contains 'apiSourceId' -and $existingApi.properties.apiSourceId) {
            Write-Warning "Skipping '$TargetApiId': it is managed by an integration ($($existingApi.properties.apiSourceId)). Update its source instead."
            return
        }
    }

    # Pick the version to write. Only the default version is published, and a
    # new version never becomes the default, so reuse an existing default.
    $versionId = ConvertTo-ResourceName -Value $Server.Version -Prefix 'version'
    $existingVersion = $null
    if ($existingApi) {
        $versions = Get-AzureCollection -Uri "$apiUri/versions?api-version=$apiVersion"
        $default = $versions | Where-Object { $_.properties.PSObject.Properties.Name -contains 'isDefault' -and $_.properties.isDefault } | Select-Object -First 1
        if ($default) {
            $existingVersion = $default
            if ($default.name -ne $versionId) {
                Write-Warning "'$TargetApiId' already has default version '$($default.name)'. Updating it to title '$($Server.Version)' instead of creating '$versionId', because a new version would not be published."
            }
            $versionId = $default.name
        }
        elseif ($versions.Count -gt 0) {
            throw "'$TargetApiId' has versions but no default version, so the registry cannot publish it. The default version cannot be set through ARM; delete and recreate the asset so its first version becomes the default."
        }
    }

    $action = if ($existingApi) { 'Update' } else { 'Create' }
    if (-not $PSCmdlet.ShouldProcess("$ApiCenterName/$WorkspaceName/apis/$TargetApiId", "$action MCP asset from $($Server.File)")) {
        return
    }

    # Asset.
    $apiProperties = if ($existingApi) { Remove-ReadOnlyProperties $existingApi.properties } else { [pscustomobject]@{} }
    Set-Property $apiProperties 'kind' 'mcp'
    Set-Property $apiProperties 'title' ($Server.Title.Substring(0, [Math]::Min(50, $Server.Title.Length)))
    if ($Server.Description) {
        Set-Property $apiProperties 'summary' ($Server.Description.Substring(0, [Math]::Min(200, $Server.Description.Length)))
        Set-Property $apiProperties 'description' ($Server.Description.Substring(0, [Math]::Min(1000, $Server.Description.Length)))
    }
    Invoke-AzureRest -Method put -Uri "$apiUri`?api-version=$apiVersion" -Body @{ properties = $apiProperties } | Out-Null

    # Version. Created before deployments so the first version becomes the default.
    $versionProperties = if ($existingVersion) { Remove-ReadOnlyProperties $existingVersion.properties } else { [pscustomobject]@{} }
    Set-Property $versionProperties 'title' ($Server.Version.Substring(0, [Math]::Min(50, $Server.Version.Length)))
    Set-Property $versionProperties 'lifecycleStage' $LifecycleStage
    Invoke-AzureRest -Method put -Uri "$apiUri/versions/$versionId`?api-version=$apiVersion" -Body @{ properties = $versionProperties } | Out-Null

    # Deployments: one per remote. Reuse a deployment that already targets the same URL.
    $existingDeployments = if ($existingApi) { Get-AzureCollection -Uri "$apiUri/deployments?api-version=$apiVersion" } else { @() }
    $usedDeploymentIds = [System.Collections.Generic.HashSet[string]]::new()
    $index = 0
    foreach ($remote in $Server.Remotes) {
        $index++
        $match = $existingDeployments | Where-Object {
            -not $usedDeploymentIds.Contains($_.name) -and
            $_.properties.PSObject.Properties.Name -contains 'server' -and
            @($_.properties.server.runtimeUri) -contains $remote.url
        } | Select-Object -First 1

        if ($match) {
            $deploymentId = $match.name
            $deploymentProperties = Remove-ReadOnlyProperties $match.properties
        }
        else {
            $deploymentId = if ($Server.Remotes.Count -eq 1) { "$versionId-remote" } else { "$versionId-remote-$index" }
            $deploymentProperties = [pscustomobject]@{
                title         = $deploymentId
                environmentId = "/workspaces/$WorkspaceName/environments/$EnvironmentId"
                versionId     = "/workspaces/$WorkspaceName/apis/$TargetApiId/versions/$versionId"
            }
        }
        [void]$usedDeploymentIds.Add($deploymentId)

        Set-Property $deploymentProperties 'server' ([pscustomobject]@{
                runtimeUri       = @($remote.url)
                mcpTransportType = $remote.type
            })
        Invoke-AzureRest -Method put -Uri "$apiUri/deployments/$deploymentId`?api-version=$apiVersion" -Body @{ properties = $deploymentProperties } | Out-Null
    }

    foreach ($stale in $existingDeployments | Where-Object { -not $usedDeploymentIds.Contains($_.name) }) {
        Write-Warning "'$TargetApiId' deployment '$($stale.name)' does not match any remote in $($Server.File) and was left unchanged; it may still be published."
    }

    # Read back what API Center stored.
    $storedVersion = Invoke-AzureRest -Method get -Uri "$apiUri/versions/$versionId`?api-version=$apiVersion"
    foreach ($deploymentId in $usedDeploymentIds) {
        $stored = Invoke-AzureRest -Method get -Uri "$apiUri/deployments/$deploymentId`?api-version=$apiVersion"
        [pscustomobject]@{
            ApiId      = $TargetApiId
            Action     = $action
            Version    = $versionId
            IsDefault  = [bool]($storedVersion.properties.PSObject.Properties.Name -contains 'isDefault' -and $storedVersion.properties.isDefault)
            Deployment = $deploymentId
            Transport  = $stored.properties.server.mcpTransportType
            Url        = @($stored.properties.server.runtimeUri)[0]
        }
    }
}

function Get-RegistryEntries {
    param(
        [Parameter(Mandatory)][string]$DataHost,
        [Parameter(Mandatory)][string[]]$ApiIds
    )

    $deviceCode = Invoke-RestMethod -Method Post `
        -Uri "https://login.microsoftonline.com/$TenantId/oauth2/v2.0/devicecode" `
        -ContentType 'application/x-www-form-urlencoded' `
        -Body @{ client_id = $ClientId; scope = 'https://azure-apicenter.net/Data.Read.All' }
    Write-Host $deviceCode.message

    $expiresAt = [DateTime]::UtcNow.AddSeconds($deviceCode.expires_in)
    $token = $null
    while (-not $token -and [DateTime]::UtcNow -lt $expiresAt) {
        Start-Sleep -Seconds $deviceCode.interval
        try {
            $token = Invoke-RestMethod -Method Post `
                -Uri "https://login.microsoftonline.com/$TenantId/oauth2/v2.0/token" `
                -ContentType 'application/x-www-form-urlencoded' `
                -Body @{
                    grant_type  = 'urn:ietf:params:oauth:grant-type:device_code'
                    client_id   = $ClientId
                    device_code = $deviceCode.device_code
                }
        }
        catch {
            $oauthError = $null
            try { $oauthError = $_.ErrorDetails.Message | ConvertFrom-Json } catch { }
            if ($oauthError -and $oauthError.error -eq 'authorization_pending') { continue }
            if ($oauthError -and $oauthError.error -eq 'slow_down') { Start-Sleep -Seconds 5; continue }
            # No OAuth error body means a transient network failure; keep polling until expiry.
            if (-not $oauthError) { continue }
            throw
        }
    }
    if (-not $token) { throw 'Device-code sign-in expired before it was completed.' }

    try {
        $registryUrl = "https://$DataHost/workspaces/$WorkspaceName/v0.1/servers"
        # Registry projection can lag ARM writes, so poll briefly.
        for ($attempt = 1; $attempt -le 8; $attempt++) {
            $response = Invoke-RestMethod -Uri $registryUrl -Headers @{ Authorization = "Bearer $($token.access_token)" }
            $entries = @($response.servers | ForEach-Object { $_.server } | Where-Object { $_.name -in $ApiIds })
            if ($entries.Count -eq $ApiIds.Count) { break }
            Start-Sleep -Seconds 15
        }
        foreach ($entry in $entries) {
            foreach ($remote in @($entry.remotes)) {
                [pscustomobject]@{ Name = $entry.name; Version = $entry.version; Type = $remote.type; Url = $remote.url }
            }
        }
        $foundNames = @($entries | ForEach-Object { $_.name })
        foreach ($missing in $ApiIds | Where-Object { $_ -notin $foundNames }) {
            Write-Warning "'$missing' is not in the registry yet. Projection can take a few minutes."
        }
    }
    finally {
        $token = $null
    }
}

if ($VerifyRegistry -and (-not $ClientId -or -not $TenantId)) {
    throw '-VerifyRegistry requires -ClientId and -TenantId.'
}
if (-not (Get-Command az -ErrorAction SilentlyContinue)) {
    throw 'Azure CLI is required. Install it and run az login first.'
}

$resolved = Resolve-Path -LiteralPath $Path
$files = @(
    if (Test-Path -LiteralPath $resolved -PathType Container) {
        Get-ChildItem -LiteralPath $resolved -Recurse -File -Filter 'server.json' | ForEach-Object { $_.FullName }
    }
    else {
        $resolved.Path
    }
)
if ($files.Count -eq 0) { throw "No server.json files found under $Path." }
if ($ApiId -and $files.Count -gt 1) { throw '-ApiId can only be used with a single server.json file.' }

New-Item -ItemType Directory -Path $tempDirectory -WhatIf:$false | Out-Null
try {
    $null = & az account show --only-show-errors --output none 2>&1
    if ($LASTEXITCODE -ne 0) { throw 'Azure CLI is not signed in. Run az login first.' }

    # Validate everything before writing anything.
    $servers = @(foreach ($file in $files) { Read-ServerDefinition -File $file })
    $targets = @(foreach ($server in $servers) {
            [pscustomobject]@{
                Server = $server
                ApiId  = if ($ApiId) { $ApiId } else { ConvertTo-ResourceName -Value $server.Name -Prefix 'mcp' }
            }
        })
    $duplicates = $targets | Group-Object ApiId | Where-Object Count -gt 1
    if ($duplicates) {
        throw "Several server.json files map to the same asset ID: $(@($duplicates | ForEach-Object { $_.Name }) -join ', ')."
    }

    $service = Invoke-AzureRest -Method get -Uri "$serviceUri`?api-version=$apiVersion"

    $environmentUri = "$workspaceUri/environments/$EnvironmentId`?api-version=$apiVersion"
    if (-not (Invoke-AzureRest -Method get -Uri $environmentUri -AllowNotFound)) {
        if ($PSCmdlet.ShouldProcess("$ApiCenterName/$WorkspaceName/environments/$EnvironmentId", 'Create environment')) {
            Invoke-AzureRest -Method put -Uri $environmentUri -Body @{
                properties = @{ title = $EnvironmentTitle; kind = $EnvironmentKind }
            } | Out-Null
        }
    }

    $results = @(foreach ($target in $targets) {
            Publish-Server -Server $target.Server -TargetApiId $target.ApiId
        })

    if ($results.Count -gt 0) {
        $results | Format-Table -AutoSize | Out-Host
    }

    if ($VerifyRegistry -and $results.Count -gt 0) {
        $published = @($results.ApiId | Select-Object -Unique)
        $registry = @(Get-RegistryEntries -DataHost $service.properties.dataApiHostname -ApiIds $published)
        $registry | Format-Table -AutoSize | Out-Host

        $expected = @(foreach ($target in $targets | Where-Object { $_.ApiId -in $published }) {
                foreach ($remote in $target.Server.Remotes) { "$($target.ApiId)|$($remote.url)|$($remote.type)" }
            })
        $mismatches = @($registry | Where-Object { "$($_.Name)|$($_.Url)|$($_.Type)" -notin $expected })
        if ($mismatches.Count -gt 0) {
            Write-Warning 'Some registry remotes do not match the declared transport. Projection may still be catching up, or other deployments exist for the asset.'
        }
    }
}
finally {
    if (Test-Path -LiteralPath $tempDirectory) {
        Remove-Item -LiteralPath $tempDirectory -Recurse -Force -WhatIf:$false
    }
}
