const std = @import("std");
const clap = @import("clap-bindings");
const regex = @import("regex");
const MyPlugin = @import("plugin.zig");

const Info = clap.extensions.parameters.Info;

pub const Parameter = enum {
    Attack,
    Decay,
    Sustain,
    Release,
    BaseAmplitude,
    Wave,
};

pub const Wave = enum(u32) {
    Sine = 1,
    HalfSine = 2,
    Saw = 3,
    Triangle = 4,
};

pub const ParamValues = std.EnumArray(Parameter, f64);

pub const param_defaults = std.enums.EnumFieldStruct(Parameter, f64, null){
    .Attack = 5.0,
    .Decay = 5.0,
    .Sustain = 0.5,
    .Release = 200.0,
    .BaseAmplitude = 0.5,
    .Wave = @intFromEnum(Wave.Sine),
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
        Parameter.BaseAmplitude => {
            info.* = .{
                .cookie = null,
                .default_value = param_defaults.BaseAmplitude,
                .min_value = 0.0,
                .max_value = 1.0,
                .name = undefined,
                .flags = .{
                    .is_automatable = true,
                },
                .id = @enumFromInt(@intFromEnum(Parameter.BaseAmplitude)),
                .module = undefined,
            };
            std.mem.copyForwards(u8, &info.name, "Base Ampltitude");
            std.mem.copyForwards(u8, &info.module, "Oscillator/BaseAmp");
        },
        Parameter.Wave => {
            info.* = .{
                .cookie = null,
                .default_value = param_defaults.Wave,
                .min_value = @intFromEnum(Wave.Sine),
                .max_value = std.meta.fields(Wave).len,
                .name = undefined,
                .flags = .{
                    .is_stepped = true,
                    .is_automatable = true,
                },
                .id = @enumFromInt(@intFromEnum(Parameter.Wave)),
                .module = undefined,
            };
            std.mem.copyForwards(u8, &info.name, "Wave");
            std.mem.copyForwards(u8, &info.module, "Oscillator/Wave");
        },
    }

    return true;
}

fn getValue(plugin: *const clap.Plugin, id: clap.Id, out_value: *f64) callconv(.C) bool {
    const obj = MyPlugin.fromPlugin(plugin);
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
        Parameter.Sustain, Parameter.BaseAmplitude => {
            _ = std.fmt.bufPrint(out_buf, "{d:.2}%", .{value * 100}) catch return false;
        },
        Parameter.Wave => {
            const intValue: u32 = @intFromFloat(value);
            const wave: Wave = @enumFromInt(intValue);
            _ = std.fmt.bufPrint(out_buf, "{s}", .{@tagName(wave)}) catch return false;
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
    const self = MyPlugin.fromPlugin(plugin);
    const index: usize = @intFromEnum(id);
    const param_type: Parameter = @enumFromInt(index);
    const value = std.mem.span(value_text);

    // Handle this as a special case as it doesn't fit the numerical value regex
    if (param_type == Parameter.Wave) {
        if (std.mem.startsWith(u8, value, @tagName(Wave.Sine))) {
            out_value.* = @intFromEnum(Wave.Sine);
            return true;
        } else if (std.mem.startsWith(u8, value, @tagName(Wave.HalfSine))) {
            out_value.* = @intFromEnum(Wave.HalfSine);
            return true;
        } else if (std.mem.startsWith(u8, value, @tagName(Wave.Saw))) {
            out_value.* = @intFromEnum(Wave.Saw);
            return true;
        } else if (std.mem.startsWith(u8, value, @tagName(Wave.Triangle))) {
            out_value.* = @intFromEnum(Wave.Triangle);
            return true;
        }
        return false;
    }

    var unitString: [64]u8 = undefined;
    var valFloat: f64 = 0;
    const pattern = "\\s*(\\d+\\.?\\d*)\\s*(S|s|seconds|MS|Ms|ms|millis|milliseconds|%)?\\s*";
    var re = regex.Regex.compile(self.allocator, pattern) catch return false;
    defer re.deinit();

    // If we had no matches, the input is invalid
    var caps = re.captures(value) catch return false;
    if (caps == null) return false;
    defer caps.?.deinit();
    const valueString = caps.?.sliceAt(1).?;
    var unitSlice: ?[]const u8 = null;

    // If we didn't have a unit afterward, don't try to assign it; depending on the param we will choose a default
    if (caps.?.len() == 3) {
        unitSlice = caps.?.sliceAt(2);
    }
    if (unitSlice != null) {
        std.mem.copyForwards(u8, &unitString, unitSlice.?);
    }

    valFloat = std.fmt.parseFloat(f64, valueString) catch return false;

    switch (param_type) {
        Parameter.Attack, Parameter.Decay, Parameter.Release => {
            if (anyUnitEql(&unitString, &.{ "S", "s", "seconds" })) {
                out_value.* = valFloat * 1000;
            } else if (unitSlice == null or anyUnitEql(&unitString, &.{ "MS", "Ms", "ms", "millis", "milliseconds" })) {
                out_value.* = valFloat;
            } else {
                return false;
            }
        },
        Parameter.Sustain, Parameter.BaseAmplitude => {
            if (std.mem.startsWith(u8, &unitString, "%")) {
                out_value.* = valFloat / 100;
            } else {
                out_value.* = valFloat;
            }
        },
        Parameter.Wave => {
            return false;
        },
    }
    return true;
}

// Ignoring this as this is how to read/modify parameter changes without processing audio
fn flush(
    _: *const clap.Plugin,
    _: *const clap.events.InputEvents,
    _: *const clap.events.OutputEvents,
) callconv(.C) void {}
