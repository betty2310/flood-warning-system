"""Edge IoT Gateway for the flood early-warning basin.

The most important component. For every station it:
  1. subscribes to all sensor telemetry, validates + normalizes it, and
     computes the water-level rise rate vs. the previous reading;
  2. writes telemetry to InfluxDB and republishes the normalized reading;
  3. runs the rule engine -> emits events (edge-triggered) and sends automatic
     commands to the actuators (only when the desired state changes);
  4. acts as a ThingsBoard Gateway: pushes every station's telemetry to the
     cloud and turns server-side RPC into local MQTT commands.

It also subscribes to actuator status and persists it to InfluxDB.
"""

import json
import os
import time
from datetime import datetime, timezone

import paho.mqtt.client as mqtt
import rules
from influxdb_client import InfluxDBClient, Point, WritePrecision
from influxdb_client.client.write_api import SYNCHRONOUS
from tb_gateway import ThingsBoardGateway

# ---- configuration (all from env, no hard-coded secrets) ----
MQTT_BROKER = os.getenv("MQTT_BROKER", "mosquitto")
MQTT_PORT = int(os.getenv("MQTT_PORT", "1883"))
DEVICE_ID = os.getenv("DEVICE_ID", "flood-gateway")
BASIN_ID = os.getenv("BASIN_ID", "to-lich")
STATIONS = [
    s.strip()
    for s in os.getenv("STATIONS", "station-01,station-02,station-03").split(",")
    if s.strip()
]

INFLUXDB_URL = os.getenv("INFLUXDB_URL", "http://influxdb:8086")
INFLUXDB_TOKEN = os.getenv("INFLUXDB_TOKEN", "flood-edge-token-please-change")
INFLUXDB_ORG = os.getenv("INFLUXDB_ORG", "hust")
INFLUXDB_BUCKET = os.getenv("INFLUXDB_BUCKET", "iot")

TB_HOST = os.getenv("TB_HOST", "").strip()
TB_PORT = int(os.getenv("TB_PORT", "1883"))
TB_GATEWAY_TOKEN = os.getenv("TB_GATEWAY_TOKEN", "").strip()

THRESHOLDS = {
    "level_warning": float(os.getenv("LEVEL_WARNING", "3.0")),
    "level_emergency": float(os.getenv("LEVEL_EMERGENCY", "4.0")),
    "rainfall_advisory": float(os.getenv("RAINFALL_ADVISORY", "40")),
    "turbidity_max": float(os.getenv("TURBIDITY_MAX", "100")),
    "ph_min": float(os.getenv("PH_MIN", "6")),
    "ph_max": float(os.getenv("PH_MAX", "9")),
}

RISE_EPSILON = 0.005  # metres/sample to count the level as "rising"

# ---- per-station runtime state ----
# station -> {prev_level, prev_ts, last_desired, active}
STATE = {}


def now_iso():
    return datetime.now(timezone.utc).isoformat()


# ================================================================
# InfluxDB
# ================================================================
def connect_influxdb():
    """Block until InfluxDB is actually ready, then return a synchronous writer.

    Waiting for health == "pass" avoids losing the first telemetry points while
    the influxdb container is still running its one-time setup.
    """
    while True:
        try:
            client = InfluxDBClient(
                url=INFLUXDB_URL, token=INFLUXDB_TOKEN, org=INFLUXDB_ORG
            )
            health = client.health()
            if health.status == "pass":
                print("InfluxDB health: pass")
                return client.write_api(write_options=SYNCHRONOUS)
            print(f"InfluxDB not ready (health={health.status}); retry in 5s")
        except Exception as exc:
            print(f"Cannot connect to InfluxDB: {exc}; retry in 5s")
        time.sleep(5)


def write_telemetry(write_api, n):
    point = (
        Point("water_telemetry")
        .tag("basin_id", n["basin_id"])
        .tag("station_id", n["station_id"])
        .field("water_level", n["water_level"])
        .field("flow_rate", n["flow_rate"])
        .field("rainfall", n["rainfall"])
        .field("turbidity", n["turbidity"])
        .field("ph", n["ph"])
        .field("rise_rate", n["rise_rate"])
        .time(datetime.now(timezone.utc), WritePrecision.NS)
    )
    write_api.write(bucket=INFLUXDB_BUCKET, org=INFLUXDB_ORG, record=point)


