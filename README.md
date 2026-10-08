# Azure API Center MCP transport repro

This demo isolates registry transport metadata from a working MCP server. It uses
.NET 8, ASP.NET Core, and the official `ModelContextProtocol.AspNetCore` SDK
(pinned to 2.2.0). No Azure Functions, weather API, API keys, or legacy HTTP+SSE
transport are used.

```text
VS Code / GitHub Copilot
        |
        | discovers server metadata
Azure API Center MCP registry
        |
        | advertises the remote /mcp URL
Weather MCP Server on Azure App Service
```

The registry is a catalog, not a reverse proxy: after discovery, VS Code connects
to the advertised App Service URL. The hypothesis is that API Center might
publish `remotes[].type: "sse"` for a Streamable HTTP server. **Do not assume the
bug is present.** Inspect the real registry response and client logs first.

The original issue's local-test section was truncated. This implementation uses
port **5000**, a maximum of **10 forecast days**, and day numbers instead of dates
so results remain deterministic across runs.

## 1. Run locally

Prerequisites: .NET 8 SDK, Python 3 (only for the optional black-box tests), curl,
and jq. For cloud steps, also install Azure CLI and zip, and use an Azure
subscription where you can create App Service and API Center resources.

Run these Bash commands from the repository:

```bash
REPO_ROOT="$(git rev-parse --show-toplevel)"
PROJECT="$REPO_ROOT/weather-mcp-server/weather-mcp-server.csproj"
dotnet restore "$PROJECT"
dotnet build "$PROJECT" --no-restore
dotnet run --project "$PROJECT" --launch-profile http
```

Wait for `Now listening on: http://localhost:5000`. In another terminal:

```bash
REPO_ROOT="$(git rev-parse --show-toplevel)"
curl --fail-with-body http://localhost:5000/
# Weather MCP Server running
curl --fail-with-body -i http://localhost:5000/health
# HTTP 200
python3 "$REPO_ROOT/tests/test_server.py" -v
```

The tests exercise MCP initialization, tool discovery, both tools, known and
unknown cities, deterministic output, invalid inputs, and absence of legacy SSE.
They use Python's standard library; no test packages are needed.

### Inspect a real MCP handshake

```bash
curl --fail-with-body -i --max-time 15 http://localhost:5000/mcp \
  -H 'Content-Type: application/json' \
  -H 'Accept: application/json, text/event-stream' \
  --data '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"weather-repro","version":"1.0"}}}'

curl --fail-with-body --max-time 15 http://localhost:5000/mcp \
  -H 'Content-Type: application/json' \
  -H 'Accept: application/json, text/event-stream' \
  -H 'MCP-Protocol-Version: 2025-06-18' \
  --data '{"jsonrpc":"2.0","method":"notifications/initialized"}'

curl --fail-with-body --max-time 15 http://localhost:5000/mcp \
  -H 'Content-Type: application/json' \
  -H 'Accept: application/json, text/event-stream' \
  -H 'MCP-Protocol-Version: 2025-06-18' \
  --data '{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}'

curl --fail-with-body --max-time 15 http://localhost:5000/mcp \
  -H 'Content-Type: application/json' \
  -H 'Accept: application/json, text/event-stream' \
  -H 'MCP-Protocol-Version: 2025-06-18' \
  --data '{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"get_current_weather","arguments":{"city":"Seattle"}}}'

curl --fail-with-body --max-time 15 http://localhost:5000/mcp \
  -H 'Content-Type: application/json' \
  -H 'Accept: application/json, text/event-stream' \
  -H 'MCP-Protocol-Version: 2025-06-18' \
  --data '{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"get_weather_forecast","arguments":{"city":"Redmond","days":3}}}'
```

Expect HTTP 200 with JSON-RPC results (possibly framed as `data:` SSE events);
the initialized notification has no JSON-RPC response and returns HTTP 202.
The server is stateless, so no `Mcp-Session-Id` is needed.
An SSE-formatted response is valid **Streamable HTTP**, not evidence of the
deprecated transport. Legacy HTTP+SSE requires a separate SSE channel advertising
a message POST endpoint; that is deliberately unavailable here:

