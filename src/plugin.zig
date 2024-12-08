const std = @import("std");
const clap = @import("clap-bindings");

const extensions = @import("extensions.zig");

sample_rate: ?f64 = null,
allocator: std.mem.Allocator,
plugin: clap.Plugin,
host: *const clap.Host,
voices: std.ArrayList(Voice),

pub const desc = clap.Plugin.Descriptor{
    .clap_version = clap.clap_version,
    .id = "com.juge.zig-audio-plugin",
    .name = "Zig Audio Plugin",
    .vendor = "juge",
    .url = "",
    .manual_url = "",
    .support_url = "",
    .version = "1.0.0",
    .description = "Test CLAP Plugin written in Zig",
    .features = &.{ clap.Plugin.features.stereo, clap.Plugin.features.synthesizer, clap.Plugin.features.instrument },
};

pub fn fromPlugin(plugin: *const clap.Plugin) *@This() {
    return @ptrCast(@alignCast(plugin.plugin_data));
}

pub fn create(host: *const clap.Host, allocator: std.mem.Allocator) !*const clap.Plugin {
    const clap_demo = try allocator.create(@This());
    const voices = std.ArrayList(Voice).init(allocator);
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
    };

    return &clap_demo.plugin;
}

// Plugin callbacks
fn _init(_: *const clap.Plugin) callconv(.C) bool {
    return true;
}

fn _destroy(plugin: *const clap.Plugin) callconv(.C) void {
    var clap_demo = fromPlugin(plugin);
    clap_demo.voices.deinit();
    clap_demo.allocator.destroy(clap_demo);
}

fn _activate(
    plugin: *const clap.Plugin,
    sample_rate: f64,
    _: u32,
    _: u32,
) callconv(.C) bool {
    var clap_demo = fromPlugin(plugin);
    clap_demo.sample_rate = sample_rate;
    return true;
}

fn _deactivate(_: *const clap.Plugin) callconv(.C) void {}

fn _startProcessing(_: *const clap.Plugin) callconv(.C) bool {
    std.debug.print("Start processing\n", .{});
    return true;
}

fn _stopProcessing(_: *const clap.Plugin) callconv(.C) void {
    std.debug.print("Stop processing\n", .{});
}

fn _reset(_: *const clap.Plugin) callconv(.C) void {
    std.debug.print("Reset\n", .{});
}

// TODO: Turn these into parameters
const attack_interval = 100; // milliseconds
const decay_interval = 0; // milliseconds
const sustain_amplitude = 1.0;
const release_interval = 100; // frames, TODO use milliseconds

const Voice = struct {
    noteId: i32,
    channel: i16,
    key: i16,
    start_time: i64,
    release_time: i64,

    pub fn is_ended(self: *const @This(), current_time: i64) bool {
        // TODO: Get the sample rate and convert the release interval to frames from milliseconds
        return self.release_time + release_interval >= current_time;
    }
};

fn _process(plugin: *const clap.Plugin, clap_process: *const clap.Process) callconv(.C) clap.Process.Status {
    const self = fromPlugin(plugin);
    std.debug.assert(clap_process.audio_inputs_count == 0);
    std.debug.assert(clap_process.audio_outputs_count == 1);

    // Each frame lasts 1 / 48000 seconds. There are typically 256 frames per process call
    const frame_count = clap_process.frames_count;

    // The number of events corresponds to how many are expected to occur within my 256 frame range
    const event_count = clap_process.in_events.size(clap_process.in_events);

    var event_index: u32 = 0;
    var current_frame: u32 = 0;

    const output_buffer_left = clap_process.audio_outputs[0].data32.?[0];
    const output_buffer_right = clap_process.audio_outputs[0].data32.?[1];

    const output_left = output_buffer_left[0..frame_count];
    const output_right = output_buffer_right[0..frame_count];
    @memset(output_left, 1);
    @memset(output_right, 1);

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
                self.process_event(clap_process.steady_time + current_frame, event);
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
        self.render_audio(clap_process.steady_time + current_frame, current_frame, next_frame, output_buffer_left, output_buffer_right);
        current_frame = next_frame;
    }

    var i: u32 = 0;
    while (i < self.voices.items.len) : (i += 1) {
        const voice = &self.voices.items[i];
        if (voice.is_ended(clap_process.steady_time)) {
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
                std.debug.print("Unable to process", .{});
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

// Processing logic
fn process_event(self: *@This(), current_time: i64, event: *const clap.events.Header) void {
    if (event.space_id != clap.events.core_space_id) {
        return;
    }
    if (!(event.type == .note_on or event.type == .note_off or event.type == .note_choke)) {
        return;
    }

    // We can cast the pointer as we now know that is the parent type
    const note_event: *const clap.events.Note = @ptrCast(@alignCast(event));
    if (event.type == .note_on) {
        const voice = Voice{ .noteId = note_event.note_id, .channel = note_event.channel, .key = note_event.key, .start_time = current_time, .release_time = std.math.minInt(i64) };

        self.voices.append(voice) catch {
            std.debug.print("Unable to append voice!", .{});
            return;
        };
    } else {
        var i: u32 = 0;
        while (i < self.voices.items.len) : (i += 1) {
            var voice = &self.voices.items[i];
            if ((voice.channel == note_event.channel or note_event.channel == -1) and
                (voice.key == note_event.key or note_event.key == -1) and
                (voice.noteId == note_event.note_id or note_event.note_id == -1))
            {
                // if (voice.noteId == note_event.note_id) {
                // Note choke would have the note be immediately removed
                if (event.type == .note_choke) {
                    _ = self.voices.orderedRemove(i);
                    if (i > 0) {
                        i -= 1;
                    }
                } else {
                    voice.release_time = current_time;
                }
            }
        }
    }
}

fn clamp1(f: f64) f64 {
    if (f < 0) return 0;
    if (f > 1) return 1;
    return f;
}

fn render_audio(self: *@This(), current_time: i64, start: u32, end: u32, output_left: [*]f32, output_right: [*]f32) void {
    var index = start;
    var time = current_time;
    while (index < end) : (index += 1) {
        var sum: f64 = 0;
        // Apply a sine wave for each voice, this could/should be done in a separate function
        var i: u32 = 0;
        while (i < self.voices.items.len) : (i += 1) {
            const voice = &self.voices.items[i];
            // Oscillations per second.
            const frequency = 440.0 * std.math.exp2((@as(f64, @floatFromInt(voice.key)) - 57.0) / 12.0);

            // Where in the wave are we? 1 wavelength is 1 / frequency long
            // So we can divide that by the sample rate to get the number of wave segments per sample
            // Then we can tell where we are in the segment by passing in the current_time minus the start_time
            // And throwing that into sine
            const phase = (frequency / self.sample_rate.?) * @as(f64, @floatFromInt((time - voice.start_time)));
            sum += std.math.sin(phase * 2.0 * 3.14159) * 0.6 * (1 / @as(f64, @floatFromInt(self.voices.items.len)));
        }
        // sum = clamp1(sum);

        output_left[index] = @floatCast(sum);
        output_right[index] = @floatCast(sum);
        time += 1;
    }
}
fn _getExtension(_: *const clap.Plugin, id: [*:0]const u8) callconv(.C) ?*const anyopaque {
    if (std.mem.eql(u8, std.mem.span(id), clap.extensions.audio_ports.id)) {
        return &extensions.audio_ports;
    }
    if (std.mem.eql(u8, std.mem.span(id), clap.extensions.note_ports.id)) {
        return &extensions.note_ports;
    }

    return null;
}

fn _onMainThread(_: *const clap.Plugin) callconv(.C) void {}
