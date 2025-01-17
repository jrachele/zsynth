const Plugin = @This();

const std = @import("std");
const clap = @import("clap-bindings");

const options = @import("options");
const extensions = @import("extensions.zig");

const Params = @import("ext/params.zig");
const GUI = @import("ext/gui/gui.zig");
const Voices = @import("audio/voices.zig");

const audio = @import("audio/audio.zig");
const waves = @import("audio/waves.zig");

const Parameter = Params.Parameter;
const Voice = Voices.Voice;
const WaveTable = waves.WaveTable;

sample_rate: ?f64 = null,
allocator: std.mem.Allocator,
plugin: clap.Plugin,
host: *const clap.Host,
voices: Voices,
params: Params,
gui: ?*GUI,
wave_table: WaveTable,

jobs: Jobs = .{},
job_mutex: std.Thread.Mutex,

const Jobs = packed struct(u32) {
    notify_host_params_changed: bool = false,
    _: u31 = 0,
};

pub const desc = clap.Plugin.Descriptor{
    .clap_version = clap.version,
    .id = "com.juge.zsynth",
    .name = "ZSynth",
    .vendor = "juge",
    .url = "",
    .manual_url = "",
    .support_url = "",
    .version = "0.0.1",
    .description = "Basic Synthesizer CLAP Plugin",
    .features = &.{ clap.Plugin.features.stereo, clap.Plugin.features.synthesizer, clap.Plugin.features.instrument },
};

pub fn fromClapPlugin(clap_plugin: *const clap.Plugin) *Plugin {
    return @ptrCast(@alignCast(clap_plugin.plugin_data));
}

pub fn init(allocator: std.mem.Allocator, host: *const clap.Host) !*Plugin {
    // Heap objects
    const plugin = try allocator.create(Plugin);
    const voices = Voices.init(allocator);
    const params = Params.init(allocator);

    // Stack objects
    const wave_table = if (options.generate_wavetables_comptime)
        comptime waves.generateWaveTable()
    else
        waves.generateWaveTable();

    plugin.* = .{
        .allocator = allocator,
        .plugin = .{
            .descriptor = &desc,
            .plugin_data = plugin,
            .init = _init,
            .destroy = _destroy,
            .activate = _activate,
            .deactivate = _deactivate,
            .startProcessing = _startProcessing,
            .stopProcessing = _stopProcessing,
            .reset = _reset,
            .process = _process,
            .getExtension = _getExtension,
            .onMainThread = _onMainThread,
        },
        .host = host,
        .voices = voices,
        .params = params,
        .wave_table = wave_table,
        .gui = null,
        .job_mutex = .{},
    };

    return plugin;
}

pub fn deinit(self: *Plugin) void {
    self.voices.deinit();
    self.params.deinit();
    self.allocator.destroy(self);
}

pub fn create(host: *const clap.Host, allocator: std.mem.Allocator) !*const clap.Plugin {
    const plugin = try Plugin.init(allocator, host);
    // This looks dangerous, but the object has the pointer so it's chill
    return &plugin.plugin;
}

// Notify the host that the params have changed, which will request a main thread refresh from the host
pub fn notifyHostParamsChanged(self: *Plugin) bool {
    self.job_mutex.lock();
    defer self.job_mutex.unlock();

    if (self.jobs.notify_host_params_changed) {
        std.log.debug("Host is already queued for notify params changed, discarding request", .{});
        return false;
    }

    self.jobs.notify_host_params_changed = true;
    return true;
}

// Plugin callbacks
fn _init(_: *const clap.Plugin) callconv(.C) bool {
    std.log.debug("Plugin initialized!", .{});
    return true;
}

fn _destroy(clap_plugin: *const clap.Plugin) callconv(.C) void {
    std.log.debug("Plugin destroyed!", .{});
    const plugin = fromClapPlugin(clap_plugin);
    plugin.deinit();
}

fn beginMainThreadLoop(plugin: *Plugin) void {
    while (plugin.loop_thread != null) {
        plugin.host.requestCallback(plugin.host);
    }
}

fn _activate(
    clap_plugin: *const clap.Plugin,
    sample_rate: f64,
    _: u32,
    _: u32,
) callconv(.C) bool {
    std.log.debug("Activate", .{});
    const plugin = fromClapPlugin(clap_plugin);
    plugin.sample_rate = sample_rate;
    return true;
}

fn _deactivate(_: *const clap.Plugin) callconv(.C) void {
    std.log.debug("Deactivate", .{});
}

fn _startProcessing(_: *const clap.Plugin) callconv(.C) bool {
    std.log.debug("Start processing", .{});
    return true;
}

fn _stopProcessing(_: *const clap.Plugin) callconv(.C) void {
    std.log.debug("Stop processing", .{});
}

fn _reset(clap_plugin: *const clap.Plugin) callconv(.C) void {
    std.log.debug("Reset", .{});

    // Tell the host to rescan the parameters
    const plugin = fromClapPlugin(clap_plugin);
    _ = plugin.notifyHostParamsChanged();
}

