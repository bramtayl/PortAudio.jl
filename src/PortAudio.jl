module PortAudio

using alsa_plugins_jll: alsa_plugins_jll
import Base:
    close,
    eltype,
    getindex,
    getproperty,
    IteratorSize,
    isopen,
    iterate,
    length,
    read,
    read!,
    show,
    showerror,
    write
using Base.Iterators: flatten, repeated
using Base.Threads: @spawn
using libportaudio_jll: libportaudio
using LinearAlgebra: transpose!
import SampledSignals: nchannels, samplerate, unsafe_read!, unsafe_write
using SampledSignals: SampleSink, SampleSource
using Suppressor: @capture_err

export PortAudioStream

include("libportaudio.jl")

using .LibPortAudio:
    paBadStreamPtr,
    Pa_CloseStream,
    PaDeviceIndex,
    PaDeviceInfo,
    PaError,
    PaErrorCode,
    Pa_GetDefaultInputDevice,
    Pa_GetDefaultOutputDevice,
    Pa_GetDeviceCount,
    Pa_GetDeviceInfo,
    Pa_GetErrorText,
    Pa_GetHostApiInfo,
    Pa_GetStreamReadAvailable,
    Pa_GetStreamWriteAvailable,
    Pa_GetVersion,
    Pa_GetVersionText,
    PaHostApiTypeId,
    Pa_Initialize,
    paInputOverflowed,
    Pa_IsStreamStopped,
    paNoFlag,
    Pa_OpenStream,
    paOutputUnderflowed,
    Pa_ReadStream,
    PaSampleFormat,
    Pa_StartStream,
    Pa_StopStream,
    PaStream,
    PaStreamParameters,
    Pa_Terminate,
    Pa_WriteStream

# for structs and strings
# PortAudio will return C_NULL instead of erroring
# so we need to handle these errors
function safe_load(result, an_error)
    if result == C_NULL
        throw(an_error)
    end
    unsafe_load(result)
end

# for functions that retrieve an index, throw a key error if it doesn't exist
function safe_key(a_function, an_index)
    safe_load(a_function(an_index), KeyError(an_index))
end

# error numbers are integers, while error codes are an @enum
function get_error_text(error_number)
    unsafe_string(Pa_GetErrorText(error_number))
end

struct PortAudioException <: Exception
    code::PaErrorCode
end
function showerror(io::IO, exception::PortAudioException)
    print(io, "PortAudioException: ")
    print(io, get_error_text(PaError(exception.code)))
end

# for integer results, PortAudio will return a negative number instead of erroring
# so we need to handle these errors
function handle_status(error_number; warn_xruns = true)
    if error_number < 0
        error_code = PaErrorCode(error_number)
        if error_code == paOutputUnderflowed || error_code == paInputOverflowed
            # warn instead of error after an xrun
            # allow users to disable these warnings
            if warn_xruns
                @warn("libportaudio: " * get_error_text(error_number))
            end
        else
            throw(PortAudioException(error_code))
        end
    end
    error_number
end

function initialize()
    # ALSA will throw extraneous warnings on start-up
    # send them to debug instead
    debug_message = @capture_err handle_status(Pa_Initialize())
    if !isempty(debug_message)
        @debug debug_message
    end
end

function terminate()
    handle_status(Pa_Terminate())
end

# alsa needs to know where the configure file is
function seek_alsa_conf(folders)
    for folder in folders
        if isfile(joinpath(folder, "alsa.conf"))
            return folder
        end
    end
    throw(ArgumentError("Could not find alsa.conf in $folders"))
end