```bash
curl -i --max-time 5 -H 'Accept: text/event-stream' http://localhost:5000/mcp
# HTTP 405: GET streams are not supported in this stateless configuration
curl -i http://localhost:5000/sse
curl -i http://localhost:5000/message
curl -i http://localhost:5000/mcp/sse
curl -i http://localhost:5000/mcp/message
# HTTP 404 for all four legacy paths
```

### Direct VS Code / Copilot baseline

Use a current VS Code version with MCP support, GitHub Copilot access, and a
trusted workspace. Open **MCP: Open Workspace Folder MCP Configuration** from the
Command Palette (the configuration lives at `$REPO_ROOT/.vscode/mcp.json`).
Add:

```json
{
  "servers": {
    "weather-direct-local": {
      "type": "http",
      "url": "http://localhost:5000/mcp"
    }
  }
}
```

VS Code's direct configuration uses `"type": "http"`; the registry schema uses
`"streamable-http"`. They are not interchangeable schema values.
Use **MCP: List Servers**, select `weather-direct-local`, start it, and approve
trust if prompted. In Copilot Chat's agent mode, enable the two weather tools:

- “Use get_current_weather for Seattle.”
- “Use get_weather_forecast for Redmond for 3 days.”

Check the tool invocation, not just a natural-language answer. Seattle must return
`city: Seattle`, `temperature: 58`, `condition: Cloudy`, `humidity: 72`, and
`windSpeed: 8`. Redmond is 57 F, light rain, 75% humidity; San Diego is 72 F,
sunny, 55% humidity. Wind speed is mph. Unknown cities use a stable SHA-256-based
sample, not randomized data.

CORS is not needed by VS Code's native MCP client. The server explicitly allows
the API Center portal origin in `weather-mcp-server/appsettings.json` so the
portal's browser-based test client can call `/mcp`; it does not enable wildcard
browser access. Add other browser client origins to `Cors:AllowedOrigins` only
when required.

## 2. Deploy to Azure App Service (Linux, .NET 8)

This creates a publicly reachable, unauthenticated **mock-data-only demo**. Do not
add secrets, real data, or privileged tools. App Service and API Center may incur
charges. Use a dedicated resource group and your approved Azure region.

```bash
REPO_ROOT="$(git rev-parse --show-toplevel)"
PROJECT="$REPO_ROOT/weather-mcp-server/weather-mcp-server.csproj"
az login
az account set --subscription '<your-subscription-id>'

LOCATION='eastus'
RG='rg-weather-mcp-repro'
PLAN='plan-weather-mcp-repro'
APP='<globally-unique-web-app-name>'
APIC='<your-api-center-name>'

az group create --name "$RG" --location "$LOCATION"
az appservice plan create --name "$PLAN" --resource-group "$RG" \
  --location "$LOCATION" --is-linux --sku B1
az webapp create --name "$APP" --resource-group "$RG" \
  --plan "$PLAN" --runtime 'DOTNETCORE:8.0'
az webapp update --name "$APP" --resource-group "$RG" --https-only true
az webapp config set --name "$APP" --resource-group "$RG" \
  --always-on true --ftps-state Disabled --min-tls-version 1.2 \
  --startup-file 'dotnet /home/site/wwwroot/weather-mcp-server.dll'
az webapp config appsettings set --name "$APP" --resource-group "$RG" \
  --settings ASPNETCORE_URLS='http://0.0.0.0:8080' ASPNETCORE_ENVIRONMENT=Production

PUBLISH_DIR="$(mktemp -d)"
dotnet publish "$PROJECT" --configuration Release --output "$PUBLISH_DIR/site"
(cd "$PUBLISH_DIR/site" && zip -qr "$PUBLISH_DIR/weather-mcp-server.zip" .)
az webapp deploy --name "$APP" --resource-group "$RG" \
  --src-path "$PUBLISH_DIR/weather-mcp-server.zip" --type zip

# Use Azure's returned hostname rather than assuming a DNS naming convention.
APP_HOST="$(az webapp show --name "$APP" --resource-group "$RG" \
  --query defaultHostName --output tsv)"
MCP_BASE_URL="https://$APP_HOST"
MCP_URL="$MCP_BASE_URL/mcp"
curl --fail-with-body "$MCP_BASE_URL/"
curl --fail-with-body -i "$MCP_BASE_URL/health"
MCP_BASE_URL="$MCP_BASE_URL" python3 "$REPO_ROOT/tests/test_server.py" -v
```

