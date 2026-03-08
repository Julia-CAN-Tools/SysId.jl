"""
SysId experiment system and runner.

SysIdSystem holds signal params (tunable via TcpMonitor/Dash) and drives
output signals according to the current signal configuration.

run_experiment! wires up IOConfigs into a SystemRuntime and runs for a duration.
"""

import SystemSimulator as SS

# ── SysIdSystem ───────────────────────────────────────────────────────────────

"""
    SysIdSystem

System for system identification experiments.

Fields:
- `params`      — all signal params + `elapsed`, `duration`, `running`
- `signal_map`  — Vector of (param_prefix, output_global_key) pairs
- `elapsed`     — accumulated time in seconds (updated each callback)
"""
mutable struct SysIdSystem <: SS.AbstractSystem
    params::Dict{String,Float64}
    signal_map::Vector{Tuple{String,String}}
    lifecycle::SS.SystemLifecycle
end

"""
    _default_signal_params(prefix) -> Dict{String,Float64}

Return a dict of all signal params for a given prefix, all zeroed (type=0 → off).
"""
function _default_signal_params(prefix::String)
    return Dict{String,Float64}(
        "$(prefix)_type"           => 0.0,
        "$(prefix)_amplitude"      => 0.0,
        "$(prefix)_frequency"      => 1.0,
        "$(prefix)_phase"          => 0.0,
        "$(prefix)_offset"         => 0.0,
        "$(prefix)_f_start"        => 0.1,
        "$(prefix)_f_end"          => 5.0,
        "$(prefix)_sweep_duration" => 10.0,
        "$(prefix)_step_time"      => 0.0,
        "$(prefix)_pulse_start"    => 0.0,
        "$(prefix)_pulse_width"    => 1.0,
    )
end

"""
    SysIdSystem(signal_map) -> SysIdSystem

Construct system with all signals off (type=0).
`signal_map` is a Vector of (param_prefix, output_global_key) pairs.
"""
function SysIdSystem(signal_map::Vector{Tuple{String,String}})
    params = Dict{String,Float64}(
        "elapsed"   => 0.0,
        "duration"  => 30.0,
        "running"   => 0.0,
        "start_cmd" => 0.0,
        "stop_cmd"  => 0.0,
    )
    for (prefix, _) in signal_map
        merge!(params, _default_signal_params(prefix))
    end
    return SysIdSystem(params, signal_map, SS.SystemLifecycle())
end

"""
    ExperimentConfig

Optional pre-populated signal configuration for an experiment.

Fields:
- `duration`     — experiment duration in seconds
- `signal_specs` — Dict mapping param_prefix => Dict of override params
  (e.g., `"Tau1" => Dict("type"=>2.0, "amplitude"=>2.0, "f_start"=>0.1, ...)`)
"""
struct ExperimentConfig
    duration::Float64
    signal_specs::Dict{String,Dict{String,Float64}}
end

ExperimentConfig(duration::Float64) = ExperimentConfig(duration, Dict{String,Dict{String,Float64}}())

"""
    SysIdSystem(signal_map, cfg) -> SysIdSystem

Construct system with initial signal parameters from an ExperimentConfig.
"""
function SysIdSystem(signal_map::Vector{Tuple{String,String}}, cfg::ExperimentConfig)
    ctrl = SysIdSystem(signal_map)
    ctrl.params["duration"] = cfg.duration
    for (prefix, spec) in cfg.signal_specs
        for (key, val) in spec
            param_key = "$(prefix)_$(key)"
            if haskey(ctrl.params, param_key)
                ctrl.params[param_key] = Float64(val)
            end
        end
    end
    return ctrl
end

# ── sysid_callback ────────────────────────────────────────────────────────────

