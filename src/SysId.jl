module SysId

include("signals.jl")
include("system.jl")
include("experiment.jl")

export AbstractSignal, SineSignal, ChirpSignal, StepSignal, PulseSignal,
       evaluate, signal_from_params,
       ExperimentConfig, SysIdSystem,
       run_experiment!, sysid_callback

end # module SysId