function __init__()
    if Sys.islinux()
        config_folder = "ALSA_CONFIG_DIR"
        if config_folder ∉ keys(ENV)
            ENV[config_folder] =
                seek_alsa_conf(("/usr/share/alsa", "/usr/local/share/alsa", "/etc/alsa"))
        end
        # the plugin folder will contain plugins for, critically, PulseAudio
        plugin_folder = "ALSA_PLUGIN_DIR"
        if plugin_folder ∉ keys(ENV) && alsa_plugins_jll.is_available()
            ENV[plugin_folder] = joinpath(alsa_plugins_jll.artifact_dir, "lib", "alsa-lib")
        end
    end
    initialize()
    atexit() do
        terminate()
    end
end

function versioninfo(io::IO = stdout)
    println(io, unsafe_string(Pa_GetVersionText()))
    println(io, "Version: ", Pa_GetVersion())
end

# bounds for when a device is used as an input or output
struct Bounds
    max_channels::Int
    low_latency::Float64
    high_latency::Float64
end

struct PortAudioDevice
    name::String
    host_api::String
    default_sample_rate::Float64
    index::PaDeviceIndex
    input_bounds::Bounds
    output_bounds::Bounds
end

function PortAudioDevice(info::PaDeviceInfo, index)
    PortAudioDevice(
        unsafe_string(info.name),
        # replace host api code with its name
        unsafe_string(safe_key(Pa_GetHostApiInfo, info.hostApi).name),
        info.defaultSampleRate,
        index,
        Bounds(
            info.maxInputChannels,
            info.defaultLowInputLatency,
            info.defaultHighInputLatency,
        ),
        Bounds(
            info.maxOutputChannels,
            info.defaultLowOutputLatency,
            info.defaultHighInputLatency,
        ),
    )
end

name(device::PortAudioDevice) = device.name
# show name and input and output bounds
function show(io::IO, device::PortAudioDevice)
    print(io, repr(name(device)))
    print(io, ' ')
    print(io, device.input_bounds.max_channels)
    print(io, '→')
    print(io, device.output_bounds.max_channels)
end

function get_default_input_index()
    handle_status(Pa_GetDefaultInputDevice())
end

function get_default_output_index()
    handle_status(Pa_GetDefaultOutputDevice())
end

# we can look up devices by index or name
function get_device_info(index::Integer)
    PortAudioDevice(safe_key(Pa_GetDeviceInfo, index), index)
end

function get_device_info(device_name::AbstractString)
    for device in devices()
        potential_match = name(device)
        if potential_match == device_name
            return device
        end
    end
    throw(KeyError(device_name))
end

function devices()
    # need to use 0 indexing for C
    map(get_device_info, (1:handle_status(Pa_GetDeviceCount())) .- 1)
end

# we can handle reading and writing from buffers in a similar way
function read_or_write(a_function, buffer, args...)
    handle_status(
        # because we're calling Pa_ReadStream and Pa_WriteStream from separate threads,
        # we put a lock around these calls
        lock(buffer.stream_lock) do
            a_function(buffer.pointer_to, buffer.data, args...)
        end,
        warn_xruns = buffer.scribe.warn_xruns,
    )
end

function write_buffer(buffer, use_frames)
    read_or_write(Pa_WriteStream, buffer, use_frames)
end

function read_buffer(buffer, use_frames)
    read_or_write(Pa_ReadStream, buffer, use_frames)
end

# these will do the actual reading and writing
# you can switch out the SampledSignalsReader/Writer defaults if you want more direct access
# a Scribe must implement the following interface:
# must have a warn_xruns::Bool field 
# must have get_input_type and get_output_type methods
# must overload call for 2 arguments:
# 1) the buffer
# 2) a tuple of custom inputs
# and return the output type
# this call method can make use of read_buffer/write_buffer methods above
abstract type Scribe end

struct SampledSignalsReader{Sample} <: Scribe
    warn_xruns::Bool
end
function SampledSignalsReader(; Sample = Float32, warn_xruns = true)
    SampledSignalsReader{Sample}(warn_xruns)
end
struct SampledSignalsWriter{Sample} <: Scribe
    warn_xruns::Bool
