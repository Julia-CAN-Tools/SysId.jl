# SysId.jl — System Identification Package Plan

## Context

Create a system identification data-collection app that generates excitation signals (Chirp, Sine, Step, Pulse), sends them to a plant over SocketCAN, records the plant's response to CSV, and provides a Dash UI for live signal parameter tuning and response visualization. Communicates with AcrobatSim.jl over virtual CAN using SystemSimulator.jl's CanIO.

## Two-Process Architecture

```
Terminal 1: AcrobatSim.jl                    Terminal 2: SysId.jl
┌─────────────────────────┐                  ┌─────────────────────────┐
│ Reads torques from vcan0│◄────── vcan0 ───►│ Writes torques to vcan0 │
│ (RX: TORQUE_CMD_MSGS)   │                  │ (TX: TORQUE_CMD_MSGS)   │
│                         │                  │                         │
│ Writes state to vcan2   │◄────── vcan2 ───►│ Reads state from vcan2  │
│ (TX: STATE_OUTPUT_MSGS) │                  │ (RX: STATE_OUTPUT_MSGS) │
│                         │                  │                         │
│ TcpMonitor: 9100/9101   │                  │ TcpMonitor: 9200/9201   │
│ Dash UI: port 8050      │                  │ Dash UI: port 8060      │
└─────────────────────────┘                  └─────────────────────────┘
```

---

## Package Structure

```
/home/aditya/Desktop/SRT/SysId.jl/
├── Project.toml
├── src/
│   ├── SysId.jl              # Module root
│   ├── signals.jl            # 4 signal types + evaluate()
│   └── experiment.jl         # SysIdController, sysid_callback, run_experiment!
├── test/
│   └── runtests.jl           # Unit + integration tests (MockIO, no vcan needed)
├── examples/
│   └── acrobot_sysid.jl      # Acrobot identification over SocketCAN + TcpMonitor
└── dash/
    ├── app.py                # Plotly Dash dashboard (port 8060)
    └── requirements.txt      # dash, plotly, numpy
```

---

## Implementation Plan

### 1. `Project.toml`

Dependencies: SystemSimulator, CANInterface, AcrobatSim (for examples).

Setup:
```bash
cd SysId.jl
julia --project=. -e 'using Pkg; Pkg.develop(path="../SystemSimulator.jl"); Pkg.develop(path="../AcrobatSim.jl")'
```

### 2. `src/signals.jl` — Excitation Signal Generators

Four struct types `<: AbstractSignal` with `evaluate(signal, t) -> Float64`:

| Signal | Formula | Fields |
|--------|---------|--------|
| `SineSignal` | `A * sin(2πft + φ) + offset` | amplitude, frequency, phase, offset |
| `ChirpSignal` | `A * sin(2π(f₀t + ½kt²)) + offset`, k=(f₁-f₀)/T | amplitude, f_start, f_end, duration, offset |
| `StepSignal` | `A + offset` if t ≥ t_step, else `offset` | amplitude, step_time, offset |
| `PulseSignal` | `A + offset` if t ∈ [t_start, t_start+width), else `offset` | amplitude, pulse_start, pulse_width, offset |

Convenience constructors: `SineSignal(amplitude, frequency; phase=0.0, offset=0.0)` etc.

Helper function to construct a signal from params dict:
```julia
function signal_from_params(params, prefix) -> Union{AbstractSignal, Nothing}
```
Reads `<prefix>_type` (0=off, 1=sine, 2=chirp, 3=step, 4=pulse) and the corresponding
parameter values (`<prefix>_amplitude`, `<prefix>_frequency`, etc.) to construct the
appropriate signal object. Returns `nothing` for type 0 (off).

### 3. `src/experiment.jl` — Controller & Experiment Runner

#### Signal Configuration via Params

Signal parameters live in the controller's `params::Dict{String,Float64}`, making them
tunable at runtime via TcpMonitor/Dash. For each output signal with prefix (e.g., `"Tau1"`):

```
Tau1_type           → 0=off, 1=sine, 2=chirp, 3=step, 4=pulse
Tau1_amplitude      → signal amplitude
Tau1_frequency      → Hz (sine)
Tau1_phase          → radians (sine)
Tau1_offset         → DC offset
Tau1_f_start        → Hz (chirp start)
Tau1_f_end          → Hz (chirp end)
Tau1_sweep_duration → seconds (chirp)
Tau1_step_time      → seconds (step)
Tau1_pulse_start    → seconds (pulse)
Tau1_pulse_width    → seconds (pulse)
```

