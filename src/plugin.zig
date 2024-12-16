const std = @import("std");
const clap = @import("clap-bindings");

const extensions = @import("extensions.zig");
const Parameters = @import("params.zig");

const Parameter = Parameters.Parameter;
const Wave = Parameters.Wave;

sample_rate: ?f64 = null,
allocator: std.mem.Allocator,
plugin: clap.Plugin,
host: *const clap.Host,
voices: std.ArrayList(Voice),
params: Parameters.ParamValues,

jobs: MainThreadJobs = .{},

const MainThreadJobs = packed struct(u32) {
    should_rescan_params: bool = false,
    sync_params_to_host: bool = false,
    _: u30 = 0,
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
    const params = Parameters.ParamValues.init(Parameters.param_defaults);
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
        .params = params,
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

const Voice = struct {
    noteId: i32,
    channel: i16,
    key: i16,
    adsr: ADSR,
    elapsed_frames: f64,
};

fn _process(plugin: *const clap.Plugin, clap_process: *const clap.Process) callconv(.C) clap.Process.Status {
    const self = fromPlugin(plugin);
    std.debug.assert(clap_process.audio_inputs_count == 0);
    std.debug.assert(clap_process.audio_outputs_count == 1);

    // Each frame lasts 1 / 48000 seconds. There are typically 256 frames per process call
    const frame_count = clap_process.frames_count;

    // The number of events corresponds to how many are expected to occur within my 256 frame range
    const event_count = clap_process.in_events.size(clap_process.in_events);

    // Process parameter event changes
    extensions.params.flush(plugin, clap_process.in_events, clap_process.out_events);

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

    // Process voice envelopes
    const dt = (@as(f64, @floatFromInt(frame_count)) / self.sample_rate.?) * 1000;
    for (self.voices.items) |*voice| {
        voice.adsr.update(dt);
    }

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
                self.processNoteChanges(event);
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
        self.renderAudio(current_frame, next_frame, output_buffer_left, output_buffer_right);
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
fn processNoteChanges(self: *@This(), event: *const clap.events.Header) void {
    if (event.space_id != clap.events.core_space_id) {
        return;
    }
    switch (event.type) {
        .note_on, .note_off, .note_choke => {
            // We can cast the pointer as we now know that is the parent type
            const note_event: *const clap.events.Note = @ptrCast(@alignCast(event));
            if (event.type == .note_on) {
                var adsr = ADSR.init(
                    self.params.get(Parameter.Attack),
                    self.params.get(Parameter.Decay),
                    self.params.get(Parameter.Sustain),
                    self.params.get(Parameter.Release),
                );

                adsr.onNoteOn();

                const voice = Voice{
                    .noteId = note_event.note_id,
                    .channel = note_event.channel,
                    .key = note_event.key,
                    .adsr = adsr,
                    .elapsed_frames = 0,
                };

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
                        // Note choke would have the note be immediately removed
                        if (event.type == .note_choke) {
                            _ = self.voices.orderedRemove(i);
                            if (i > 0) {
                                i -= 1;
                            }
                        } else {
                            voice.adsr.onNoteOff();
                        }
                    }
                }
            }
        },
        else => {},
    }
}

fn clamp1(f: f64) f64 {
    if (f < 0) return 0;
    if (f > 1) return 1;
    return f;
}

fn toFrames(ms: f64, sample_rate: f64) f64 {
    const seconds = ms / 1000;
    return std.math.floor(sample_rate * seconds);
}

fn min(a: f64, b: f64) f64 {
    if (a <= b) {
        return a;
    } else {
        return b;
    }
}

fn feedForward(x: []f64, fir: []const f64) f64 {
    var i: usize = 0;
    while (i < fir.len) : (i += 1) {
        x[i] = fir[i] * x[x.len - 1 - i];
    }
    return x[x.len - 1];
}

const ADSRState = enum {
    Idle,
    Attack,
    Decay,
    Sustain,
    Release,
};

