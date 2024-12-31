const clap = @import("clap-bindings");
const std = @import("std");

const Plugin = @import("../plugin.zig");

// Voice info
pub fn create() clap.ext.voice_info.Plugin {
    return .{
        .get = _get,
    };
}

/// returns true on success and populates `info.*` with the voice info.
fn _get(clap_plugin: *const clap.Plugin, info: *clap.ext.voice_info.Info) callconv(.C) bool {
    const plugin = Plugin.fromClapPlugin(clap_plugin);

    const voice_count = plugin.voices.getVoiceCount();
    const voice_capacity = plugin.voices.getVoiceCapacity();

    info.voice_count = @intCast(voice_count);
    info.voice_capacity = @intCast(voice_capacity);
    info.flags.supports_overlapping_notes = true;

    return true;
}
