"""rain.py: rain level (0-4) for one place, from Open-Meteo's hourly forecast."""
import json
import urllib.parse
import urllib.request

API = "https://api.open-meteo.com/v1/forecast"
WINDOW_HOURS = 12   # how far ahead to look


class RainError(ValueError):
    """Could not get a usable rain forecast."""


def level_from_mm(mm_per_hour):
    """Map the heaviest hourly rainfall (mm/h) to the packer's 0-4 scale,
    using PAGASA's rainfall intensity bands."""
    if mm_per_hour < 0.1:
        return 0    # no significant rain
    if mm_per_hour < 2.5:
        return 1    # light
    if mm_per_hour < 7.5:
        return 2    # moderate
    if mm_per_hour < 15:
        return 3    # heavy
    return 4        # intense (15+ mm/h)


def rain_level(lat, lon, hours=WINDOW_HOURS, timeout=10):
    params = urllib.parse.urlencode({
        "latitude": lat,
        "longitude": lon,
        "hourly": "precipitation",
        "forecast_hours": hours,
        "timezone": "Asia/Manila",
    })
    try:
        with urllib.request.urlopen(f"{API}?{params}", timeout=timeout) as resp:
            data = json.load(resp)
        values = [v for v in data["hourly"]["precipitation"] if v is not None]
    except (OSError, ValueError, KeyError) as e:
        raise RainError(f"could not read Open-Meteo forecast: {e}") from e
    if not values:
        raise RainError("Open-Meteo returned no precipitation values")
    return level_from_mm(max(values))

def rain_levels(points, hours=WINDOW_HOURS, batch_size=100, timeout=30):
    """Rain levels (0-4) for many (lat, lon) points, batching Open-Meteo
    multi-location requests. Points whose batch fails get None."""
    levels = []
    for start in range(0, len(points), batch_size):
        batch = points[start:start + batch_size]
        params = urllib.parse.urlencode({
            "latitude": ",".join(f"{lat:.5f}" for lat, _ in batch),
            "longitude": ",".join(f"{lon:.5f}" for _, lon in batch),
            "hourly": "precipitation",
            "forecast_hours": hours,
            "timezone": "Asia/Manila",
        })
        try:
            with urllib.request.urlopen(f"{API}?{params}", timeout=timeout) as resp:
                data = json.load(resp)
        except (OSError, ValueError):
            levels.extend([None] * len(batch))
            continue
        results = data if isinstance(data, list) else [data]
        for index in range(len(batch)):
            try:
                values = [v for v in results[index]["hourly"]["precipitation"] if v is not None]
                levels.append(level_from_mm(max(values)) if values else None)
            except (IndexError, KeyError, TypeError):
                levels.append(None)
    return levels
