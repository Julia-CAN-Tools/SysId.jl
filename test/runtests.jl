using Test
import SystemSimulator as SS
using SysId

# ── MockIO (same pattern as SystemSimulator tests) ────────────────────────────

mutable struct MockIO <: SS.AbstractIO
    rx::Channel{Any}
    tx::Channel{Any}
    in_names::Vector{String}
    out_names::Vector{String}
    closed::Bool
end

function MockIO(in_names::Vector{String}, out_names::Vector{String}; bufsize::Int=128)
    return MockIO(Channel{Any}(bufsize), Channel{Any}(bufsize), in_names, out_names, false)
end

function SS.read_raw(io::MockIO)
    io.closed && return nothing
    try
        isready(io.rx) && return take!(io.rx)
    catch
        return nothing
    end
    sleep(0.005)
    return nothing
end

function SS.decode_raw!(io::MockIO, raw, local_inputs::Dict{String,Float64})::Bool
    raw isa AbstractDict || return false
    for name in io.in_names
        haskey(raw, name) && (local_inputs[name] = Float64(raw[name]))
    end
    return true
end

function SS.encode_raw(io::MockIO, local_outputs::AbstractDict{String,<:Real})::Vector{Any}
    isempty(io.out_names) && return Any[]
    payload = Dict{String,Float64}(
        name => Float64(get(local_outputs, name, 0.0)) for name in io.out_names
    )
    return Any[payload]
end

function SS.write_raw(io::MockIO, payload)::Nothing
    io.closed && return nothing
    put!(io.tx, payload)
    return nothing
end

SS.input_signal_names(io::MockIO)  = copy(io.in_names)
SS.output_signal_names(io::MockIO) = copy(io.out_names)

function Base.close(io::MockIO)::Nothing
    io.closed = true
    isopen(io.rx) && close(io.rx)
    isopen(io.tx) && close(io.tx)
    return nothing
end

