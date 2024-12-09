const std = @import("std");

const clap = @import("clap-bindings");
const MyPlugin = @import("plugin.zig");

const Info = clap.extensions.parameters.Info;

pub const Parameter = enum {
    Attack,
    Decay,
    Sustain,
    Release,
    BaseAmplitude,
};

pub const ParamValues = std.EnumArray(Parameter, f64);

pub const param_defaults = std.enums.EnumFieldStruct(Parameter, f64, null){
    .Attack = 200.0,
    .Decay = 200.0,
    .Sustain = 0.5,
    .Release = 200.0,
    .BaseAmplitude = 0.5,
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
                .default_value = 200,
                .min_value = 100,
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
                .default_value = 200,
                .min_value = 100,
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
                .default_value = 1.0,
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
                .default_value = 200,
                .min_value = 100,
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
                .default_value = 1.0,
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
    const index: usize = @intFromEnum(id);
    const out_buf = out_buffer[0..out_buffer_capacity];

    const param_type: Parameter = @enumFromInt(index);
    switch (param_type) {
        Parameter.Attack, Parameter.Decay, Parameter.Release => {
            _ = std.fmt.bufPrint(out_buf, "{d} frames", .{std.math.floor(value)}) catch return false;
        },
        Parameter.Sustain, Parameter.BaseAmplitude => {
            _ = std.fmt.bufPrint(out_buf, "{d:.2}%", .{value * 100}) catch return false;
        },
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
