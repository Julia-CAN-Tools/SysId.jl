"""
Plotly Dash dashboard for SysId system identification.

Connects to SysId.jl's TcpMonitor (via SystemSimulator.jl):
  - Port 9200: send tunable signal parameters
  - Port 9201: receive all streamed signals

Usage:
    pip install -r requirements.txt
    python app.py

Start SysId.jl first:
    cd SysId.jl && julia --threads=auto --project=. examples/acrobot_sysid.jl
"""

import socket
import struct
import threading
from collections import deque

from dash import Dash, dcc, html, Input, Output, State, callback

# ---------------------------------------------------------------------------
# TCP client for TcpMonitor binary protocol (reused from AcrobatSim/dash)
# ---------------------------------------------------------------------------

class SimulatorClient:
    """Connects to SystemSimulator TcpMonitor and exchanges data."""

    def __init__(self, host="localhost", stream_port=9201, param_port=9200):
        self.host = host
        self.stream_port = stream_port
        self.param_port = param_port

        self.signal_names = []
        self.param_names = []
        self.history = {}       # name -> deque of floats
        self.maxlen = 3000
        self.lock = threading.Lock()
        self._running = False

        self._stream_sock = None
        self._param_sock = None
        self._reader_thread = None

    def connect_stream(self):
        """Connect to the stream port, read handshake, start reader thread."""
        self._stream_sock = socket.create_connection((self.host, self.stream_port))
        self.signal_names = self._read_handshake(self._stream_sock)
        with self.lock:
            for name in self.signal_names:
                self.history[name] = deque(maxlen=self.maxlen)
        self._running = True
        self._reader_thread = threading.Thread(target=self._reader_loop, daemon=True)
        self._reader_thread.start()

    def connect_params(self):
        """Connect to the param port and read handshake."""
        self._param_sock = socket.create_connection((self.host, self.param_port))
        self.param_names = self._read_handshake(self._param_sock)

    def _read_handshake(self, sock):
        """Read TcpMonitor handshake: count + name strings."""
        raw = self._recv_exact(sock, 4)
        n = struct.unpack("<I", raw)[0]
        names = []
        for _ in range(n):
            slen_raw = self._recv_exact(sock, 2)
            slen = struct.unpack("<H", slen_raw)[0]
            name = self._recv_exact(sock, slen).decode("utf-8")
            names.append(name)
        return names

    def _recv_exact(self, sock, nbytes):
        """Receive exactly nbytes from socket."""
        buf = bytearray()
        while len(buf) < nbytes:
            chunk = sock.recv(nbytes - len(buf))
            if not chunk:
                raise ConnectionError("Socket closed")
            buf.extend(chunk)
        return bytes(buf)

    def _reader_loop(self):
        """Background thread: read Float64 frames, append to history."""
        n = len(self.signal_names)
        frame_size = n * 8
        while self._running:
            try:
                data = self._recv_exact(self._stream_sock, frame_size)
            except (ConnectionError, OSError):
                break
            values = struct.unpack(f"<{n}d", data)
            with self.lock:
                for name, val in zip(self.signal_names, values):
                    self.history[name].append(val)

    def send_params(self, param_dict):
        """Send parameter values in declared order."""
        if self._param_sock is None or not self.param_names:
            return
        values = [param_dict.get(name, 0.0) for name in self.param_names]
        payload = struct.pack(f"<{len(values)}d", *values)
        try:
            self._param_sock.sendall(payload)
        except (ConnectionError, OSError):
            pass

    def get_history(self, name):
        """Return a copy of the history buffer for a signal."""
        with self.lock:
            buf = self.history.get(name)
            if buf is None:
                return []
            return list(buf)

    def close(self):
        self._running = False
        for s in (self._stream_sock, self._param_sock):
            if s:
                try:
                    s.close()
                except OSError:
                    pass


# ---------------------------------------------------------------------------
# Signal parameter slider definitions
# type: 0=off, 1=sine, 2=chirp, 3=step, 4=pulse
# ---------------------------------------------------------------------------

SIGNAL_PREFIXES = ["Tau1", "Tau2"]