const ADSR = struct {
    // State of the ADSR envelope
    state: ADSRState,
    attack_time: f64 = 0,
    decay_time: f64 = 0,
    release_time: f64 = 0,
    sustain_value: f64 = 0,

    // Current envelope value for fast retrieval
    value: f64 = 0,

    // Elapsed time since the last state change
    elapsed: f64 = 0,

    // Below this states will transition naturally into the next state
    const ms = 1;

    pub fn init(attack_time: f64, decay_time: f64, sustain_value: f64, release_time: f64) @This() {
        return .{
            .state = ADSRState.Idle,
            .attack_time = attack_time,
            .decay_time = decay_time,
            .release_time = release_time,
            .sustain_value = sustain_value,
        };
    }

    pub fn update(self: *@This(), dt: f64) void {
        switch (self.state) {
            ADSRState.Idle => {},
            ADSRState.Attack => {
                // Gradually build to attack_time
                self.value = self.elapsed / self.attack_time;
                if (self.value >= 1 or self.attack_time < ms) {
                    // Once we hit the top, begin decaying
                    self.value = 1;
                    self.state = .Decay;
                    self.elapsed = 0;
                }
            },
            ADSRState.Decay => {
                const decay_progress = self.elapsed / self.decay_time;
                self.value = 1.0 + (self.sustain_value - 1.0) * decay_progress;
                if (self.elapsed >= self.decay_time or self.decay_time < ms) {
                    self.value = self.sustain_value;
                    self.state = .Sustain;
                }
            },
            ADSRState.Sustain => {
                self.value = self.sustain_value;
            },
            ADSRState.Release => {
                const release_progress = self.elapsed / self.release_time;
                self.value = self.sustain_value * (1.0 - release_progress);
                if (self.elapsed >= self.release_time or self.release_time < ms) {
                    self.value = 0.0;
                    self.state = .Idle;
                }
            },
        }
        self.elapsed += dt;
    }

    fn onNoteOn(self: *@This()) void {
        self.state = .Attack;
        self.elapsed = 0;
    }

    fn onNoteOff(self: *@This()) void {
        self.state = .Release;
        self.elapsed = 0;
    }

    fn isEnded(self: *const @This()) bool {
        return self.state == .Idle and self.elapsed > 0;
    }
};

fn renderAudio(self: *@This(), start: u32, end: u32, output_left: [*]f32, output_right: [*]f32) void {
    const waveValue: u32 = @intFromFloat(self.params.get(Parameter.Wave));
    const waveType: Wave = @enumFromInt(waveValue);

    var index = start;
    while (index < end) : (index += 1) {
        var voice_sum: f64 = 0;
        for (self.voices.items) |*voice| {

            // Oscillations per second.
            const frequency = 440.0 * std.math.exp2((@as(f64, @floatFromInt(voice.key)) - 57.0) / 12.0);

            // Where in the wave are we? 1 wavelength is 1 / frequency long
            // So we can divide that by the sample rate to get the number of wave segments per sample
            // Then we can tell where we are in the segment by passing in the elapsed frames the voice has already had
            // And throwing that into sine
            const phase = (frequency / self.sample_rate.?) * voice.elapsed_frames;
            const phase_value = phase - std.math.floor(phase);
            var wave: f64 = 0;
            switch (waveType) {
                Wave.Sine => {
                    wave = std.math.sin(phase * 2.0 * 3.14159);
                },
                Wave.HalfSine => {
                    wave = clamp1(std.math.sin(phase * 2.0 * 3.14159));
                },
                Wave.Saw => {
                    wave = (phase_value * 2) - 1;
                },
                Wave.Triangle => {
                    if (phase_value < 0.5) {
                        wave = phase_value * 2;
                    } else {
                        wave = (1 - phase_value) * 2;
                    }
                    wave = (wave * 2) - 1;
                },
                Wave.Square => {
                    if (phase_value < 0.5) {
                        wave = -1;
                    } else {
                        wave = 1;
                    }
                },
            }

            // Elapse the voice time by a frame
            voice.elapsed_frames += 1;

            voice_sum += wave * voice.adsr.value;
        }
        const output: f32 = @floatCast(voice_sum);
        output_left[index] = output;
        output_right[index] = output;
    }
}
fn _getExtension(_: *const clap.Plugin, id: [*:0]const u8) callconv(.C) ?*const anyopaque {
    if (std.mem.eql(u8, std.mem.span(id), clap.extensions.audio_ports.id)) {
        return &extensions.audio_ports;
    }
    if (std.mem.eql(u8, std.mem.span(id), clap.extensions.note_ports.id)) {
        return &extensions.note_ports;
    }
    if (std.mem.eql(u8, std.mem.span(id), clap.extensions.parameters.id)) {
        return &extensions.params;
    }
    if (std.mem.eql(u8, std.mem.span(id), clap.extensions.state.id)) {
        return &extensions.state;
    }
    if (std.mem.eql(u8, std.mem.span(id), clap.extensions.gui.id)) {
        return &extensions.gui;
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
            while (i < Parameters.param_count) : (i += 1) {
                p.clear(self.host, @enumFromInt(i), .{ .all = true });
            }
            p.rescan(self.host, .{
                .all = true,
            });
        }
        self.jobs.should_rescan_params = false;
    }
}