end
function SampledSignalsWriter(; Sample = Float32, warn_xruns = true)
    SampledSignalsWriter{Sample}(warn_xruns)
end

# define on types
# throw an error if not defined
function get_input_type(a_type::Type)
    throw(MethodError(get_input_type, (a_type,)))
end
function get_output_type(a_type::Type)
    throw(MethodError(get_output_type, (a_type,)))
end

# convenience functions so you can pass objects too
function get_input_type(::Thing) where {Thing}
    get_input_type(Thing)
end

function get_output_type(::Thing) where {Thing}
    get_output_type(Thing)
end

# SampledSignals inputs will be a triple of the last 3 arguments to unsafe_read/write
# we will already have access to the stream itself
function get_input_type(
    ::Type{<:Union{<:SampledSignalsReader{Sample}, <:SampledSignalsWriter{Sample}}},
) where {Sample}
    Tuple{Array{Sample, 2}, Int, Int}
end

# output is the number of frames read/written
function get_output_type(::Type{<:Union{SampledSignalsReader, SampledSignalsWriter}})
    Int
end

# write a full chunk, starting from the middle of the julia buffer
function full_write!(buffer, julia_buffer, already)
    chunk_frames = buffer.chunk_frames
    @inbounds transpose!(
        buffer.data,
        view(julia_buffer, (1:chunk_frames) .+ already, :),
    )
    write_buffer(buffer, chunk_frames)
end

function (writer::SampledSignalsWriter)(buffer, (julia_buffer, offset, frame_count))
    chunk_frames = buffer.chunk_frames
    foreach(
        let buffer = buffer, julia_buffer = julia_buffer
            already -> full_write!(buffer, julia_buffer, already)
        end,
        # start at the offset, keep going until there is less than a chunk left
        offset:chunk_frames:(offset + frame_count - chunk_frames),
    )
    # write what's left
    left = frame_count % chunk_frames
    @inbounds transpose!(
        view(buffer.data, :, 1:left),
        # the last left frames of the julia buffer
        view(julia_buffer, (1:left) .+ (offset + frame_count - left), :),
    )
    write_buffer(buffer, left)
    frame_count
end

# similar to above
function full_read!(buffer, julia_buffer, already)
    chunk_frames = buffer.chunk_frames
    read_buffer(buffer, chunk_frames)
    @inbounds transpose!(
        view(julia_buffer, (1:chunk_frames) .+ already, :),
        buffer.data,
    )
end

function (reader::SampledSignalsReader)(buffer, (julia_buffer, offset, frame_count))
    chunk_frames = buffer.chunk_frames
    foreach(
        let buffer = buffer, julia_buffer = julia_buffer
            already -> full_read!(buffer, julia_buffer, already)
        end,
        offset:chunk_frames:(offset + frame_count - chunk_frames),
    )
    left = frame_count % chunk_frames
    read_buffer(buffer, left)
    @inbounds transpose!(
        view(julia_buffer, (1:left) .+ (offset + frame_count - left), :),
        view(buffer.data, :, 1:left),
    )
    frame_count
end

# a Buffer contains not just a buffer
# but everything you might need for a source or sink
# hopefully, because it is immutable, the optimizer can just pass what it needs
struct Buffer{Sample, Scribe, InputType, OutputType}
    stream_lock::ReentrantLock
    pointer_to::Ptr{PaStream}
    device::PortAudioDevice
    data::Array{Sample}
    number_of_channels::Int
    chunk_frames::Int
    scribe::Scribe
    inputs::Channel{InputType}
    outputs::Channel{OutputType}
    debug_io::IOStream
end

has_channels(something) = nchannels(something) > 0

