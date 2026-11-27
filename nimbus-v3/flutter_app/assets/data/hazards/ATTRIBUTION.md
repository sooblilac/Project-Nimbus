# Hazard map data

The `noah_*.geojson` files are derived from the UP NOAH Center hazard maps,
produced by PAGASA / MGB and published by UP NOAH (https://noah.up.edu.ph) under
the Open Data Commons Open Database License (ODbL) 1.0:
https://opendatacommons.org/licenses/odbl/1-0/

Derived by NIMBUS and shared under the same license (ODbL 1.0). Changes: clipped
to a box about 13 km around each town, polygons and holes smaller than 5,000 m²
removed, shapes simplified (mapshaper, 10% weighted), and the hazard level field
renamed to `Var`: 1 = low, 2 = medium, 3 = high.

| File | Hazard | Source collection |
|---|---|---|
| `noah_flood_100yr_*`, `noah_flood_*` | Flood, 100-year rain return period | `Flood/100yr/<Province>.zip` |
| `noah_landslide_*` | Landslide susceptibility (field `LH`) | `Landslide/LandslideHazards/<Province>.zip` |
| `noah_surge_*` | Storm surge, Storm Surge Advisory 4 (worst case; field `HAZ`) | `Storm Surge/StormSurgeAdvisory4/<Province>.zip` |

Towns: 0401005000 Batangas City and 0401019000 Nasugbu (Batangas), 0200901000
Basco (Batanes). Mirror used: https://huggingface.co/datasets/Siesta-22/project-noah-hazard-maps

These maps show where hazards are likely. They are not live reports.
