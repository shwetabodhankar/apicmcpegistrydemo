<#
.SYNOPSIS
Registers an MCP server that is already running on Azure App Service in Azure
API Center, using metadata from the server's .NET project.

.DESCRIPTION
The script does not build or deploy anything. It:

  1. Reads the project file for the server name (AssemblyName, or the project
     file name), Title, Version and Description.
  2. Reads the C# sources for the MapMcp("<path>") endpoint and checks that
     legacy HTTP+SSE is not enabled.
  3. Looks up the App Service app's hostname and confirms it is running.
  4. Probes https://<host><path> with an MCP "initialize" request to confirm
     the live endpoint speaks Streamable HTTP.
  5. Creates or updates, through ARM:
       * the API Center environment,
       * the MCP asset (API of kind "mcp"),
       * its version,
       * "default-sse" and "default-streamable" definitions, like the portal's
         "Add remote" flow generates (the Streamable one uses the real MCP path),
       * a deployment linked to "default-streamable", with
         server.mcpTransportType = "streamable-http".

server.mcpTransportType is not part of the published ARM schema. It is the
property API Center's own Git integration sets, and the MCP registry reads it
to publish remotes[].type. Without it the registry publishes "sse". The
definitions and the deployment's definition link do not affect the registry;
they keep the portal view consistent with a portal registration.

Existing assets:
  * The registry only publishes an API's default version, and a newly created
    version never becomes the default. If the asset already has a default
    version, that version is updated (its title becomes the project version).
  * An existing deployment with the same runtime URL is updated in place.
  * Assets managed by an integration (for example Git sync) are not changed.

.EXAMPLE
.\scripts\register-app-service-mcp.ps1 `
  -SubscriptionId '<subscription-id>' `
  -WebAppName '<web-app>' -WebAppResourceGroup '<app-rg>' `
  -ResourceGroup '<api-center-rg>' -ApiCenterName '<api-center>' `
  -WhatIf

.EXAMPLE
.\scripts\register-app-service-mcp.ps1 `
  -SubscriptionId '<subscription-id>' `
  -WebAppName '<web-app>' -WebAppResourceGroup '<app-rg>' `
  -ResourceGroup '<api-center-rg>' -ApiCenterName '<api-center>' `
  -VerifyRegistry -ClientId '<app-client-id>' -TenantId '<tenant-id>'