#### SysIdController

```julia
mutable struct SysIdController <: SS.AbstractController
    params::Dict{String,Float64}
    signal_map::Vector{Tuple{String, String}}  # (param_prefix, output_global_key)
    elapsed::Float64
end
```

Constructor takes `signal_map` and optional `ExperimentConfig` for initial values:
```julia
SysIdController(signal_map; duration=30.0)           # defaults, all signals off
SysIdController(signal_map, experiment; duration=30.0) # pre-configured signals
```

Initializes params with defaults for each signal prefix + `"elapsed"`, `"running"`, `"duration"`.

#### SignalAssignment & ExperimentConfig

`SignalAssignment(output_key::String, signal::AbstractSignal)` — used for initial configuration only.

`ExperimentConfig(signals::Vector{SignalAssignment}, duration::Float64)` — optional convenience
to pre-populate signal params before run. These values can be overridden at runtime via Dash.

#### sysid_callback

```julia
function sysid_callback(ctrl::SysIdController, inputs, outputs, dt)
    ctrl.elapsed += dt

    if ctrl.elapsed <= ctrl.params["duration"]
        for (prefix, output_key) in ctrl.signal_map
            sig = signal_from_params(ctrl.params, prefix)
            if sig !== nothing && haskey(outputs, output_key)
                outputs[output_key] = evaluate(sig, ctrl.elapsed)
            elseif haskey(outputs, output_key)
                outputs[output_key] = 0.0
            end
        end
        ctrl.params["running"] = 1.0
    else
        for (_, output_key) in ctrl.signal_map
            haskey(outputs, output_key) && (outputs[output_key] = 0.0)
        end
        ctrl.params["running"] = 0.0
    end

    ctrl.params["elapsed"] = ctrl.elapsed
end
```

Key: signals are constructed from params each cycle, so TcpMonitor param updates
take effect immediately.

#### run_experiment!

```julia
function run_experiment!(
    signal_map::Vector{Tuple{String,String}},
    ios::Vector{SS.IOConfig},
    dt_ms::Int;
    experiment::Union{ExperimentConfig,Nothing}=nothing,
    duration::Float64=30.0,
    logfile::String="sysid_log.csv",
    monitor::Union{SS.MonitorConfig,Nothing}=nothing,
)::String
```

1. Creates `SysIdController(signal_map, experiment; duration=duration)` or `SysIdController(signal_map; duration=duration)`
2. Builds `SystemConfig(dt_ms, ios, logfile, monitor)`
3. Creates `SystemRuntime`, validates signal assignment keys
4. Calls `start!`, sleeps `duration + 0.5s`, calls `request_stop!` + `stop!`
5. Returns logfile path

### 4. `src/SysId.jl` — Module Root

```julia
module SysId
import SystemSimulator as SS
include("signals.jl")
include("experiment.jl")
export AbstractSignal, SineSignal, ChirpSignal, StepSignal, PulseSignal, evaluate,
       signal_from_params,
       SignalAssignment, ExperimentConfig, SysIdController, sysid_callback, run_experiment!
end
```

### 5. `test/runtests.jl`

Uses lightweight MockIO (same pattern as `SystemSimulator.jl/test/runtests.jl`):

- **Signal tests:** Pure math — `evaluate()` at known time points for all 4 types
- **signal_from_params tests:** Construct signals from param dicts, verify evaluate matches
- **SysIdController tests:** Call `sysid_callback` directly with mock dicts, verify signal values and zeroing
- **Integration test:** MockIO + SystemRuntime with SysIdController, verify CSV output

### 6. `examples/acrobot_sysid.jl` — Acrobot CAN Identification

