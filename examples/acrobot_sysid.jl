"""
Acrobot system identification over SocketCAN.

Two-process setup:
  Terminal 1: cd AcrobatSim.jl && julia --threads=auto --project=. src/runscript.jl
  Terminal 2: cd SysId.jl     && julia --threads=auto --project=. examples/acrobot_sysid.jl
  Terminal 3: cd SysId.jl/dash && python app.py

Communication:
  vcan0 — SysId writes torque commands (TX: TORQUE_CMD_MESSAGES)
  vcan2 — SysId reads  state output   (RX: STATE_OUTPUT_MESSAGES)
"""

import SystemSimulator as SS
import CANInterface as CI
using AcrobatSim: TORQUE_CMD_MESSAGES, STATE_OUTPUT_MESSAGES
using SysId

# ── IO endpoints ──────────────────────────────────────────────────────────────

# vcan0: write torque commands to the plant (write-only)
cmd_io = SS.CanIO(
    CI.SocketCanDriver("vcan0"),
    typeof(TORQUE_CMD_MESSAGES[1])[],    # no RX catalog
    deepcopy(TORQUE_CMD_MESSAGES),       # TX catalog
)

# vcan2: read plant state (read-only)
state_io = SS.CanIO(
    CI.SocketCanDriver("vcan2"),
    deepcopy(STATE_OUTPUT_MESSAGES),     # RX catalog
    typeof(STATE_OUTPUT_MESSAGES[1])[]   # no TX catalog
)

io_configs = SS.IOConfig[
    SS.IOConfig(:cmd,   cmd_io,   256, SS.IO_MODE_WRITEONLY),
    SS.IOConfig(:state, state_io, 256, SS.IO_MODE_READONLY),
]

# ── Signal map ────────────────────────────────────────────────────────────────
# (param_prefix, output_global_key)
signal_map = Tuple{String,String}[
    ("Tau1", "cmd.Tau1"),
    ("Tau2", "cmd.Tau2"),
]

# ── Experiment configuration ──────────────────────────────────────────────────
# Default: chirp on Tau1 (0.1→5 Hz, 2 Nm), sine on Tau2 (0.5 Hz, 1 Nm)
experiment = ExperimentConfig(
    30.0,   # 30 seconds
    Dict(
        "Tau1" => Dict(
            "type"           => 2.0,   # chirp
            "amplitude"      => 2.0,
            "f_start"        => 0.1,
            "f_end"          => 5.0,
            "sweep_duration" => 30.0,
            "offset"         => 0.0,
        ),
        "Tau2" => Dict(
            "type"      => 1.0,   # sine
            "amplitude" => 1.0,
            "frequency" => 0.5,
            "phase"     => 0.0,
            "offset"    => 0.0,
        ),
    ),
)

# ── TcpMonitor (for Dash UI on port 8060) ────────────────────────────────────
monitor = SS.MonitorConfig("0.0.0.0", 9200, 9201)

# ── Waker: send a dummy frame on vcan2 to unblock the state_io reader ─────────
function waker()
    _sock = CI.SocketCanDriver("vcan2")
    try
        CI.write(_sock, UInt32(0x18FF0000), ntuple(_ -> UInt8(0), 8))
    catch err
        @warn "Waker frame write failed" exception=(err, catch_backtrace())
    finally
        CI.close(_sock)
    end
end

# ── Run ───────────────────────────────────────────────────────────────────────
logfile = joinpath(@__DIR__, "..", "AcrobotSysIdLog.csv")

@info "SysId starting" monitor_params=9200 monitor_stream=9201 dash_port=8060
@info "Connect Dash UI: cd SysId.jl/dash && python app.py"

run_experiment!(
    signal_map,
    io_configs,
    10;   # 10 ms → 100 Hz
    logfile   = logfile,
    experiment = experiment,
    monitor   = monitor,
    waker_fn  = waker,
)
