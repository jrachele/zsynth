const Plugin = @This();

const std = @import("std");
const clap = @import("clap-bindings");

const options = @import("options");
const extensions = @import("extensions.zig");

const Params = @import("ext/params.zig");
const GUI = @import("ext/gui.zig");
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

const Jobs = packed struct(u32) {
    notify_host_params_changed: bool = false,
    notify_host_voices_changed: bool = false,
    _: u30 = 0,
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
    const voices = Voices.init(allocator, plugin);
    const params = Params.init(allocator);

    // Stack objects
    const wave_table = if (options.generate_wavetables_comptime)
        comptime waves.generate_wave_table()
    else
        waves.generate_wave_table();

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

// Notify the host that the voices have changed, which will request a main thread refresh from the host
pub fn notifyHostVoicesChanged(self: *Plugin) bool {
    if (self.jobs.notify_host_voices_changed) {
        std.log.warn("Host is already queued for notify voice changed, discarding request", .{});
        return false;
    }

    self.jobs.notify_host_voices_changed = true;
    self.host.requestCallback(self.host);
    return true;
}

// Notify the host that the params have changed, which will request a main thread refresh from the host
pub fn notifyHostParamsChanged(self: *Plugin) bool {
    if (self.jobs.notify_host_params_changed) {
        std.log.warn("Host is already queued for notify params changed, discarding request", .{});
        return false;
    }

    self.jobs.notify_host_params_changed = true;
    self.host.requestCallback(self.host);
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

fn _activate(
    clap_plugin: *const clap.Plugin,
    sample_rate: f64,
    _: u32,
    _: u32,
) callconv(.C) bool {
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
    plugin.jobs.notify_host_params_changed = true;
    plugin.host.requestCallback(plugin.host);
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

    const param_event_count = plugin.params.events.items.len;

    const output_buffer_left = clap_process.audio_outputs[0].data32.?[0];
    const output_buffer_right = clap_process.audio_outputs[0].data32.?[1];

    // Clear the output buffers of any leftover memory
    for (0..frame_count) |i| {
        output_buffer_left[i] = 0;
        output_buffer_right[i] = 0;
    }

    if (input_event_count == 0 and param_event_count == 0 and plugin.voices.getVoiceCount() == 0) {
        return clap.Process.Status.sleep;
    }

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

        // Process GUI parameter event changes
        if (plugin.params.mutex.tryLock()) {
            defer plugin.params.mutex.unlock();

            while (plugin.params.events.popOrNull()) |*event| {
                const event_header: *clap.events.Header = @constCast(@alignCast(&event.header));
                event_header.sample_offset = current_frame;
                if (!clap_process.out_events.tryPush(clap_process.out_events, event_header)) {
                    std.log.err("Unable to notify DAW of parameter event changes!", .{});
                    return clap.Process.Status.@"error";
                }
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

    // Process parameter event changes
    extensions.Params._flush(clap_plugin, clap_process.in_events, clap_process.out_events);

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
            _ = plugin.notifyHostVoicesChanged();
            if (i > 0) {
                i -= 1;
            }
        }
    }
    return clap.Process.Status.@"continue";
}

const ext_audio_ports = extensions.AudioPorts.create();
const ext_note_ports = extensions.NotePorts.create();
const ext_params = extensions.Params.create();
const ext_state = extensions.State.create();
const ext_gui = extensions.GUI.create();
const ext_voice_info = extensions.VoiceInfo.create();

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

    return null;
}

fn _onMainThread(clap_plugin: *const clap.Plugin) callconv(.C) void {
    const plugin = fromClapPlugin(clap_plugin);
    if (plugin.jobs.notify_host_params_changed) {
        if (plugin.host.getExtension(plugin.host, clap.ext.params.id)) |host_header| {
            std.log.debug("Notifying host that params changed", .{});
            var params_host: *clap.ext.params.Host = @constCast(@ptrCast(@alignCast(host_header)));
            params_host.rescan(plugin.host, .{
                .all = true,
            });
        } else {
            std.log.err("Unable to query params extension to notify params changed!", .{});
        }
        plugin.jobs.notify_host_params_changed = false;
    }

    if (plugin.jobs.notify_host_voices_changed) {
        if (plugin.host.getExtension(plugin.host, clap.ext.voice_info.id)) |host_header| {
            std.log.debug("Notifying host that voices changed", .{});
            var voice_info_host: *clap.ext.voice_info.Host = @constCast(@ptrCast(@alignCast(host_header)));
            voice_info_host.changed(plugin.host);
        } else {
            std.log.err("Unable to query voice info extension to notify voices changed!", .{});
        }
        plugin.jobs.notify_host_voices_changed = false;
    }

    // Update the GUI if exists
    if (plugin.gui) |gui| {
        if (gui.is_visible) {
            if (!gui.draw()) {
                if (plugin.host.getExtension(plugin.host, clap.ext.gui.id)) |host_header| {
                    var gui_host: *clap.ext.gui.Host = @constCast(@ptrCast(@alignCast(host_header)));
                    gui_host.closed(plugin.host, true);
                }
            }
        }
    }
}