```julia
using SysId, AcrobatSim
import SystemSimulator as SS
import CANInterface as CI

# CAN IO: write torques to vcan0, read state from vcan2
tx_io = SS.CanIO(CI.SocketCanDriver("vcan0"),
    typeof(TORQUE_CMD_MESSAGES[1])[], deepcopy(TORQUE_CMD_MESSAGES))
rx_io = SS.CanIO(CI.SocketCanDriver("vcan2"),
    deepcopy(STATE_OUTPUT_MESSAGES), typeof(STATE_OUTPUT_MESSAGES[1])[])

ios = [
    SS.IOConfig(:cmd, tx_io, 256, SS.IO_MODE_WRITEONLY),
    SS.IOConfig(:state, rx_io, 256, SS.IO_MODE_READONLY),
]

signal_map = [("Tau1", "cmd.Tau1"), ("Tau2", "cmd.Tau2")]

experiment = ExperimentConfig([
    SignalAssignment("cmd.Tau1", ChirpSignal(2.0, 0.1, 5.0, 30.0)),
    SignalAssignment("cmd.Tau2", SineSignal(1.0, 0.5)),
], 30.0)

logfile = run_experiment!(
    signal_map, ios, 10;
    experiment=experiment,
    duration=30.0,
    logfile=joinpath(@__DIR__, "..", "acrobot_sysid.csv"),
    monitor=SS.MonitorConfig("0.0.0.0", 9200, 9201),
)
```

The waker frame for clean shutdown of the vcan2 reader is sent after `run_experiment!` returns:
```julia
_waker = CI.SocketCanDriver("vcan2")
try CI.write(_waker, UInt32(0x18FF0000), ntuple(_->UInt8(0), 8))
finally CI.close(_waker) end
```

### 7. `dash/app.py` — Plotly Dash Dashboard (port 8060)

Follows the same `SimulatorClient` pattern as AcrobatSim's Dash app (`AcrobatSim.jl/dash/app.py`).

**Connection:**
- Stream port: 9201 (receives Time, state.Theta1/2, state.Omega1/2, cmd.Tau1/2, elapsed, running, + all signal params)
- Param port: 9200 (sends signal parameter updates)

**Layout:**

```
┌──────────────────────────────────────────────────────────────────────┐
│ ┌──────────────┐  ┌───────────────────────┐┌──────────────────────┐ │
│ │  Tau1 Config  │  │ Excitation Signals    ││ Joint Angles         │ │
│ │              │  │ (cmd.Tau1, cmd.Tau2)  ││ (state.Theta1/2)     │ │
│ │ Type: [▼]    │  │                       ││                      │ │
│ │ Amplitude    │  │                       ││                      │ │
│ │ Frequency    │  └───────────────────────┘└──────────────────────┘ │
│ │ Phase        │  ┌───────────────────────┐┌──────────────────────┐ │
│ │ Offset       │  │ Joint Velocities      ││ Input-Output         │ │
│ │ f_start      │  │ (state.Omega1/2)      ││ (Tau1 vs Theta1)     │ │
│ │ f_end        │  │                       ││                      │ │
│ │ sweep_dur    │  │                       ││                      │ │
│ │ step_time    │  └───────────────────────┘└──────────────────────┘ │
│ │ pulse_start  │                                                    │
│ │ pulse_width  │                                                    │
│ ├──────────────┤                                                    │
│ │  Tau2 Config  │                                                    │
│ │ (same sliders)│                                                    │
│ ├──────────────┤                                                    │
│ │ Duration [s] │                                                    │
│ └──────────────┘                                                    │
└──────────────────────────────────────────────────────────────────────┘
```

**Sidebar (left, ~300px):**

For each output signal (Tau1, Tau2), a section with:
- `dcc.Dropdown` for signal type: Off (0), Sine (1), Chirp (2), Step (3), Pulse (4)
- Sliders for all parameters (always visible, unused ones ignored by callback):
  - Amplitude: -10.0 to 10.0, step 0.1, default 1.0
  - Frequency [Hz]: 0.01 to 20.0, step 0.01, default 1.0 (sine)
  - Phase [rad]: -π to π, step 0.01, default 0.0
  - Offset: -10.0 to 10.0, step 0.1, default 0.0
  - f_start [Hz]: 0.01 to 20.0, step 0.01, default 0.1 (chirp)
  - f_end [Hz]: 0.01 to 20.0, step 0.01, default 5.0 (chirp)
  - Sweep Duration [s]: 1.0 to 60.0, step 0.5, default 10.0 (chirp)
  - Step Time [s]: 0.0 to 60.0, step 0.1, default 1.0 (step)
  - Pulse Start [s]: 0.0 to 60.0, step 0.1, default 1.0 (pulse)
  - Pulse Width [s]: 0.01 to 10.0, step 0.01, default 0.5 (pulse)