// This occurs on the audio thread
fn _process(clap_plugin: *const clap.Plugin, clap_process: *const clap.Process) callconv(.C) clap.Process.Status {
    const plugin = fromClapPlugin(clap_plugin);
    std.debug.assert(clap_process.audio_inputs_count == 0);
    std.debug.assert(clap_process.audio_outputs_count == 1);

    // Each frame lasts 1 / 48000 seconds. There are typically 256 frames per process call
    const frame_count = clap_process.frames_count;

    // The number of events corresponds to how many are expected to occur within my 256 frame range
    const input_event_count = clap_process.in_events.size(clap_process.in_events);

    const output_buffer_left = clap_process.audio_outputs[0].data32.?[0];
    const output_buffer_right = clap_process.audio_outputs[0].data32.?[1];

    // Clear the output buffers of any leftover memory
    for (0..frame_count) |i| {
        output_buffer_left[i] = 0;
        output_buffer_right[i] = 0;
    }

    // Process parameter event changes
    extensions.Params._flush(clap_plugin, clap_process.in_events, clap_process.out_events);

    var event_index: u32 = 0;
    var current_frame: u32 = 0;
    while (current_frame < frame_count) {
        // Process all events scheduled for the current frame
        while (event_index < input_event_count) {
            const event = clap_process.in_events.get(clap_process.in_events, event_index);
            if (event.sample_offset > current_frame) {
                // Stop if the event time is beyond the current frame
                break;
            }

            // Append the event if it matches the current frame
            if (event.sample_offset == current_frame) {
                audio.processNoteChanges(plugin, event);
                event_index += 1;
            }
        }

        // Determine the next frame to render up to
        var next_frame: u32 = frame_count; // Default to the end of the frame buffer

        // If we still have an event left over, then the next frame begins at where the event begins
        if (event_index < input_event_count) {
            const next_event = clap_process.in_events.get(clap_process.in_events, event_index);
            next_frame = next_event.sample_offset;
        }

        // Render audio from the current frame to the next frame (or the end of the buffer)
        audio.renderAudio(plugin, current_frame, next_frame, output_buffer_left, output_buffer_right);
        current_frame = next_frame;
    }

    var i: u32 = 0;
    while (i < plugin.voices.voices.items.len) : (i += 1) {
        const voice = &plugin.voices.voices.items[i];
        if (voice.adsr.isEnded()) {
            const note = clap.events.Note{
                .header = .{
                    .size = @sizeOf(clap.events.Note),
                    .flags = .{},
                    .sample_offset = 0,
                    .space_id = clap.events.core_space_id,
                    .type = .note_end,
                },
                .key = voice.key,
                .note_id = voice.noteId,
                .channel = voice.channel,
                .port_index = .unspecified,
                .velocity = 1,
            };
            if (!clap_process.out_events.tryPush(clap_process.out_events, &note.header)) {
                std.log.debug("Unable to add note end events to outboard event queue!", .{});
                return clap.Process.Status.@"error";
            }

            _ = plugin.voices.voices.orderedRemove(i);
            if (i > 0) {
                i -= 1;
            }
        }
    }

    plugin.host.requestCallback(plugin.host);
    return clap.Process.Status.@"continue";
}

const ext_audio_ports = extensions.AudioPorts.create();
const ext_note_ports = extensions.NotePorts.create();
const ext_params = extensions.Params.create();
const ext_state = extensions.State.create();
const ext_gui = extensions.GUI.create();
const ext_voice_info = extensions.VoiceInfo.create();
const ext_thread_pool = extensions.ThreadPool.create();

fn _getExtension(_: *const clap.Plugin, id: [*:0]const u8) callconv(.C) ?*const anyopaque {
    std.log.debug("Get extension called {s}!", .{id});
    if (std.mem.eql(u8, std.mem.span(id), clap.ext.audio_ports.id)) {
        return &ext_audio_ports;
    }
    if (std.mem.eql(u8, std.mem.span(id), clap.ext.note_ports.id)) {
        return &ext_note_ports;
    }
    if (std.mem.eql(u8, std.mem.span(id), clap.ext.params.id)) {
        return &ext_params;
    }
    if (std.mem.eql(u8, std.mem.span(id), clap.ext.state.id)) {
        return &ext_state;
    }
    if (std.mem.eql(u8, std.mem.span(id), clap.ext.gui.id)) {
        return &ext_gui;
    }
    if (std.mem.eql(u8, std.mem.span(id), clap.ext.voice_info.id)) {
        return &ext_voice_info;
    }
    if (std.mem.eql(u8, std.mem.span(id), clap.ext.thread_pool.id)) {
        return &ext_thread_pool;
    }

    return null;
}

fn _onMainThread(clap_plugin: *const clap.Plugin) callconv(.C) void {
    const plugin = fromClapPlugin(clap_plugin);

    if (plugin.jobs.notify_host_params_changed) {
        plugin.job_mutex.lock();
        defer plugin.job_mutex.unlock();
        if (plugin.host.getExtension(plugin.host, clap.ext.params.id)) |host_header| {
            std.log.debug("Notifying host that params changed", .{});
            var params_host: *clap.ext.params.Host = @constCast(@ptrCast(@alignCast(host_header)));
            params_host.rescan(plugin.host, .{
                .text = true,
                .values = true,
            });
        } else {
            std.log.err("Unable to query params extension to notify params changed!", .{});
        }
        plugin.jobs.notify_host_params_changed = false;
    }

    // Update the GUI if exists
    if (plugin.gui) |gui| {
        gui.update() catch |err| {
            std.log.err("Error occurred during GUI update loop: {}", .{err});
        };
    }
}
