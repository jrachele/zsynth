const std = @import("std");
const clap = @import("clap-bindings");

const Plugin = @import("plugin.zig");
const GUI = @import("ext/gui.zig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Create a fake Plugin
    // Create a bogus pointer because who cares anyway for this
    const host = try allocator.create(clap.Host);
    defer allocator.destroy(host);

    const plugin = try Plugin.init(allocator, host);
    defer plugin.deinit();
    var gui = try GUI.init(allocator, plugin);
    defer gui.deinit();

    while (gui.draw()) {}
}