- Experiment Duration slider: 1.0 to 120.0, step 1.0, default 30.0

**Graphs (right, 2x2 grid):**
1. **Excitation Signals** — cmd.Tau1 and cmd.Tau2 vs Time
2. **Joint Angles** — state.Theta1 and state.Theta2 vs Time
3. **Joint Velocities** — state.Omega1 and state.Omega2 vs Time
4. **Input-Output** — Tau1 vs Theta1 cross-plot (scatter, for identification insight)

**Update callback (200ms interval):**
1. Read all slider/dropdown values
2. Build param dict with proper prefix naming (`Tau1_type`, `Tau1_amplitude`, etc.)
3. Send to SysId runtime via `client.send_params(param_dict)`
4. Read signal history from stream
5. Update all 4 graphs

**SimulatorClient class:** Identical to `AcrobatSim.jl/dash/app.py` — reuse the `SimulatorClient` class verbatim (TCP binary protocol, handshake, reader thread, ring buffers).

### 8. `dash/requirements.txt`

```
dash>=2.14
plotly>=5.18
numpy>=1.24
```

---

## Run Commands (4 terminals)

```bash
# Prerequisites: set up virtual CAN
sudo bash J1939Parser.jl/logs/setupVirtualCAN.sh

# Terminal 1: AcrobatSim runtime
cd AcrobatSim.jl && julia --threads=auto --project=. src/runscript.jl

# Terminal 2: AcrobatSim Dash UI (port 8050)
cd AcrobatSim.jl/dash && python app.py

# Terminal 3: SysId runtime
cd SysId.jl && julia --threads=auto --project=. examples/acrobot_sysid.jl

# Terminal 4: SysId Dash UI (port 8060)
cd SysId.jl/dash && pip install -r requirements.txt && python app.py
```

---

## Files Created (all new)

| File | Purpose |
|------|---------|
| `SysId.jl/Project.toml` | Package manifest |
| `SysId.jl/src/SysId.jl` | Module root |
| `SysId.jl/src/signals.jl` | 4 signal types + evaluate() + signal_from_params() |
| `SysId.jl/src/experiment.jl` | SysIdController (params-based), callback, run_experiment! |
| `SysId.jl/test/runtests.jl` | Unit + integration tests |
| `SysId.jl/examples/acrobot_sysid.jl` | Acrobot CAN identification + TcpMonitor |
| `SysId.jl/dash/app.py` | Plotly Dash UI (port 8060) |
| `SysId.jl/dash/requirements.txt` | Python dependencies |

## Files Referenced (read-only)

| File | Why |
|------|-----|
| `SystemSimulator.jl/src/IO/abstractIO.jl` | AbstractIO interface |
| `SystemSimulator.jl/src/runtime.jl` | SystemRuntime, AbstractController |
| `SystemSimulator.jl/src/loops.jl` | Control loop, start!/stop! |
| `SystemSimulator.jl/src/config.jl` | SystemConfig, IOConfig, MonitorConfig |
| `SystemSimulator.jl/test/runtests.jl` | MockIO pattern for tests |
| `AcrobatSim.jl/src/catalogs.jl` | TORQUE_CMD_MESSAGES, STATE_OUTPUT_MESSAGES |
| `AcrobatSim.jl/dash/app.py` | SimulatorClient pattern + Dash layout reference |

## Verification

1. `cd SysId.jl && julia --threads=auto --project=. test/runtests.jl` — all tests pass
2. Set up vcan: `sudo bash J1939Parser.jl/logs/setupVirtualCAN.sh`
3. Start AcrobatSim: `cd AcrobatSim.jl && julia --threads=auto --project=. src/runscript.jl`
4. Run SysId: `cd SysId.jl && julia --threads=auto --project=. examples/acrobot_sysid.jl`
5. Open Dash: `cd SysId.jl/dash && python app.py` — adjust signal params via sliders, observe live response
6. Inspect `acrobot_sysid.csv`: verify excitation patterns (chirp/sine) and state response data
