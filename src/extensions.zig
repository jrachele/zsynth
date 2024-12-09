const std = @import("std");
const clap = @import("clap-bindings");

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

const MyPlugin = @import("plugin.zig");

pub const Parameters = struct {
    const Info = clap.extensions.parameters.Info;

    pub const Parameter = struct {
        info: Info,
        val: f64 = 0,

        pub const Attack = 0;
        pub const Decay = 1;
        pub const Sustain = 2;
        pub const Release = 3;
        pub const BaseAmplitude = 4;
    };

    fn create() clap.extensions.parameters.Plugin {
        return .{
            .count = count,
            .getInfo = getInfo,
            .getValue = getValue,
            .valueToText = valueToText,
            .textToValue = textToValue,
            .flush = flush,
        };
    }

    fn count(plugin: *const clap.Plugin) callconv(.C) u32 {
        // const obj = MyPlugin.fromPlugin(plugin);
        // const len = obj.params.items.len;
        // return @intCast(len);
        _ = plugin;
        return 5;
    }

    fn getInfo(plugin: *const clap.Plugin, index: u32, info: *Info) callconv(.C) bool {
        var obj = MyPlugin.fromPlugin(plugin);
        std.debug.print("Index: {}, count(plugin): {}\n", .{ index, count(plugin) });
        if (index > count(plugin)) {
            return false;
        }

        const param = &obj.params.items[index];
        info.* = param.info;
        std.debug.print("info: {s}\n", .{info.name});

        return true;
    }

    fn getValue(plugin: *const clap.Plugin, id: clap.Id, out_value: *f64) callconv(.C) bool {
        const obj = MyPlugin.fromPlugin(plugin);
        const index: usize = @intFromEnum(id);
        if (index > count(plugin)) {
            return false;
        }

        out_value.* = obj.params.items[index].val;
        return true;
    }

    fn valueToText(
        _: *const clap.Plugin,
        id: clap.Id,
        value: f64,
        out_buffer: [*]u8,
        out_buffer_capacity: u32,
    ) callconv(.C) bool {
        const index: usize = @intFromEnum(id);
        const out_buf = out_buffer[0..out_buffer_capacity];

        switch (index) {
            Parameter.Attack, Parameter.Decay, Parameter.Release => {
                _ = std.fmt.bufPrint(out_buf, "{d} frames", .{std.math.floor(value)}) catch return false;
            },
            Parameter.Sustain, Parameter.BaseAmplitude => {
                _ = std.fmt.bufPrint(out_buf, "{d:.2}%", .{value * 100}) catch return false;
            },
            else => {},
        }
        return true;
    }

    fn textToValue(
        _: *const clap.Plugin,
        _: clap.Id,
        value_text: [*:0]const u8,
        out_value: *f64,
    ) callconv(.C) bool {
        const value = std.mem.span(value_text);
        const val_float = std.fmt.parseFloat(f64, value) catch return false;
        out_value.* = val_float;

        // TODO Actually parse stuff
        return true;
    }

    // Ignoring this as this is how to read/modify parameter changes without processing audio
    fn flush(
        _: *const clap.Plugin,
        _: *const clap.events.InputEvents,
        _: *const clap.events.OutputEvents,
    ) callconv(.C) void {}
};
