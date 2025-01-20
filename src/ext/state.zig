const clap = @import("clap-bindings");
const std = @import("std");
const tracy = @import("tracy");

const Params = @import("params.zig");
const Plugin = @import("../plugin.zig");

pub fn create() clap.ext.state.Plugin {
    return .{
        .save = _save,
        .load = _load,
    };
}

// Frankly shocking how nice Zig makes this
fn _save(clap_plugin: *const clap.Plugin, stream: *const clap.OStream) callconv(.C) bool {
    tracy.frameMark();
    const zone = tracy.initZone(@src(), .{ .name = "Saving plugin state" });
    defer zone.deinit();

    std.log.debug("Saving plugin state...", .{});
    const plugin = Plugin.fromClapPlugin(clap_plugin);

    // Ensure thread safety by locking the params first before reading them
    const locked = plugin.params.mutex.tryLock();
    if (!locked) {
        return false;
    }

    defer plugin.params.mutex.unlock();
    const str = std.json.stringifyAlloc(plugin.allocator, plugin.params.values.values, .{}) catch return false;
    std.log.debug("Plugin data saved: {s}", .{str});
    defer plugin.allocator.free(str);

    const res = stream.write(stream, str.ptr, str.len);
    if (res == .write_error) {
        std.log.err("Unable to write to plugin host output stream!", .{});
        return false;
    }
    var total_bytes_written = @intFromEnum(res);
    while (total_bytes_written < str.len) {
        const bytes: usize = @intCast(total_bytes_written);
        // Not gonna bother checking the write error again lol
        total_bytes_written += @intFromEnum(stream.write(stream, str.ptr + bytes, str.len - bytes));
    }

    return total_bytes_written == str.len;
}

fn _load(clap_plugin: *const clap.Plugin, stream: *const clap.IStream) callconv(.C) bool {
    tracy.frameMark();
    const zone = tracy.initZone(@src(), .{ .name = "Loading plugin state" });
    defer zone.deinit();

    std.log.debug("State._load called from plugin host", .{});
    const plugin = Plugin.fromClapPlugin(clap_plugin);

    var param_data_buf = std.ArrayList(u8).init(plugin.allocator);
    defer param_data_buf.deinit();

    const MAX_BUF_SIZE = 1024; // this is entirely arbitrary.
    var buf: [MAX_BUF_SIZE]u8 = undefined;
    const res = stream.read(stream, &buf, MAX_BUF_SIZE);
    if (res == .read_error or res == .end_of_file) {
        std.log.err("Clap IStream Read Error or EOF on first read!", .{});
        return false;
    }

    var bytes_read = @intFromEnum(res);
    while (bytes_read > 0) {
        // Append to the current working buffer
        const bytes: usize = @intCast(bytes_read);
        param_data_buf.appendSlice(buf[0..bytes]) catch {
            std.log.err("Unable to append state data from plugin host to param data buffer.", .{});
            return false;
        };

        // Read some more data in
        bytes_read = @intFromEnum(stream.read(stream, &buf, MAX_BUF_SIZE));
    }

    const params = createParamsFromBuffer(plugin.allocator, param_data_buf.items);
    if (params == null) {
        std.log.err("Unable to create params from the active state buffer! {s}", .{param_data_buf.items});
        return true;
    }

    // Mutate the overall plugin params now that they are properly loaded
    if (plugin.params.mutex.tryLock()) {
        defer plugin.params.mutex.unlock();

        plugin.params.values = params.?;
        return true;
    }

    return false;
}
// Load the JSON state from a complete buffer.
fn createParamsFromBuffer(allocator: std.mem.Allocator, buffer: []u8) ?Params.ParameterArray {
    const params_data = std.json.parseFromSlice([]Params.ParameterValue, allocator, buffer, .{
        .ignore_unknown_fields = true,
    }) catch |err| {
        std.log.err("Error loading parameters: {}", .{err});
        return null;
    };
    defer params_data.deinit();

    var params = Params.ParameterArray.init(Params.param_defaults);
    if (Params.param_count != params_data.value.len) {
        std.log.warn("Parameter count {d} does not match length of previously saved parameter data {d}", .{ Params.param_count, params_data.value.len });
        // Return the default parameter payload
        return params;
    }
    for (params_data.value, 0..) |param, i| {
        if (i >= Params.param_count) break;
        const param_type = std.meta.intToEnum(Params.Parameter, i) catch |err| {
            std.log.err("Error creating parameter: {}", .{err});
            return null;
        };
        params.set(param_type, param);
    }

    return params;
}
