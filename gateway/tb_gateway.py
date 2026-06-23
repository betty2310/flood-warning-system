"""ThingsBoard Gateway MQTT client.

Connects to a (self-hosted) ThingsBoard server using the Gateway device's
ACCESS_TOKEN as the MQTT username, then:
  * announces each station as a sub-device      -> v1/gateway/connect
  * pushes per-station telemetry                -> v1/gateway/telemetry
  * sets per-station static attributes          -> v1/gateway/attributes
  * reports the gateway's own client attributes -> v1/devices/me/attributes
  * receives shared-attribute updates + replies <- v1/devices/me/attributes
    to a one-shot read of them (remote alarm        + .../attributes/response/+
    threshold tuning for the gateway device)
  * receives server-side RPC for a sub-device   <- v1/gateway/rpc
  * replies with the RPC result                 -> v1/gateway/rpc

Designed to DEGRADE GRACEFULLY: if TB_HOST or TB_GATEWAY_TOKEN is empty, or the
server is unreachable, the edge stack keeps running and these calls are no-ops.
The connection is established/retried on a background thread so it never blocks
the gateway's local edge processing.
"""

import json
import threading
import time

import paho.mqtt.client as mqtt

CONNECT_TOPIC = "v1/gateway/connect"
TELEMETRY_TOPIC = "v1/gateway/telemetry"
ATTRIBUTES_TOPIC = "v1/gateway/attributes"
RPC_TOPIC = "v1/gateway/rpc"

DEVICE_ATTRIBUTES_TOPIC = "v1/devices/me/attributes"
DEVICE_ATTRIBUTES_REQUEST_TOPIC = "v1/devices/me/attributes/request/"
DEVICE_ATTRIBUTES_RESPONSE_TOPIC = "v1/devices/me/attributes/response/"


