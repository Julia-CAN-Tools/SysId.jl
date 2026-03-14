import SystemSimulator as SS

const CachedSignal = Union{Nothing,SineSignal,ChirpSignal,StepSignal,PulseSignal}

mutable struct SysIdSystem <: SS.AbstractSystem
    params::Dict{String,Float64}
    signal_map::Vector{Tuple{String,String}}
    lifecycle::SS.SystemLifecycle
    signal_cache::Vector{CachedSignal}
    _params_dirty::Bool
end

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
    signal_cache = Vector{CachedSignal}(undef, length(signal_map))
    ctrl = SysIdSystem(params, signal_map, SS.SystemLifecycle(), signal_cache, true)
    _refresh_signal_cache!(ctrl)
    return ctrl
end

struct ExperimentConfig
    duration::Float64
    signal_specs::Dict{String,Dict{String,Float64}}
end

ExperimentConfig(duration::Float64) =
    ExperimentConfig(duration, Dict{String,Dict{String,Float64}}())

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
    ctrl._params_dirty = true
    _refresh_signal_cache!(ctrl)
    return ctrl
end

function _refresh_signal_cache!(ctrl::SysIdSystem)
    @inbounds for (i, (prefix, _)) in enumerate(ctrl.signal_map)
        ctrl.signal_cache[i] = signal_from_params(ctrl.params, prefix)
    end
    ctrl._params_dirty = false
    return ctrl
end

"""
    sysid_callback(ctrl, inputs, outputs, dt_s)

Control callback for system identification. Each cycle:
1. Checks start_cmd / stop_cmd counters for start/stop events
2. If active, increments elapsed time and evaluates signals
3. Zeros outputs when stopped or after duration expires
"""
function sysid_callback(ctrl::SysIdSystem, _inputs, outputs, dt_s::Float64)
    p = ctrl.params
    event = SS.update_lifecycle!(ctrl.lifecycle, p, dt_s)

    if ctrl._params_dirty || event == :started
        _refresh_signal_cache!(ctrl)
    end

    if ctrl.lifecycle.active
        t = ctrl.lifecycle.elapsed
        @inbounds for (i, (_, out_key)) in enumerate(ctrl.signal_map)
            sig = ctrl.signal_cache[i]
            outputs[out_key] = sig === nothing ? 0.0 : evaluate(sig, t)
        end
    else
        for (_, out_key) in ctrl.signal_map
            outputs[out_key] = 0.0
        end
    end

    return nothing
end
