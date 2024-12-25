const builtin = @import("builtin");
const std = @import("std");

const audio = @import("audio/audio.zig");
const waves = @import("audio/waves.zig");
const Voice = audio.Voice;
const Wave = waves.Wave;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    // const allocator = gpa.allocator();
}

test "Multi arrays" {
    var data: [1][2][3]f64 = undefined;

    var layer1 = &data[0];

    var layer2 = &layer1[0];
    layer2[2] = 2312321313;
    std.log.debug("{any}", .{data});
}
