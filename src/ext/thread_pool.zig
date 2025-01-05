const clap = @import("clap-bindings");
const std = @import("std");

const Plugin = @import("../plugin.zig");

// Voice info
pub fn create() clap.ext.thread_pool.Plugin {
    return .{
        .exec = _exec,
    };
}

/// function to be called by the host's thread pool.
pub fn _exec(clap_plugin: *const clap.Plugin, task_index: u32) callconv(.C) void {
    const plugin = Plugin.fromClapPlugin(clap_plugin);
    plugin.voices.processVoice(task_index) catch |err| {
        std.log.err("Unable to process voice data at index {d}: {}", .{ task_index, err });
    };
}