Wait for deployment startup before testing. If health fails, check App Service's
**Log stream** and deployment logs before proceeding; a cold start, wrong startup
command, blocked network, or authentication failure is not a registry transport bug.

Before registering with API Center, repeat the VS Code direct baseline with a
server named `weather-direct-azure` and URL `https://<returned-app-hostname>/mcp`,
still using `"type": "http"`. Both tools must work. Stop/disable the local entry
so it cannot accidentally provide the successful tool invocation.

## 3. Register the remote MCP server in Azure API Center

Use the portal workflow so this repro exercises API Center's Remote MCP
registration and its generated metadata, rather than a hand-authored registry.

1. In the Azure portal, create an **Azure API Center** resource in `$RG`, with
   name `$APIC` and a supported region. Record its region, tier, and creation date.
   If using an existing center, use an isolated demo workspace with no sensitive
   catalog entries.
2. In API Center's **Inventory → Environments**, create an environment for the
   demo App Service (or select an existing appropriate environment).
3. Open **Inventory → Assets → Register an asset → MCP server**.
4. Name the asset `weather-mcp-server`, and supply the required version title,
   identifier (for example `1.0.0`), and lifecycle stage.
5. Under **Remotes → Add remote**, enter the **Runtime URL** equal to `$MCP_URL`
   (the HTTPS App Service URL ending in `/mcp`), and select the environment.
6. Finish registration. Inspect the asset's version, definitions, and deployment
   to confirm the URL was saved. Record any transport field offered by your
   portal version and its value; if offered, select Streamable HTTP.

The documented remote form does not currently specify a transport selector.
API Center may generate both SSE and Streamable OpenAPI definitions. **Those
definitions are not evidence of which transport the registry actually publishes.**
Do not change generated metadata before recording the original response.

For the simplest isolated VS Code gallery repro, configure API Center's portal
data access under **Consumption → Portal settings → Access** to permit anonymous
access to **only a dedicated mock-data catalog**,
if your environment permits it. This is separate from the weather server's
authentication. Do not expose an existing private catalog or disable enterprise
access controls. If anonymous access is not allowed, keep authenticated access
and use the API Center extension/authenticated inspection path described below;
do not interpret inability to authenticate as a transport mismatch.

### Alternative: register from the project code with the correct transport

The portal registration above publishes the remote as `sse`.
[`scripts/register-app-service-mcp.ps1`](scripts/register-app-service-mcp.ps1)
instead registers the already-deployed App Service app as `streamable-http`. It
takes the name, `Title`, `Version` and `Description` from
`weather-mcp-server.csproj` and the endpoint path from `MapMcp("/mcp")`. It then
checks the live endpoint with a Streamable HTTP `initialize` request and creates
or updates the environment, asset, version and deployment through ARM. The
deployment sets the undocumented property `server.mcpTransportType`, which the
registry reads. The script is self-contained and does not build or deploy the app.

```powershell
.\scripts\register-app-service-mcp.ps1 `
  -SubscriptionId '<subscription-id>' `
  -WebAppName '<web-app-name>' -WebAppResourceGroup '<app-resource-group>' `
  -ResourceGroup '<api-center-resource-group>' -ApiCenterName '<api-center-name>' `
  -WhatIf   # remove to register; add -VerifyRegistry -ClientId <app> -TenantId <tenant> to read /v0.1/servers
```

Use the portal path when reproducing the `sse` issue, and this script when you
want the registry to publish the correct transport.

## 4. Inspect the actual registry JSON

Copy your center's data-plane hostname/registry URL from its portal settings.
The documented registry URL format is:

```text
https://<center>.data.<region>.azure-apicenter.ms/workspaces/default/v0.1/servers
```

Use your actual hostname and workspace, not a guessed hostname. API Center docs
have also shown examples without `/workspaces`; use the URL exposed for your
resource and verify it returns a registry listing. A 404 is not transport evidence.

The endpoint `https://<data-plane-host>/mcp` is a different feature: API Center's
own catalog-search MCP server. **Do not configure it as the weather server or as
the registry listing URL.**

In the same Bash session as deployment:

