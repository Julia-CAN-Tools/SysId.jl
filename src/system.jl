import SystemSimulator as SS

const CachedSignal = Union{Nothing,SineSignal,ChirpSignal,StepSignal,PulseSignal}

struct SignalParamSlots
    type::Int
    amplitude::Int
    frequency::Int
    phase::Int
    offset::Int
    f_start::Int
    f_end::Int
    sweep_duration::Int
    step_time::Int
    pulse_start::Int
    pulse_width::Int
end

mutable struct SysIdSystem <: SS.AbstractSystem
    param_names::Vector{String}
    initial_values::Dict{String,Float64}
    signal_map::Vector{Tuple{String,String}}
    lifecycle::SS.SystemLifecycle
    lifecycle_slots::Union{SS.LifecycleSlots,Nothing}
    signal_slots::Vector{SignalParamSlots}
    output_slots::Vector{Int}
    signal_cache::Vector{CachedSignal}
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

function _signal_param_names(prefix::String)
    return String[
        "$(prefix)_type",
        "$(prefix)_amplitude",
        "$(prefix)_frequency",
        "$(prefix)_phase",
        "$(prefix)_offset",
        "$(prefix)_f_start",
        "$(prefix)_f_end",
        "$(prefix)_sweep_duration",
        "$(prefix)_step_time",
        "$(prefix)_pulse_start",
        "$(prefix)_pulse_width",
    ]
end

function SysIdSystem(signal_map::Vector{Tuple{String,String}})
    initial_values = Dict{String,Float64}(
        "elapsed"   => 0.0,
        "duration"  => 30.0,
        "running"   => 0.0,
        "start_cmd" => 0.0,
        "stop_cmd"  => 0.0,
    )
    param_names = ["elapsed", "duration", "running", "start_cmd", "stop_cmd"]
    for (prefix, _) in signal_map
        defaults = _default_signal_params(prefix)
        append!(param_names, _signal_param_names(prefix))
        merge!(initial_values, defaults)
    end
    signal_cache = Vector{CachedSignal}(undef, length(signal_map))
    ctrl = SysIdSystem(
        param_names,
        initial_values,
        signal_map,
        SS.SystemLifecycle(),
        nothing,
        SignalParamSlots[],
        Int[],
        signal_cache,
    )
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
    ctrl.initial_values["duration"] = cfg.duration
    for (prefix, spec) in cfg.signal_specs
        for (key, val) in spec
            param_key = "$(prefix)_$(key)"
            if haskey(ctrl.initial_values, param_key)
                ctrl.initial_values[param_key] = Float64(val)
            end
        end
    end
    return ctrl
end

function _bind_signal_slots(params, prefix::String)
    return SignalParamSlots(
        SS.signal_slot(params, "$(prefix)_type"),
        SS.signal_slot(params, "$(prefix)_amplitude"),
        SS.signal_slot(params, "$(prefix)_frequency"),
        SS.signal_slot(params, "$(prefix)_phase"),
        SS.signal_slot(params, "$(prefix)_offset"),
        SS.signal_slot(params, "$(prefix)_f_start"),
        SS.signal_slot(params, "$(prefix)_f_end"),
        SS.signal_slot(params, "$(prefix)_sweep_duration"),
        SS.signal_slot(params, "$(prefix)_step_time"),
        SS.signal_slot(params, "$(prefix)_pulse_start"),
        SS.signal_slot(params, "$(prefix)_pulse_width"),
    )
end

SS.parameter_names(ctrl::SysIdSystem) = copy(ctrl.param_names)

function SS.monitor_parameter_names(ctrl::SysIdSystem)
    return String[name for name in ctrl.param_names if name != "running" && name != "elapsed"]
end

function SS.initialize_parameters!(ctrl::SysIdSystem, params)::Nothing
    for name in ctrl.param_names
        params[name] = ctrl.initial_values[name]
    end
    return nothing
end

function SS.bind!(ctrl::SysIdSystem, runtime)::Nothing
    ctrl.lifecycle_slots = SS.bind_lifecycle(runtime.params)
    ctrl.signal_slots = [_bind_signal_slots(runtime.params, prefix) for (prefix, _) in ctrl.signal_map]
    ctrl.output_slots = [SS.signal_slot(runtime.outputs, out_key) for (_, out_key) in ctrl.signal_map]
    return nothing
end

function SS.parameters_updated!(ctrl::SysIdSystem, params)::Nothing
    @inbounds for i in eachindex(ctrl.signal_slots)
        ctrl.signal_cache[i] = signal_from_slots(params, ctrl.signal_slots[i])
    end
    return nothing
end

function SS.control_step!(ctrl::SysIdSystem, _inputs, outputs, params, dt_s::Float64)
    event = SS.update_lifecycle!(ctrl.lifecycle, params, ctrl.lifecycle_slots, dt_s)

    if event == :started
        SS.parameters_updated!(ctrl, params)
    end

    if ctrl.lifecycle.active
        t = ctrl.lifecycle.elapsed
        @inbounds for i in eachindex(ctrl.output_slots)
            sig = ctrl.signal_cache[i]
            outputs[ctrl.output_slots[i]] = sig === nothing ? 0.0 : evaluate(sig, t)
        end
    else
        @inbounds for slot in ctrl.output_slots
            outputs[slot] = 0.0
        end
    end

    return nothing
end

function sysid_callback(ctrl::SysIdSystem, inputs, outputs, params, dt_s::Float64)
    return SS.control_step!(ctrl, inputs, outputs, params, dt_s)
end