def write_event(write_api, station_id, event):
    point = (
        Point("gateway_events")
        .tag("station_id", station_id)
        .tag("event_type", event["event_type"])
        .tag("severity", event["severity"])
        .field("value", float(event["value"]))
        .field("threshold", float(event["threshold"]))
        .field("action_taken", event["action_taken"])
        .time(datetime.now(timezone.utc), WritePrecision.NS)
    )
    write_api.write(bucket=INFLUXDB_BUCKET, org=INFLUXDB_ORG, record=point)


def write_status(write_api, status):
    point = (
        Point("actuator_status")
        .tag("station_id", status["station_id"])
        .field("pump", status.get("pump", "off"))
        .field("gate", status.get("gate", "closed"))
        .field("siren", status.get("siren", "off"))
        .field("board", status.get("board", "normal"))
        .field("last_command_reason", status.get("last_command_reason", ""))
        .time(datetime.now(timezone.utc), WritePrecision.NS)
    )
    write_api.write(bucket=INFLUXDB_BUCKET, org=INFLUXDB_ORG, record=point)


# ================================================================
# Normalization
# ================================================================
def validate_and_normalize(station_id, data):
    """Return a normalized reading dict, or None if the payload is invalid."""
    required = ["water_level", "flow_rate", "rainfall", "turbidity", "ph"]
    try:
        reading = {k: float(data[k]) for k in required}
    except (KeyError, TypeError, ValueError):
        print(f"[{station_id}] dropped invalid telemetry: {data}")
        return None

    st = STATE.setdefault(
        station_id,
        {"prev_level": None, "prev_ts": None, "last_desired": {}, "active": set()},
    )

    level = reading["water_level"]
    now = time.time()
    rise_rate = 0.0
    rising = False
    if st["prev_level"] is not None:
        delta = level - st["prev_level"]
        dt = max(now - st["prev_ts"], 1e-3)
        rise_rate = round(delta / dt * 60.0, 3)  # metres per minute
        rising = delta > RISE_EPSILON
    st["prev_level"] = level
    st["prev_ts"] = now

    reading.update(
        {
            "device_id": data.get("device_id", "sensor-" + station_id),
            "basin_id": data.get("basin_id", BASIN_ID),
            "station_id": station_id,
            "rise_rate": rise_rate,
            "rising": rising,
            "timestamp": now_iso(),
        }
    )
    return reading


def reason_for(board):
    return {
        "emergency": "water_level_emergency",
        "warning": "water_level_high",
        "advisory": "heavy_rain_rising",
    }.get(board, "normal")


# ================================================================
# MQTT message handling
# ================================================================
def handle_telemetry(client, write_api, tb, station_id, data):
    n = validate_and_normalize(station_id, data)
    if n is None:
        return
    st = STATE[station_id]

    # one-time: forward the station's static location to ThingsBoard as device
    # attributes, so it appears on the map widget (cached + re-sent on reconnect).
    if not st.get("loc_sent"):
        lat, lon = data.get("latitude"), data.get("longitude")
        if lat is not None and lon is not None:
            tb.push_attributes(
                station_id, {"latitude": float(lat), "longitude": float(lon)}
            )
            st["loc_sent"] = True

    # republish normalized reading + persist telemetry
    client.publish(f"basin/{station_id}/gateway/normalized", json.dumps(n))
    try:
        write_telemetry(write_api, n)
    except Exception as exc:
        print(f"[{station_id}] influx telemetry write failed: {exc}")

    # rule engine
    desired, active = rules.evaluate(n, THRESHOLDS)

    # events: only on a rising edge (newly-active condition)
    new_conditions = set(active.keys()) - st["active"]
    for key in new_conditions:
        event = dict(active[key])
        event["station_id"] = station_id
        event["timestamp"] = now_iso()
        client.publish(f"basin/{station_id}/gateway/event", json.dumps(event))
        try:
            write_event(write_api, station_id, event)
        except Exception as exc:
            print(f"[{station_id}] influx event write failed: {exc}")
        print(
            f"[{station_id}] EVENT {event['event_type']} "
            f"({event['severity']}) value={event['value']} thr={event['threshold']}"
        )
    st["active"] = set(active.keys())

    # commands: send only the actuator targets whose desired value changed
    reason = reason_for(desired["board"])
    for target in ("pump", "gate", "siren", "board"):
        if st["last_desired"].get(target) != desired[target]:
            command = {
                "station_id": station_id,
                "target": target,
                "action": desired[target],
                "reason": reason,
                "timestamp": now_iso(),
            }
            client.publish(f"basin/{station_id}/actuator/command", json.dumps(command))
            print(f"[{station_id}] CMD {target}={desired[target]} ({reason})")
    st["last_desired"] = desired

    # uplink to ThingsBoard
    tb.push_telemetry(
        station_id,
        {
            "water_level": n["water_level"],
            "flow_rate": n["flow_rate"],
            "rainfall": n["rainfall"],
            "turbidity": n["turbidity"],
            "ph": n["ph"],
            "rise_rate": n["rise_rate"],
        },
        int(time.time() * 1000),
    )


