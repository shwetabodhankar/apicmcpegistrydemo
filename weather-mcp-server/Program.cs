var builder = WebApplication.CreateBuilder(args);

var allowedOrigins = builder.Configuration
    .GetSection("Cors:AllowedOrigins")
    .GetChildren()
    .Select(origin => origin.Value)
    .OfType<string>()
    .ToArray();

builder.Services.AddCors(options =>
{
    options.AddPolicy("McpBrowserClients", policy =>
    {
        policy.WithOrigins(allowedOrigins)
            .AllowAnyHeader()
            .AllowAnyMethod()
            .WithExposedHeaders("Mcp-Session-Id");
    });
});

builder.Services
    .AddMcpServer()
    .WithHttpTransport(options =>
    {
        options.Stateless = true;
#pragma warning disable MCP9004 // Explicitly keep the deprecated transport disabled.
        options.EnableLegacySse = false;
#pragma warning restore MCP9004
    })
    .WithToolsFromAssembly();

var app = builder.Build();

app.UseCors("McpBrowserClients");

app.MapGet("/", () => "Weather MCP Server running");
app.MapGet("/health", () => Results.Ok());
app.MapMcp("/mcp");

app.Run();
