#!/usr/bin/env julia
using Base.Sys: iswindows
using PortAudio:
    combine_default_sample_rates,
    devices,
    get_default_input_index,
    get_default_output_index,
    get_device_info,
    get_input_type,
    get_output_type,
    handle_status,
    initialize,
    PortAudioException,
    PortAudio,
    PortAudioDevice,
    PortAudioStream,
    safe_load,
    seek_alsa_conf,
    terminate
using PortAudio.LibPortAudio:
    Pa_AbortStream,
    PaError,
    PaErrorCode,
    paFloat32,
    Pa_GetDefaultHostApi,
    Pa_GetDeviceInfo,
    Pa_GetHostApiCount,
    Pa_GetLastHostErrorInfo,
    Pa_GetSampleSize,
    Pa_GetStreamCpuLoad,
    Pa_GetStreamInfo,
    Pa_GetStreamReadAvailable,
    Pa_GetStreamTime,
    Pa_GetStreamWriteAvailable,
    Pa_GetVersionInfo,
    Pa_HostApiDeviceIndexToDeviceIndex,
    paHostApiNotFound,
    Pa_HostApiTypeIdToHostApiIndex,
    PaHostErrorInfo,
    paInDevelopment,
    paInvalidDevice,
    Pa_IsFormatSupported,
    Pa_IsStreamActive,
    paNoError,
    paNoFlag,
    paNotInitialized,
    Pa_OpenDefaultStream,
    paOutputUnderflowed,
    Pa_SetStreamFinishedCallback,
    Pa_Sleep,
    Pa_StopStream,
    PaStream,
    PaStreamInfo,
    PaStreamParameters,
    PaVersionInfo
using SampledSignals: nchannels, s, SampleBuf, samplerate, SinSource
using Test: @test, @test_logs, @test_nowarn, @testset, @test_throws

@testset "Tests without sound" begin
    @testset "Reports version" begin
        io = IOBuffer()
        PortAudio.versioninfo(io)
        result = split(String(take!((io))), "\n")
        # make sure this is the same version I tested with
        @test startswith(result[1], "PortAudio V19")
    end

    @testset "Can list devices without crashing" begin
        display(devices())
        println()
    end

    @testset "libortaudio without sound" begin
        @test handle_status(Pa_GetHostApiCount()) >= 0
        @test handle_status(Pa_GetDefaultHostApi()) >= 0
        # version info not available on windows?
        if !Sys.iswindows()
            @test safe_load(Pa_GetVersionInfo(), ErrorException("no info")) isa
                  PaVersionInfo
        end
        @test safe_load(Pa_GetLastHostErrorInfo(), ErrorException("no info")) isa
              PaHostErrorInfo
        @test PaErrorCode(Pa_IsFormatSupported(C_NULL, C_NULL, 0.0)) == paInvalidDevice
        @test PaErrorCode(
            Pa_OpenDefaultStream(Ref(C_NULL), 0, 0, paFloat32, 0.0, 0, C_NULL, C_NULL),
        ) == paInvalidDevice
    end

    @testset "Errors without sound" begin
        @test sprint(showerror, PortAudioException(paNotInitialized)) ==
              "PortAudioException: PortAudio not initialized"
        @test_throws KeyError("foobarbaz") get_device_info("foobarbaz")
        @test_throws KeyError(-1) get_device_info(-1)
        @test_throws ArgumentError("Could not find alsa.conf in ()") seek_alsa_conf(())
        @test_logs (:warn, "libportaudio: Output underflowed") handle_status(
            PaError(paOutputUnderflowed),
        )
        @test_throws PortAudioException(paNotInitialized) handle_status(
            PaError(paNotInitialized),
        )
        Pa_Sleep(1)
        @test Pa_GetSampleSize(paFloat32) == 4
        @test_throws MethodError(get_input_type, (Any,)) get_input_type(Any)
        @test_throws MethodError(get_output_type, (Any,)) get_output_type(Any)
    end
end