def handle_status(write_api, tb, station_id, data):
    try:
        write_status(write_api, data)
    except Exception as exc:
        print(f"[{station_id}] influx status write failed: {exc}")
    # mirror actuator state to the cloud
    tb.push_telemetry(
        station_id,
        {
            "pump": data.get("pump", "off"),
            "gate": data.get("gate", "closed"),
            "siren": data.get("siren", "off"),
            "board": data.get("board", "normal"),
        },
        int(time.time() * 1000),
    )


def main():
    write_api = connect_influxdb()

    mqtt_client = mqtt.Client(client_id=DEVICE_ID)

    # ThingsBoard RPC -> local MQTT command
    def rpc_handler(device, method, params):
        mapping = {
            "setPump": ("pump", "on" if params else "off"),
            "setGate": ("gate", "open" if params else "close"),
            "setSiren": ("siren", "on" if params else "off"),
            "setBoard": ("board", str(params)),
        }
        if method not in mapping:
            print(f"[TB] unknown RPC method: {method}")
            return False
        target, action = mapping[method]
        command = {
            "station_id": device,
            "target": target,
            "action": action,
            "reason": f"rpc_{method}",
            "timestamp": now_iso(),
        }
        mqtt_client.publish(f"basin/{device}/actuator/command", json.dumps(command))
        print(f"[TB] RPC applied: {device} {target}={action}")
        return True

    def apply_shared_attributes(attrs):
        global THRESHOLDS
        updated = {}
        for raw_key, raw_val in attrs.items():
            key = str(raw_key).strip().lower()
            if key not in THRESHOLDS:
                continue
            try:
                updated[key] = float(raw_val)
            except (TypeError, ValueError):
                print(f"[TB] ignoring non-numeric threshold {raw_key}={raw_val!r}")
        if not updated:
            return
        THRESHOLDS = {**THRESHOLDS, **updated}
        print(
            f"[TB] thresholds updated from shared attributes: {updated}; "
            f"active now: {THRESHOLDS}"
        )
        tb.push_device_attributes({f"active_{k}": v for k, v in updated.items()})

    tb = ThingsBoardGateway(
        TB_HOST,
        TB_PORT,
        TB_GATEWAY_TOKEN,
        STATIONS,
        rpc_handler,
        attribute_handler=apply_shared_attributes,
        shared_attribute_keys=list(THRESHOLDS.keys()),
    )

    tb.push_device_attributes({f"active_{k}": v for k, v in THRESHOLDS.items()})
    tb.start()

    def on_connect(client, userdata, flags, rc):
        if rc == 0:
            print("Connected to MQTT broker.")
            client.subscribe("basin/+/sensor/telemetry")
            client.subscribe("basin/+/actuator/status")
            print("Subscribed to telemetry + actuator status.")
        else:
            print(f"Failed to connect to MQTT broker. rc={rc}")

    def on_message(client, userdata, message):
        try:
            parts = message.topic.split("/")
            if len(parts) < 4:
                return
            station_id, kind, leaf = parts[1], parts[2], parts[3]
            data = json.loads(message.payload.decode("utf-8"))
            if kind == "sensor" and leaf == "telemetry":
                handle_telemetry(client, write_api, tb, station_id, data)
            elif kind == "actuator" and leaf == "status":
                handle_status(write_api, tb, station_id, data)
        except Exception as exc:
            print(f"Failed to process message on {message.topic}: {exc}")

    mqtt_client.on_connect = on_connect
    mqtt_client.on_message = on_message

    print(
        f"Gateway starting. Stations: {', '.join(STATIONS)}. "
        f"Thresholds (env defaults, tunable via TB shared attributes): {THRESHOLDS}"
    )
    while True:
        try:
            print(f"Connecting to MQTT broker at {MQTT_BROKER}:{MQTT_PORT} ...")
            mqtt_client.connect(MQTT_BROKER, MQTT_PORT, keepalive=60)
            mqtt_client.loop_forever()
        except Exception as exc:
            print(f"MQTT connection error: {exc}; retry in 5s")
            time.sleep(5)


if __name__ == "__main__":
    main()