# (param_suffix, min, max, step, default, label)
COMMON_SLIDERS = [
    ("amplitude",      0.0,  10.0,  0.1,   1.0,  "Amplitude"),
    ("offset",        -5.0,   5.0,  0.1,   0.0,  "Offset"),
]
SINE_SLIDERS = [
    ("frequency",     0.01,  20.0,  0.01,  1.0,  "Frequency [Hz]"),
    ("phase",        -3.14,   3.14, 0.01,  0.0,  "Phase [rad]"),
]
CHIRP_SLIDERS = [
    ("f_start",       0.01,  10.0,  0.01,  0.1,  "f_start [Hz]"),
    ("f_end",         0.1,   20.0,  0.1,   5.0,  "f_end [Hz]"),
    ("sweep_duration", 1.0, 120.0,  1.0,  30.0,  "Sweep duration [s]"),
]
STEP_SLIDERS = [
    ("step_time",     0.0,   60.0,  0.5,   0.0,  "Step time [s]"),
]
PULSE_SLIDERS = [
    ("pulse_start",   0.0,   60.0,  0.5,   0.0,  "Pulse start [s]"),
    ("pulse_width",   0.1,   30.0,  0.1,   1.0,  "Pulse width [s]"),
]


def make_slider(pid, lo, hi, step, val, label):
    return html.Div([
        html.Label(label, style={"fontSize": "11px", "color": "#555"}),
        dcc.Slider(
            id=f"slider-{pid}",
            min=lo, max=hi, step=step, value=val,
            marks=None,
            tooltip={"placement": "right", "always_visible": True},
        ),
    ], style={"marginBottom": "4px"})


def make_signal_section(prefix):
    """Build sidebar section for one signal (Tau1 or Tau2)."""
    type_dd = html.Div([
        html.Label(f"{prefix} type", style={"fontSize": "12px", "fontWeight": "bold"}),
        dcc.Dropdown(
            id=f"dd-{prefix}-type",
            options=[
                {"label": "Off",   "value": 0},
                {"label": "Sine",  "value": 1},
                {"label": "Chirp", "value": 2},
                {"label": "Step",  "value": 3},
                {"label": "Pulse", "value": 4},
            ],
            value=0,
            clearable=False,
            style={"fontSize": "12px", "marginBottom": "6px"},
        ),
    ])

    sliders = []
    for suffix, lo, hi, step, val, label in COMMON_SLIDERS + SINE_SLIDERS + CHIRP_SLIDERS + STEP_SLIDERS + PULSE_SLIDERS:
        sliders.append(make_slider(f"{prefix}-{suffix}", lo, hi, step, val, label))

    return html.Div([type_dd] + sliders + [html.Hr()], style={"marginBottom": "4px"})


sidebar_children = [html.H3("SysId Parameters", style={"marginTop": "0"})]

for prefix in SIGNAL_PREFIXES:
    sidebar_children.append(make_signal_section(prefix))

sidebar_children.append(html.Label("Duration [s]", style={"fontSize": "12px", "fontWeight": "bold"}))
sidebar_children.append(make_slider("duration", 1.0, 300.0, 1.0, 30.0, "Duration [s]"))


# ---------------------------------------------------------------------------
# Collect all control IDs for the callback
# ---------------------------------------------------------------------------

def all_slider_ids():
    ids = []
    for prefix in SIGNAL_PREFIXES:
        for suffix, *_ in COMMON_SLIDERS + SINE_SLIDERS + CHIRP_SLIDERS + STEP_SLIDERS + PULSE_SLIDERS:
            ids.append(f"slider-{prefix}-{suffix}")
    ids.append("slider-duration")
    return ids

def all_dropdown_ids():
    return [f"dd-{prefix}-type" for prefix in SIGNAL_PREFIXES]


# ---------------------------------------------------------------------------
# Dash app
# ---------------------------------------------------------------------------

client = SimulatorClient()

try:
    client.connect_stream()
    print(f"Stream connected: {len(client.signal_names)} signals")
except Exception as e:
    print(f"Stream connection failed (start SysId.jl first): {e}")

try:
    client.connect_params()
    print(f"Params connected: {client.param_names}")
except Exception as e:
    print(f"Param connection failed: {e}")


app = Dash(__name__)

app.layout = html.Div([
    dcc.Interval(id="interval", interval=200, n_intervals=0),
    html.Div([
        # Sidebar
        html.Div(
            sidebar_children,
            style={
                "width": "280px", "padding": "10px", "overflowY": "auto",
                "borderRight": "1px solid #ccc", "height": "100vh",
            },
        ),
        # Plot grid (2x2)
        html.Div([
            html.Div([
                dcc.Graph(id="graph-excitation",  style={"height": "45vh"}),
                dcc.Graph(id="graph-angles",      style={"height": "45vh"}),
            ], style={"flex": "1"}),
            html.Div([
                dcc.Graph(id="graph-velocities",  style={"height": "45vh"}),
                dcc.Graph(id="graph-io-cross",    style={"height": "45vh"}),
            ], style={"flex": "1"}),
        ], style={"display": "flex", "flex": "1"}),
    ], style={"display": "flex", "height": "100vh"}),
])

