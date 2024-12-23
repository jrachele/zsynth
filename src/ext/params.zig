const builtin = @import("builtin");
const std = @import("std");
const clap = @import("clap-bindings");
const regex = @import("regex");
const Plugin = @import("../plugin.zig");

const Wave = @import("../audio/waves.zig").Wave;

const Info = clap.extensions.parameters.Info;

pub const Parameter = enum {
    Attack,
    Decay,
    Sustain,
    Release,
    WaveShape,

    // Debug params
    DebugBool1,
    DebugBool2,
};

pub const ParamValues = std.EnumArray(Parameter, f64);

pub const param_defaults = std.enums.EnumFieldStruct(Parameter, f64, null){
    .Attack = 5.0,
    .Decay = 5.0,
    .Sustain = 0.5,
    .Release = 200.0,
    .WaveShape = @intFromEnum(Wave.Sine),

    .DebugBool1 = 0.0,
    .DebugBool2 = 0.0,
};

pub const param_count = std.meta.fields(Parameter).len;

pub fn create() clap.extensions.parameters.Plugin {
    return .{
        .count = count,
        .getInfo = getInfo,
        .getValue = getValue,
        .valueToText = valueToText,
        .textToValue = textToValue,
        .flush = flush,
    };
}

fn count(_: *const clap.Plugin) callconv(.C) u32 {
    return @intCast(param_count);
}

fn getInfo(plugin: *const clap.Plugin, index: u32, info: *Info) callconv(.C) bool {
    if (index > count(plugin)) {
        return false;
    }

    const param_type: Parameter = @enumFromInt(index);
    switch (param_type) {
        Parameter.Attack => {
            info.* = .{
                .cookie = null,
                .default_value = param_defaults.Attack,
                .min_value = 0,
                .max_value = 20000,
                .name = undefined,
                .flags = .{
                    .is_stepped = true,
                    .is_automatable = true,
                },
                .id = @enumFromInt(@intFromEnum(Parameter.Attack)),
                .module = undefined,
            };
            std.mem.copyForwards(u8, &info.name, "Attack");
            std.mem.copyForwards(u8, &info.module, "Envelope/Attack");
        },
        Parameter.Decay => {
            info.* = .{
                .cookie = null,
                .default_value = param_defaults.Decay,
                .min_value = 0,
                .max_value = 20000,
                .name = undefined,
                .flags = .{
                    .is_stepped = true,
                    .is_automatable = true,
                },
                .id = @enumFromInt(@intFromEnum(Parameter.Decay)),
                .module = undefined,
            };
            std.mem.copyForwards(u8, &info.name, "Decay");
            std.mem.copyForwards(u8, &info.module, "Envelope/Decay");
        },
        Parameter.Sustain => {
            info.* = .{
                .cookie = null,
                .default_value = param_defaults.Sustain,
                .min_value = 0.0,
                .max_value = 1.0,
                .name = undefined,
                .flags = .{
                    .is_automatable = true,
                },
                .id = @enumFromInt(@intFromEnum(Parameter.Sustain)),
                .module = undefined,
            };
            std.mem.copyForwards(u8, &info.name, "Sustain");
            std.mem.copyForwards(u8, &info.module, "Envelope/Sustain");
        },
        Parameter.Release => {
            info.* = .{
                .cookie = null,
                .default_value = param_defaults.Release,
                .min_value = 0,
                .max_value = 20000,
                .name = undefined,

                .flags = .{
                    .is_stepped = true,
                    .is_automatable = true,
                },
                .id = @enumFromInt(@intFromEnum(Parameter.Release)),
                .module = undefined,
            };
            std.mem.copyForwards(u8, &info.name, "Release");
            std.mem.copyForwards(u8, &info.module, "Envelope/Release");
        },
        Parameter.WaveShape => {
            info.* = .{
                .cookie = null,
                .default_value = param_defaults.WaveShape,
                .min_value = @intFromEnum(Wave.Sine),
                .max_value = std.meta.fields(Wave).len,
                .name = undefined,
                .flags = .{
                    .is_stepped = true,
                    .is_automatable = true,
                    .is_enum = true,
                },
                .id = @enumFromInt(@intFromEnum(Parameter.WaveShape)),
                .module = undefined,
            };
            std.mem.copyForwards(u8, &info.name, "Wave");
            std.mem.copyForwards(u8, &info.module, "Oscillator/Wave");
        },
        // DEBUG PARAMS
        Parameter.DebugBool1 => {
            info.* = .{
                .cookie = null,
                .default_value = param_defaults.DebugBool1,
                .min_value = 0,
                .max_value = 1,
                .name = undefined,
                .flags = .{
                    .is_stepped = true,
                    .is_automatable = true,
                    .is_hidden = builtin.mode != .Debug,
                },
                .id = @enumFromInt(@intFromEnum(Parameter.DebugBool1)),
                .module = undefined,
            };
            std.mem.copyForwards(u8, &info.name, "Use Wave Table");
            std.mem.copyForwards(u8, &info.module, "Debug/Bool1");
        },
        Parameter.DebugBool2 => {
            info.* = .{
                .cookie = null,
                .default_value = param_defaults.DebugBool2,
                .min_value = 0,
                .max_value = 1,
                .name = undefined,
                .flags = .{
                    .is_stepped = true,
                    .is_automatable = true,
                    .is_hidden = builtin.mode != .Debug,
                },
                .id = @enumFromInt(@intFromEnum(Parameter.DebugBool2)),
                .module = undefined,
            };
            std.mem.copyForwards(u8, &info.name, "Bool2");
            std.mem.copyForwards(u8, &info.module, "Debug/Bool2");
        },
    }

    return true;
}

