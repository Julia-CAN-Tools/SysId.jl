"""
SysId — System Identification Package

Generates excitation signals (Chirp, Sine, Step, Pulse), sends them to a plant
over SocketCAN via SystemSimulator.jl's CanIO, and records the plant's response
to CSV. Provides Dash UI support for live signal parameter tuning.
"""
module SysId

include("signals.jl")
include("experiment.jl")

export AbstractSignal, SineSignal, ChirpSignal, StepSignal, PulseSignal
export evaluate, signal_from_params
export ExperimentConfig, SysIdSystem
export sysid_callback, run_experiment!

end # module SysId