if !isempty(devices())
    # make sure we can terminate, then reinitialize
    terminate()
    initialize()

    # these default values are specific to local machines
    input_index = get_default_input_index()
    default_input_device = get_device_info(input_index)
    default_input_device_name = default_input_device.name
    output_index = get_default_output_index()
    default_output_device = get_device_info(output_index)
    default_output_device_name = default_output_device.name

    @testset "Tests with sound" begin
        @testset "Interactive tests" begin
            println("Recording...")
            stream = PortAudioStream(2, 0)
            buffer = read(stream, 5s)
            sleep(1)
            @test size(buffer) ==
                  (round(Int, 5 * samplerate(stream)), nchannels(stream.source))
            close(stream)
            println("Playing back recording...")
            PortAudioStream(0, 2) do stream
                write(stream, buffer)
            end
            sleep(1)
            println("Testing pass-through")
            stream = PortAudioStream(2, 2)
            sink = stream.sink
            source = stream.source
            @test sprint(show, stream) == """
                PortAudioStream{Float32}
                  Samplerate: 44100.0Hz
                  2 channel sink: $(repr(default_output_device_name))
                  2 channel source: $(repr(default_input_device_name))"""
            @test sprint(show, sink) == "2 channel sink: $(repr(default_input_device_name))"
            @test sprint(show, source) ==
                  "2 channel source: $(repr(default_output_device_name))"
            write(stream, stream, 5s)
            sleep(1)
            @test PaErrorCode(handle_status(Pa_StopStream(stream.pointer_to))) == paNoError
            @test isopen(stream)
            close(stream)
            @test !isopen(stream)
            @test !isopen(sink)
            @test !isopen(source)
            println("done")
        end
        @testset "Samplerate-converting writing" begin
            PortAudioStream(0, 2) do stream
                write(
                    stream,
                    SinSource(eltype(stream), samplerate(stream) * 0.8, [220, 330]),
                    3s,
                )
                sleep(1)                
                write(
                    stream,
                    SinSource(eltype(stream), samplerate(stream) * 1.2, [220, 330]),
                    3s,
                )
                sleep(1)
            end
        end
        @testset "Open Device by name" begin
            PortAudioStream(default_input_device_name, default_output_device_name) do stream
            end
        end
        # no way to check that the right data is actually getting read or written here,
        # but at least it's not crashing.
        @testset "Queued Writing" begin
            PortAudioStream(0, 2) do stream
                buffer = SampleBuf(
                    rand(eltype(stream), 48000, nchannels(stream.sink)) * 0.1,
                    samplerate(stream),
                )
                frame_count_1 = @async write(stream, buffer)
                frame_count_2 = @async write(stream, buffer)
                @test fetch(frame_count_1) == 48000
                sleep(1)
                @test fetch(frame_count_2) == 48000
                sleep(1)
            end
        end
        @testset "Queued Reading" begin
            PortAudioStream(2, 0) do stream
                buffer = SampleBuf(
                    rand(eltype(stream), 48000, nchannels(stream.source)) * 0.1,
                    samplerate(stream),
                )
                frame_count_1 = @async read!(stream, buffer)
                frame_count_2 = @async read!(stream, buffer)
                @test fetch(frame_count_1) == 48000
                sleep(1)
                @test fetch(frame_count_2) == 48000
                sleep(1)
            end
        end
        @testset "Constructors" begin
            PortAudioStream(2, max; call_back = C_NULL) do stream
                @test isopen(stream)
            end
            PortAudioStream(default_input_device_name) do stream
                @test isopen(stream)
            end
        end
        @testset "Errors with sound" begin
            big = typemax(Int)
            @test_throws DomainError(
                typemax(Int),
                "$big exceeds max input channels for $default_input_device_name",
            ) PortAudioStream(big, 0)
            @test_throws ArgumentError("Input or output must have at least 1 channel") PortAudioStream(
                0,
                0,
            )
            @test_throws ArgumentError("""
            Default sample rate 0 for input $default_input_device_name disagrees with
            default sample rate 1 for output $default_output_device_name.
            Please specify a sample rate.
            """) combine_default_sample_rates(
                default_input_device,
                0,
                default_output_device,
                1,
            )
        end
        @testset "libportaudio with sound" begin
            @test PaErrorCode(Pa_HostApiTypeIdToHostApiIndex(paInDevelopment)) ==
                  paHostApiNotFound
            @test Pa_HostApiDeviceIndexToDeviceIndex(paInDevelopment, 0) == 0
            stream = PortAudioStream(2, 2)
            pointer_to = stream.pointer_to
            @test handle_status(Pa_GetStreamReadAvailable(pointer_to)) >= 0
            @test handle_status(Pa_GetStreamWriteAvailable(pointer_to)) >= 0
            @test Bool(handle_status(Pa_IsStreamActive(pointer_to)))
            @test safe_load(Pa_GetStreamInfo(pointer_to), ErrorException("no info")) isa
                  PaStreamInfo
            @test Pa_GetStreamTime(pointer_to) >= 0
            @test Pa_GetStreamCpuLoad(pointer_to) >= 0
            @test PaErrorCode(handle_status(Pa_AbortStream(pointer_to))) == paNoError
            @test PaErrorCode(
                handle_status(Pa_SetStreamFinishedCallback(pointer_to, C_NULL)),
            ) == paNoError
        end
    end
end