fn getValue(plugin: *const clap.Plugin, id: clap.Id, out_value: *f64) callconv(.C) bool {
    const obj = Plugin.fromPlugin(plugin);
    const index: usize = @intFromEnum(id);
    if (index > count(plugin)) {
        return false;
    }

    out_value.* = obj.params.get(@enumFromInt(index));
    return true;
}

fn valueToText(
    _: *const clap.Plugin,
    id: clap.Id,
    value: f64,
    out_buffer: [*]u8,
    out_buffer_capacity: u32,
) callconv(.C) bool {
    const out_buf = out_buffer[0..out_buffer_capacity];

    const index: usize = @intFromEnum(id);
    const param_type: Parameter = @enumFromInt(index);
    switch (param_type) {
        Parameter.Attack, Parameter.Decay, Parameter.Release => {
            if (value >= 1000) {
                _ = std.fmt.bufPrint(out_buf, "{d:.3} s", .{value / 1000}) catch return false;
            } else {
                _ = std.fmt.bufPrint(out_buf, "{d:.0} ms", .{value}) catch return false;
            }
        },
        Parameter.Sustain => {
            _ = std.fmt.bufPrint(out_buf, "{d:.2}%", .{value * 100}) catch return false;
        },
        Parameter.WaveShape => {
            const intValue: u32 = @intFromFloat(value);
            const wave: Wave = @enumFromInt(intValue);
            _ = std.fmt.bufPrint(out_buf, "{s}", .{@tagName(wave)}) catch return false;
        },
        Parameter.DebugBool1, Parameter.DebugBool2 => {
            const bool_value: bool = if (value != 0.0) true else false;
            _ = std.fmt.bufPrint(out_buf, "{s}", .{if (bool_value) "true" else "false"}) catch return false;
        },
    }
    return true;
}

fn anyUnitEql(unit: []const u8, cmps: []const []const u8) bool {
    for (cmps) |cmp| {
        if (std.mem.startsWith(u8, unit, cmp)) {
            return true;
        }
    }
    return false;
}

