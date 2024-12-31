const Voices = @This();

const std = @import("std");
const clap = @import("clap-bindings");
const ADSR = @import("adsr.zig");
const Plugin = @import("../plugin.zig");

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

voices: std.ArrayList(Voice),
plugin: *Plugin,

pub fn init(allocator: std.mem.Allocator, plugin: *Plugin) Voices {
    return .{
        .voices = .init(allocator),
        .plugin = plugin,
    };
}

pub fn deinit(self: *Voices) void {
    self.voices.deinit();
}