"""
    sysid_callback(ctrl, inputs, outputs, dt_s)

Control callback for system identification. Each cycle:
1. Checks start_cmd / stop_cmd counters for start/stop events
2. If active, increments elapsed time and evaluates signals
3. Zeros outputs when stopped or after duration expires
"""
function sysid_callback(ctrl::SysIdSystem, _inputs, outputs, dt_s::Float64)
    p = ctrl.params
    SS.update_lifecycle!(ctrl.lifecycle, p, dt_s)

    if ctrl.lifecycle.active
        t = ctrl.lifecycle.elapsed
        for (prefix, out_key) in ctrl.signal_map
            sig = signal_from_params(p, prefix)
            outputs[out_key] = sig === nothing ? 0.0 : evaluate(sig, t)
        end
    else
        for (_, out_key) in ctrl.signal_map
            outputs[out_key] = 0.0
        end
    end

    return nothing
end

# ── run_experiment! ───────────────────────────────────────────────────────────

"""
    run_experiment!(signal_map, io_configs, dt_ms; kwargs...) -> String

Run a system identification experiment.

Arguments:
- `signal_map`   — Vector of (param_prefix, output_global_key) pairs
- `io_configs`   — Vector of IOConfig (pre-built with SS.IOConfig)
- `dt_ms`        — control loop sample period in milliseconds

Keyword arguments:
- `logfile`      — CSV output path (default: "SysIdLog.csv")
- `experiment`   — optional ExperimentConfig for initial signal params
- `monitor`      — optional SS.MonitorConfig for Dash connectivity
- `waker_fn`     — optional 0-arg function called after stop to unblock blocking readers
- `autostart`    — if true, start experiment immediately (default: true when no monitor)

When `autostart` is false (default with monitor/Dash), the runtime waits for
start/stop commands from Dash. Press Ctrl+C to shut down the runtime.

Returns the logfile path.
"""
function run_experiment!(
    signal_map::Vector{Tuple{String,String}},
    io_configs::Vector{SS.IOConfig},
    dt_ms::Int;
    logfile::String = "SysIdLog.csv",
    experiment::Union{ExperimentConfig,Nothing} = nothing,
    monitor::Union{SS.MonitorConfig,Nothing} = nothing,
    waker_fn::Union{Function,Nothing} = nothing,
    autostart::Bool = (monitor === nothing),
)
    ctrl = if experiment !== nothing
        SysIdSystem(signal_map, experiment)
    else
        SysIdSystem(signal_map)
    end

    cfg = SS.SystemConfig(dt_ms, io_configs, logfile, monitor)
    sf  = SS.StopSignal()
    runtime = SS.SystemRuntime(cfg, sf, ctrl)

    duration = ctrl.params["duration"]

    @info "Starting SysId runtime" dt_ms=dt_ms duration_s=duration logfile=logfile autostart=autostart

    # Wrap the callback to sync lifecycle params (running, elapsed) back into
    # runtime.params after each invocation. apply_monitor_params! initialises
    # runtime.params from Dash (which sends 0 for these read-only fields), so
    # without this sync copy_to_monitor! always streams running=0 and the Dash
    # status display never leaves "Idle".
    function synced_callback(c, inputs, outputs, dt_s)
        sysid_callback(c, inputs, outputs, dt_s)
        runtime.params["running"] = c.params["running"]
        runtime.params["elapsed"] = c.params["elapsed"]
    end

    SS.start!(runtime, synced_callback)

    if autostart
        # Trigger start immediately (simulate start_cmd = 1)
        ctrl.params["start_cmd"] = 1.0
        @info "Experiment auto-started"
    else
        @info "Waiting for start command from Dash UI"
    end

    try
        if autostart
            sleep(duration + 0.5)
        else
            # Wait indefinitely — lifecycle controlled from Dash
            while !SS.stop_requested(sf)
                sleep(1.0)
            end
        end
    catch e
        e isa InterruptException || rethrow(e)
        @info "Interrupted — stopping"
    end

    SS.request_stop!(sf)

    if waker_fn !== nothing
        try
            waker_fn()
        catch err
            @warn "Waker function failed" exception=(err, catch_backtrace())
        end
    end

    SS.stop!(runtime)

    @info "Experiment complete" steps=runtime.step_count[] logfile=logfile

    return logfile
end