```bash
REGISTRY_BASE='https://<your-data-plane-host>/workspaces/default'
REGISTRY_URL="$REGISTRY_BASE/v0.1/servers"
EVIDENCE_DIR="$(mktemp -d)"

curl --fail-with-body --silent --show-error --max-time 30 \
  --dump-header "$EVIDENCE_DIR/registry.headers" \
  "$REGISTRY_URL" --output "$EVIDENCE_DIR/registry.json"

jq '.servers[] | (.server // .) | {name, version, remotes}' \
  "$EVIDENCE_DIR/registry.json"

# Select by the exact deployed URL, not an assumed registry asset name.
jq --arg url "$MCP_URL" \
  '[.servers[] | (.server // .) |
    {name, version, remotes: [.remotes[]? | select(.url == $url)]} |
    select(.remotes | length > 0)]' \
  "$EVIDENCE_DIR/registry.json"

jq --arg url "$MCP_URL" \
  '[.servers[] | (.server // .) | .remotes[]? |
    select(.url == $url) | {type, url}]' \
  "$EVIDENCE_DIR/registry.json"
```

If the selected array is empty, registration is not yet visible, the URL differs,
or the result is paginated. Check the response's pagination metadata and follow
its next cursor/link until the weather entry is found; do not conclude that an
empty first page means a transport bug. Allow time for publication and refresh.

Expected remote metadata for **this server** (illustrative, not captured evidence):

```json
{
  "type": "streamable-http",
  "url": "https://<returned-app-hostname>/mcp"
}
```

If the response instead contains `"type": "sse"` with that exact `/mcp` URL,
record the unchanged JSON and response timestamp. This establishes a metadata
discrepancy against the tested Streamable HTTP-only server, not yet a proven
VS Code connection failure.

### Authenticated registry inspection

For an authenticated center, configure Entra access and the **Azure API Center
Data Reader** role according to the API Center documentation. A data-plane token
is required, not an ARM management token:

```bash
# Do not enable shell tracing or log/share the token.
TOKEN="$(az account get-access-token --resource https://azure-apicenter.net \
  --query accessToken --output tsv)"
curl --fail-with-body --silent --show-error --max-time 30 \
  --oauth2-bearer "$TOKEN" "$REGISTRY_URL" \
  --output "$EVIDENCE_DIR/registry.json"
unset TOKEN
```

Token acquisition depends on tenant consent and the identity's permissions.
Do not put tokens into source-controlled VS Code settings or evidence bundles.
HTTP 401/403 means authentication/authorization must be resolved before the
transport comparison.

## 5. Consume the API Center registry from VS Code

Record the VS Code version (`code --version`), Copilot extension version, and
API Center registration details before the comparison. Stop/disable both direct
weather entries and remove them from the Chat tool selection.

For a registry accessible anonymously, open **Preferences: Open User Settings
(JSON)** and temporarily set:

```json
{
  "chat.mcp.gallery.serviceUrl": "https://<your-data-plane-host>/workspaces/default",
  "chat.mcp.gallery.version": "v0.1"
}
```

Use `REGISTRY_BASE`, **not** the full `/v0.1/servers` URL: VS Code appends the
version and `/servers` path. If these settings are not recognized in your build,
use a current VS Code release that supports custom MCP galleries and record its
version. Do not substitute `chat.mcp.discovery.enabled`; that setting is for
discovery from other local applications.

1. Reload VS Code. Open the Extensions view's MCP server gallery (search
   `@mcp`, or use **MCP: Browse Servers** if available).
2. Find the registered weather asset by its actual registry name and install
   it **from the API Center gallery**. Do not manually add its URL for this test.
