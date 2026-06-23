# Correlated Red River flood scenario

Replaces the old per-station random `PROFILE` model with one **correlated basin
scenario**: a single storm drives the whole basin, and the flood wave propagates
downstream (`st1 → st2 → st3`), accumulating to a higher peak and a higher
severity as it goes. This is the textbook early-warning story — the upstream
gauge fires an advisory before the city floods.

## Model

- **One basin storm**: a recurring trapezoid (calm → rising → plateau →
  receding), driven by the **wall clock** so every container stays in lockstep
  with no coordinator and no inter-station messaging.
- Each station reads that same storm **offset by its travel-time `lag`**, then
  integrates it into water level with its own `base` / `cap` / `gain`:

  ```
  phase    = (now − SCENARIO_EPOCH − lag) % LOOP_PERIOD
  rainfall = storm(phase)
  level   += gain·rainfall − DRAINAGE_K·(level − base);   clamp to [base, cap]
  ```

- The **`cap` fixes the severity band** deterministically; `gain` only sets how
  fast the level climbs to the cap. Thresholds are global (warning > 3.0 m,
  emergency > 4.0 m, rain advisory > 40 mm) — stations differ by physics, not by
  rules.

## Basin topology (`BASIN` table in `sensor/sensor.py`)

| station    | gauge   | role       | lag   | base  | cap   | gain  | peak severity        |
|------------|---------|------------|-------|-------|-------|-------|----------------------|
| station-01 | Yên Bái | upstream   | 0 s   | 1.0 m | 2.6 m | 0.003 | ADVISORY (rain only) |
| station-02 | Sơn Tây | midstream  | +30 s | 1.5 m | 3.6 m | 0.004 | WARNING              |
| station-03 | Hà Nội  | downstream | +60 s | 2.0 m | 4.8 m | 0.006 | EMERGENCY            |

## Shared knobs (`.env`)

`LOOP_PERIOD=300`, `PEAK_RAIN=65` (must exceed `RAINFALL_ADVISORY`),
`SCENARIO_EPOCH=0`, `DRAINAGE_K=0.04`, `PUBLISH_INTERVAL=2`.

## What you see each 300 s loop

1. ~75–110 s: st1 rain crosses 40 mm while rising → **st1 ADVISORY** (early warning).
2. +30 s / +60 s: the advisory, then the rising level, reach st2 then st3.
3. st2 level crosses 3.0 m → **st2 WARNING** (pump + gate open).
4. st3 level crosses 4.0 m → **st3 EMERGENCY** (pump + gate + siren).
5. Everything recedes in the same order, then the cycle repeats.

Lead time from st1 advisory to st3 emergency ≈ **60 s** — it equals st3's `lag`,
because st1's advisory and st3's emergency fall at about the same point in the
storm. Want more warning time? Increase the downstream `lag`.

## Tuning

- **Spread the wave** → increase the per-station `lag`.
- **Who floods worst / which band** → change `cap` (it defines the band).
- **Rise speed / curve shape** → change `gain` (higher = steeper climb to cap).
- **Storm size / pace** → `PEAK_RAIN`, `LOOP_PERIOD`.
- **Clean cold start** → set `SCENARIO_EPOCH` near launch time so the loop begins
  in the calm phase.

## Notes

- Correlation is pure shared-clock + lag; there is **no coupling** between
  containers. Consequence: the rainfall trace also appears to travel downstream
  (at the river's pace), not just the water level — chosen for simplicity/clarity.
- Container restarts **resync** to basin phase (no per-container storm restart).
- Unchanged: rule engine, actuators, flood-api, and all thresholds. The gateway
  gained one small thing — forwarding station location to ThingsBoard (below).

## Geolocation & the ThingsBoard map

Each station carries its real Red River gauge position so the stations can be
plotted on a ThingsBoard map widget.

| station    | gauge   | latitude | longitude |
|------------|---------|----------|-----------|
| station-01 | Yên Bái | 21.7050  | 104.8690  |
| station-02 | Sơn Tây | 21.1480  | 105.5040  |
| station-03 | Hà Nội  | 21.0430  | 105.8600  |

**Data path:** the sensor includes `latitude` / `longitude` in its telemetry; the
gateway forwards them to ThingsBoard **once per station as device attributes** (via
`v1/gateway/attributes`), cached and re-sent on reconnect. Static position lives in
attributes (not time-series), so it never clutters the telemetry history while you
can still color markers by the latest `water_level`.

**Dashboard setup (ThingsBoard):**
1. Add a **Map** widget (e.g. *Maps → OpenStreetMap*).
2. Entity alias: all three station devices (`station-01/02/03`).
3. Map settings → position keys: `latitude` / `longitude` (attribute scope).
4. Optional: color markers by severity with a marker-color function on the latest
   `water_level` (e.g. red > 4.0 m, amber > 3.0 m, else green).

Coordinates live in the `BASIN` table in `sensor/sensor.py` — edit there to move a
station.
