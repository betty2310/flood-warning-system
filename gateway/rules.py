"""Flood early-warning rule engine (pure logic, no I/O).

Given one station's normalized reading and the configured thresholds, decide:
  1. desired  -> the target state for the 4 actuators (declarative: recomputed
                 every tick, so devices switch OFF again once water recedes).
  2. active   -> the alarm conditions currently true, each with an event payload.
                 The gateway turns these into events on a rising edge (a newly
                 active condition) so events are not re-emitted every tick.

Implements the four mandatory PRD rules with advisory/warning/emergency levels:
  R1  water_level > LEVEL_WARNING    -> pump on, gate open, board warning   (flood_warning / warning)
  R2  water_level > LEVEL_EMERGENCY  -> + siren on, board emergency         (flood_emergency / emergency)
  R3  rainfall > RAINFALL_ADVISORY & level rising -> board advisory         (heavy_rain / advisory)
  R4  turbidity > TURBIDITY_MAX OR ph<PH_MIN OR ph>PH_MAX                    (water_quality_alert / warning)
"""


def _event(event_type, severity, value, threshold, action_taken):
    return {
        "event_type": event_type,
        "severity": severity,
        "value": round(float(value), 2),
        "threshold": float(threshold),
        "action_taken": action_taken,
    }


def evaluate(reading, thresholds):
    """Return (desired_actuator_state, active_conditions).

    reading: dict with water_level, rainfall, turbidity, ph, rising (bool).
    thresholds: dict with level_warning, level_emergency, rainfall_advisory,
                turbidity_max, ph_min, ph_max.
    """
    level = reading["water_level"]
    rainfall = reading["rainfall"]
    turbidity = reading["turbidity"]
    ph = reading["ph"]
    rising = reading.get("rising", False)

    desired = {"pump": "off", "gate": "closed", "siren": "off", "board": "normal"}
    active = {}

    # --- R1 / R2: water level (emergency supersedes warning) ---
    if level > thresholds["level_emergency"]:
        desired["pump"] = "on"
        desired["gate"] = "open"
        desired["siren"] = "on"
        desired["board"] = "emergency"
        active["flood_emergency"] = _event(
            "flood_emergency", "emergency", level, thresholds["level_emergency"],
            "pump_on,gate_open,siren_on,board_emergency",
        )
    elif level > thresholds["level_warning"]:
        desired["pump"] = "on"
        desired["gate"] = "open"
        desired["board"] = "warning"
        active["flood_warning"] = _event(
            "flood_warning", "warning", level, thresholds["level_warning"],
            "pump_on,gate_open,board_warning",
        )

    # --- R3: heavy rain while the level is rising -> advisory ---
    if rainfall > thresholds["rainfall_advisory"] and rising:
        if desired["board"] == "normal":
            desired["board"] = "advisory"
        active["heavy_rain"] = _event(
            "heavy_rain", "advisory", rainfall, thresholds["rainfall_advisory"],
            "board_advisory",
        )

    # --- R4: water quality (turbidity OR pH out of band) ---
    if turbidity > thresholds["turbidity_max"]:
        active["water_quality_alert"] = _event(
            "water_quality_alert", "warning", turbidity, thresholds["turbidity_max"],
            "none",
        )
    elif ph < thresholds["ph_min"] or ph > thresholds["ph_max"]:
        bound = thresholds["ph_min"] if ph < thresholds["ph_min"] else thresholds["ph_max"]
        active["water_quality_alert"] = _event(
            "water_quality_alert", "warning", ph, bound, "none",
        )

    return desired, active
