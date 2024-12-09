const std = @import("std");
const clap = @import("clap-bindings");
const Parameters = @import("params.zig");

// Extensions
pub const audio_ports = AudioPorts.create();
pub const note_ports = NotePorts.create();
pub const params = Parameters.create();

// Audio Ports Extension
const AudioPorts = struct {
    fn create() clap.extensions.audio_ports.Plugin {
        return .{
            .count = count,
            .get = get,
        };
    }

    /// number of ports for either input or output
    fn count(_: *const clap.Plugin, is_input: bool) callconv(.C) u32 {
        return if (is_input) 0 else 1;
    }
    /// get info about an audio port. returns true on success and stores the result into `info`.
    fn get(_: *const clap.Plugin, index: u32, is_input: bool, info: *clap.extensions.audio_ports.Info) callconv(.C) bool {
        var nameBuf: [clap.name_capacity]u8 = undefined;
        if (is_input) {
            return false;
            // const name = std.fmt.bufPrint(&nameBuf, "Audio Input {}", .{index}) catch {
            //     return false;
            // };
            // std.mem.copyForwards(u8, &info.name, name);

            // std.debug.print("{s}", .{name});

            // info.id = @enumFromInt(index);
            // info.channel_count = 1;
            // info.flags = .{
            //     .is_main = true,
            //     .supports_64bits = false,
            // };
            // info.port_type = "mono";
            // info.in_place_pair = .invalid_id;
        } else {
            const name = std.fmt.bufPrint(&nameBuf, "Audio Output {}", .{index}) catch {
                return false;
            };
            std.mem.copyForwards(u8, &info.name, name);
            std.debug.print("{s}", .{name});

            info.id = @enumFromInt(index);
            info.channel_count = 2;
            info.flags = .{
                .is_main = true,
                .supports_64bits = false,
            };
            info.port_type = "stereo";
            info.in_place_pair = .invalid_id;
        }

        return true;
    }
};

const NotePorts = struct {
    fn create() clap.extensions.note_ports.Plugin {
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
};
