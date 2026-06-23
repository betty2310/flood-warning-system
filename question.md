# 12. Design rationale (the required report questions)

<details>
<summary>Click to expand — the 8 questions the assignment asks you to answer</summary>

1. **Why process flood warnings at the edge, not the cloud?** Flooding is
   safety-critical and time-sensitive. The edge gateway actuates the
   pump/gate/siren in **milliseconds**, independent of the WAN link; if
   connectivity to the centre drops, local protection keeps working.
2. **How is the topic / message format designed?** A hierarchical
   `basin/<station>/<role>/<leaf>` scheme with compact JSON. It scales per
   station, enables wildcard subscriptions (`basin/+/sensor/telemetry`), and
   cleanly separates telemetry / command / status / event streams.
3. **How does the rule engine tier alerts?** Three severities — _advisory_
   (heavy rain while rising), _warning_ (level > 3.0 → pump/gate), _emergency_
   (level > 4.0 → + siren) — plus a water-quality warning. State is
   **declarative**, so actions reverse automatically as conditions clear.
4. **What happens when the level exceeds a threshold?** telemetry → gateway
   normalizes + computes rise rate → rule engine fires → event published &
   stored → automatic command to the actuator → actuator updates & re-publishes
   status → stored & shown in Grafana → mirrored to ThingsBoard.
5. **How is the gateway a ThingsBoard Gateway?** It connects once with a Gateway
   token and multiplexes many sub-devices over `v1/gateway/connect` /
   `v1/gateway/telemetry`, subscribes to `v1/gateway/rpc`, and translates each
   server RPC (`setPump`, …) into a local MQTT command, replying with the result.
6. **Why still push to the cloud if the edge already handles it?** For
   basin-/city-wide situational awareness, cross-station correlation, long-term
   history, remote operator control, alarms/notifications, and maps no single
   edge node can provide.
7. **Why shouldn't containers use `localhost` to call each other?** Each
   container has its own network namespace, so `localhost` means _that
   container_. On the shared Docker network, services resolve each other by
   **service name** (`mosquitto`, `influxdb`).
8. **What's needed to scale to a whole city on ThingsBoard?** More edge gateways
   (one per zone), an **asset hierarchy** (city → basin → station) with device
   profiles + shared attributes for thresholds, map-based dashboards,
   tenant/customer separation, and centralized alarm rule chains.

</details>

---
