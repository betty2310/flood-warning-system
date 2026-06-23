"""Virtual water-monitoring station sensor (correlated basin scenario).

Simulates one observation station on the Red River basin. All stations share ONE
basin storm driven by the wall clock: each station reads that same storm offset by
its travel-time LAG, so the flood wave marches downstream (st1 -> st2 -> st3) and
accumulates to a higher crest as it travels. The correlation is pure shared-clock
+ lag -- there is no messaging between stations and no coordinator.

    rain (one basin storm) --lag--> level INTEGRATES rain minus drainage and
    floats toward a per-station PEAK. This is a MAJOR-STORM scenario: every station
    crosses the EMERGENCY threshold, staggered downstream so the wave and the
    rising severity stay visible:
        station-01 (upstream,  Yen Bai) peak ~4.8 m -> EMERGENCY (just over)
        station-02 (midstream, Son Tay) peak ~5.5 m -> EMERGENCY
        station-03 (downstream, Ha Noi) peak ~6.2 m -> EMERGENCY (biggest crest)

    The heavy-rain plateau is NOT flat: a slow, mean-reverting rainfall GUST
    (random walk) makes each storm surge and lull, so the level wobbles around its
    peak every cycle instead of pinning to a clamp.

Each container instance is one station, selected purely by STATION_ID. The shared
storm knobs (loop period, peak rain, gust, epoch) come from env so the whole
scenario can be retuned without code changes.
"""

import json
import os
import random
import time
from datetime import datetime, timezone

import paho.mqtt.client as mqtt

BASIN_ID = os.getenv("BASIN_ID", "red-river")
STATION_ID = os.getenv("STATION_ID", "station-01")
DEVICE_ID = os.getenv("DEVICE_ID", "sensor-" + STATION_ID)
MQTT_BROKER = os.getenv("MQTT_BROKER", "mosquitto")
MQTT_PORT = int(os.getenv("MQTT_PORT", "1883"))
PUBLISH_INTERVAL = float(os.getenv("PUBLISH_INTERVAL", "2"))

TOPIC = f"basin/{STATION_ID}/sensor/telemetry"

# ---- Shared basin storm (one storm for the whole basin) ----
# A recurring trapezoid driven by the wall clock, so every container stays in
# lockstep without any coordination: they all evaluate the same phase of the same
# cycle, just shifted by their own lag.
LOOP_PERIOD = float(os.getenv("LOOP_PERIOD", "300"))  # seconds per storm cycle
PEAK_RAIN = float(os.getenv("PEAK_RAIN", "65"))  # mm at the storm plateau (> advisory)
SCENARIO_EPOCH = float(
    os.getenv("SCENARIO_EPOCH", "0")
)  # shared t0; align for a clean cold start
DRAINAGE_K = float(
    os.getenv("DRAINAGE_K", "0.25")
)  # response rate: how fast the level tracks rain (rise) and recedes toward base.
# Must be fast enough (time constant tau ~ PUBLISH_INTERVAL/K seconds, << the
# plateau) that the level REACHES its peak and HOLDS during the rain plateau,
# instead of lagging into a rounded triangle that never gets there.

# Rainfall gust: a slow, mean-reverting random walk added on top of the storm so
# the heavy-rain plateau surges and lulls (never a flat line). It is scaled by the
# storm intensity, so it only shows while it is actually raining. Per-container
# (each station gusts independently -- realistic local rain cells); the macro wave
# still stays correlated via the shared clock. Slow enough (GUST_REVERT small) that
# the level integrator can follow it, so the wobble is visible -- not smoothed away.
GUST_MM = float(os.getenv("GUST_MM", "10"))  # max gust amplitude (+/- mm)
GUST_VOL = float(os.getenv("GUST_VOL", "2.2"))  # per-tick volatility of the walk
GUST_REVERT = float(
    os.getenv("GUST_REVERT", "0.10")
)  # 0..1 mean-reversion; higher = shorter, choppier gusts

