const clap = @import("clap-bindings");
const std = @import("std");

pub fn create() clap.extensions.note_ports.Plugin {
    return .{
        .count = count,
        .get = get,
    };
}

/// number of ports for either input or output
fn count(_: *const clap.Plugin, is_input: bool) callconv(.C) u32 {
    return if (is_input) 1 else 0;
}
/// get info about a note port. returns true on success and stores the result into `info`.
fn get(_: *const clap.Plugin, index: u32, is_input: bool, info: *clap.extensions.note_ports.Info) callconv(.C) bool {
    if (!is_input or index != 0) {
        return false;
    }

    var nameBuf: [clap.name_capacity]u8 = undefined;
    const name = std.fmt.bufPrint(&nameBuf, "Note Input {}", .{index}) catch {
        return false;
    };
    std.mem.copyForwards(u8, &info.name, name);

    info.id = @enumFromInt(index);
    info.supported_dialects = .{
        .clap = true,
    };

    info.preferred_dialect = .clap;
    return true;
}
