"""
Plotly Dash dashboard for SysId system identification.

Connects to SysId.jl's TcpMonitor (via SystemSimulator.jl):
  - Port 9200: send tunable signal parameters
  - Port 9201: receive all streamed signals

Usage:
    pip install -e ../../srt-dash
    python app.py

Start SysId.jl first:
    cd SysId.jl && julia --threads=auto --project=. examples/acrobot_sysid.jl
"""

from srt_dash import AppConfig, ParamDef, PlotDef, TraceDef, build_app

SIGNAL_TYPES = [("Off", 0), ("Sine", 1), ("Chirp", 2), ("Step", 3), ("Pulse", 4)]

# All slider suffixes for each signal prefix
SIGNAL_SLIDER_DEFS = [
    # (suffix,          label,                min,   max,    step,  default)
    ("amplitude",       "Amplitude",          0.0,   10.0,   0.1,   1.0),
    ("offset",          "Offset",            -5.0,    5.0,   0.1,   0.0),
    ("frequency",       "Frequency [Hz]",    0.01,   20.0,   0.01,  1.0),
    ("phase",           "Phase [rad]",       -3.14,   3.14,  0.01,  0.0),
    ("f_start",         "f_start [Hz]",      0.01,   10.0,   0.01,  0.1),
    ("f_end",           "f_end [Hz]",         0.1,   20.0,   0.1,   5.0),
    ("sweep_duration",  "Sweep duration [s]", 1.0,  120.0,   1.0,  30.0),
    ("step_time",       "Step time [s]",      0.0,   60.0,   0.5,   0.0),
    ("pulse_start",     "Pulse start [s]",    0.0,   60.0,   0.5,   0.0),
    ("pulse_width",     "Pulse width [s]",    0.1,   30.0,   0.1,   1.0),
]

SIGNAL_PREFIXES = ["Tau1", "Tau2"]


def sysid_param_builder(widget_values):
    """Custom param dict builder that maps prefixed widget values to Julia param keys."""
    param_dict = {}
    for prefix in SIGNAL_PREFIXES:
        param_dict[f"{prefix}_type"] = widget_values.get(f"{prefix}_type", 0.0)
        for suffix, *_ in SIGNAL_SLIDER_DEFS:
            key = f"{prefix}_{suffix}"
            param_dict[key] = widget_values.get(key, 0.0)
    param_dict["duration"] = widget_values.get("duration", 30.0)
    return param_dict


# Build param definitions for each signal prefix
params = []
for prefix in SIGNAL_PREFIXES:
    params.append(ParamDef(
        f"{prefix}_type", f"{prefix} type",
        kind="dropdown", options=SIGNAL_TYPES, default=0, group=prefix,
    ))
    for suffix, label, lo, hi, step, default in SIGNAL_SLIDER_DEFS:
        params.append(ParamDef(
            f"{prefix}_{suffix}", label, lo, hi, step, default, group=prefix,
        ))

params.append(ParamDef("duration", "Duration [s]", 1.0, 300.0, 1.0, 30.0, group="Experiment"))

config = AppConfig(
    title="SysId",
    port=8060,
    stream_port=9201,
    param_port=9200,
    param_builder=sysid_param_builder,
    params=params,
    plots=[
        PlotDef("graph-excitation", "Excitation Signals", [
            TraceDef("cmd.Tau1", "Tau1 [N*m]"),
            TraceDef("cmd.Tau2", "Tau2 [N*m]"),
        ], yaxis="Torque [N*m]"),
        PlotDef("graph-angles", "Joint Angles", [
            TraceDef("state.Theta1", "theta1 [rad]"),
            TraceDef("state.Theta2", "theta2 [rad]"),
        ], yaxis="Angle [rad]"),
        PlotDef("graph-velocities", "Joint Velocities", [
            TraceDef("state.Omega1", "omega1 [rad/s]"),
            TraceDef("state.Omega2", "omega2 [rad/s]"),
        ], yaxis="Angular Velocity [rad/s]"),
        PlotDef("graph-io-cross", "I/O Cross-Plot (Tau1 vs theta1)", [
            TraceDef("state.Theta1", "Tau1 vs theta1", mode="markers"),
        ], xaxis="Tau1 [N*m]", yaxis="theta1 [rad]", x_signal="cmd.Tau1"),
    ],
)

app = build_app(config)

if __name__ == "__main__":
    app.run(debug=True, use_reloader=False, host="0.0.0.0", port=config.port)
