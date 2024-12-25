const std = @import("std");
const clap = @import("clap-bindings");
const ADSR = @import("adsr.zig");

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
    noteId: i32 = 0,
    channel: i16 = 0,
    key: i16 = 0,
    velocity: f64 = 0,
    expression_values: ExpressionValues = ExpressionValues.init(expression_values_default),
    adsr: ADSR = ADSR.init(0, 0, 1, 0),
    elapsed_frames: u64 = 0,

    pub fn getTunedKey(self: *Voice) f64 {
        return @as(f64, @floatFromInt(self.key)) + self.expression_values.get(.tuning);
    }
};

pub inline fn getVoiceByKey(voices: []Voice, key: i16) ?*Voice {
    for (voices) |*voice| {
        if (voice.key == key) {
            return voice;
        }
    }

    return null;
}

voices: std.ArrayList(Voice),
const Self = @This();

pub fn init(allocator: std.mem.Allocator) Self {
    return .{
        .voices = .init(allocator),
    };
}

pub fn deinit(self: *Self) void {
    self.voices.deinit();
}
