"""
Excitation signal generators for system identification.

Four signal types with `evaluate(signal, t) -> Float64`:
- SineSignal, ChirpSignal, StepSignal, PulseSignal
"""

abstract type AbstractSignal end

# ── Sine ──────────────────────────────────────────────────────────────────────

struct SineSignal <: AbstractSignal
    amplitude::Float64
    frequency::Float64
    phase::Float64
    offset::Float64
end

SineSignal(; amplitude=1.0, frequency=1.0, phase=0.0, offset=0.0) =
    SineSignal(amplitude, frequency, phase, offset)

evaluate(s::SineSignal, t::Float64) =
    s.amplitude * sin(2π * s.frequency * t + s.phase) + s.offset

# ── Chirp ─────────────────────────────────────────────────────────────────────

struct ChirpSignal <: AbstractSignal
    amplitude::Float64
    f_start::Float64
    f_end::Float64
    duration::Float64
    offset::Float64
end

ChirpSignal(; amplitude=1.0, f_start=0.1, f_end=5.0, duration=10.0, offset=0.0) =
    ChirpSignal(amplitude, f_start, f_end, duration, offset)

function evaluate(s::ChirpSignal, t::Float64)
    k = (s.f_end - s.f_start) / s.duration
    return s.amplitude * sin(2π * (s.f_start * t + 0.5 * k * t^2)) + s.offset
end

# ── Step ──────────────────────────────────────────────────────────────────────

struct StepSignal <: AbstractSignal
    amplitude::Float64
    step_time::Float64
    offset::Float64
end

StepSignal(; amplitude=1.0, step_time=0.0, offset=0.0) =
    StepSignal(amplitude, step_time, offset)

evaluate(s::StepSignal, t::Float64) =
    t >= s.step_time ? s.amplitude + s.offset : s.offset

# ── Pulse ─────────────────────────────────────────────────────────────────────

struct PulseSignal <: AbstractSignal
    amplitude::Float64
    pulse_start::Float64
    pulse_width::Float64
    offset::Float64
end

PulseSignal(; amplitude=1.0, pulse_start=0.0, pulse_width=1.0, offset=0.0) =
    PulseSignal(amplitude, pulse_start, pulse_width, offset)

function evaluate(s::PulseSignal, t::Float64)
    if t >= s.pulse_start && t < s.pulse_start + s.pulse_width
        return s.amplitude + s.offset
    end
    return s.offset
end

# ── signal_from_params ────────────────────────────────────────────────────────

"""
    signal_from_params(params, prefix) -> Union{AbstractSignal, Nothing}

Construct a signal from the params dict by reading `<prefix>_type` and relevant fields.
Type codes: 0=off, 1=sine, 2=chirp, 3=step, 4=pulse.
Returns `nothing` for type 0 (off).
"""
function signal_from_params(params::Dict{String,Float64}, prefix::String)
    sig_type = round(Int, get(params, "$(prefix)_type", 0.0))

    if sig_type == 1  # sine
        return SineSignal(
            amplitude = get(params, "$(prefix)_amplitude", 1.0),
            frequency = get(params, "$(prefix)_frequency", 1.0),
            phase     = get(params, "$(prefix)_phase", 0.0),
            offset    = get(params, "$(prefix)_offset", 0.0),
        )
    elseif sig_type == 2  # chirp
        return ChirpSignal(
            amplitude = get(params, "$(prefix)_amplitude", 1.0),
            f_start   = get(params, "$(prefix)_f_start", 0.1),
            f_end     = get(params, "$(prefix)_f_end", 5.0),
            duration  = get(params, "$(prefix)_sweep_duration", 10.0),
            offset    = get(params, "$(prefix)_offset", 0.0),
        )
    elseif sig_type == 3  # step
        return StepSignal(
            amplitude = get(params, "$(prefix)_amplitude", 1.0),
            step_time = get(params, "$(prefix)_step_time", 0.0),
            offset    = get(params, "$(prefix)_offset", 0.0),
        )
    elseif sig_type == 4  # pulse
        return PulseSignal(
            amplitude   = get(params, "$(prefix)_amplitude", 1.0),
            pulse_start = get(params, "$(prefix)_pulse_start", 0.0),
            pulse_width = get(params, "$(prefix)_pulse_width", 1.0),
            offset      = get(params, "$(prefix)_offset", 0.0),
        )
    else
        return nothing  # type 0 or unknown → off
    end
end

function signal_from_slots(params, slots)
    sig_type = round(Int, params[slots.type])

    if sig_type == 1
        return SineSignal(
            amplitude = params[slots.amplitude],
            frequency = params[slots.frequency],
            phase     = params[slots.phase],
            offset    = params[slots.offset],
        )
    elseif sig_type == 2
        return ChirpSignal(
            amplitude = params[slots.amplitude],
            f_start   = params[slots.f_start],
            f_end     = params[slots.f_end],
            duration  = params[slots.sweep_duration],
            offset    = params[slots.offset],
        )
    elseif sig_type == 3
        return StepSignal(
            amplitude = params[slots.amplitude],
            step_time = params[slots.step_time],
            offset    = params[slots.offset],
        )
    elseif sig_type == 4
        return PulseSignal(
            amplitude   = params[slots.amplitude],
            pulse_start = params[slots.pulse_start],
            pulse_width = params[slots.pulse_width],
            offset      = params[slots.offset],
        )
    else
        return nothing
    end
end