function buffer_task(
    stream_lock,
    pointer_to,
    device,
    channels,
    scribe::Scribe,
    debug_io;
    Sample = Float32,
    chunk_frames = 128
) where {Scribe}
    InputType = get_input_type(scribe)
    OutputType = get_output_type(scribe)
    input_channel = Channel{InputType}(0)
    output_channel = Channel{OutputType}(0)
    # unbuffered channels so putting and taking will block till everyone's ready
    buffer = Buffer{Sample, Scribe, InputType, OutputType}(
        stream_lock,
        pointer_to,
        device,
        zeros(Sample, channels, chunk_frames),
        channels,
        chunk_frames,
        scribe,
        input_channel,
        output_channel,
        debug_io
    )
    # we will spawn new threads to read from and write to port audio
    # while the reading thread is talking to PortAudio, the writing thread can be setting up, and vice versa
    # start the scribe thread when its created
    # if there's channels at all
    # we can't make the task a field of the buffer, because the task uses the buffer
    task = Task(let buffer = buffer
        # xruns will return an error code and send a duplicate warning to stderr
        # since we handle the error codes, we don't need the duplicate warnings
        # so we send them to a debug log
        () -> redirect_stderr(buffer.debug_io) do
            run_scribe(buffer)
        end
    end)
    # makes it able to run on a separate thread
    task.sticky = false
    if has_channels(buffer)
        schedule(task)
        # output channel will close when the task ends
        bind(output_channel, task)
    else
        close(input_channel)
        close(output_channel)
    end
    buffer, task
end

nchannels(buffer::Buffer) = buffer.number_of_channels
name(buffer::Buffer) = name(buffer.device)

#
# PortAudioStream
#

struct PortAudioStream{SinkBuffer, SourceBuffer}
    sample_rate::Float64
    # pointer to the c object
    pointer_to::Ptr{PaStream}
    sink_buffer::SinkBuffer
    sink_task::Task
    source_buffer::SourceBuffer
    source_task::Task
    debug_file::String
    debug_io::IOStream
end

# portaudio uses codes instead of types for the sample format
const TYPE_TO_FORMAT = Dict{Type, PaSampleFormat}(
    Float32 => 1,
    Int32 => 2,
    # Int24 => 4,
    Int16 => 8,
    Int8 => 16,
    UInt8 => 3,
)

function make_parameters(
    device,
    channels,
    latency;
    Sample = Float32,
    host_api_specific_stream_info = C_NULL,
)
    if channels == 0
        # if we don't need any channels, we don't need the source/sink at all
        C_NULL
    else
        Ref(
            PaStreamParameters(
                device.index,
                channels,
                TYPE_TO_FORMAT[Sample],
                latency,
                host_api_specific_stream_info,
            ),
        )
    end
end

# if users passes max as the number of channels, we fill it in for them
# this is currently undocumented
function fill_max_channels(kind, device, bounds, channels)
    max_channels = bounds.max_channels
    if channels === max
        max_channels
    elseif channels > max_channels
        throw(
            DomainError(
                channels,
                "$channels exceeds max $kind channels for $(name(device))",
            ),
        )
    else
        channels
    end
end

# we can only have one sample rate
# so if the default sample rates differ, throw an error
function combine_default_sample_rates(
    input_device,
    input_sample_rate,
    output_device,
    output_sample_rate,
)
    if input_sample_rate != output_sample_rate
        throw(
            ArgumentError(
                """
Default sample rate $input_sample_rate for input $(name(input_device)) disagrees with
default sample rate $output_sample_rate for output $(name(output_device)).
Please specify a sample rate.
""",
            ),
        )
    end
    input_sample_rate
end

# the scribe will be running on a separate thread in the background
# alternating transposing and
# waiting to pass inputs and outputs back and forth to PortAudio
function run_scribe(buffer)
    scribe = buffer.scribe
    inputs = buffer.inputs
    outputs = buffer.outputs
    while true
        input = try
            take!(inputs)
        catch an_error
            # if the input channel is closed, the scribe knows its done
            if an_error isa InvalidStateException && an_error.state === :closed
                break
            else
                rethrow(an_error)
            end
        end
        put!(outputs, scribe(buffer, input))
    end
end

