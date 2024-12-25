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
    should_rescan_params: bool = false,
    sync_params_to_host: bool = false,
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

pub fn fromClapPlugin(plugin: *const clap.Plugin) *@This() {
    return @ptrCast(@alignCast(plugin.plugin_data));
}

const Plugin = @This();

pub fn init(allocator: std.mem.Allocator, host: *const clap.Host) !*Plugin {
    // Heap objects
    const plugin = try allocator.create(Plugin);
    const voices = Voices.init(allocator);
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
    plugin.jobs.should_rescan_params = true;
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
    const event_count = clap_process.in_events.size(clap_process.in_events);

    // Process parameter event changes
    extensions.Params._flush(clap_plugin, clap_process.in_events, clap_process.out_events);

    const output_buffer_left = clap_process.audio_outputs[0].data32.?[0];
    const output_buffer_right = clap_process.audio_outputs[0].data32.?[1];

    var event_index: u32 = 0;
    var current_frame: u32 = 0;
    while (current_frame < frame_count) {
        // Process all events scheduled for the current frame
        while (event_index < event_count) {
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

            while (plugin.params.events.popOrNull()) |event| {
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
        if (event_index < event_count) {
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
    return clap.Process.Status.@"continue";
}

const ext_audio_ports = extensions.AudioPorts.create();
const ext_note_ports = extensions.NotePorts.create();
const ext_params = extensions.Params.create();
const ext_state = extensions.State.create();
const ext_gui = extensions.GUI.create();

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

    return null;
}

fn _onMainThread(clap_plugin: *const clap.Plugin) callconv(.C) void {
    std.log.debug("onMainThread invoked...", .{});
    const plugin = fromClapPlugin(clap_plugin);
    if (plugin.jobs.should_rescan_params) {
        // Tell the host to rescan the parameters
        std.log.debug("Rescanning parameters...", .{});
        const params_host = plugin.host.getExtension(plugin.host, clap.ext.params.id);
        if (params_host == null) {
            std.log.debug("Could not get params host!", .{});
        } else {
            const p: *const clap.ext.params.Host = @ptrCast(@alignCast(params_host.?));
            std.log.debug("Clearing and rescanning all", .{});
            var i: usize = 0;
            while (i < Params.param_count) : (i += 1) {
                p.clear(plugin.host, @enumFromInt(i), .{ .all = true });
            }
            p.rescan(plugin.host, .{
                .all = true,
            });
        }
        plugin.jobs.should_rescan_params = false;
    }

    // Update the GUI if exists
    if (plugin.gui != null) {
        while (plugin.gui.?.draw()) {}
        plugin.gui.?.deinit();
        plugin.gui = null;
        if (plugin.host.getExtension(plugin.host, clap.ext.gui.id)) |host_header| {
            var gui_host: *clap.ext.gui.Host = @constCast(@ptrCast(@alignCast(host_header)));
            std.log.debug("Got GUI host, sending closed event", .{});
            // Is this a Bitwig bug or is this not being listened to properly?
            gui_host.closed(plugin.host, true);
        }
    }
}
