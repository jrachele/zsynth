const clap = @import("clap-bindings");
const std = @import("std");

const Params = @import("params.zig");
const Plugin = @import("../plugin.zig");

pub fn create() clap.extensions.state.Plugin {
    return .{
        .save = save,
        .load = load,
    };
}

// Frankly shocking how nice Zig makes this
fn save(plugin: *const clap.Plugin, stream: *const clap.OStream) callconv(.C) bool {
    std.debug.print("Saving plugin state...\n", .{});
    const self = Plugin.fromPlugin(plugin);
    const str = std.json.stringifyAlloc(self.allocator, self.params, .{}) catch return false;
    std.debug.print("Plugin data saved: {s}\n", .{str});
    defer self.allocator.free(str);

    return stream.write(stream, str.ptr, str.len) == str.len;
}

fn load(plugin: *const clap.Plugin, stream: *const clap.IStream) callconv(.C) bool {
    std.debug.print("Loading plugin state...\n", .{});
    const self = Plugin.fromPlugin(plugin);
    const MAX_BUF_SIZE = 1024; // this is entirely arbitrary.
    var buf: [MAX_BUF_SIZE]u8 = undefined;
    const bytes_read = stream.read(stream, &buf, MAX_BUF_SIZE);
    if (bytes_read < 0) return false;
    const bytes: usize = @intCast(bytes_read);
    std.debug.print("Plugin data loaded: {s}\n", .{buf[0..bytes]});
    const params_obj = std.json.parseFromSlice(Params.ParamValues, self.allocator, buf[0..bytes], .{
        .ignore_unknown_fields = true,
    }) catch |err| {
        std.debug.print("Error loading parameters: {}\n", .{err});
        self.params = Params.ParamValues.init(Params.param_defaults);
        return true;
    };
    defer params_obj.deinit();

    self.params = params_obj.value;
    return true;
}
