import math
import re
from typing import NamedTuple


class WindModelError(ValueError):
    """The bulletin is missing something the wind estimate needs."""


EARTH_RADIUS_KM = 6371.0
EDGE_WIND_KPH = 39      # wind at the outer edge of the strong-wind radius (the bottom of Signal 1)
WINDOW_HOURS = 36       # the longest lead time in the signal table

# PAGASA's table: (signal, winds of at least this many km/h, expected within this many hours)
SIGNALS = [(5, 185, 12), (4, 118, 12), (3, 89, 18), (2, 62, 24), (1, 39, 36)]


class LocalImpact(NamedTuple):
    signal: int
    peak_wind_kph: int
    gusts_kph: int
    closest_km: int


def distance_km(lat1, lon1, lat2, lon2):
    """Great-circle distance between two points, in km (haversine)."""
    p1, p2 = math.radians(lat1), math.radians(lat2)
    a = (math.sin((p2 - p1) / 2) ** 2
         + math.cos(p1) * math.cos(p2) * math.sin(math.radians(lon2 - lon1) / 2) ** 2)
    return 2 * EARTH_RADIUS_KM * math.asin(math.sqrt(a))


def wind_at(distance, vmax, radius):
    """Estimated sustained wind (km/h) `distance` km from the center: vmax at the center,
    falling in a straight line to 39 km/h at `radius`, and 0 beyond it."""
    if distance >= radius:
        return 0.0
    edge = min(EDGE_WIND_KPH, vmax)
    return vmax - (vmax - edge) * distance / radius


def strong_wind_radius(bulletin):
    """'... winds extend outwards up to 350 km from the center' -> 350.0"""
    text = bulletin.get("windExtent") or ""
    m = re.search(r"up to\s+([\d,]+)\s*km", text, re.I)
    radius = float(m.group(1).replace(",", "")) if m else 0.0
    if radius <= 0:
        raise WindModelError(f"cannot read the wind radius from {text!r}")
    return radius


def _track(bulletin):
    """[(hour, lat, lon, max sustained wind)] for now and each complete forecast point, in time order.
    Forecast points with a missing value are skipped; the current position and wind are required."""
    pos = bulletin.get("currentPosition") or {}
    vmax = (bulletin.get("intensity") or {}).get("maxSustainedWindsKph")
    if None in (pos.get("lat"), pos.get("lon"), vmax) or vmax <= 0:
        raise WindModelError("the bulletin has no usable storm position or wind speed")
    points = [(0, pos["lat"], pos["lon"], vmax)]
    for f in sorted(bulletin.get("forecast") or [], key=lambda f: f.get("hours") or 0):
        values = (f.get("hours"), f.get("lat"), f.get("lon"), f.get("maxSustainedWindsKph"))
        if None not in values and values[0] > points[-1][0]:
            points.append(values)
    return points


def _state_at(points, hour):
    """The storm's (lat, lon, max wind) at `hour`, interpolated between track points."""
    for (t0, la0, lo0, v0), (t1, la1, lo1, v1) in zip(points, points[1:]):
        if hour <= t1:
            f = (hour - t0) / (t1 - t0)
            return la0 + f * (la1 - la0), lo0 + f * (lo1 - lo0), v0 + f * (v1 - v0)
    return points[-1][1:]


def _signal(winds):
    """Highest signal whose table row fits. `winds` is [(hour, local wind km/h), ...]."""
    for level, at_least, within in SIGNALS:
        if any(w >= at_least for hour, w in winds if hour <= within):
            return level
    return 0


def local_impact(bulletin, lat, lon):
    points = _track(bulletin)
    radius = strong_wind_radius(bulletin)
    gust = bulletin["intensity"].get("gustsKph")
    if gust is None:
        raise WindModelError("the bulletin has no gust speed")
    ratio = gust / points[0][3]

    horizon = int(min(WINDOW_HOURS, points[-1][0]))   # never look past the last forecast point
    winds, closest = [], None
    for hour in range(horizon + 1):
        s_lat, s_lon, vmax = _state_at(points, hour)
        d = distance_km(s_lat, s_lon, lat, lon)
        closest = d if closest is None else min(closest, d)
        winds.append((hour, wind_at(d, vmax, radius)))

    peak = max(w for _, w in winds)
    return LocalImpact(_signal(winds), round(peak), round(peak * ratio), round(closest))