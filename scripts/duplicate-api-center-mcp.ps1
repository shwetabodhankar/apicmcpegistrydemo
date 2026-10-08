<#
.SYNOPSIS
Duplicates one MCP asset version within an Azure API Center.

.DESCRIPTION
Copies the asset metadata, version, generated SSE and Streamable HTTP
definitions, OpenAPI specifications, and matching deployments. The duplicate
continues to use the source deployment's runtime URL and environment.

The script validates the complete source before creating resources. -WhatIf
performs these read-only validation calls but skips all PUT and import requests.
#>
[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
param(
    [Parameter(Mandatory)]
    [ValidatePattern('^[0-9a-fA-F-]{36}$')]
    [string]$SubscriptionId,

    [Parameter(Mandatory)]
    [string]$ResourceGroup,

    [Parameter(Mandatory)]
    [string]$ApiCenterName,

    [Parameter(Mandatory)]
    [ValidatePattern('^[a-zA-Z0-9-]{3,90}$')]
    [string]$SourceApiId,

    [Parameter(Mandatory)]
    [ValidatePattern('^[a-zA-Z0-9-]{3,90}$')]
    [string]$SourceVersionId,

    [Parameter(Mandatory)]
    [ValidatePattern('^[a-zA-Z0-9-]{3,90}$')]
    [string]$DuplicateApiId,

    [ValidatePattern('^[a-zA-Z0-9-]{3,90}$')]
    [string]$DuplicateVersionId = $SourceVersionId,

    [ValidatePattern('^[a-zA-Z0-9-]{3,90}$')]
    [string]$WorkspaceName = 'default'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Pin the preview API because MCP is not supported by older API Center schemas.
$apiVersion = '2024-06-01-preview'
$baseUri = "https://management.azure.com/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroup/providers/Microsoft.ApiCenter/services/$ApiCenterName/workspaces/$WorkspaceName"
$tempDirectory = Join-Path ([System.IO.Path]::GetTempPath()) "api-center-mcp-$([guid]::NewGuid())"

# Sends authenticated ARM requests through the user's existing Azure CLI session.
function Invoke-AzureRest {
    param(
        [Parameter(Mandatory)]
        [ValidateSet('get', 'put', 'post')]
        [string]$Method,

        [Parameter(Mandatory)]
        [string]$Uri,

        [object]$Body
    )

    $arguments = @(
        'rest',
        '--method', $Method,
        '--uri', $Uri,
        '--only-show-errors',
        '--output', 'json'
    )

    if ($null -ne $Body) {
        # A temporary JSON file avoids PowerShell and shell quoting changes.
        $bodyFile = Join-Path $tempDirectory "$([guid]::NewGuid()).json"
        $Body | ConvertTo-Json -Depth 100 | Set-Content -LiteralPath $bodyFile -Encoding utf8NoBOM
        $arguments += @(
            '--headers', 'Content-Type=application/json',
            '--body', "@$bodyFile"
        )
    }

    $output = & az @arguments 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "Azure REST request failed: $Method $Uri`n$($output -join [Environment]::NewLine)"
    }

    $text = ($output -join [Environment]::NewLine).Trim()
    if ($text) {
        return $text | ConvertFrom-Json -Depth 100
    }
}

# Follows nextLink so validation and cloning do not silently omit later pages.
function Get-AzureCollection {
    param(
        [Parameter(Mandatory)]
        [string]$Uri
    )

    $items = [System.Collections.Generic.List[object]]::new()
    $nextUri = $Uri
    while ($nextUri) {
        $page = Invoke-AzureRest -Method get -Uri $nextUri
        foreach ($item in @($page.value)) {
            $items.Add($item)
        }
        $nextUri = if ($page.PSObject.Properties.Name -contains 'nextLink') {
            $page.nextLink
        }
        else {
            $null
        }
    }
    return $items
}

# Removes server-managed fields that ARM rejects in create or update payloads.
function Copy-WritableProperties {
    param(
        [Parameter(Mandatory)]
        [object]$Properties
    )

    $copy = $Properties | ConvertTo-Json -Depth 100 | ConvertFrom-Json -Depth 100
    foreach ($readOnlyProperty in @('provisioningState')) {
        if ($copy.PSObject.Properties.Name -contains $readOnlyProperty) {
            $copy.PSObject.Properties.Remove($readOnlyProperty)
        }
    }
    return $copy
}

# API Center can return a specification inline or through a short-lived URL.
function Export-DefinitionSpecification {
    param(
        [Parameter(Mandatory)]
        [string]$DefinitionUri
    )

    $result = Invoke-AzureRest -Method post -Uri "$DefinitionUri/exportSpecification?api-version=$apiVersion"
    if ($result.format -eq 'inline') {
        return [string]$result.value
    }
    if ($result.format -eq 'link') {
        return (Invoke-WebRequest -UseBasicParsing -Uri $result.value).Content
    }
    throw "Unsupported specification export format '$($result.format)'."
}

# Generated definitions may use OpenAPI 3.x or its Swagger/OpenAPI 2.0 predecessor.
function Get-OpenApiVersion {
    param(
        [Parameter(Mandatory)]
        [string]$Specification
    )

    if ($Specification -match '"openapi"\s*:\s*"([^"]+)"') {
        return $Matches[1]
    }
    if ($Specification -match '(?m)^\s*openapi\s*:\s*[''"]?([^''"\s]+)') {
        return $Matches[1]
    }
    if ($Specification -match '"swagger"\s*:\s*"([^"]+)"') {
        return $Matches[1]
    }
    if ($Specification -match '(?m)^\s*swagger\s*:\s*[''"]?([^''"\s]+)') {
        return $Matches[1]
    }
    throw 'The exported definition is not an OpenAPI or Swagger document.'
}

if (-not (Get-Command az -ErrorAction SilentlyContinue)) {
    throw 'Azure CLI is required. Install it and run az login before this script.'
}

New-Item -ItemType Directory -Path $tempDirectory | Out-Null

try {
    $null = & az account show --only-show-errors --output none 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw 'Azure CLI is not signed in. Run az login first.'
    }

    $apisUri = "$baseUri/apis?api-version=$apiVersion"
    $sourceApiUri = "$baseUri/apis/$SourceApiId"
    $duplicateApiUri = "$baseUri/apis/$DuplicateApiId"
    $sourceVersionUri = "$sourceApiUri/versions/$SourceVersionId"
    $duplicateVersionUri = "$duplicateApiUri/versions/$DuplicateVersionId"

    # Refuse to overwrite an existing asset with the requested duplicate ID.
    $allApis = Get-AzureCollection -Uri $apisUri
    if ($allApis.name -contains $DuplicateApiId) {
        throw "API '$DuplicateApiId' already exists. Choose a different DuplicateApiId."
    }

    $sourceApi = Invoke-AzureRest -Method get -Uri "$sourceApiUri`?api-version=$apiVersion"
    if ($sourceApi.properties.kind -ne 'mcp') {
        throw "Source API '$SourceApiId' has kind '$($sourceApi.properties.kind)', not 'mcp'."
    }

    $sourceVersion = Invoke-AzureRest -Method get -Uri "$sourceVersionUri`?api-version=$apiVersion"
    $sourceDefinitions = Get-AzureCollection -Uri "$sourceVersionUri/definitions?api-version=$apiVersion"
    if ($sourceDefinitions.Count -eq 0) {
        throw "Source version '$SourceVersionId' has no definitions."
    }

    # Export first so all source data is validated before the write gate.
    $definitionCopies = foreach ($definition in $sourceDefinitions) {
        $definitionUri = "$sourceVersionUri/definitions/$($definition.name)"
        $specification = Export-DefinitionSpecification -DefinitionUri $definitionUri
        $searchableText = @(
            $definition.name
            $definition.properties.title
            $definition.properties.description
            $specification
        ) -join "`n"

        [pscustomobject]@{
            Definition = $definition
            Specification = $specification
            IsSse = $searchableText -match '(?i)(server-sent events|\bsse\b)'
            IsStreamable = $searchableText -match '(?i)streamable'
        }
    }

    # Both generated transports are required for this specific comparison.
    if (-not ($definitionCopies.IsSse -contains $true)) {
        throw 'The source version does not contain an SSE definition. Nothing was duplicated.'
    }
    if (-not ($definitionCopies.IsStreamable -contains $true)) {
        throw 'The source version does not contain a Streamable definition. Nothing was duplicated.'
    }

    # All Azure writes occur after this gate, which makes -WhatIf non-destructive.
    if (-not $PSCmdlet.ShouldProcess(
        "$ApiCenterName/$WorkspaceName/$DuplicateApiId",
        "Duplicate MCP asset '$SourceApiId' and version '$SourceVersionId'"
    )) {
        return
    }

    # Create the parent asset and version before their definition children.
    $apiProperties = Copy-WritableProperties -Properties $sourceApi.properties
    $apiProperties.title = "$($sourceApi.properties.title) (duplicate)"
    Invoke-AzureRest -Method put -Uri "$duplicateApiUri`?api-version=$apiVersion" -Body @{
        properties = $apiProperties
    } | Out-Null

    Invoke-AzureRest -Method put -Uri "$duplicateVersionUri`?api-version=$apiVersion" -Body @{
        properties = Copy-WritableProperties -Properties $sourceVersion.properties
    } | Out-Null

    foreach ($copy in $definitionCopies) {
        $definition = $copy.Definition
        $duplicateDefinitionUri = "$duplicateVersionUri/definitions/$($definition.name)"

        Invoke-AzureRest -Method put -Uri "$duplicateDefinitionUri`?api-version=$apiVersion" -Body @{
            properties = Copy-WritableProperties -Properties $definition.properties
        } | Out-Null

        # Import the exact exported document instead of regenerating a substitute.
        Invoke-AzureRest -Method post -Uri "$duplicateDefinitionUri/importSpecification?api-version=$apiVersion" -Body @{
            format = 'inline'
            value = $copy.Specification
            specification = @{
                name = 'openapi'
                version = Get-OpenApiVersion -Specification $copy.Specification
            }
        } | Out-Null
    }

    $sourceDeployments = Get-AzureCollection -Uri "$sourceApiUri/deployments?api-version=$apiVersion"
    foreach ($deployment in $sourceDeployments) {
        $properties = Copy-WritableProperties -Properties $deployment.properties

        # Only clone deployments for the selected version and retarget their definition IDs.
        if ($properties.definitionId -match "/apis/$([regex]::Escape($SourceApiId))/versions/$([regex]::Escape($SourceVersionId))/definitions/([^/]+)$") {
            $definitionName = $Matches[1]
            $properties.definitionId = "/workspaces/$WorkspaceName/apis/$DuplicateApiId/versions/$DuplicateVersionId/definitions/$definitionName"
        }
        else {
            continue
        }

        Invoke-AzureRest -Method put -Uri "$duplicateApiUri/deployments/$($deployment.name)?api-version=$apiVersion" -Body @{
            properties = $properties
        } | Out-Null
    }

    # Report transport evidence from the definitions now present on the duplicate.
    $duplicateDefinitions = Get-AzureCollection -Uri "$duplicateVersionUri/definitions?api-version=$apiVersion"
    $report = foreach ($definition in $duplicateDefinitions) {
        $sourceCopy = $definitionCopies | Where-Object { $_.Definition.name -eq $definition.name }
        [pscustomobject]@{
            DefinitionId = $definition.name
            Title = $definition.properties.title
            SSE = [bool]$sourceCopy.IsSse
            StreamableHTTP = [bool]$sourceCopy.IsStreamable
        }
    }

    $report | Format-Table -AutoSize

    if (-not ($report.SSE -contains $true) -or -not ($report.StreamableHTTP -contains $true)) {
        throw "Duplicate '$DuplicateApiId' was created, but both transport definitions were not found."
    }

    Write-Host "Duplicate MCP asset '$DuplicateApiId' contains both SSE and Streamable HTTP definitions."
}
finally {
    # Specification payloads may contain service metadata, so always remove them.
    if (Test-Path -LiteralPath $tempDirectory) {
        Remove-Item -LiteralPath $tempDirectory -Recurse -Force
    }
}
