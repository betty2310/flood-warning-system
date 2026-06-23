# ThingsBoard dashboard — Flood Early Warning (Red River)

`flood-dashboard.json` is an importable ThingsBoard **4.x** dashboard (built and
verified against TB 4.3 widget schemas).

## What's inside

- **Mực nước theo thời gian** — water-level time-series for all three stations,
  with dashed **alert lines** at 3.0 m (warning, amber) and 4.0 m (emergency,
  red). `system.time_series_chart`
- **Bản đồ trạm** — OpenStreetMap with the three gauges (Yên Bái → Sơn Tây → Hà
  Nội); markers colored by level (green < 3.0, amber ≥ 3.0, red ≥ 4.0).
  `system.map`
- **RPC controls** — pump / gate / siren switches for each station (9 total) that
  call `setPump` / `setGate` / `setSiren` with a boolean param — exactly what the
  gateway's `rpc_handler` expects. Each switch also reflects the actuator's live
  state from the `pump` / `gate` / `siren` telemetry. `system.single_switch`

## Prerequisites

The dashboard binds to devices **by name** (`station-01/02/03`) and reads the
`latitude` / `longitude` attributes — which exist only after the stack is running
and the gateway has connected to ThingsBoard:

1. `docker compose up -d --build`
2. In TB → **Entities → Devices**, confirm `station-01/02/03` exist and have
   `latitude` / `longitude` (Attributes → client scope) plus live telemetry.

## Import

1. ThingsBoard → **Dashboards** → **+** → **Import dashboard**.
2. Upload `flood-dashboard.json`.
3. Open it — the entity aliases auto-resolve by device name, so there's nothing to
   wire by hand.

## Notes

- **RPC path:** a switch sends a server-side RPC to a station device → TB routes it
  to the gateway (`v1/gateway/rpc`) → the gateway publishes the local actuator
  command. The gateway's automatic rule engine keeps running, so a manual toggle
  can be overridden on the next telemetry tick if the water level dictates.
- **Map base layer:** OpenStreetMap (no API key; needs internet from the browser).
  If tiles don't load, open the widget → Map settings and choose another provider.
- Validated structurally against TB 4.x schemas. If a widget ever shows
  "not found", it's a version nuance — open it and pick the equivalent; the
  datasource/alias is already wired.
- To move a station or change which devices appear, edit the entity aliases here or
  the `latitude` / `longitude` in `sensor/sensor.py`.

# Alarm rule chain — multi-level water-level alarms

`water-level-alarms-rulechain.json` raises a **multi-level alarm** from the
`water_level` telemetry, server-side in ThingsBoard (separate from, and in addition
to, the edge gateway's own events):

- `water_level > 4.0 m` → alarm severity **CRITICAL** (Khẩn cấp)
- `water_level > 3.0 m` → alarm severity **WARNING** (Cảnh báo)
- back to `≤ 3.0 m` → alarm **cleared**

It uses one alarm type, **`Water Level Flood`**, whose severity escalates and
de-escalates with the band (so you get true "nhiều mức" levels on a single alarm),
and stores the triggering `waterLevel` in the alarm details. Alarms are raised
per-station (the device is the alarm originator).

## Import
Rule chains → **+ → Import rule chain** → upload `water-level-alarms-rulechain.json`.

## Wire it in (one node in Root — non-destructive)
This chain only does alarm logic, so your Root chain keeps saving telemetry. Route
telemetry into it:
1. Open the **Root Rule Chain**.
2. Drag in a **Rule Chain** node (Flow group) and select **Water Level Alarms**.
3. Connect the **Message Type Switch** node's **`Post telemetry`** output to it
   (or chain it off the `Save Timeseries` node's `Success` output).
4. Save.

Alternatively, set **Water Level Alarms** as the station **device profile's** rule
chain — but then first add `Save Timeseries` / `Save Client Attributes` nodes to it,
because a device-profile chain *fully replaces* Root for those devices.

## See the alarms
TB top bar → **Alarms**, or add an **Alarms table** widget to the dashboard and
filter by the station devices. The severity column shows Warning vs Critical.

## Tune thresholds
Edit the `Phân loại mực nước` (switch) node's TBEL script — change the `4.0` / `3.0`
values. Keep them aligned with `LEVEL_EMERGENCY` / `LEVEL_WARNING` if you want the TB
alarms to match the edge gateway's events.