# this is the top-level outer constructor that all the other outer constructors end up calling
"""
    PortAudioStream(input_channels = 2, output_channels = 2; options...)
    PortAudioStream(duplex_device, input_channels = 2, output_channels = 2; options...)
    PortAudioStream(input_device, output_device, input_channels = 2, output_channels = 2; options...)

Audio devices can either be `PortAudioDevice` instances as returned
by `PortAudio.devices()`, or strings with the device name as reported by the
operating system. If a single `duplex_device` is given it will be used for both
input and output. If no devices are given the system default devices will be
used.

Options:

  - `Sample`: Sample type of the audio stream (defaults to Float32)
  - `sample_rate`: Sample rate (defaults to device sample rate)
  - `latency`: Requested latency. Stream could underrun when too low, consider
    using provided device defaults
  - `warn_xruns`: Display a warning if there is a stream overrun or underrun, which
    often happens when Julia is compiling, or with a particularly large
    GC run. This is true by default.
    Only effects duplex streams.
"""
function PortAudioStream(
    input_device::PortAudioDevice,
    output_device::PortAudioDevice,
    input_channels = 2,
    output_channels = 2;
    Sample = Float32,
    # for several keywords, nothing means we will fill them with defaults
    sample_rate = nothing,
    latency = nothing,
    warn_xruns = true,
    # these defaults are currently undocumented
    # data is passed to and from portaudio in chunks with this many frames
    chunk_frames = 128,
    frames_per_buffer = 0,
    flags = paNoFlag,
    call_back = C_NULL,
    user_data = C_NULL,
    input_info = C_NULL,
    output_info = C_NULL,
    stream_lock = ReentrantLock(),
    # this is where you can insert custom readers or writers instead
    writer = SampledSignalsWriter(; Sample = Sample, warn_xruns = warn_xruns),
    reader = SampledSignalsReader(; Sample = Sample, warn_xruns = warn_xruns)
)
    debug_file, debug_io = mktemp()
    input_channels_filled =
        fill_max_channels("input", input_device, input_device.input_bounds, input_channels)
    output_channels_filled = fill_max_channels(
        "output",
        output_device,
        output_device.output_bounds,
        output_channels,
    )
    # which defaults we use will depend on whether input or output have any channels
    if input_channels_filled > 0
        if output_channels_filled > 0
            if latency === nothing
                # use the max of high latency for input and output
                latency = max(
                    input_device.input_bounds.high_latency,
                    output_device.output_bounds.high_latency,
                )
            end
            if sample_rate === nothing
                sample_rate = combine_default_sample_rates(
                    input_device,
                    input_device.default_sample_rate,
                    output_device,
                    output_device.default_sample_rate,
                )
            end
        else
            if latency === nothing
                latency = input_device.input_bounds.high_latency
            end
            if sample_rate === nothing
                sample_rate = input_device.default_sample_rate
            end
        end
    else
        if output_channels_filled > 0
            if latency === nothing
                latency = output_device.output_bounds.high_latency
            end
            if sample_rate === nothing
                sample_rate = output_device.default_sample_rate
            end
        else
            throw(ArgumentError("Input or output must have at least 1 channel"))
        end
    end
    # we need a mutable pointer so portaudio can set it for us
    mutable_pointer = Ref{Ptr{PaStream}}(0)
    handle_status(
        Pa_OpenStream(
            mutable_pointer,
            make_parameters(
                input_device,
                input_channels_filled,
                latency;
                host_api_specific_stream_info = input_info,
            ),
            make_parameters(
                output_device,
                output_channels_filled,
                latency;
                Sample = Sample,
                host_api_specific_stream_info = output_info,
            ),
            sample_rate,
            frames_per_buffer,
            flags,
            call_back,
            user_data,
        ),
    )
    pointer_to = mutable_pointer[]
    handle_status(Pa_StartStream(pointer_to))
    PortAudioStream(
        sample_rate,
        pointer_to,
        # we need to keep track of the tasks
        # so we can wait for them to finish and catch errors
        buffer_task(
            stream_lock,
            pointer_to,
            output_device,
            output_channels_filled,
            writer,
            debug_io;
            Sample = Sample,
            chunk_frames = chunk_frames,
        )...,
        buffer_task(
            stream_lock,
            pointer_to,
            input_device,
            input_channels_filled,
            reader,
            debug_io;
            Sample = Sample,
            chunk_frames = chunk_frames,
        )...,
        debug_file,
        debug_io
    )
