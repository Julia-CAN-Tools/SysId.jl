using Test
import SystemSimulator as SS
using SysId

mutable struct MockIO <: SS.AbstractIO
    rx::Channel{Any}
    tx::Channel{Any}
    in_names::Vector{String}
    out_names::Vector{String}
    closed::Bool
end

function MockIO(in_names::Vector{String}, out_names::Vector{String}; bufsize::Int=128)
    MockIO(Channel{Any}(bufsize), Channel{Any}(bufsize), in_names, out_names, false)
end

function SS.read_raw(io::MockIO)
    io.closed && return nothing
    try
        if isready(io.rx)
            return take!(io.rx)
        end
    catch
        return nothing
    end
    sleep(0.005)
    return nothing
end

function SS.decode_raw!(io::MockIO, raw, local_inputs::AbstractDict{String,Float64})::Bool
    raw isa AbstractDict || return false
    for name in io.in_names
        haskey(raw, name) && (local_inputs[name] = Float64(raw[name]))
    end
    return true
end

function SS.encode_raw(io::MockIO, local_outputs::AbstractDict{String,<:Real})::Vector{Any}
    isempty(io.out_names) && return Any[]
    payload = Dict{String,Float64}(name => Float64(get(local_outputs, name, 0.0)) for name in io.out_names)
    return Any[payload]
end

function SS.write_raw(io::MockIO, payload)::Nothing
    io.closed && return nothing
    put!(io.tx, payload)
    return nothing
end

SS.input_signal_names(io::MockIO) = copy(io.in_names)
SS.output_signal_names(io::MockIO) = copy(io.out_names)

function Base.close(io::MockIO)
    io.closed = true
    isopen(io.rx) && close(io.rx)
    isopen(io.tx) && close(io.tx)
    return nothing
end

function wait_until(predicate; timeout=2.0, step=0.01)
    t0 = time()
    while time() - t0 < timeout
        predicate() && return true
        sleep(step)
    end
    return predicate()
end

@testset "SysId" begin
    @testset "Signal generators" begin
        @test evaluate(SineSignal(amplitude=2.0, frequency=0.0, offset=1.0), 0.0) ≈ 1.0 atol=1e-10
        @test evaluate(StepSignal(amplitude=3.0, step_time=0.5, offset=1.0), 0.25) ≈ 1.0 atol=1e-10
        @test evaluate(StepSignal(amplitude=3.0, step_time=0.5, offset=1.0), 0.75) ≈ 4.0 atol=1e-10
        @test evaluate(PulseSignal(amplitude=5.0, pulse_start=1.0, pulse_width=0.5, offset=0.0), 1.25) ≈ 5.0 atol=1e-10
    end

    @testset "SysIdSystem parameter setup" begin
        ctrl = SysIdSystem([("T", "io.T"), ("S", "io.S")])
        @test "duration" in SS.parameter_names(ctrl)
        @test "T_type" in SS.parameter_names(ctrl)
        @test "S_amplitude" in SS.parameter_names(ctrl)
        @test SS.monitor_parameter_names(ctrl) == [name for name in SS.parameter_names(ctrl) if name != "running" && name != "elapsed"]
    end

    @testset "Runtime-driven excitation output" begin
        io = MockIO(String[], ["T"])
        logfile = tempname() * ".csv"
        cfg = SS.SystemConfig(20, [SS.IOConfig(:io, io, 32, SS.IO_MODE_WRITEONLY)], logfile)
        ctrl = SysIdSystem([("T", "io.T")])
        runtime = SS.SystemRuntime(cfg, SS.StopSignal(), ctrl)

        runtime.params["T_type"] = 3.0
        runtime.params["T_amplitude"] = 5.0
        runtime.params["T_step_time"] = 0.0
        runtime.params["T_offset"] = 0.0
        runtime.params["duration"] = 10.0
        runtime.params["start_cmd"] = 1.0
        SS.parameters_updated!(runtime.system, runtime.params)

        SS.start!(runtime)
        @test wait_until(() -> isapprox(runtime.outputs["io.T"], 5.0; atol=1e-10))
        @test isready(io.tx)
        payload = take!(io.tx)
        while isready(io.tx)
            payload = take!(io.tx)
        end
        @test payload["T"] ≈ 5.0 atol=1e-10

        SS.stop!(runtime)
        rm(logfile; force=true)
    end

    @testset "run_experiment! integration" begin
        io = MockIO(String[], ["T"])
        logfile = tempname() * ".csv"
        experiment = ExperimentConfig(0.2, Dict("T" => Dict("type" => 3.0, "amplitude" => 2.0, "step_time" => 0.0)))
        path = run_experiment!(
            [("T", "io.T")],
            [SS.IOConfig(:io, io, 32, SS.IO_MODE_WRITEONLY)],
            20;
            logfile=logfile,
            experiment=experiment,
            autostart=true,
        )

        @test path == logfile
        @test isfile(logfile)
        @test length(readlines(logfile)) >= 2
        rm(logfile; force=true)
    end
end
