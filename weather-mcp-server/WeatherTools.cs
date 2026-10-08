using System.ComponentModel;
using System.Security.Cryptography;
using System.Text;
using ModelContextProtocol;
using ModelContextProtocol.Server;

[McpServerToolType]
public static class WeatherTools
{
    [McpServerTool(Name = "get_current_weather", UseStructuredContent = true)]
    [Description("Get deterministic mock weather. Temperature is Fahrenheit, humidity is percent, and windSpeed is mph.")]
    public static Weather GetCurrentWeather(
        [Description("City name, for example Seattle.")] string city)
    {
        if (string.IsNullOrWhiteSpace(city) || city.Trim().Length > 100)
        {
            throw new McpException("City must contain between 1 and 100 characters.");
        }

        city = city.Trim();
        var normalized = city.ToUpperInvariant();
        return normalized switch
        {
            "SEATTLE" => new Weather("Seattle", 58, "Cloudy", 72, 8),
            "REDMOND" => new Weather("Redmond", 57, "Light rain", 75, 6),
            "SAN DIEGO" => new Weather("San Diego", 72, "Sunny", 55, 5),
            _ => CreateSample(city, normalized)
        };
    }

    [McpServerTool(Name = "get_weather_forecast", UseStructuredContent = true)]
    [Description("Get 1 to 10 days of deterministic mock weather, numbered from day 1. Temperature is Fahrenheit and windSpeed is mph.")]
    public static Forecast GetWeatherForecast(
        [Description("City name.")] string city,
        [Description("Number of forecast days, from 1 to 10.")] int days)
    {
        if (days is < 1 or > 10)
        {
            throw new McpException("Days must be between 1 and 10.");
        }

        var current = GetCurrentWeather(city);
        var forecast = Enumerable.Range(1, days)
            .Select(day => new ForecastDay(
                day,
                current.Temperature + (day - 1) % 5 - 2,
                current.Condition,
                current.Humidity,
                current.WindSpeed))
            .ToArray();
        return new Forecast(current.City, forecast);
    }

    private static Weather CreateSample(string city, string normalized)
    {
        var hash = SHA256.HashData(Encoding.UTF8.GetBytes(normalized));
        string[] conditions = ["Sunny", "Cloudy", "Partly cloudy", "Light rain"];
        return new Weather(city, 45 + hash[0] % 41, conditions[hash[1] % conditions.Length],
            40 + hash[2] % 46, 3 + hash[3] % 13);
    }
}

public sealed record Weather(string City, int Temperature, string Condition, int Humidity, int WindSpeed);
public sealed record Forecast(string City, ForecastDay[] Days);
public sealed record ForecastDay(int Day, int Temperature, string Condition, int Humidity, int WindSpeed);
