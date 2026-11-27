# Flood hazard data

`noah_flood_100yr_*.geojson` are derived from the UP NOAH Center flood hazard
maps (100-year rain return period), produced by PAGASA and published by UP NOAH
(https://noah.up.edu.ph) under the Open Data Commons Open Database License
(ODbL) 1.0: https://opendatacommons.org/licenses/odbl/1-0/

Derived by NIMBUS and shared under the same license (ODbL 1.0). Changes:
clipped to a box around the town, polygons and holes smaller than 5,000 m²
removed, and shapes simplified (mapshaper, 10% weighted). Attribute `Var`:
1 = low (0–0.5 m), 2 = medium (>0.5–1.5 m), 3 = high (>1.5 m). Hazard levels
also account for flow velocity.

These maps show where flooding is likely in very heavy rain. They are not live
flood reports.

Source files used: `Flood/100yr/Batangas.zip` from the NOAH hazard map
collection (mirror: https://huggingface.co/datasets/Siesta-22/project-noah-hazard-maps).