# ─────────────────────────────────────────────────────────────────────────────
@testset "SysId" begin

    # ── Signal evaluate() ─────────────────────────────────────────────────────
    @testset "SineSignal" begin
        s = SineSignal(amplitude=2.0, frequency=1.0, phase=0.0, offset=0.5)
        @test evaluate(s, 0.0) ≈ 0.5          atol=1e-10  # sin(0)=0
        @test evaluate(s, 0.25) ≈ 2.5         atol=1e-10  # sin(π/2)=1
        @test evaluate(s, 0.5) ≈ 0.5          atol=1e-10  # sin(π)=0
        @test evaluate(s, 0.75) ≈ -1.5        atol=1e-10  # sin(3π/2)=-1
    end

    @testset "SineSignal defaults" begin
        s = SineSignal()
        @test s.amplitude == 1.0
        @test s.frequency == 1.0
        @test s.phase     == 0.0
        @test s.offset    == 0.0
        @test evaluate(s, 0.0) ≈ 0.0 atol=1e-10
    end

    @testset "ChirpSignal" begin
        s = ChirpSignal(amplitude=1.0, f_start=1.0, f_end=1.0, duration=10.0, offset=0.0)
        # With f_start == f_end == 1 Hz, k=0, behaves like a pure sine at 1 Hz
        @test evaluate(s, 0.0)  ≈ 0.0  atol=1e-10
        @test evaluate(s, 0.25) ≈ 1.0  atol=1e-10  # sin(π/2)=1
        @test evaluate(s, 0.5)  ≈ 0.0  atol=1e-8
    end

    @testset "ChirpSignal offset" begin
        s = ChirpSignal(amplitude=2.0, f_start=0.5, f_end=2.0, duration=5.0, offset=1.0)
        # At t=0: sin(0)=0, so evaluate=0+1=1
        @test evaluate(s, 0.0) ≈ 1.0 atol=1e-10
    end

    @testset "StepSignal" begin
        s = StepSignal(amplitude=3.0, step_time=1.0, offset=0.5)
        @test evaluate(s, 0.0)  ≈ 0.5  atol=1e-10  # before step
        @test evaluate(s, 0.99) ≈ 0.5  atol=1e-10  # just before
        @test evaluate(s, 1.0)  ≈ 3.5  atol=1e-10  # at step time
        @test evaluate(s, 5.0)  ≈ 3.5  atol=1e-10  # after step
    end

    @testset "StepSignal defaults" begin
        s = StepSignal()
        @test evaluate(s, 0.0) ≈ 1.0 atol=1e-10  # step at t=0
        @test evaluate(s, 1.0) ≈ 1.0 atol=1e-10
    end

    @testset "PulseSignal" begin
        s = PulseSignal(amplitude=5.0, pulse_start=2.0, pulse_width=1.0, offset=0.0)
        @test evaluate(s, 1.99) ≈ 0.0  atol=1e-10  # before pulse
        @test evaluate(s, 2.0)  ≈ 5.0  atol=1e-10  # at start
        @test evaluate(s, 2.5)  ≈ 5.0  atol=1e-10  # during
        @test evaluate(s, 3.0)  ≈ 0.0  atol=1e-10  # at end (exclusive)
        @test evaluate(s, 4.0)  ≈ 0.0  atol=1e-10  # after
    end

    @testset "PulseSignal with offset" begin
        s = PulseSignal(amplitude=1.0, pulse_start=0.0, pulse_width=0.5, offset=2.0)
        @test evaluate(s, 0.0)  ≈ 3.0 atol=1e-10  # pulse + offset
        @test evaluate(s, 0.5)  ≈ 2.0 atol=1e-10  # offset only (exclusive end)
    end

    # ── signal_from_params() ──────────────────────────────────────────────────
    @testset "signal_from_params type=0 → nothing" begin
        p = Dict{String,Float64}("Tau1_type" => 0.0)
        @test signal_from_params(p, "Tau1") === nothing
    end

    @testset "signal_from_params type=1 → SineSignal" begin
        p = Dict{String,Float64}(
            "Tau1_type"      => 1.0,
            "Tau1_amplitude" => 2.0,
            "Tau1_frequency" => 0.5,
            "Tau1_phase"     => 0.0,
            "Tau1_offset"    => 1.0,
        )
        sig = signal_from_params(p, "Tau1")
        @test sig isa SineSignal
        @test sig.amplitude == 2.0
        @test sig.frequency == 0.5
        @test sig.offset    == 1.0
    end

    @testset "signal_from_params type=2 → ChirpSignal" begin
        p = Dict{String,Float64}(
            "Tau2_type"           => 2.0,
            "Tau2_amplitude"      => 1.5,
            "Tau2_f_start"        => 0.1,
            "Tau2_f_end"          => 5.0,
            "Tau2_sweep_duration" => 20.0,
            "Tau2_offset"         => 0.0,
        )
        sig = signal_from_params(p, "Tau2")
        @test sig isa ChirpSignal
        @test sig.amplitude == 1.5
        @test sig.f_start   == 0.1
        @test sig.f_end     == 5.0
        @test sig.duration  == 20.0
    end

    @testset "signal_from_params type=3 → StepSignal" begin
        p = Dict{String,Float64}(
            "S_type"      => 3.0,
            "S_amplitude" => 4.0,
            "S_step_time" => 2.5,
            "S_offset"    => 0.5,
        )
        sig = signal_from_params(p, "S")
        @test sig isa StepSignal
        @test sig.amplitude == 4.0
        @test sig.step_time == 2.5
    end

    @testset "signal_from_params type=4 → PulseSignal" begin
        p = Dict{String,Float64}(
            "P_type"        => 4.0,
            "P_amplitude"   => 3.0,
            "P_pulse_start" => 1.0,
            "P_pulse_width" => 0.5,
            "P_offset"      => 0.0,
        )
        sig = signal_from_params(p, "P")
        @test sig isa PulseSignal
        @test sig.amplitude   == 3.0
        @test sig.pulse_start == 1.0
        @test sig.pulse_width == 0.5
    end

    @testset "signal_from_params uses defaults for missing keys" begin
        p = Dict{String,Float64}("X_type" => 1.0)
        sig = signal_from_params(p, "X")
        @test sig isa SineSignal
        @test sig.amplitude == 1.0
        @test sig.frequency == 1.0
    end

    # ── SysIdController construction ──────────────────────────────────────────
    @testset "SysIdController default constructor" begin
        signal_map = [("Tau1", "cmd.Tau1"), ("Tau2", "cmd.Tau2")]
        ctrl = SysIdController(signal_map)
        @test ctrl.lifecycle.elapsed == 0.0
        @test ctrl.params["duration"] == 30.0
        @test ctrl.params["running"] == 0.0
        @test ctrl.params["Tau1_type"] == 0.0
        @test ctrl.params["Tau2_type"] == 0.0
        @test haskey(ctrl.params, "Tau1_amplitude")
        @test haskey(ctrl.params, "Tau2_sweep_duration")
    end

    @testset "SysIdController with ExperimentConfig" begin
        signal_map = [("Tau1", "cmd.Tau1")]
        cfg = ExperimentConfig(10.0, Dict(
            "Tau1" => Dict("type" => 2.0, "amplitude" => 2.0, "f_start" => 0.1, "f_end" => 5.0, "sweep_duration" => 10.0),
        ))
        ctrl = SysIdController(signal_map, cfg)
        @test ctrl.params["duration"] == 10.0
        @test ctrl.params["Tau1_type"] == 2.0
        @test ctrl.params["Tau1_amplitude"] == 2.0
        @test ctrl.params["Tau1_f_start"] == 0.1
    end

    # ── sysid_callback direct tests ───────────────────────────────────────────
    @testset "sysid_callback writes signal values" begin
        signal_map = [("T", "io.T")]
        ctrl = SysIdController(signal_map)
        ctrl.params["T_type"]      = 3.0   # step
        ctrl.params["T_amplitude"] = 5.0
        ctrl.params["T_step_time"] = 0.0
        ctrl.params["T_offset"]    = 0.0
        ctrl.params["duration"]    = 10.0
        ctrl.params["start_cmd"]   = 1.0   # trigger start

        inputs  = Dict{String,Float64}()
        outputs = Dict{String,Float64}("io.T" => 0.0)

        sysid_callback(ctrl, inputs, outputs, 0.01)

        @test outputs["io.T"] ≈ 5.0 atol=1e-10
        @test ctrl.lifecycle.elapsed ≈ 0.01 atol=1e-10
        @test ctrl.params["running"] == 1.0
    end

    @testset "sysid_callback zeros outputs after duration" begin
        signal_map = [("T", "io.T")]
        ctrl = SysIdController(signal_map)
        ctrl.params["T_type"]      = 3.0
        ctrl.params["T_amplitude"] = 5.0
        ctrl.params["T_step_time"] = 0.0
        ctrl.params["duration"]    = 1.0
        ctrl.params["start_cmd"]   = 1.0   # trigger start
        ctrl.lifecycle.active = true
        ctrl.lifecycle.prev_start_cmd = 1.0
        ctrl.lifecycle.elapsed = 1.0   # already at duration

        outputs = Dict{String,Float64}("io.T" => 99.0)
        sysid_callback(ctrl, Dict{String,Float64}(), outputs, 0.01)

        @test outputs["io.T"] == 0.0
        @test ctrl.params["running"] == 0.0
        @test ctrl.lifecycle.active == false
    end

    @testset "sysid_callback type=0 outputs zero" begin
        signal_map = [("T", "io.T")]
        ctrl = SysIdController(signal_map)
        # type=0 → off, but experiment started
        ctrl.params["duration"]  = 10.0
        ctrl.params["start_cmd"] = 1.0   # trigger start

        outputs = Dict{String,Float64}("io.T" => 99.0)
        sysid_callback(ctrl, Dict{String,Float64}(), outputs, 0.01)
        @test outputs["io.T"] == 0.0
    end

    @testset "sysid_callback not active without start_cmd" begin
        signal_map = [("T", "io.T")]
        ctrl = SysIdController(signal_map)
        ctrl.params["T_type"]      = 3.0
        ctrl.params["T_amplitude"] = 5.0
        ctrl.params["duration"]    = 10.0
        # No start_cmd → not active

        outputs = Dict{String,Float64}("io.T" => 99.0)
        sysid_callback(ctrl, Dict{String,Float64}(), outputs, 0.01)
        @test outputs["io.T"] == 0.0
        @test ctrl.params["running"] == 0.0
        @test ctrl.lifecycle.active == false
    end

    @testset "sysid_callback stop_cmd stops experiment" begin
        signal_map = [("T", "io.T")]
        ctrl = SysIdController(signal_map)
        ctrl.params["T_type"]      = 3.0
        ctrl.params["T_amplitude"] = 5.0
        ctrl.params["duration"]    = 10.0
        ctrl.params["start_cmd"]   = 1.0
        ctrl.lifecycle.prev_start_cmd = 1.0
        ctrl.lifecycle.active = true
        ctrl.lifecycle.elapsed = 0.5

        # Trigger stop
        ctrl.params["stop_cmd"] = 1.0

        outputs = Dict{String,Float64}("io.T" => 0.0)
        sysid_callback(ctrl, Dict{String,Float64}(), outputs, 0.01)

        @test outputs["io.T"] == 0.0
        @test ctrl.params["running"] == 0.0
        @test ctrl.lifecycle.active == false
        @test ctrl.lifecycle.active == false
    end

    @testset "sysid_callback accumulates elapsed" begin
        signal_map = [("T", "io.T")]
        ctrl = SysIdController(signal_map)
        ctrl.params["duration"]  = 100.0
        ctrl.params["start_cmd"] = 1.0   # trigger start

        outputs = Dict{String,Float64}("io.T" => 0.0)
        for _ in 1:5
            sysid_callback(ctrl, Dict{String,Float64}(), outputs, 0.01)
        end
        @test ctrl.lifecycle.elapsed ≈ 0.05 atol=1e-10
        @test ctrl.params["elapsed"] ≈ 0.05 atol=1e-10
    end

    @testset "sysid_callback restart after stop" begin
        signal_map = [("T", "io.T")]
        ctrl = SysIdController(signal_map)
        ctrl.params["T_type"]      = 3.0
        ctrl.params["T_amplitude"] = 5.0
        ctrl.params["duration"]    = 10.0

        outputs = Dict{String,Float64}("io.T" => 0.0)

        # Start first experiment
        ctrl.params["start_cmd"] = 1.0
        sysid_callback(ctrl, Dict{String,Float64}(), outputs, 0.01)
        @test ctrl.lifecycle.active == true
        @test outputs["io.T"] ≈ 5.0 atol=1e-10

        # Stop it
        ctrl.params["stop_cmd"] = 1.0
        sysid_callback(ctrl, Dict{String,Float64}(), outputs, 0.01)
        @test ctrl.lifecycle.active == false

        # Start second experiment (increment start_cmd)
        ctrl.params["start_cmd"] = 2.0
        sysid_callback(ctrl, Dict{String,Float64}(), outputs, 0.01)
        @test ctrl.lifecycle.active == true
        @test ctrl.lifecycle.elapsed ≈ 0.01 atol=1e-10  # elapsed reset
        @test outputs["io.T"] ≈ 5.0 atol=1e-10
    end

    # ── Integration: MockIO + SystemRuntime ───────────────────────────────────
    @testset "Integration: MockIO end-to-end" begin
        # rx-only (plant state) and tx (excitation commands)
        io_rx = MockIO(["state"], String[])
        io_tx = MockIO(String[], ["cmd"])

        signal_map = [("S", "tx.cmd")]
        ctrl = SysIdController(signal_map)
        ctrl.params["S_type"]      = 3.0   # step
        ctrl.params["S_amplitude"] = 7.0
        ctrl.params["S_step_time"] = 0.0
        ctrl.params["S_offset"]    = 0.0
        ctrl.params["duration"]    = 10.0
        ctrl.params["start_cmd"]   = 1.0   # trigger start

        logfile = tempname() * ".csv"
        cfg = SS.SystemConfig(
            20,
            [
                SS.IOConfig(:rx, io_rx, 32, SS.IO_MODE_READONLY),
                SS.IOConfig(:tx, io_tx, 32, SS.IO_MODE_WRITEONLY),
            ],
            logfile,
        )
        runtime = SS.SystemRuntime(cfg, SS.StopSignal(), ctrl)
        SS.start!(runtime, sysid_callback)

        # Inject a plant state frame
        put!(io_rx.rx, Dict("state" => 1.23))
        sleep(0.5)

        # The tx channel should have command frames with ~7.0
        @test isready(io_tx.tx)
        payload = take!(io_tx.tx)
        @test payload["cmd"] ≈ 7.0 atol=1e-10

        # rx input should be visible in runtime
        @test runtime.inputs["rx.state"] ≈ 1.23 atol=1e-6

        SS.stop!(runtime)
        sleep(0.35)

        @test isfile(logfile)
        lines = readlines(logfile)
        @test length(lines) >= 2   # header + at least one data row
        @test startswith(lines[1], "Time")

        rm(logfile; force=true)
    end

end # @testset "SysId"
