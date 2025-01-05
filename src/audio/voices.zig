const Voices = @This();

const std = @import("std");
const clap = @import("clap-bindings");
const ADSR = @import("adsr.zig");
const Plugin = @import("../plugin.zig");

const waves = @import("waves.zig");
const Wave = waves.Wave;

pub const Expression = clap.events.NoteExpression.Id;
pub const ExpressionValues = std.EnumArray(Expression, f64);
const expression_values_default: std.enums.EnumFieldStruct(Expression, f64, null) = .{
    .volume = 1,
    .pan = 0.5,
    .tuning = 0,
    .vibrato = 0,
    .expression = 0,
    .brightness = 0,
    .pressure = 0,
};

// Work payload for multi-threaded jobs
const VoiceRenderPayload = struct {
    start: u32,
    end: u32,
    output_left: [*]f32,
    output_right: [*]f32,
    data_mutex: std.Thread.Mutex,
};

voices: std.ArrayList(Voice),
plugin: *Plugin,
render_payload: ?VoiceRenderPayload = null,

pub fn init(allocator: std.mem.Allocator, plugin: *Plugin) Voices {
    return .{
        .voices = .init(allocator),
        .plugin = plugin,
    };
}

pub fn deinit(self: *Voices) void {
    self.voices.deinit();
}

pub fn processVoice(self: *Voices, voice_index: u32) !void {
    if (self.render_payload == null) {
        return error.NoRenderPayload;
    }

    if (voice_index >= self.voices.items.len) {
        return error.InvalidVoiceIndex;
    }

    const voice: *Voice = self.getVoice(@intCast(voice_index)).?;

    const wave_value: u32 = @intFromFloat(self.plugin.params.values.get(.WaveShape));
    const wave_type: Wave = try std.meta.intToEnum(Wave, wave_value);

    var render_payload = self.render_payload.?;
    const plugin = self.plugin;

    var index = render_payload.start;
    while (index < render_payload.end) : (index += 1) {
        var voice_sum_l: f64 = 0;
        var voice_sum_r: f64 = 0;
        var voice_sum_mono: f64 = 0;
        var wave: f64 = undefined;
        const t: f64 = @floatFromInt(voice.elapsed_frames);

        // retrieve the wave data from the pre-calculated table
        wave = waves.get(&plugin.wave_table, wave_type, plugin.sample_rate.?, voice.getTunedKey(), t);

        // Elapse the voice time by a frame and update envelope
        voice.elapsed_frames += 1;

        const pan = voice.expression_values.get(Expression.pan);
        voice_sum_mono += wave * voice.adsr.value * 0.5;
        voice_sum_l += voice_sum_mono * (1 - pan);
        voice_sum_r += voice_sum_mono * pan;

        const dt = (1 / plugin.sample_rate.?) * 1000;
        voice.adsr.update(dt);

        var output_l: f32 = @floatCast(voice_sum_l);
        var output_r: f32 = @floatCast(voice_sum_r);

        if (plugin.params.get(.ScaleVoices) == 1.0) {
            // Apply scaling to prevent the amplitude to go too crazy
            const scaling = 1.0 / @max(1, std.math.sqrt(@as(f32, @floatFromInt(self.getVoiceCount()))));
            output_l *= scaling;
            output_r *= scaling;
        }

        render_payload.data_mutex.lock();
        render_payload.output_left[index] += output_l;
        render_payload.output_right[index] += output_r;
        render_payload.data_mutex.unlock();
    }
}

pub const Voice = struct {
    noteId: clap.events.NoteId = .unspecified,
    channel: clap.events.Channel = .unspecified,
    key: clap.events.Key = .unspecified,
    velocity: f64 = 0,
    expression_values: ExpressionValues = ExpressionValues.init(expression_values_default),
    adsr: ADSR = ADSR.init(0, 0, 1, 0),
    elapsed_frames: u64 = 0,

    pub fn getTunedKey(self: *const Voice) f64 {
        return @as(f64, @floatFromInt(@intFromEnum(self.key))) + self.expression_values.get(.tuning);
    }
};

pub fn getVoice(self: *Voices, index: usize) ?*Voice {
    if (index > self.getVoiceCount()) return null;

    return &self.voices.items[index];
}

pub fn getVoiceByKey(voices: []Voice, key: clap.events.Key) ?*Voice {
    for (voices) |*voice| {
        if (voice.key == key) {
            return voice;
        }
    }

    return null;
}

pub fn getVoiceCount(self: *const Voices) usize {
    return self.voices.items.len;
}

pub fn getVoiceCapacity(self: *const Voices) usize {
    return self.voices.capacity;
}

pub fn addVoice(self: *Voices, voice: Voice) !void {
    try self.voices.append(voice);

    self.notifyHost();
}

pub fn getVoices(self: *Voices) []Voice {
    return self.voices.items;
}

fn notifyHost(self: *const Voices) void {
    _ = self.plugin.notifyHostVoicesChanged();
}
