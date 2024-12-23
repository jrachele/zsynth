const std = @import("std");
const clap = @import("clap-bindings");

const extensions = @import("extensions.zig");

const Params = @import("ext/params.zig");
const audio = @import("audio/audio.zig");
const waves = @import("audio/waves.zig");

const Parameter = Params.Parameter;
const Voice = audio.Voice;

sample_rate: ?f64 = null,
allocator: std.mem.Allocator,
plugin: clap.Plugin,
host: *const clap.Host,
voices: std.ArrayList(Voice),
params: Params.ParamValues,

jobs: MainThreadJobs = .{},

const MainThreadJobs = packed struct(u32) {
    should_rescan_params: bool = false,
    sync_params_to_host: bool = false,
    generate_wave_table: bool = false,
    _: u29 = 0,
};

pub const desc = clap.Plugin.Descriptor{
    .clap_version = clap.clap_version,
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

pub fn fromPlugin(plugin: *const clap.Plugin) *@This() {
    return @ptrCast(@alignCast(plugin.plugin_data));
}

pub fn create(host: *const clap.Host, allocator: std.mem.Allocator) !*const clap.Plugin {
    const clap_demo = try allocator.create(@This());
    const param_values = Params.ParamValues.init(Params.param_defaults);
    var voices = std.ArrayList(Voice).init(allocator);
    errdefer voices.deinit();
    errdefer allocator.destroy(clap_demo);
    clap_demo.* = .{
        .allocator = allocator,
        .plugin = .{
            .descriptor = &desc,
            .plugin_data = clap_demo,
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
        .params = param_values,
    };

    return &clap_demo.plugin;
}

// Plugin callbacks
fn _init(_: *const clap.Plugin) callconv(.C) bool {
    return true;
}

fn _destroy(plugin: *const clap.Plugin) callconv(.C) void {
    var self = fromPlugin(plugin);
    self.voices.deinit();
    self.allocator.destroy(self);
}

fn _activate(
    plugin: *const clap.Plugin,
    sample_rate: f64,
    _: u32,
    _: u32,
) callconv(.C) bool {
    var self = fromPlugin(plugin);
    self.sample_rate = sample_rate;
    if (!waves.comptime_wave_table) {
        self.jobs.generate_wave_table = true;
        self.host.requestCallback(self.host);
    }

    return true;
}

fn _deactivate(_: *const clap.Plugin) callconv(.C) void {}

fn _startProcessing(_: *const clap.Plugin) callconv(.C) bool {
    return true;
}

fn _stopProcessing(_: *const clap.Plugin) callconv(.C) void {
    std.debug.print("Stop processing\n", .{});
}

fn _reset(plugin: *const clap.Plugin) callconv(.C) void {
    std.debug.print("Reset\n", .{});
    // Tell the host to rescan the parameters
    var self = fromPlugin(plugin);
    self.jobs.should_rescan_params = true;
    self.host.requestCallback(self.host);
}

fn _process(plugin: *const clap.Plugin, clap_process: *const clap.Process) callconv(.C) clap.Process.Status {
    const self = fromPlugin(plugin);
    std.debug.assert(clap_process.audio_inputs_count == 0);
    std.debug.assert(clap_process.audio_outputs_count == 1);

    // Each frame lasts 1 / 48000 seconds. There are typically 256 frames per process call
    const frame_count = clap_process.frames_count;

    // The number of events corresponds to how many are expected to occur within my 256 frame range
    const event_count = clap_process.in_events.size(clap_process.in_events);

    // Process parameter event changes
    extensions.ext_params.flush(plugin, clap_process.in_events, clap_process.out_events);

    var event_index: u32 = 0;
    var current_frame: u32 = 0;

    const output_buffer_left = clap_process.audio_outputs[0].data32.?[0];
    const output_buffer_right = clap_process.audio_outputs[0].data32.?[1];

    const output_left = output_buffer_left[0..frame_count];
    const output_right = output_buffer_right[0..frame_count];

    // Set the initial signal to the impulse
    @memset(output_left, 0);
    @memset(output_right, 0);
    output_left[0] = 1;
    output_right[0] = 1;

    while (current_frame < frame_count) {
        // Process all events scheduled for the current frame
        while (event_index < event_count) {
            const event = clap_process.in_events.get(clap_process.in_events, event_index);
            if (event.sample_offset > current_frame) {
                // Stop if the event time is beyond the current frame
                break;
            }

            // Process the event if it matches the current frame
            if (event.sample_offset == current_frame) {
                audio.processNoteChanges(self, event);
                event_index += 1;
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
        audio.renderAudio(self, current_frame, next_frame, output_buffer_left, output_buffer_right);
        current_frame = next_frame;
    }

    var i: u32 = 0;
    while (i < self.voices.items.len) : (i += 1) {
        const voice = &self.voices.items[i];
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
                .port_index = 0,
                .velocity = 1,
            };
            if (!clap_process.out_events.tryPush(clap_process.out_events, &note.header)) {
                std.debug.print("Unable to add note end events to outboard event queue!\n", .{});
                return clap.Process.Status.@"error";
            }

            _ = self.voices.orderedRemove(i);
            if (i > 0) {
                i -= 1;
            }
        }
    }
    return clap.Process.Status.@"continue";
}

fn _getExtension(_: *const clap.Plugin, id: [*:0]const u8) callconv(.C) ?*const anyopaque {
    if (std.mem.eql(u8, std.mem.span(id), clap.extensions.audio_ports.id)) {
        return &extensions.ext_audio_ports;
    }
    if (std.mem.eql(u8, std.mem.span(id), clap.extensions.note_ports.id)) {
        return &extensions.ext_note_ports;
    }
    if (std.mem.eql(u8, std.mem.span(id), clap.extensions.parameters.id)) {
        return &extensions.ext_params;
    }
    if (std.mem.eql(u8, std.mem.span(id), clap.extensions.state.id)) {
        return &extensions.ext_state;
    }
    if (std.mem.eql(u8, std.mem.span(id), clap.extensions.gui.id)) {
        return &extensions.ext_gui;
    }

    return null;
}

fn _onMainThread(plugin: *const clap.Plugin) callconv(.C) void {
    const self = fromPlugin(plugin);
    if (self.jobs.should_rescan_params) {
        // Tell the host to rescan the parameters
        const params_host = self.host.getExtension(self.host, clap.extensions.parameters.id);
        if (params_host == null) {
            std.debug.print("Could not get params host!\n", .{});
        } else {
            const p: *const clap.extensions.parameters.Host = @ptrCast(@alignCast(params_host.?));
            std.debug.print("Clearing and rescanning all", .{});
            var i: usize = 0;
            while (i < Params.param_count) : (i += 1) {
                p.clear(self.host, @enumFromInt(i), .{ .all = true });
            }
            p.rescan(self.host, .{
                .all = true,
            });
        }
        self.jobs.should_rescan_params = false;
    }
    if (self.jobs.generate_wave_table) {
        // Sanity check
        if (!waves.comptime_wave_table) {
            waves.wave_table = waves.generate_wave_table();
        }
        self.jobs.generate_wave_table = false;
    }
}