SLIDER_IDS   = all_slider_ids()
DROPDOWN_IDS = all_dropdown_ids()


@callback(
    Output("graph-excitation", "figure"),
    Output("graph-angles",     "figure"),
    Output("graph-velocities", "figure"),
    Output("graph-io-cross",   "figure"),
    Input("interval", "n_intervals"),
    [Input(did, "value") for did in DROPDOWN_IDS],
    [State(sid, "value") for sid in SLIDER_IDS],
)
def update_graphs(n_intervals, *args):
    n_dd = len(DROPDOWN_IDS)
    dd_values  = args[:n_dd]
    slv_values = args[n_dd:]

    # Build param dict for TcpMonitor
    param_dict = {}

    # Type dropdowns
    for prefix, dd_val in zip(SIGNAL_PREFIXES, dd_values):
        param_dict[f"{prefix}_type"] = float(dd_val) if dd_val is not None else 0.0

    # Sliders: (prefix, suffix) order mirrors all_slider_ids()
    slider_idx = 0
    for prefix in SIGNAL_PREFIXES:
        for suffix, *_ in COMMON_SLIDERS + SINE_SLIDERS + CHIRP_SLIDERS + STEP_SLIDERS + PULSE_SLIDERS:
            val = slv_values[slider_idx]
            param_dict[f"{prefix}_{suffix}"] = float(val) if val is not None else 0.0
            slider_idx += 1

    # Duration slider (last)
    dur_val = slv_values[slider_idx]
    param_dict["duration"] = float(dur_val) if dur_val is not None else 30.0

    client.send_params(param_dict)

    # Read history
    time_data = client.get_history("Time")
    tau1   = client.get_history("cmd.Tau1")
    tau2   = client.get_history("cmd.Tau2")
    theta1 = client.get_history("state.Theta1")
    theta2 = client.get_history("state.Theta2")
    omega1 = client.get_history("state.Omega1")
    omega2 = client.get_history("state.Omega2")

    # 1) Excitation signals
    fig_exc = {
        "data": [
            {"x": time_data, "y": tau1, "name": "Tau1 [N·m]", "type": "scatter"},
            {"x": time_data, "y": tau2, "name": "Tau2 [N·m]", "type": "scatter"},
        ],
        "layout": {
            "title": "Excitation Signals",
            "xaxis": {"title": "Time [s]"},
            "yaxis": {"title": "Torque [N·m]"},
            "margin": {"t": 40},
        },
    }

    # 2) Joint angles
    fig_angles = {
        "data": [
            {"x": time_data, "y": theta1, "name": "θ1 [rad]", "type": "scatter"},
            {"x": time_data, "y": theta2, "name": "θ2 [rad]", "type": "scatter"},
        ],
        "layout": {
            "title": "Joint Angles",
            "xaxis": {"title": "Time [s]"},
            "yaxis": {"title": "Angle [rad]"},
            "margin": {"t": 40},
        },
    }

    # 3) Joint velocities
    fig_vel = {
        "data": [
            {"x": time_data, "y": omega1, "name": "ω1 [rad/s]", "type": "scatter"},
            {"x": time_data, "y": omega2, "name": "ω2 [rad/s]", "type": "scatter"},
        ],
        "layout": {
            "title": "Joint Velocities",
            "xaxis": {"title": "Time [s]"},
            "yaxis": {"title": "Angular Velocity [rad/s]"},
            "margin": {"t": 40},
        },
    }

    # 4) Input-Output cross-plot (Tau1 vs Theta1)
    fig_cross = {
        "data": [
            {
                "x": tau1, "y": theta1,
                "name": "Tau1 vs θ1",
                "type": "scatter",
                "mode": "markers",
                "marker": {"size": 3, "opacity": 0.6},
            },
        ],
        "layout": {
            "title": "I/O Cross-Plot (Tau1 vs θ1)",
            "xaxis": {"title": "Tau1 [N·m]"},
            "yaxis": {"title": "θ1 [rad]"},
            "margin": {"t": 40},
        },
    }

    return fig_exc, fig_angles, fig_vel, fig_cross


if __name__ == "__main__":
    app.run(debug=True, host="0.0.0.0", port=8060)