class ThingsBoardGateway:
    def __init__(
        self,
        host,
        port,
        token,
        stations,
        rpc_handler,
        attribute_handler=None,
        shared_attribute_keys=None,
    ):
        self.host = host
        self.port = port
        self.token = token
        self.stations = stations
        self.rpc_handler = rpc_handler  # fn(device, method, params) -> bool
        self.attribute_handler = attribute_handler  # fn(shared_attrs: dict) -> None
        self.shared_attribute_keys = list(shared_attribute_keys or [])
        self.enabled = bool(host and token)
        self.connected = False
        self._client = None
        self._attributes = {}  # device -> static attrs, (re)sent on connect
        self._device_attributes = {}  # gateway's own client attrs, (re)sent on connect
        self._attr_request_id = 0  # increments per shared-attr request

    # ---- lifecycle --------------------------------------------------
    def start(self):
        if not self.enabled:
            print(
                "[TB] disabled (TB_HOST or TB_GATEWAY_TOKEN not set) -- "
                "running edge-only, cloud sync off."
            )
            return
        thread = threading.Thread(target=self._connect_loop, daemon=True)
        thread.start()

    def _connect_loop(self):
        self._client = mqtt.Client()
        self._client.username_pw_set(self.token)
        self._client.on_connect = self._on_connect
        self._client.on_disconnect = self._on_disconnect
        self._client.on_message = self._on_message
        while True:
            try:
                print(f"[TB] connecting to {self.host}:{self.port} ...")
                self._client.connect(self.host, self.port, keepalive=60)
                self._client.loop_forever()
            except Exception as exc:
                print(f"[TB] connection error: {exc}; retry in 10s")
                self.connected = False
                time.sleep(10)

    def _on_connect(self, client, userdata, flags, rc):
        if rc == 0:
            self.connected = True
            print("[TB] connected.")
            client.subscribe(RPC_TOPIC)
            # shared-attribute updates + the reply to our one-shot read of them
            client.subscribe(DEVICE_ATTRIBUTES_TOPIC)
            client.subscribe(DEVICE_ATTRIBUTES_RESPONSE_TOPIC + "+")
            for station in self.stations:
                client.publish(CONNECT_TOPIC, json.dumps({"device": station}))
            print(f"[TB] announced sub-devices: {', '.join(self.stations)}")
            # (re)publish cached static attributes (e.g. station location) so the
            # map keeps working across reconnects / first-time device creation.
            for station, attrs in self._attributes.items():
                self._publish_attributes(station, attrs)
            # (re)publish the gateway's own client attributes (e.g. the active
            # thresholds) so the TB device page reflects them across reconnects.
            if self._device_attributes:
                self._publish_device_attributes(self._device_attributes)
            # Pull the current shared thresholds ONCE. TB only pushes updates on
            # change, so without this read the gateway would never learn values
            # an operator set before it connected.
            self._request_shared_attributes()
        else:
            print(f"[TB] connect failed rc={rc}")

    def _on_disconnect(self, client, userdata, rc):
        self.connected = False
        print(f"[TB] disconnected rc={rc}")

    # ---- uplink -----------------------------------------------------
    def push_telemetry(self, station_id, values, ts_ms):
        """Publish one station's telemetry batch to ThingsBoard."""
        if not (self.enabled and self.connected):
            return
        payload = {station_id: [{"ts": ts_ms, "values": values}]}
        try:
            self._client.publish(TELEMETRY_TOPIC, json.dumps(payload))
        except Exception as exc:
            print(f"[TB] telemetry publish failed: {exc}")

    def push_attributes(self, station_id, attrs):
        """Set static (client-side) attributes for a station, e.g. its map location.

        Cached so they survive reconnects: TB persists attributes server-side, but
        re-announcing on connect makes first-time device creation reliable.
        """
        self._attributes[station_id] = {**self._attributes.get(station_id, {}), **attrs}
        self._publish_attributes(station_id, self._attributes[station_id])

    def _publish_attributes(self, station_id, attrs):
        if not (self.enabled and self.connected):
            return
        try:
            self._client.publish(ATTRIBUTES_TOPIC, json.dumps({station_id: attrs}))
        except Exception as exc:
            print(f"[TB] attributes publish failed: {exc}")

    def push_device_attributes(self, attrs):
        """Report the gateway's OWN client-side attributes (e.g. the thresholds
        currently in force), so they're visible on the TB device page. Cached
        and re-sent on reconnect, mirroring push_attributes for sub-devices.

        Note this is the CLIENT scope: it does not collide with, and never
        echoes back as, the SHARED attributes an operator sets remotely.
        """
        self._device_attributes = {**self._device_attributes, **attrs}
        self._publish_device_attributes(self._device_attributes)

    def _publish_device_attributes(self, attrs):
        if not (self.enabled and self.connected):
            return
        try:
            self._client.publish(DEVICE_ATTRIBUTES_TOPIC, json.dumps(attrs))
        except Exception as exc:
            print(f"[TB] device attributes publish failed: {exc}")

    # ---- downlink (shared attributes) -------------------------------
    def _request_shared_attributes(self):
        """Ask TB for the current value of the shared attributes we care about.

        Pushes on DEVICE_ATTRIBUTES_TOPIC only fire on CHANGE, so this one-shot
        request is what loads values an operator set before the gateway started.
        The reply arrives on .../response/<id> and is handled like a push.
        """
        if not (self.enabled and self.connected and self.shared_attribute_keys):
            return
        self._attr_request_id += 1
        topic = DEVICE_ATTRIBUTES_REQUEST_TOPIC + str(self._attr_request_id)
        payload = {"sharedKeys": ",".join(self.shared_attribute_keys)}
        try:
            self._client.publish(topic, json.dumps(payload))
            print(
                f"[TB] requested current shared attributes: {self.shared_attribute_keys}"
            )
        except Exception as exc:
            print(f"[TB] shared-attr request failed: {exc}")

    # ---- downlink (RPC) ---------------------------------------------
    def _on_message(self, client, userdata, message):
        """Route one inbound message to the RPC or shared-attribute handler."""
        topic = message.topic
        try:
            payload = json.loads(message.payload.decode("utf-8"))
        except Exception as exc:
            print(f"[TB] bad payload on {topic}: {exc}")
            return
        if topic == RPC_TOPIC:
            self._handle_rpc(client, payload)
        elif topic == DEVICE_ATTRIBUTES_TOPIC or topic.startswith(
            DEVICE_ATTRIBUTES_RESPONSE_TOPIC
        ):
            self._handle_attribute_update(payload)

    def _handle_rpc(self, client, req):
        try:
            device = req.get("device")
            data = req.get("data", {})
            rpc_id = data.get("id")
            method = data.get("method")
            params = data.get("params")
            print(f"[TB] RPC <- device={device} method={method} params={params}")

            success = False
            try:
                success = bool(self.rpc_handler(device, method, params))
            except Exception as exc:
                print(f"[TB] rpc_handler error: {exc}")

            reply = {"device": device, "id": rpc_id, "data": {"success": success}}
            client.publish(RPC_TOPIC, json.dumps(reply))
            print(f"[TB] RPC -> reply {reply}")
        except Exception as exc:
            print(f"[TB] failed to handle RPC: {exc}")

    def _handle_attribute_update(self, payload):
        """Normalize both message shapes to a flat dict of shared attrs, then
        hand them to attribute_handler:

          * push update   (v1/devices/me/attributes)            {"key": val, ...}
          * request reply (.../attributes/response/<id>)        {"shared": {...},
                                                                 "client": {...}}
        """
        if not isinstance(payload, dict):
            return
        if "shared" in payload or "client" in payload:
            attrs = dict(payload.get("shared") or {})
        else:
            attrs = payload
        if not attrs:
            return
        print(f"[TB] shared attributes <- {attrs}")
        if self.attribute_handler:
            try:
                self.attribute_handler(attrs)
            except Exception as exc:
                print(f"[TB] attribute_handler error: {exc}")