end

# handle device names given as streams
function PortAudioStream(
    in_device_name::AbstractString,
    out_device_name::AbstractString,
    arguments...;
    keywords...,
)
    PortAudioStream(
        get_device_info(in_device_name),
        get_device_info(out_device_name),
        arguments...;
        keywords...,
    )
end

# if one device is given, use it for input and output
function PortAudioStream(
    device::Union{PortAudioDevice, AbstractString},
    input_channels = 2,
    output_channels = 2;
    keywords...,
)
    PortAudioStream(device, device, input_channels, output_channels; keywords...)
end

# use the default input and output devices
function PortAudioStream(input_channels = 2, output_channels = 2; keywords...)
    in_index = get_default_input_index()
    out_index = get_default_output_index()
    PortAudioStream(
        get_device_info(in_index),
        get_device_info(out_index),
        input_channels,
        output_channels;
        keywords...,
    )
end

# handle do-syntax
function PortAudioStream(do_function::Function, arguments...; keywords...)
    stream = PortAudioStream(arguments...; keywords...)
    try
        do_function(stream)
    finally
        close(stream)
    end
end

function close(stream::PortAudioStream)
    source_buffer = stream.source_buffer
    sink_buffer = stream.sink_buffer
    # closing is tricky, because we want to make sure we've read exactly as much as we've written
    # but we have don't know exactly what the tasks are doing
    # for now, just close one and then the other
    if has_channels(source_buffer)
        # this will shut down the channels, which will shut down the threads
        close(source_buffer.inputs)
        # wait for tasks to finish to make sure any errors get caught
        wait(stream.source_task)
        # output channels will close because they are bound to the task
    end
    if has_channels(sink_buffer)
        close(sink_buffer.inputs)
        wait(stream.sink_task)
    end
    pointer_to = stream.pointer_to
    # only stop if it's not already stopped
    if !Bool(handle_status(Pa_IsStreamStopped(pointer_to)))
        handle_status(Pa_StopStream(pointer_to))
    end
    handle_status(Pa_CloseStream(pointer_to))
    # close the debug log and then read the file
    # this will contain duplicate xrun warnings mentioned above
    close(stream.debug_io)
    debug_log = open(stream.debug_file, "r") do io
        read(io, String)
    end
    if !isempty(debug_log)
        @debug debug_log
    end
end

function isopen(pointer_to::Ptr{PaStream})
    # we aren't actually interested if the stream is stopped or not
    # instead, we are looking for the error which comes from checking on a closed stream
    error_number = Pa_IsStreamStopped(pointer_to)
    if error_number >= 0
        true
    else
        PaErrorCode(error_number) != paBadStreamPtr
    end
end
isopen(stream::PortAudioStream) = isopen(stream.pointer_to)

samplerate(stream::PortAudioStream) = stream.sample_rate
function eltype(
    ::Type{<:PortAudioStream{<:Buffer{Sample}, <:Buffer{Sample}}},
) where {Sample}
    Sample
end

# these defaults will error for non-sampledsignal scribes
# which is probably ok; we want these users to define new methods
read(stream::PortAudioStream, arguments...) = read(stream.source, arguments...)
read!(stream::PortAudioStream, arguments...) = read!(stream.source, arguments...)
write(stream::PortAudioStream, arguments...) = write(stream.sink, arguments...)
function write(sink::PortAudioStream, source::PortAudioStream, arguments...)
    write(sink.sink, source.source, arguments...)