3. Inspect the installed MCP configuration via **MCP: Open User Configuration**
   or the configuration link in **MCP: List Servers**. Record the selected remote
   URL and client configuration. VS Code's installed entry may say `"type":
   "http"` even when registry metadata says `"sse"`; preserve both observations.
4. Start the registry-installed server, approve trust, and open **Show Output**
   from **MCP: List Servers**. Keep the server's MCP output and relevant VS Code
   logs; redact credentials and unrelated information.
5. Enable **only the registry-installed weather tools** in Chat and repeat the
   exact Seattle/current-weather and Redmond/3-day-forecast prompts.
6. If it fails, record the request URL, HTTP status, transport-related message,
   whether initialization happened, and whether tools were discovered. Compare
   with the successful direct Azure baseline against the **same** URL.

The generic gallery setting does not guarantee automatic Entra authentication.
For an authenticated center, Microsoft's **Azure API Center** VS Code extension
supports **Connect to an API Center** with data-plane hostname, client ID, and
tenant ID. Use its sign-in/discovery workflow as permitted by your environment,
and record that this is an extension-driven path, not the anonymous core-gallery
path. Failure to access the gallery is distinct from failure to connect to the
weather MCP server.

### Interpret the result honestly

**Important current-client limitation:** the inspected VS Code source selects
`remotes[0]` and installs its URL/headers as `"type": "http"` without preserving
the registry's `remote.type`. Its runtime tries Streamable HTTP POST first and
can fall back to legacy SSE after an initial non-authentication 4xx response.
Consequently, a type-only registry mismatch need not cause failure in that
client. These are source observations, not a claim about every released build;
record and test your actual VS Code version. If the asset has several remotes,
also check which one VS Code selected.

| Registry and client observation | Conclusion |
| --- | --- |
| `streamable-http`; registry-installed tools work | No repro on this service/client version. |
| `sse`; direct Azure tools work; registry-installed connection fails attempting legacy SSE at the same URL | Metadata mismatch and client failure reproduced; preserve payload and logs. |
| `sse`; registry-installed tools still work | Metadata mismatch observed, but no client failure; the client may auto-detect/fall back to Streamable HTTP. |
| Registry-installed URL differs from the direct URL | Resolve URL/registration differences before attributing failure to transport. |
| 401/403, DNS/TLS errors, missing gallery entry, or failing Azure health | Inconclusive for transport; investigate the specific prerequisite failure. |

Streamable HTTP clients may probe with GET or retry transports. A GET 405 by itself
is **not** a failure if a subsequent POST initialize succeeds. Do not manufacture
a failure by enabling legacy transport, editing registry JSON, or changing the
working server. If the metadata is correct or your VS Code version tolerates the
mismatch, report that result instead of claiming the requested failure occurred.

Record these items for a useful issue report:

- Deployment URL, SDK version (2.2.0), .NET runtime, VS Code/Copilot versions,
  API Center region/tier, registration method, and UTC observation time.
- Direct local and direct Azure tool results, and deployed black-box test output.
- Raw registry entry including `remotes[].type` and `remotes[].url`.
- Registry-installed configuration and MCP output showing success or failure.
- A clear distinction between the metadata discrepancy and the client impact.

Azure deployment, portal registration, registry inspection, and interactive
Copilot testing require your Azure/VS Code access. They are not automatically
performed by building this repository; no live Azure mismatch is asserted here.

## References

- [Official .NET MCP SDK](https://github.com/modelcontextprotocol/csharp-sdk)
- [Streamable HTTP transport specification](https://modelcontextprotocol.io/specification/2025-06-18/basic/transports)
- [Register and discover MCP servers in API Center](https://learn.microsoft.com/azure/api-center/register-discover-mcp-server)
- [API Center portal setup and access](https://learn.microsoft.com/azure/api-center/set-up-api-center-portal)
- [API Center VS Code extension access](https://learn.microsoft.com/azure/api-center/enable-api-center-portal-vs-code-extension)
- [API Center catalog MCP endpoint (distinct from registry)](https://learn.microsoft.com/azure/api-center/discover-catalog-mcp-server)
- [VS Code MCP server configuration](https://code.visualstudio.com/docs/copilot/customization/mcp-servers)
- [VS Code gallery URL/version implementation](https://github.com/microsoft/vscode/blob/main/src/vs/workbench/services/mcp/browser/mcpGalleryManifestService.ts)
- [VS Code registry listing URL construction](https://github.com/microsoft/vscode/blob/main/src/vs/platform/mcp/common/mcpGalleryManifestService.ts)
- [VS Code registry-to-client installation mapping](https://github.com/microsoft/vscode/blob/main/src/vs/platform/mcp/common/mcpManagementService.ts)
- [VS Code HTTP transport negotiation](https://github.com/microsoft/vscode/blob/main/src/vs/workbench/api/common/extHostMcp.ts)
