"""Virtual flood-control actuator for one station.

Subscribes to the station command topic, applies commands to four devices
(pump, gate, siren, alert board) and republishes the full status. It also
emits a periodic status heartbeat so the gateway can persist actuator_status
to InfluxDB continuously (not only when a command arrives).

Commands (from gateway auto-control OR manual REST/ThingsBoard RPC):
    {"station_id","target","action","reason","timestamp"}
    target  in {pump, gate, siren, board}
    action  pump/siren: on|off   gate: open|close   board: <severity word>
"""

import json
import os
import threading
import time
from datetime import datetime, timezone

import paho.mqtt.client as mqtt


STATION_ID = os.getenv("STATION_ID", "station-01")
DEVICE_ID = os.getenv("DEVICE_ID", "actuator-" + STATION_ID)
MQTT_BROKER = os.getenv("MQTT_BROKER", "mosquitto")
MQTT_PORT = int(os.getenv("MQTT_PORT", "1883"))
STATUS_INTERVAL = float(os.getenv("STATUS_INTERVAL", "10"))

COMMAND_TOPIC = f"basin/{STATION_ID}/actuator/command"
STATUS_TOPIC = f"basin/{STATION_ID}/actuator/status"

state_lock = threading.Lock()
state = {
    "pump": "off",
    "gate": "closed",
    "siren": "off",
    "board": "normal",
    "last_command_reason": "init",
}


def apply_command(target, action):
    """Update a single device's state from a command action."""
    action = str(action).lower()
    if target == "pump":
        state["pump"] = "on" if action in ("on", "true", "open") else "off"
    elif target == "gate":
        state["gate"] = "open" if action in ("open", "on", "true") else "closed"
    elif target == "siren":
        state["siren"] = "on" if action in ("on", "true") else "off"
    elif target == "board":
        # board carries a severity word: normal/advisory/warning/emergency
        state["board"] = action
    else:
        print(f"Unknown actuator target: {target}")
        return False
    return True


def build_status():
    return {
        "device_id": DEVICE_ID,
        "station_id": STATION_ID,
        "pump": state["pump"],
        "gate": state["gate"],
        "siren": state["siren"],
        "board": state["board"],
        "last_command_reason": state["last_command_reason"],
        "timestamp": datetime.now(timezone.utc).isoformat(),
    }


def publish_status(client):
    with state_lock:
        payload = build_status()
    client.publish(STATUS_TOPIC, json.dumps(payload))
    print(f"Status: pump={payload['pump']} gate={payload['gate']} "
          f"siren={payload['siren']} board={payload['board']} "
          f"reason={payload['last_command_reason']}")


def on_connect(client, userdata, flags, rc):
    if rc == 0:
        print("Connected to MQTT broker.")
        client.subscribe(COMMAND_TOPIC)
        print(f"Subscribed to: {COMMAND_TOPIC}")
        publish_status(client)            # announce initial state
    else:
        print(f"Failed to connect to MQTT broker. Return code: {rc}")


def on_message(client, userdata, message):
    try:
        command = json.loads(message.payload.decode("utf-8"))
        target = command.get("target")
        action = command.get("action")
        reason = command.get("reason", "manual")
        print(f"Command received: target={target} action={action} reason={reason}")

        with state_lock:
            changed = apply_command(target, action)
            if changed:
                state["last_command_reason"] = reason

        publish_status(client)            # echo new state immediately
    except Exception as exc:
        print(f"Failed to process command: {exc}")


def main():
    client = mqtt.Client(client_id=DEVICE_ID)
    client.on_connect = on_connect
    client.on_message = on_message

    while True:
        try:
            print(f"Connecting to MQTT broker at {MQTT_BROKER}:{MQTT_PORT} ...")
            client.connect(MQTT_BROKER, MQTT_PORT, keepalive=60)
            break
        except Exception as exc:
            print(f"Connection failed: {exc}")
            print("Retrying in 5 seconds ...")
            time.sleep(5)

    client.loop_start()

    # Periodic heartbeat so actuator_status is continuously recorded.
    while True:
        time.sleep(STATUS_INTERVAL)
        try:
            publish_status(client)
        except Exception as exc:
            print(f"Heartbeat publish failed: {exc}")


if __name__ == "__main__":
    main()