end

function show(io::IO, stream::PortAudioStream)
    # just show the first type parameter (eltype)
    print(io, "PortAudioStream{")
    print(io, eltype(stream))
    println(io, "}")
    print(io, "  Samplerate: ", samplerate(stream), "Hz")
    # show source or sink if there's any channels
    sink = stream.sink
    if has_channels(sink)
        print(io, "\n  ")
        show(io, sink)
    end
    source = stream.source
    if has_channels(source)
        print(io, "\n  ")
        show(io, source)
    end
end

#
# PortAudioSink & PortAudioSource
#

# Define our source and sink types
# If we had multiple inheritance, then PortAudioStreams could be both a sink and source
# Since we don't, we have to make wrappers instead
for (TypeName, Super) in ((:PortAudioSink, :SampleSink), (:PortAudioSource, :SampleSource))
    @eval struct $TypeName{InputBuffer, OutputBuffer} <: $Super
        stream::PortAudioStream{InputBuffer, OutputBuffer}
    end
end

# provided for backwards compatibility
# only defined for SampledSignals scribes
function getproperty(
    stream::PortAudioStream{
        <:Buffer{<:Any, <:SampledSignalsWriter},
        <:Buffer{<:Any, <:SampledSignalsReader},
    },
    property::Symbol,
)
    if property === :sink
        PortAudioSink(stream)
    elseif property === :source
        PortAudioSource(stream)
    else
        getfield(stream, property)
    end
end

function nchannels(source_or_sink::PortAudioSource)
    nchannels(source_or_sink.stream.source_buffer)
end
function nchannels(source_or_sink::PortAudioSink)
    nchannels(source_or_sink.stream.sink_buffer)
end
function samplerate(source_or_sink::Union{PortAudioSink, PortAudioSource})
    samplerate(source_or_sink.stream)
end
function eltype(
    ::Type{
        <:Union{
            <:PortAudioSink{<:Buffer{Sample}, <:Buffer{Sample}},
            <:PortAudioSource{<:Buffer{Sample}, <:Buffer{Sample}},
        },
    },
) where {Sample}
    Sample
end
function isopen(source_or_sink::Union{PortAudioSink, PortAudioSource})
    isopen(source_or_sink.stream)
end
name(source_or_sink::PortAudioSink) = name(source_or_sink.stream.sink_buffer)
name(source_or_sink::PortAudioSource) = name(source_or_sink.stream.source_buffer)

# could show full type name, but the PortAudio part is probably redundant
# because these will usually only get printed as part of show for PortAudioStream
kind(::PortAudioSink) = "sink"
kind(::PortAudioSource) = "source"
function show(io::IO, sink_or_source::Union{PortAudioSink, PortAudioSource})
    print(
        io,
        nchannels(sink_or_source),
        " channel ",
        kind(sink_or_source),
        ": ",
        # put in quotes
        repr(name(sink_or_source)),
    )
end

# both reading and writing will outsource to the readers or writers
# so we just need to pass inputs in and take outputs out
# SampledSignals can take care of this feeding for us
function exchange(buffer, arguments...)
    put!(buffer.inputs, arguments)
    take!(buffer.outputs)
end

# these will only work with sampledsignals scribes
function unsafe_write(
    sink::PortAudioSink{<:Buffer{<:Any, <:SampledSignalsWriter}},
    julia_buffer::Array,
    offset,
    frame_count,
)
    exchange(sink.stream.sink_buffer, julia_buffer, offset, frame_count)
end

function unsafe_read!(
    source::PortAudioSource{<:Any, <:Buffer{<:Any, <:SampledSignalsReader}},
    julia_buffer::Array,
    offset,
    frame_count,
)
    exchange(source.stream.source_buffer, julia_buffer, offset, frame_count)
end

end # module PortAudio