fn textToValue(
    plugin: *const clap.Plugin,
    id: clap.Id,
    value_text: [*:0]const u8,
    out_value: *f64,
) callconv(.C) bool {
    const self = Plugin.fromPlugin(plugin);
    const index: usize = @intFromEnum(id);
    const param_type: Parameter = @enumFromInt(index);
    const value = std.mem.span(value_text);

    // Handle special case param types that don't fit the numerical value regex
    if (param_type == Parameter.WaveShape) {
        if (std.mem.startsWith(u8, value, @tagName(Wave.Sine))) {
            out_value.* = @intFromEnum(Wave.Sine);
            return true;
        } else if (std.mem.startsWith(u8, value, @tagName(Wave.Saw))) {
            out_value.* = @intFromEnum(Wave.Saw);
            return true;
        } else if (std.mem.startsWith(u8, value, @tagName(Wave.Triangle))) {
            out_value.* = @intFromEnum(Wave.Triangle);
            return true;
        } else if (std.mem.startsWith(u8, value, @tagName(Wave.Square))) {
            out_value.* = @intFromEnum(Wave.Square);
            return true;
        }
        return false;
    } else if (param_type == Parameter.DebugBool1 or param_type == Parameter.DebugBool2) {
        if (std.mem.startsWith(u8, value, "t")) {
            out_value.* = 1.0;
        } else {
            out_value.* = 0.0;
        }
        return true;
    }

    var unit_string: [64]u8 = undefined;
    var val_float: f64 = 0;
    const pattern = "\\s*(\\d+\\.?\\d*)\\s*(S|s|seconds|MS|Ms|ms|millis|milliseconds|%)?\\s*";
    var re = regex.Regex.compile(self.allocator, pattern) catch return false;
    defer re.deinit();

    // If we had no matches, the input is invalid
    var caps = re.captures(value) catch return false;
    if (caps == null) return false;
    defer caps.?.deinit();
    const value_string = caps.?.sliceAt(1).?;
    var unit_slice: ?[]const u8 = null;

    // If we didn't have a unit afterward, don't try to assign it; depending on the param we will choose a default
    if (caps.?.len() == 3) {
        unit_slice = caps.?.sliceAt(2);
    }
    if (unit_slice != null) {
        std.mem.copyForwards(u8, &unit_string, unit_slice.?);
    }

    val_float = std.fmt.parseFloat(f64, value_string) catch return false;

    switch (param_type) {
        Parameter.Attack, Parameter.Decay, Parameter.Release => {
            if (anyUnitEql(&unit_string, &.{ "S", "s", "seconds" })) {
                out_value.* = val_float * 1000;
            } else if (unit_slice == null or anyUnitEql(&unit_string, &.{ "MS", "Ms", "ms", "millis", "milliseconds" })) {
                out_value.* = val_float;
            } else {
                return false;
            }
        },
        Parameter.Sustain => {
            if (std.mem.startsWith(u8, &unit_string, "%")) {
                out_value.* = val_float / 100;
            } else {
                out_value.* = val_float;
            }
        },
        else => {
            return false;
        },
    }
    return true;
}

// Handle parameter changes
fn flush(
    plugin: *const clap.Plugin,
    events: *const clap.events.InputEvents,
    _: *const clap.events.OutputEvents,
) callconv(.C) void {
    const self = Plugin.fromPlugin(plugin);
    var i: u32 = 0;
    while (i < events.size(events)) : (i += 1) {
        const event = events.get(events, i);
        if (event.type == .param_value) {
            const param_event: *const clap.events.ParamValue = @ptrCast(@alignCast(event));
            const index = @intFromEnum(param_event.param_id);
            if (index >= param_count) {
                return;
            }

            self.params.set(@enumFromInt(index), param_event.value);
        }
    }
    for (self.voices.items) |*voice| {
        voice.adsr.attack_time = self.params.get(Parameter.Attack);
        voice.adsr.decay_time = self.params.get(Parameter.Decay);
        voice.adsr.release_time = self.params.get(Parameter.Release);
        voice.adsr.sustain_value = self.params.get(Parameter.Sustain);
    }
}
