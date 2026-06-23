"""REST API for the flood early-warning system (FastAPI).

Read side is dead-simple: everything is queried from InfluxDB (the edge
source of truth written by the gateway). The only write is POST /command,
which publishes to the actuator command topic over MQTT -- the actuators'
sole control plane -- so a manual command behaves exactly like a gateway or
ThingsBoard command.

Endpoints (per PRD):
    GET  /health
    GET  /stations
    GET  /stations/{station_id}/state
    GET  /stations/{station_id}/events
    POST /stations/{station_id}/command
"""

import json
import os
from contextlib import asynccontextmanager
from datetime import datetime, timezone

import paho.mqtt.client as mqtt
from fastapi import FastAPI, HTTPException
from influxdb_client import InfluxDBClient
from pydantic import BaseModel


MQTT_BROKER = os.getenv("MQTT_BROKER", "mosquitto")
MQTT_PORT = int(os.getenv("MQTT_PORT", "1883"))

INFLUXDB_URL = os.getenv("INFLUXDB_URL", "http://influxdb:8086")
INFLUXDB_TOKEN = os.getenv("INFLUXDB_TOKEN", "flood-edge-token-please-change")
INFLUXDB_ORG = os.getenv("INFLUXDB_ORG", "hust")
INFLUXDB_BUCKET = os.getenv("INFLUXDB_BUCKET", "iot")

STATIONS = [s.strip() for s in os.getenv("STATIONS", "station-01,station-02,station-03").split(",") if s.strip()]
VALID_TARGETS = {"pump", "gate", "siren", "board"}

ctx = {}  # holds influx_client, query_api, mqtt_client


@asynccontextmanager
async def lifespan(app: FastAPI):
    influx = InfluxDBClient(url=INFLUXDB_URL, token=INFLUXDB_TOKEN, org=INFLUXDB_ORG)
    ctx["influx"] = influx
    ctx["query"] = influx.query_api()

    client = mqtt.Client(client_id="flood-api")
    try:
        client.connect(MQTT_BROKER, MQTT_PORT, keepalive=60)
        client.loop_start()
    except Exception as exc:
        print(f"MQTT connect failed (commands disabled until broker is up): {exc}")
    ctx["mqtt"] = client

    yield

    client.loop_stop()
    influx.close()


app = FastAPI(title="Flood Early-Warning REST API", version="1.0.0", lifespan=lifespan)


# ----------------------------------------------------------------
# InfluxDB query helpers
# ----------------------------------------------------------------
def _latest(measurement, station_id, since="-1h"):
    """Return the most recent record (all fields pivoted) or None."""
    flux = f'''
from(bucket: "{INFLUXDB_BUCKET}")
  |> range(start: {since})
  |> filter(fn: (r) => r._measurement == "{measurement}" and r.station_id == "{station_id}")
  |> pivot(rowKey: ["_time"], columnKey: ["_field"], valueColumn: "_value")
  |> sort(columns: ["_time"], desc: true)
  |> limit(n: 1)
'''
    tables = ctx["query"].query(org=INFLUXDB_ORG, query=flux)
    for table in tables:
        for record in table.records:
            return record.values
    return None


def _clean(values):
    """Strip Influx bookkeeping columns from a record dict."""
    if not values:
        return None
    drop = {"result", "table", "_start", "_stop", "_measurement"}
    out = {k: v for k, v in values.items() if k not in drop}
    if "_time" in out:
        out["timestamp"] = out.pop("_time").isoformat()
    return out


def station_state(station_id):
    telemetry = _clean(_latest("water_telemetry", station_id))
    status = _clean(_latest("actuator_status", station_id))
    return {"station_id": station_id, "telemetry": telemetry, "actuator": status}


# ----------------------------------------------------------------
# Routes
# ----------------------------------------------------------------
@app.get("/health")
def health():
    try:
        h = ctx["influx"].health()
        influx_ok = h.status == "pass"
    except Exception as exc:
        return {"status": "degraded", "influxdb": f"error: {exc}"}
    return {"status": "ok" if influx_ok else "degraded", "influxdb": "up" if influx_ok else "down"}


@app.get("/stations")
def list_stations():
    out = []
    for station_id in STATIONS:
        telemetry = _clean(_latest("water_telemetry", station_id))
        status = _clean(_latest("actuator_status", station_id))
        out.append({
            "station_id": station_id,
            "water_level": telemetry.get("water_level") if telemetry else None,
            "board": status.get("board") if status else None,
        })
    return {"stations": out}


@app.get("/stations/{station_id}/state")
def get_state(station_id: str):
    if station_id not in STATIONS:
        raise HTTPException(status_code=404, detail=f"unknown station {station_id}")
    return station_state(station_id)


@app.get("/stations/{station_id}/events")
def get_events(station_id: str, limit: int = 50, hours: int = 24):
    if station_id not in STATIONS:
        raise HTTPException(status_code=404, detail=f"unknown station {station_id}")
    flux = f'''
from(bucket: "{INFLUXDB_BUCKET}")
  |> range(start: -{hours}h)
  |> filter(fn: (r) => r._measurement == "gateway_events" and r.station_id == "{station_id}")
  |> pivot(rowKey: ["_time"], columnKey: ["_field"], valueColumn: "_value")
  |> sort(columns: ["_time"], desc: true)
  |> limit(n: {limit})
'''
    events = []
    for table in ctx["query"].query(org=INFLUXDB_ORG, query=flux):
        for record in table.records:
            events.append(_clean(record.values))
    return {"station_id": station_id, "count": len(events), "events": events}


class CommandBody(BaseModel):
    target: str
    action: str
    reason: str = "manual_api"


@app.post("/stations/{station_id}/command")
def send_command(station_id: str, body: CommandBody):
    if station_id not in STATIONS:
        raise HTTPException(status_code=404, detail=f"unknown station {station_id}")
    if body.target not in VALID_TARGETS:
        raise HTTPException(status_code=400, detail=f"target must be one of {sorted(VALID_TARGETS)}")

    command = {
        "station_id": station_id,
        "target": body.target,
        "action": body.action,
        "reason": body.reason,
        "timestamp": datetime.now(timezone.utc).isoformat(),
    }
    topic = f"basin/{station_id}/actuator/command"
    result = ctx["mqtt"].publish(topic, json.dumps(command))
    if result.rc != mqtt.MQTT_ERR_SUCCESS:
        raise HTTPException(status_code=503, detail="failed to publish command to MQTT")
    return {"published": True, "topic": topic, "command": command}