# Storm shape as fractions of LOOP_PERIOD: calm -> rising -> heavy plateau -> receding.
# Calm is the largest slice so each storm reads as a DISCRETE event -- a clear quiet
# baseline, then a rise, a wobbling plateau, a recede -- instead of back-to-back waves
# with no gap. Keep CALM's fraction comfortably above the largest station lag below,
# or the downstream station is still flooding when the next storm's calm should show.
# (At 120 s this is 36 / 18 / 36 / 30 s; at 300 s, 90 / 45 / 90 / 75 s.)
CALM = 0.30 * LOOP_PERIOD
RISING = 0.15 * LOOP_PERIOD
PLATEAU = 0.30 * LOOP_PERIOD
RECEDING = LOOP_PERIOD - CALM - RISING - PLATEAU

# ---- Basin topology: one coherent table for the whole river ----
# Every station reads the SAME storm, offset by its travel-time `lag`, and integrates
# it so the level floats toward its own `peak` at sustained peak rain. `peak` fixes
# the crest (and thus the severity band); the inflow `gain` is DERIVED from it in
# main(), so you only ever tune the crest you want to see.
#   lag       : travel-time delay as a FRACTION of LOOP_PERIOD (NOT seconds), so the
#               wave marches at the same visible pace at any cycle length. (Absolute
#               seconds, e.g. 60s on a 120s loop = half a cycle, push the downstream
#               station to the OPPOSITE phase -- it looks anti-correlated, not like a
#               wave. Keep the max lag well under CALM's fraction.)
#   base      : resting water level (m) -- higher downstream (bigger river stage)
#   peak      : crest water level (m) at sustained peak rain -- the severity ceiling
#   cap       : hard safety clamp (m), well above peak; physics keeps level < cap
#   lat, lon  : real gauge position on the Red River (for the ThingsBoard map)
# Major-storm scenario: every peak is above the 4.0 m emergency threshold, staggered
# upstream->downstream so the wave AND the rising crest are both readable -- the storm
# hits st1 first, then st2, then st3 (each higher), and recedes in the same order.
BASIN = {
    "station-01": {
        "name": "Yên Bái",
        "role": "upstream",
        "lat": 21.7050,
        "lon": 104.8690,
        "lag": 0.0,  # head of the wave (fraction of LOOP_PERIOD)
        "base": 1.0,
        "peak": 4.8,
        "cap": 6.5,
    },
    "station-02": {
        "name": "Sơn Tây",
        "role": "midstream",
        "lat": 21.1480,
        "lon": 105.5040,
        "lag": 0.06,  # ~6% of a cycle behind st1
        "base": 1.5,
        "peak": 5.5,
        "cap": 7.5,
    },
    "station-03": {
        "name": "Hà Nội",
        "role": "downstream",
        "lat": 21.0430,
        "lon": 105.8600,
        "lag": 0.12,  # ~12% of a cycle behind st1 (downstream tail)
        "base": 2.0,
        "peak": 6.2,
        "cap": 8.5,
    },
}
STATION = BASIN.get(STATION_ID, BASIN["station-01"])


def storm_intensity(phase):
    """Return the 0..1 storm strength at this point in the cycle.

    `phase` is seconds into the LOOP_PERIOD cycle (already lag-shifted by caller):
    calm -> rising -> heavy plateau -> receding. The caller turns this into mm of
    rain (PEAK_RAIN * intensity) and adds the gust.
    """
    if phase < CALM:
        return 0.0
    if phase < CALM + RISING:
        return (phase - CALM) / RISING  # ramp up 0 -> 1
    if phase < CALM + RISING + PLATEAU:
        return 1.0  # sustained heavy rain
    return max(0.0, 1.0 - (phase - CALM - RISING - PLATEAU) / RECEDING)  # ramp down