#>
[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Medium')]
param(
    [Parameter(Mandatory)]
    [ValidatePattern('^[0-9a-fA-F-]{36}$')]
    [string]$SubscriptionId,

    [Parameter(Mandatory)]
    [string]$WebAppName,

    [Parameter(Mandatory)]
    [string]$WebAppResourceGroup,

    [Parameter(Mandatory)]
    [string]$ResourceGroup,

    [Parameter(Mandatory)]
    [string]$ApiCenterName,

    [string]$ProjectPath = (Join-Path $PSScriptRoot '..\weather-mcp-server\weather-mcp-server.csproj'),

    # Overrides the asset ID, which is otherwise derived from the server name.
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

    [switch]$SkipEndpointCheck,

    # Reads /v0.1/servers afterwards. Needs an app registration allowed to call
    # the API Center data plane (for example the "<api-center>-apic-aad" app
    # with public client flows enabled); signs in with a device code.
    [switch]$VerifyRegistry,

    [string]$ClientId,

    [string]$TenantId
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$armApiVersion = '2024-06-01-preview'
$transport = 'streamable-http'
$serviceUri = "https://management.azure.com/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroup/providers/Microsoft.ApiCenter/services/$ApiCenterName"
$workspaceUri = "$serviceUri/workspaces/$WorkspaceName"
$tempDirectory = Join-Path ([System.IO.Path]::GetTempPath()) "apic-register-$([guid]::NewGuid())"

function Invoke-AzureRest {
    param(
        [Parameter(Mandatory)]
        [ValidateSet('get', 'put', 'post')]
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

function Test-Property {
    param([object]$Object, [string]$Name)
    return ($null -ne $Object -and $Object.PSObject.Properties.Name -contains $Name -and $Object.$Name)
}

# API Center resource names allow only letters, digits and hyphens (3-90 characters).
function ConvertTo-ResourceName {
    param(
        [Parameter(Mandatory)][string]$Value,
        [Parameter(Mandatory)][string]$Prefix
    )

    $name = ($Value.ToLowerInvariant() -replace '[^a-z0-9]+', '-').Trim('-')
    if ($name.Length -lt 3) { $name = "$Prefix-$name".Trim('-') }
    if ($name.Length -gt 90) { $name = $name.Substring(0, 90).TrimEnd('-') }
    return $name
}

function Limit-Text {
    param([string]$Text, [int]$Length)
    if (-not $Text) { return $Text }
    return $Text.Substring(0, [Math]::Min($Length, $Text.Length))
}

function Get-ProjectProperty {
    param(
        [Parameter(Mandatory)][xml]$Project,
        [Parameter(Mandatory)][string]$Name
    )

    foreach ($group in @($Project.Project.PropertyGroup)) {
        if ($null -ne $group -and $group.PSObject.Properties.Name -contains $Name) {
            $value = [string]$group.$Name
            if ($value.Trim()) { return $value.Trim() }
        }
    }
    return $null
}

function Get-RegistryEntry {
    param(
        [Parameter(Mandatory)][string]$DataHost,
        [Parameter(Mandatory)][string]$Name
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
            $entry = @($response.servers | ForEach-Object { $_.server } | Where-Object { $_.name -eq $Name }) | Select-Object -First 1
            if ($entry) { return $entry }
            Start-Sleep -Seconds 15
        }
        return $null
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

# 1. Project metadata.
$projectFile = (Resolve-Path -LiteralPath $ProjectPath).Path
[xml]$project = Get-Content -LiteralPath $projectFile -Raw
$projectDirectory = Split-Path -Parent $projectFile

$serverName = Get-ProjectProperty $project 'AssemblyName'
if (-not $serverName) { $serverName = [System.IO.Path]::GetFileNameWithoutExtension($projectFile) }

$version = Get-ProjectProperty $project 'Version'
if (-not $version) {
    throw "$projectFile has no <Version>. Add one so the registered version comes from the code."
}

$title = Get-ProjectProperty $project 'Title'
if (-not $title) { $title = Get-ProjectProperty $project 'Product' }
if (-not $title) { $title = $serverName }

$description = Get-ProjectProperty $project 'Description'
if (-not $description) {
    Write-Warning "$projectFile has no <Description>; the asset will have no description."
}

$targetApiId = if ($ApiId) { $ApiId } else { ConvertTo-ResourceName -Value $serverName -Prefix 'mcp' }

# 2. MCP endpoint path and transport, from the C# sources.
$sources = @(Get-ChildItem -LiteralPath $projectDirectory -Recurse -File -Filter '*.cs' |
        Where-Object { $_.FullName -notmatch '[\\/](bin|obj)[\\/]' })
$mapCalls = @(foreach ($source in $sources) {
        $text = Get-Content -LiteralPath $source.FullName -Raw
        foreach ($match in [regex]::Matches($text, 'MapMcp\s*\(\s*(?:"(?<path>[^"]*)")?')) {
            $path = $match.Groups['path'].Value
            if (-not $path) { $path = '/' }
            if (-not $path.StartsWith('/')) { $path = "/$path" }
            $path
        }
        if ($text -match 'EnableLegacySse\s*=\s*true') {
            Write-Warning "$($source.Name) enables legacy HTTP+SSE. The server is still registered as $transport."
        }
    })
$mcpPaths = @($mapCalls | Select-Object -Unique)
if ($mcpPaths.Count -eq 0) { throw "No MapMcp(...) call found under $projectDirectory." }
if ($mcpPaths.Count -gt 1) { throw "Several MCP endpoints found ($($mcpPaths -join ', ')). This script registers one endpoint." }
$mcpPath = $mcpPaths[0]

# 3. App Service hostname.
$webApp = az webapp show --subscription $SubscriptionId --name $WebAppName --resource-group $WebAppResourceGroup `
    --query '{host:defaultHostName,state:state}' --output json --only-show-errors 2>&1
if ($LASTEXITCODE -ne 0) {
    throw "Could not read App Service app '$WebAppName': $($webApp -join ' ')"
}
$webApp = $webApp | ConvertFrom-Json
if ($webApp.state -ne 'Running') {
    throw "App Service app '$WebAppName' is '$($webApp.state)', not Running."
}
$mcpUrl = "https://$($webApp.host)$mcpPath"
if ($mcpUrl.Length -gt 200) { throw "$mcpUrl is longer than the 200 characters API Center allows." }

# 4. Confirm the live endpoint speaks Streamable HTTP before registering it as such.
$liveName = $null
$liveVersion = $null
if (-not $SkipEndpointCheck) {
    $initialize = @{
        jsonrpc = '2.0'
        id      = 1
        method  = 'initialize'
        params  = @{
            protocolVersion = '2025-06-18'
            capabilities    = @{}
            clientInfo      = @{ name = 'register-app-service-mcp'; version = '1.0' }
        }
    } | ConvertTo-Json -Depth 5 -Compress

    try {
        $response = Invoke-WebRequest -Uri $mcpUrl -Method Post -Body $initialize -TimeoutSec 60 `
            -ContentType 'application/json' -Headers @{ Accept = 'application/json, text/event-stream' }
    }
    catch {
        throw "Streamable HTTP initialize to $mcpUrl failed: $($_.Exception.Message). Use -SkipEndpointCheck to register anyway."
    }

    # The result may be plain JSON or an SSE-framed "data:" event; both are Streamable HTTP.
    $body = [string]$response.Content
    $dataLine = $body -split "`n" | Where-Object { $_ -like 'data:*' } | Select-Object -First 1
    $json = if ($dataLine) { $dataLine.Substring(5).Trim() } else { $body }
    try { $result = $json | ConvertFrom-Json } catch { throw "Unexpected initialize response from ${mcpUrl}: $body" }
    if (-not (Test-Property $result 'result')) { throw "Initialize to $mcpUrl did not return a result: $body" }

    $serverInfo = if (Test-Property $result.result 'serverInfo') { $result.result.serverInfo } else { $null }
    if (Test-Property $serverInfo 'name') { $liveName = [string]$serverInfo.name }
    if (Test-Property $serverInfo 'version') { $liveVersion = [string]$serverInfo.version }
}

[pscustomobject]@{
    Project        = $projectFile
    ServerName     = $serverName
    ApiId          = $targetApiId
    Title          = $title
    Version        = $version
    McpUrl         = $mcpUrl
    Transport      = $transport
    LiveServerName = if ($SkipEndpointCheck) { '(not checked)' } else { $liveName }
    LiveVersion    = if ($SkipEndpointCheck) { '(not checked)' } else { $liveVersion }
} | Format-List | Out-Host

if ($liveVersion -and -not $liveVersion.StartsWith($version)) {
    Write-Warning "The running app reports version $liveVersion, but the project says $version. The app may not be deployed from this code."
}

New-Item -ItemType Directory -Path $tempDirectory -WhatIf:$false | Out-Null
try {
    $null = & az account show --only-show-errors --output none 2>&1
    if ($LASTEXITCODE -ne 0) { throw 'Azure CLI is not signed in. Run az login first.' }

    $apiUri = "$workspaceUri/apis/$targetApiId"
    $existingApi = Invoke-AzureRest -Method get -Uri "$apiUri`?api-version=$armApiVersion" -AllowNotFound
    if ($existingApi) {
        if ($existingApi.properties.kind -ne 'mcp') {
            throw "Asset '$targetApiId' exists with kind '$($existingApi.properties.kind)', not 'mcp'."
        }
        if (Test-Property $existingApi.properties 'apiSourceId') {
            throw "Asset '$targetApiId' is managed by an integration ($($existingApi.properties.apiSourceId)). Update its source instead, or use -ApiId."
        }
    }

    # Pick the version. Only the default version is published, and a new
    # version never becomes the default, so reuse an existing default.
    $versionId = ConvertTo-ResourceName -Value $version -Prefix 'version'
    $existingVersion = $null
    if ($existingApi) {
        $versions = Get-AzureCollection -Uri "$apiUri/versions?api-version=$armApiVersion"
        $default = $versions | Where-Object { Test-Property $_.properties 'isDefault' } | Select-Object -First 1
        if ($default) {
            $existingVersion = $default
            if ($default.name -ne $versionId) {
                Write-Warning "'$targetApiId' already has default version '$($default.name)'. Updating it to title '$version' instead of creating '$versionId', because a new version would not be published."
            }
            $versionId = $default.name
        }
        elseif ($versions.Count -gt 0) {
            throw "'$targetApiId' has versions but no default version, so the registry cannot publish it. The default version cannot be set through ARM; delete and recreate the asset so its first version becomes the default."
        }
    }

    $action = if ($existingApi) { 'Update' } else { 'Create' }
    if (-not $PSCmdlet.ShouldProcess("$ApiCenterName/$WorkspaceName/apis/$targetApiId", "$action MCP asset for $mcpUrl ($transport)")) {
        return
    }

    # 5a. Environment.
    $environmentUri = "$workspaceUri/environments/$EnvironmentId`?api-version=$armApiVersion"
    if (-not (Invoke-AzureRest -Method get -Uri $environmentUri -AllowNotFound)) {
        Invoke-AzureRest -Method put -Uri $environmentUri -Body @{
            properties = @{ title = $EnvironmentTitle; kind = $EnvironmentKind }
        } | Out-Null
    }

    # 5b. Asset.
    $apiProperties = if ($existingApi) { Remove-ReadOnlyProperties $existingApi.properties } else { [pscustomobject]@{} }
    Set-Property $apiProperties 'kind' 'mcp'
    Set-Property $apiProperties 'title' (Limit-Text $title 50)
    if ($description) {
        Set-Property $apiProperties 'summary' (Limit-Text $description 200)
        Set-Property $apiProperties 'description' (Limit-Text $description 1000)
    }
    Invoke-AzureRest -Method put -Uri "$apiUri`?api-version=$armApiVersion" -Body @{ properties = $apiProperties } | Out-Null

    # 5c. Version, created before the deployment so a new asset's first version becomes the default.
    $versionProperties = if ($existingVersion) { Remove-ReadOnlyProperties $existingVersion.properties } else { [pscustomobject]@{} }
    Set-Property $versionProperties 'title' (Limit-Text $version 50)
    Set-Property $versionProperties 'lifecycleStage' $LifecycleStage
    Invoke-AzureRest -Method put -Uri "$apiUri/versions/$versionId`?api-version=$armApiVersion" -Body @{ properties = $versionProperties } | Out-Null

    # 5d. Definitions, matching what the portal's "Add remote" flow generates
    # (Swagger 2.0 tagged with x-ms-agentic-protocol). The registry does not read
    # them; they keep the portal view consistent. Unlike the portal, the
    # Streamable definition uses the server's real MCP path.
    $definitionIds = @{}
    $mcpHost = ([Uri]$mcpUrl).Host
    $generatedDefinitions = @(
        [pscustomobject]@{
            Id       = 'default-sse'
            Title    = "SSE Definition for $title"
            Protocol = 'mcp-sse-1.0'
            Path     = '/sse'
            Method   = 'get'
        },
        [pscustomobject]@{
            Id       = 'default-streamable'
            Title    = "Streamable Definition for $title"
            Protocol = 'mcp-streamable-1.0'
            Path     = $mcpPath
            Method   = 'post'
        }
    )
    foreach ($definition in $generatedDefinitions) {
        $operation = [ordered]@{
            summary                 = 'MCP Server Actions'
            'x-ms-agentic-protocol' = $definition.Protocol
            operationId             = 'InvokeMCP'
        }
        if ($definition.Method -eq 'post') { $operation.responses = @{} }

        $specification = [ordered]@{
            swagger             = '2.0'
            info                = [ordered]@{
                title       = "$title-$($definition.Id -replace '^default-', '')"
                description = if ($description) { $description } else { $title }
                version     = $version
            }
            host                = $mcpHost
            basePath            = '/'
            schemes             = @('https')
            paths               = @{ $definition.Path = @{ $definition.Method = $operation } }
            securityDefinitions = @{}
            security            = @()
        } | ConvertTo-Json -Depth 10

        $definitionUri = "$apiUri/versions/$versionId/definitions/$($definition.Id)"
        Invoke-AzureRest -Method put -Uri "$definitionUri`?api-version=$armApiVersion" -Body @{
            properties = @{
                title       = Limit-Text $definition.Title 50
                description = "Generated by register-app-service-mcp.ps1 for $title"
            }
        } | Out-Null
        Invoke-AzureRest -Method post -Uri "$definitionUri/importSpecification?api-version=$armApiVersion" -Body @{
            format        = 'inline'
            value         = $specification
            specification = @{ name = 'openapi'; version = '2.0' }
        } | Out-Null
        $definitionIds[$definition.Id] = "/workspaces/$WorkspaceName/apis/$targetApiId/versions/$versionId/definitions/$($definition.Id)"
    }

    # 5e. Deployment. Reuse one that already targets this URL (for example a portal-created one).
    $existingDeployments = if ($existingApi) { Get-AzureCollection -Uri "$apiUri/deployments?api-version=$armApiVersion" } else { @() }
    $match = $existingDeployments | Where-Object {
        (Test-Property $_.properties 'server') -and (@($_.properties.server.runtimeUri) -contains $mcpUrl)
    } | Select-Object -First 1

    if ($match) {
        $deploymentId = $match.name
        $deploymentProperties = Remove-ReadOnlyProperties $match.properties
    }
    else {
        $deploymentId = "$versionId-remote"
        $deploymentProperties = [pscustomobject]@{
            title         = $deploymentId
            environmentId = "/workspaces/$WorkspaceName/environments/$EnvironmentId"
        }
    }
    # Link to the Streamable definition, as a portal registration links to its SSE one.
    Set-Property $deploymentProperties 'definitionId' $definitionIds['default-streamable']
    Set-Property $deploymentProperties 'server' ([pscustomobject]@{
            runtimeUri       = @($mcpUrl)
            mcpTransportType = $transport
        })
    Invoke-AzureRest -Method put -Uri "$apiUri/deployments/$deploymentId`?api-version=$armApiVersion" -Body @{ properties = $deploymentProperties } | Out-Null

    foreach ($other in $existingDeployments | Where-Object { $_.name -ne $deploymentId }) {
        Write-Warning "'$targetApiId' also has deployment '$($other.name)', which was left unchanged and may still be published."
    }

    # Read back what API Center stored.
    $storedVersion = Invoke-AzureRest -Method get -Uri "$apiUri/versions/$versionId`?api-version=$armApiVersion"
    $storedDefinitions = Get-AzureCollection -Uri "$apiUri/versions/$versionId/definitions?api-version=$armApiVersion"
    $storedDeployment = Invoke-AzureRest -Method get -Uri "$apiUri/deployments/$deploymentId`?api-version=$armApiVersion"
    [pscustomobject]@{
        ApiId        = $targetApiId
        Action       = $action
        Version      = $versionId
        IsDefault    = [bool](Test-Property $storedVersion.properties 'isDefault')
        Definitions  = (@($storedDefinitions | ForEach-Object { $_.name }) -join ', ')
        Deployment   = $deploymentId
        LinkedTo     = if (Test-Property $storedDeployment.properties 'definitionId') { ($storedDeployment.properties.definitionId -split '/')[-1] } else { $null }
        Transport    = $storedDeployment.properties.server.mcpTransportType
        Url          = @($storedDeployment.properties.server.runtimeUri)[0]
    } | Format-List | Out-Host

    if ($VerifyRegistry) {
        $service = Invoke-AzureRest -Method get -Uri "$serviceUri`?api-version=$armApiVersion"
        $entry = Get-RegistryEntry -DataHost $service.properties.dataApiHostname -Name $targetApiId
        if (-not $entry) {
            Write-Warning "'$targetApiId' is not in the registry yet. Projection can take a few minutes."
        }
        else {
            @($entry.remotes) | ForEach-Object {
                [pscustomobject]@{ Name = $entry.name; Version = $entry.version; Type = $_.type; Url = $_.url }
            } | Format-Table -AutoSize | Out-Host

            if (-not (@($entry.remotes) | Where-Object { $_.url -eq $mcpUrl -and $_.type -eq $transport })) {
                Write-Warning "The registry does not yet show $mcpUrl as $transport. Projection may still be catching up."
            }
        }
    }
}
finally {
    if (Test-Path -LiteralPath $tempDirectory) {
        Remove-Item -LiteralPath $tempDirectory -Recurse -Force -WhatIf:$false
    }
}
