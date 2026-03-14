import SystemSimulator as SS

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
    io_configs::Vector{SS.IOConfig{IO}},
    dt_ms::Int;
    logfile::String = "SysIdLog.csv",
    experiment::Union{ExperimentConfig,Nothing} = nothing,
    monitor::Union{SS.MonitorConfig,Nothing} = nothing,
    waker_fn::Union{Function,Nothing} = nothing,
    autostart::Bool = (monitor === nothing),
) where {IO<:SS.AbstractIO}
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