def make_reading(level, rainfall):
    """Derive correlated flow, turbidity and pH for the current level/rain."""
    flow_rate = round(2.0 * level + 0.05 * rainfall + random.uniform(-0.5, 0.5), 2)
    turbidity = round(20.0 + 1.2 * rainfall + random.uniform(-5.0, 8.0), 1)

    # pH normally near neutral; occasionally drift abnormal to exercise the
    # water-quality rule on the gateway.
    ph = round(random.gauss(7.1, 0.2), 2)
    roll = random.random()
    if roll < 0.04:
        ph = round(random.uniform(5.2, 5.9), 2)  # acidic anomaly
    elif roll < 0.08:
        ph = round(random.uniform(9.1, 9.6), 2)  # alkaline anomaly

    return flow_rate, max(turbidity, 0.0), ph


def connect_mqtt_client():
    client = mqtt.Client(client_id=DEVICE_ID)
    while True:
        try:
            print(f"Connecting to MQTT broker at {MQTT_BROKER}:{MQTT_PORT} ...")
            client.connect(MQTT_BROKER, MQTT_PORT, keepalive=60)
            print("Connected to MQTT broker.")
            return client
        except Exception as exc:
            print(f"Connection failed: {exc}")
            print("Retrying in 5 seconds ...")
            time.sleep(5)


def main():
    client = connect_mqtt_client()
    # Inflow gain DERIVED from the crest: at sustained peak rain the level settles
    # at `peak` (base + gain*PEAK_RAIN/DRAINAGE_K == peak). So tune the crest in the
    # BASIN table, never gain. cap stays a far-above safety clamp, so the level
    # FLOATS near peak (and wobbles with the gust) instead of pinning to a flat line.
    gain = (STATION["peak"] - STATION["base"]) * DRAINAGE_K / PEAK_RAIN
    lag = STATION["lag"] * LOOP_PERIOD  # travel-time delay: fraction of cycle -> seconds
    print(
        f"[{STATION_ID}] {STATION['name']} ({STATION['role']}) "
        f"lag={lag:.0f}s base={STATION['base']} peak={STATION['peak']} "
        f"-> {TOPIC}"
    )

    level = STATION["base"]
    gust = 0.0  # rainfall gust state: slow, mean-reverting random walk (mm)

    while True:
        try:
            # Where this station is in the shared storm cycle right now. Driving
            # this off the wall clock keeps all stations correlated with no IPC.
            phase = (time.time() - SCENARIO_EPOCH - lag) % LOOP_PERIOD
            intensity = storm_intensity(phase)

            # Gust random walk: heavy rain surges and lulls instead of holding a
            # flat plateau. Scaled by intensity so it vanishes when it's not raining.
            gust += -GUST_REVERT * gust + random.gauss(0.0, GUST_VOL)
            gust = max(-GUST_MM, min(gust, GUST_MM))
            rainfall = PEAK_RAIN * intensity + gust * intensity + random.uniform(0.0, 2.0)
            rainfall = round(max(rainfall, 0.0), 1)

            # Integrate: rain raises the level, drainage pulls it back to base, so
            # the level floats toward `peak` and wobbles with the gust.
            level += gain * rainfall - DRAINAGE_K * (level - STATION["base"])
            level += random.uniform(-0.02, 0.02)
            level = max(STATION["base"] - 0.1, min(level, STATION["cap"]))

            flow_rate, turbidity, ph = make_reading(level, rainfall)

            payload = {
                "device_id": DEVICE_ID,
                "basin_id": BASIN_ID,
                "station_id": STATION_ID,
                "station_name": STATION["name"],
                "latitude": STATION["lat"],
                "longitude": STATION["lon"],
                "water_level": round(level, 2),
                "flow_rate": flow_rate,
                "rainfall": rainfall,
                "turbidity": turbidity,
                "ph": ph,
                "timestamp": datetime.now(timezone.utc).isoformat(),
            }

            result = client.publish(TOPIC, json.dumps(payload))
            if result.rc == mqtt.MQTT_ERR_SUCCESS:
                print(
                    f"Published: water_level={payload['water_level']} "
                    f"rainfall={rainfall} turbidity={turbidity} ph={ph}"
                )
            else:
                print(f"Failed to publish. Error code: {result.rc}")

            time.sleep(PUBLISH_INTERVAL)
        except Exception as exc:
            print(f"Runtime error: {exc}")
            client = connect_mqtt_client()


if __name__ == "__main__":
    main()
