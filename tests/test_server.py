"""Black-box MCP checks against a running local or deployed server (stdlib only)."""

import json
import os
import unittest
import urllib.error
import urllib.request


BASE_URL = os.environ.get("MCP_BASE_URL", "http://localhost:5000").rstrip("/")
PROTOCOL = "2025-06-18"
API_CENTER_PORTAL_ORIGIN = (
    "https://apic-mcp-20261006232520-7688.portal.eastus.azure-apicenter.ms"
)


class WeatherServerTests(unittest.TestCase):
    def request(self, path, body=None, headers=None):
        request = urllib.request.Request(
            BASE_URL + path, data=body, headers=headers or {}
        )
        try:
            return urllib.request.urlopen(request, timeout=15)
        except urllib.error.HTTPError as error:
            return error

    def rpc(self, method, params):
        body = json.dumps(
            {"jsonrpc": "2.0", "id": 1, "method": method, "params": params}
        ).encode()
        with self.request(
            "/mcp",
            body,
            {
                "Content-Type": "application/json",
                "Accept": "application/json, text/event-stream",
                "MCP-Protocol-Version": PROTOCOL,
            },
        ) as response:
            self.assertEqual(response.status, 200)
            text = response.read().decode()
            if response.headers.get_content_type() == "text/event-stream":
                text = next(
                    line[5:].strip()
                    for line in text.splitlines()
                    if line.startswith("data:")
                )
            payload = json.loads(text)
        self.assertNotIn("error", payload)
        return payload["result"]

    def call_tool(self, name, **arguments):
        return self.rpc("tools/call", {"name": name, "arguments": arguments})

    def test_health(self):
        with self.request("/") as response:
            self.assertEqual(response.status, 200)
            self.assertEqual(response.read().decode(), "Weather MCP Server running")
        with self.request("/health") as response:
            self.assertEqual(response.status, 200)

    def test_api_center_portal_cors(self):
        request = urllib.request.Request(
            BASE_URL + "/mcp",
            method="OPTIONS",
            headers={
                "Origin": API_CENTER_PORTAL_ORIGIN,
                "Access-Control-Request-Method": "POST",
                "Access-Control-Request-Headers": (
                    "content-type,mcp-protocol-version,mcp-session-id"
                ),
            },
        )
        with urllib.request.urlopen(request, timeout=15) as response:
            self.assertEqual(response.status, 204)
            self.assertEqual(
                response.headers["Access-Control-Allow-Origin"],
                API_CENTER_PORTAL_ORIGIN,
            )
            self.assertIn(
                "POST", response.headers["Access-Control-Allow-Methods"].split(", ")
            )

    def test_initialize_and_list_tools(self):
        result = self.rpc(
            "initialize",
            {
                "protocolVersion": PROTOCOL,
                "capabilities": {},
                "clientInfo": {"name": "weather-repro-test", "version": "1.0"},
            },
        )
        self.assertEqual(result["protocolVersion"], PROTOCOL)
        self.assertIn("tools", result["capabilities"])
        with self.request(
            "/mcp",
            json.dumps(
                {"jsonrpc": "2.0", "method": "notifications/initialized"}
            ).encode(),
            {
                "Content-Type": "application/json",
                "Accept": "application/json, text/event-stream",
                "MCP-Protocol-Version": PROTOCOL,
            },
        ) as response:
            self.assertEqual(response.status, 202)
        tools = self.rpc("tools/list", {})["tools"]
        self.assertEqual(
            {tool["name"] for tool in tools},
            {"get_current_weather", "get_weather_forecast"},
        )

    def test_known_cities(self):
        for city, temperature, condition, humidity in (
            ("Seattle", 58, "Cloudy", 72),
            ("Redmond", 57, "Light rain", 75),
            ("San Diego", 72, "Sunny", 55),
        ):
            with self.subTest(city=city):
                result = self.call_tool("get_current_weather", city=city)
                self.assertFalse(result.get("isError", False))
                weather = result["structuredContent"]
                self.assertEqual(weather["city"], city)
                self.assertEqual(weather["temperature"], temperature)
                self.assertEqual(weather["condition"], condition)
                self.assertEqual(weather["humidity"], humidity)
                self.assertIn("windSpeed", weather)

    def test_deterministic_unknown_city(self):
        first = self.call_tool("get_current_weather", city="Atlantis")
        second = self.call_tool("get_current_weather", city="Atlantis")
        self.assertEqual(first, second)
        lower = self.call_tool("get_current_weather", city=" atlantis ")
        for field in ("temperature", "condition", "humidity", "windSpeed"):
            self.assertEqual(
                first["structuredContent"][field], lower["structuredContent"][field]
            )

    def test_forecast(self):
        for days in (1, 3, 10):
            with self.subTest(days=days):
                result = self.call_tool("get_weather_forecast", city="Seattle", days=days)
                self.assertFalse(result.get("isError", False))
                forecast = result["structuredContent"]
                self.assertEqual(forecast["city"], "Seattle")
                self.assertEqual(len(forecast["days"]), days)
                self.assertEqual(
                    [day["day"] for day in forecast["days"]], list(range(1, days + 1))
                )
                self.assertEqual(
                    result,
                    self.call_tool("get_weather_forecast", city="Seattle", days=days),
                )

    def test_invalid_arguments(self):
        for city in ("", "   ", "x" * 101):
            with self.subTest(city=city):
                self.assertTrue(
                    self.call_tool("get_current_weather", city=city)["isError"]
                )
        for days in (-1, 0, 11):
            with self.subTest(days=days):
                self.assertTrue(
                    self.call_tool("get_weather_forecast", city="Seattle", days=days)[
                        "isError"
                    ]
                )

    def test_no_legacy_sse(self):
        with self.request("/mcp", headers={"Accept": "text/event-stream"}) as response:
            self.assertEqual(response.status, 405)
        for path in ("/sse", "/message", "/mcp/sse", "/mcp/message"):
            with self.subTest(path=path):
                with self.request(path) as response:
                    self.assertEqual(response.status, 404)


if __name__ == "__main__":
    unittest.main()
