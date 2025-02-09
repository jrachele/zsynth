const Params = @This();

const builtin = @import("builtin");
const std = @import("std");
const clap = @import("clap-bindings");
const regex = @import("regex");
const tracy = @import("tracy");

const Plugin = @import("../plugin.zig");
const Wave = @import("../audio/waves.zig").Wave;

const FilterType = @import("../audio/filter.zig").FilterType;

const Info = clap.ext.params.Info;

pub const Parameter = enum {
    // ADSR
    Attack,
    Decay,
    Sustain,
    Release,

    // Oscillator
    WaveShape1,
    WaveShape2,
    Octave1,
    Octave2,
    Pitch1,
    Pitch2,
    Mix,
    ScaleVoices,

    // Filter
    FilterEnable,
    FilterType,
    FilterFreq,
    FilterQ,

    // Debug params
    DebugBool1,
    DebugBool2,
};

pub const ParameterValue = union(enum) {
    Float: f64,
    Wave: Wave,
    Filter: FilterType,
    Bool: bool,

    pub fn asFloat(parameterValue: ParameterValue) f64 {
        switch (parameterValue) {
            .Float => {
                return parameterValue.Float;
            },
            .Wave => {
                return @floatFromInt(@intFromEnum(parameterValue.Wave));
            },
            .Filter => {
                return @floatFromInt(@intFromEnum(parameterValue.Filter));
            },
            .Bool => {
                if (parameterValue.Bool) {
                    return 1.0;
                } else {
                    return 0.0;
                }
            },
        }
    }
};

pub const ParameterArray = std.EnumArray(Parameter, ParameterValue);

pub const param_defaults = std.enums.EnumFieldStruct(Parameter, ParameterValue, null){
    .Attack = .{ .Float = 5.0 },
    .Decay = .{ .Float = 5.0 },
    .Sustain = .{ .Float = 0.5 },
    .Release = .{ .Float = 200.0 },

    .WaveShape1 = .{ .Wave = Wave.Saw },
    .WaveShape2 = .{ .Wave = Wave.Sine },
    .Pitch1 = .{ .Float = 0.0 },
    .Pitch2 = .{ .Float = 0.0 },
    .Octave1 = .{ .Float = 0.0 },
    .Octave2 = .{ .Float = -1.0 },
    .Mix = .{ .Float = 0.0 },

    .FilterEnable = .{ .Bool = false },
    .FilterType = .{ .Filter = FilterType.LowPass },
    .FilterFreq = .{ .Float = 20000 },
    .FilterQ = .{ .Float = 1.0 },

    .ScaleVoices = .{ .Bool = false },

    .DebugBool1 = .{ .Bool = false },
    .DebugBool2 = .{ .Bool = false },
};

pub const param_count = std.meta.fields(Parameter).len;

values: ParameterArray = .init(param_defaults),
mutex: std.Thread.Mutex,
events: std.ArrayList(clap.events.ParamValue),

pub fn init(allocator: std.mem.Allocator) Params {
    const events = std.ArrayList(clap.events.ParamValue).init(allocator);
    return .{
        .events = events,
        .mutex = .{},
    };
}

pub fn deinit(self: *Params) void {
    self.events.deinit();
}

/// Thread-safe getter for parameter values
pub fn get(self: *Params, param: Parameter) ParameterValue {
    self.mutex.lock();
    defer self.mutex.unlock();
    return self.values.get(param);
}

/// Thread-safe setter for params that also optionally notifies the host
const ParamSetFlags = struct {
    should_notify_host: bool = false,
};

pub fn set(self: *Params, param: Parameter, val: ParameterValue, flags: ParamSetFlags) !void {
    self.mutex.lock();
    defer self.mutex.unlock();
    self.values.set(param, val);

    if (flags.should_notify_host) {
        // Add to the event queue to notify the DAW on the audio thread
        const param_index: usize = @intFromEnum(param);
        const event = clap.events.ParamValue{
            .header = .{
                .type = .param_value,
                .size = @sizeOf(clap.events.ParamValue),
                .space_id = clap.events.core_space_id,
                .sample_offset = 0, // This will be set by the _process function when telling the DAW
                .flags = .{},
            },
            .note_id = .unspecified,
            .channel = .unspecified,
            .key = .unspecified,
            .port_index = .unspecified,
            .param_id = @enumFromInt(param_index),
            .value = val.asFloat(),
            .cookie = null,
        };

        try self.events.append(event);
    }

    std.log.debug("Changed param value of {} to {}", .{ param, val });
}

pub inline fn create() clap.ext.params.Plugin {
    return .{
        .count = _count,
        .getInfo = _getInfo,
        .getValue = _getValue,
        .valueToText = _valueToText,
        .textToValue = _textToValue,
        .flush = _flush,
    };
}

fn _count(_: *const clap.Plugin) callconv(.C) u32 {
    return @intCast(param_count);
}

pub fn _getInfo(clap_plugin: *const clap.Plugin, index: u32, info: *Info) callconv(.C) bool {
    if (index > _count(clap_plugin)) {
        return false;
    }

    const param_type: Parameter = @enumFromInt(index);
    switch (param_type) {
        Parameter.Attack => {
            info.* = .{
                .cookie = null,
                .default_value = param_defaults.Attack.Float,
                .min_value = 0,
                .max_value = 20000,
                .name = [_]u8{0} ** 256,
                .flags = .{
                    .is_stepped = true,
                    .is_automatable = true,
                },
                .id = @enumFromInt(@intFromEnum(Parameter.Attack)),
                .module = [_]u8{0} ** 1024,
            };
            std.mem.copyForwards(u8, &info.name, "Attack");
            std.mem.copyForwards(u8, &info.module, "Envelope/Attack");
        },
        Parameter.Decay => {
            info.* = .{
                .cookie = null,
                .default_value = param_defaults.Decay.Float,
                .min_value = 0,
                .max_value = 20000,
                .name = [_]u8{0} ** 256,
                .flags = .{
                    .is_stepped = true,
                    .is_automatable = true,
                },
                .id = @enumFromInt(@intFromEnum(Parameter.Decay)),
                .module = [_]u8{0} ** 1024,
            };
            std.mem.copyForwards(u8, &info.name, "Decay");
            std.mem.copyForwards(u8, &info.module, "Envelope/Decay");
        },
        Parameter.Sustain => {
            info.* = .{
                .cookie = null,
                .default_value = param_defaults.Sustain.Float,
                .min_value = 0.0,
                .max_value = 1.0,
                .name = [_]u8{0} ** 256,
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
                .default_value = param_defaults.Release.Float,
                .min_value = 0,
                .max_value = 20000,
                .name = [_]u8{0} ** 256,

                .flags = .{
                    .is_stepped = true,
                    .is_automatable = true,
                },
                .id = @enumFromInt(@intFromEnum(Parameter.Release)),
                .module = [_]u8{0} ** 1024,
            };
            std.mem.copyForwards(u8, &info.name, "Release");
            std.mem.copyForwards(u8, &info.module, "Envelope/Release");
        },
        Parameter.WaveShape1 => {
            info.* = .{
                .cookie = null,
                .default_value = param_defaults.WaveShape1.asFloat(),
                .min_value = 0,
                .max_value = std.meta.fields(Wave).len,
                .name = [_]u8{0} ** 256,
                .flags = .{
                    .is_stepped = true,
                    .is_automatable = true,
                    .is_enum = true,
                },
                .id = @enumFromInt(@intFromEnum(Parameter.WaveShape1)),
                .module = [_]u8{0} ** 1024,
            };
            std.mem.copyForwards(u8, &info.name, "Wave Shape 1");
            std.mem.copyForwards(u8, &info.module, "Oscillator/WaveShape1");
        },
        Parameter.WaveShape2 => {
            info.* = .{
                .cookie = null,
                .default_value = param_defaults.WaveShape2.asFloat(),
                .min_value = 0,
                .max_value = std.meta.fields(Wave).len,
                .name = [_]u8{0} ** 256,
                .flags = .{
                    .is_stepped = true,
                    .is_automatable = true,
                    .is_enum = true,
                },
                .id = @enumFromInt(@intFromEnum(Parameter.WaveShape2)),
                .module = [_]u8{0} ** 1024,
            };
            std.mem.copyForwards(u8, &info.name, "Wave Shape 2");
            std.mem.copyForwards(u8, &info.module, "Oscillator/WaveShape2");
        },
        Parameter.Octave1 => {
            info.* = .{
                .cookie = null,
                .default_value = param_defaults.Octave1.Float,
                .min_value = -2,
                .max_value = 3,
                .name = [_]u8{0} ** 256,

                .flags = .{
                    .is_stepped = true,
                    .is_automatable = true,
                },
                .id = @enumFromInt(@intFromEnum(Parameter.Octave1)),
                .module = [_]u8{0} ** 1024,
            };
            std.mem.copyForwards(u8, &info.name, "Octave 1");
            std.mem.copyForwards(u8, &info.module, "Oscillator/Octave1");
        },
        Parameter.Octave2 => {
            info.* = .{
                .cookie = null,
                .default_value = param_defaults.Octave2.Float,
                .min_value = -2,
                .max_value = 3,
                .name = [_]u8{0} ** 256,

                .flags = .{
                    .is_stepped = true,
                    .is_automatable = true,
                },
                .id = @enumFromInt(@intFromEnum(Parameter.Octave2)),
                .module = [_]u8{0} ** 1024,
            };
            std.mem.copyForwards(u8, &info.name, "Octave 2");
            std.mem.copyForwards(u8, &info.module, "Oscillator/Octave2");
        },
        Parameter.Pitch1 => {
            info.* = .{
                .cookie = null,
                .default_value = param_defaults.Pitch1.Float,
                .min_value = -7.0,
                .max_value = 7.0,
                .name = [_]u8{0} ** 256,

                .flags = .{
                    .is_automatable = true,
                },
                .id = @enumFromInt(@intFromEnum(Parameter.Pitch1)),
                .module = [_]u8{0} ** 1024,
            };
            std.mem.copyForwards(u8, &info.name, "Pitch 1");
            std.mem.copyForwards(u8, &info.module, "Oscillator/Pitch1");
        },
        Parameter.Pitch2 => {
            info.* = .{
                .cookie = null,
                .default_value = param_defaults.Pitch2.Float,
                .min_value = -7.0,
                .max_value = 7.0,
                .name = [_]u8{0} ** 256,

                .flags = .{
                    .is_automatable = true,
                },
                .id = @enumFromInt(@intFromEnum(Parameter.Pitch2)),
                .module = [_]u8{0} ** 1024,
            };
            std.mem.copyForwards(u8, &info.name, "Pitch 2");
            std.mem.copyForwards(u8, &info.module, "Oscillator/Pitch2");
        },
        Parameter.Mix => {
            info.* = .{
                .cookie = null,
                .default_value = param_defaults.Mix.Float,
                .min_value = 0,
                .max_value = 1,
                .name = [_]u8{0} ** 256,

                .flags = .{
                    .is_automatable = true,
                },
                .id = @enumFromInt(@intFromEnum(Parameter.Mix)),
                .module = [_]u8{0} ** 1024,
            };
            std.mem.copyForwards(u8, &info.name, "Mix");
            std.mem.copyForwards(u8, &info.module, "Oscillator/Mix");
        },
        Parameter.FilterEnable => {
            info.* = .{
                .cookie = null,
                .default_value = param_defaults.FilterEnable.asFloat(),
                .min_value = 0,
                .max_value = 1,
                .name = [_]u8{0} ** 256,
                .flags = .{
                    .is_stepped = true,
                    .is_automatable = true,
                },
                .id = @enumFromInt(@intFromEnum(Parameter.FilterEnable)),
                .module = [_]u8{0} ** 1024,
            };
            std.mem.copyForwards(u8, &info.name, "Enable Filter");
            std.mem.copyForwards(u8, &info.module, "Filter/Enable");
        },
        Parameter.FilterType => {
            info.* = .{
                .cookie = null,
                .default_value = param_defaults.FilterType.asFloat(),
                .min_value = 0,
                .max_value = std.meta.fields(FilterType).len,
                .name = [_]u8{0} ** 256,

                .flags = .{
                    .is_stepped = true,
                    .is_automatable = true,
                    .is_enum = true,
                },
                .id = @enumFromInt(@intFromEnum(Parameter.FilterType)),
                .module = [_]u8{0} ** 1024,
            };
            std.mem.copyForwards(u8, &info.name, "Filter Type");
            std.mem.copyForwards(u8, &info.module, "Filter/Type");
        },
        Parameter.FilterFreq => {
            info.* = .{
                .cookie = null,
                .default_value = param_defaults.FilterFreq.Float,
                .min_value = 20,
                .max_value = 20000,
                .name = [_]u8{0} ** 256,
                .flags = .{
                    .is_stepped = true,
                    .is_automatable = true,
                },
                .id = @enumFromInt(@intFromEnum(Parameter.FilterFreq)),
                .module = [_]u8{0} ** 1024,
            };
            std.mem.copyForwards(u8, &info.name, "Frequency Cutoff");
            std.mem.copyForwards(u8, &info.module, "Filter/Frequency");
        },
        Parameter.FilterQ => {
            info.* = .{
                .cookie = null,
                .default_value = param_defaults.FilterQ.Float,
                .min_value = 1,
                .max_value = 100,
                .name = [_]u8{0} ** 256,
                .flags = .{
                    .is_stepped = true,
                    .is_automatable = true,
                },
                .id = @enumFromInt(@intFromEnum(Parameter.FilterQ)),
                .module = [_]u8{0} ** 1024,
            };
            std.mem.copyForwards(u8, &info.name, "Filter Q Factor");
            std.mem.copyForwards(u8, &info.module, "Filter/Q");
        },
        Parameter.ScaleVoices => {
            info.* = .{
                .cookie = null,
                .default_value = param_defaults.ScaleVoices.asFloat(),
                .min_value = 0,
                .max_value = 1,
                .name = [_]u8{0} ** 256,
                .flags = .{
                    .is_stepped = true,
                    .is_automatable = true,
                },
                .id = @enumFromInt(@intFromEnum(Parameter.ScaleVoices)),
                .module = [_]u8{0} ** 1024,
            };
            std.mem.copyForwards(u8, &info.name, "ScaleVoices");
            std.mem.copyForwards(u8, &info.module, "Oscillator/ScaleVoices");
        },
        // DEBUG PARAMS
        Parameter.DebugBool1 => {
            info.* = .{
                .cookie = null,
                .default_value = param_defaults.DebugBool1.asFloat(),
                .min_value = 0,
                .max_value = 1,
                .name = [_]u8{0} ** 256,
                .flags = .{
                    .is_stepped = true,
                    .is_automatable = builtin.mode == .Debug,
                    .is_hidden = builtin.mode != .Debug,
                },
                .id = @enumFromInt(@intFromEnum(Parameter.DebugBool1)),
                .module = [_]u8{0} ** 1024,
            };
            std.mem.copyForwards(u8, &info.name, "Use Thread Pool");
            std.mem.copyForwards(u8, &info.module, "Debug/Bool1");
        },
        Parameter.DebugBool2 => {
            info.* = .{
                .cookie = null,
                .default_value = param_defaults.DebugBool2.asFloat(),
                .min_value = 0,
                .max_value = 1,
                .name = [_]u8{0} ** 256,
                .flags = .{
                    .is_stepped = true,
                    .is_automatable = builtin.mode == .Debug,
                    .is_hidden = builtin.mode != .Debug,
                },
                .id = @enumFromInt(@intFromEnum(Parameter.DebugBool2)),
                .module = [_]u8{0} ** 1024,
            };
            std.mem.copyForwards(u8, &info.name, "Bool2");
            std.mem.copyForwards(u8, &info.module, "Debug/Bool2");
        },
    }

    return true;
}

fn _getValue(clap_plugin: *const clap.Plugin, id: clap.Id, out_value: *f64) callconv(.C) bool {
    const plugin = Plugin.fromClapPlugin(clap_plugin);
    const index: usize = @intFromEnum(id);
    if (index > _count(clap_plugin)) {
        return false;
    }

    out_value.* = plugin.params.get(@enumFromInt(index)).asFloat();
    return true;
}

pub fn _valueToText(
    _: *const clap.Plugin,
    id: clap.Id,
    value: f64,
    out_buffer: [*]u8,
    out_buffer_capacity: u32,
) callconv(.C) bool {
    const zone = tracy.ZoneN(@src(), "Value to Text");
    defer zone.End();

    const out_buf = out_buffer[0..out_buffer_capacity];

    const index: usize = @intFromEnum(id);
    const param_type: Parameter = @enumFromInt(index);
    var bufSlice: []u8 = undefined;
    switch (param_type) {
        // Seconds and millisecond parameters
        Parameter.Attack, Parameter.Decay, Parameter.Release => {
            if (value >= 1000) {
                bufSlice = std.fmt.bufPrint(out_buf, "{d:.3} s", .{value / 1000}) catch return false;
            } else {
                bufSlice = std.fmt.bufPrint(out_buf, "{d:.0} ms", .{value}) catch return false;
            }
        },
        // Hz-based parameters
        Parameter.FilterFreq => {
            bufSlice = std.fmt.bufPrint(out_buf, "{d:.2} Hz", .{value}) catch return false;
        },
        // Percentage-based parameters
        Parameter.Sustain, Parameter.Mix => {
            bufSlice = std.fmt.bufPrint(out_buf, "{d:.2}%", .{value * 100}) catch return false;
        },
        // Step parameters
        Parameter.Pitch1, Parameter.Pitch2 => {
            bufSlice = std.fmt.bufPrint(out_buf, "{d:.2} st", .{value}) catch return false;
        },
        // Octaves parameters
        Parameter.Octave1, Parameter.Octave2 => {
            bufSlice = std.fmt.bufPrint(out_buf, "{d:.0}\'", .{std.math.pow(f64, 2, 3 - value)}) catch return false;
        },
        // No-unit params
        Parameter.FilterQ => {
            bufSlice = std.fmt.bufPrint(out_buf, "{d:.0}", .{value}) catch return false;
        },
        // Wave shapes
        Parameter.WaveShape1, Parameter.WaveShape2 => {
            const intValue: u32 = @intFromFloat(value);
            const wave = std.meta.intToEnum(Wave, intValue) catch return false;
            bufSlice = std.fmt.bufPrint(out_buf, "{s}", .{@tagName(wave)}) catch return false;
        },
        // Filter
        Parameter.FilterType => {
            const intValue: u32 = @intFromFloat(value);
            const filter = std.meta.intToEnum(FilterType, intValue) catch return false;
            bufSlice = std.fmt.bufPrint(out_buf, "{s}", .{@tagName(filter)}) catch return false;
        },
        // Boolean parameters
        Parameter.FilterEnable, Parameter.ScaleVoices, Parameter.DebugBool1, Parameter.DebugBool2 => {
            const bool_value: bool = if (value != 0.0) true else false;
            bufSlice = std.fmt.bufPrint(out_buf, "{s}", .{if (bool_value) "true" else "false"}) catch return false;
        },
    }
    // Null terminate the buffer
    if (bufSlice.len < out_buffer_capacity) {
        out_buf[bufSlice.len] = 0;
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

fn _textToValue(
    clap_plugin: *const clap.Plugin,
    id: clap.Id,
    value_text: [*:0]const u8,
    out_value: *f64,
) callconv(.C) bool {
    const zone = tracy.ZoneN(@src(), "Text To Value");
    defer zone.End();

    const plugin = Plugin.fromClapPlugin(clap_plugin);
    const index: usize = @intFromEnum(id);
    const param_type: Parameter = @enumFromInt(index);
    const value = std.mem.span(value_text);

    // Handle special case param types that don't fit the numerical value regex
    switch (param_type) {
        // Wave parameters
        .WaveShape1, .WaveShape2 => {
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
        },
        // Filter parameters
        .FilterType => {
            if (std.mem.startsWith(u8, value, @tagName(FilterType.BandPass))) {
                out_value.* = @intFromEnum(FilterType.BandPass);
                return true;
            } else if (std.mem.startsWith(u8, value, @tagName(FilterType.LowPass))) {
                out_value.* = @intFromEnum(FilterType.LowPass);
                return true;
            } else if (std.mem.startsWith(u8, value, @tagName(FilterType.HighPass))) {
                out_value.* = @intFromEnum(FilterType.HighPass);
                return true;
            }
            return false;
        },
        // Bool parameters
        .FilterEnable, .ScaleVoices, .DebugBool1, .DebugBool2 => {
            if (std.mem.startsWith(u8, value, "t")) {
                out_value.* = 1.0;
            } else {
                out_value.* = 0.0;
            }
            return true;
        },
        // The rest will be handled below
        else => {},
    }

    var unit_string: [64]u8 = undefined;
    var val_float: f64 = 0;
    const pattern = "\\s*(\\d+\\.?\\d*)\\s*(S|s|seconds|MS|Ms|ms|millis|milliseconds|%|st|Hz|hz|HZ)?\\s*";
    var re = regex.Regex.compile(plugin.allocator, pattern) catch return false;
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
        // Second and millisecond params
        Parameter.Attack, Parameter.Decay, Parameter.Release => {
            if (anyUnitEql(&unit_string, &.{ "S", "s", "seconds" })) {
                out_value.* = val_float * 1000;
            } else if (unit_slice == null or anyUnitEql(&unit_string, &.{ "MS", "Ms", "ms", "millis", "milliseconds" })) {
                out_value.* = val_float;
            } else {
                return false;
            }
        },
        // Percentage-based parameters
        Parameter.Sustain, Parameter.Mix => {
            if (std.mem.startsWith(u8, &unit_string, "%")) {
                out_value.* = val_float / 100;
            } else {
                out_value.* = val_float;
            }
        },
        // Parameters whose units don't influence value
        Parameter.Pitch1, Parameter.Pitch2, Parameter.Octave1, Parameter.Octave2, Parameter.FilterFreq, Parameter.FilterQ => {
            out_value.* = val_float;
        },
        else => {
            return false;
        },
    }
    return true;
}

fn processEvent(plugin: *Plugin, event: *const clap.events.Header) bool {
    if (event.space_id != clap.events.core_space_id) {
        return false;
    }
    if (event.type == .param_value) {
        const param_event: *const clap.events.ParamValue = @ptrCast(@alignCast(event));
        const index = @intFromEnum(param_event.param_id);
        if (index >= param_count) {
            return false;
        }

        const param: Parameter = @enumFromInt(index);
        const value: ParameterValue = switch (param) {
            // There is perhaps a better way of doing this, but I don't know what that is.
            .Attack, .Decay, .Release, .Sustain, .Octave1, .Octave2, .Pitch1, .Pitch2, .Mix, .FilterFreq, .FilterQ => .{ .Float = param_event.value },
            // Cast the float as an int first, then cast as an enum
            .WaveShape1, .WaveShape2 => .{ .Wave = @as(Wave, @enumFromInt(@as(usize, @intFromFloat(param_event.value)))) },
            .FilterType => .{ .Filter = @as(FilterType, @enumFromInt(@as(usize, @intFromFloat(param_event.value)))) },
            .FilterEnable, .ScaleVoices, .DebugBool1, .DebugBool2 => .{ .Bool = if (param_event.value == 1.0) true else false },
        };

        plugin.params.set(param, value, .{}) catch unreachable;
        return true;
    }
    return false;
}

// Handle parameter changes
pub fn _flush(
    clap_plugin: *const clap.Plugin,
    input_events: *const clap.events.InputEvents,
    output_events: *const clap.events.OutputEvents,
) callconv(.C) void {
    const zone = tracy.ZoneN(@src(), "Flush parameters");
    defer zone.End();

    const plugin = Plugin.fromClapPlugin(clap_plugin);
    var params_did_change = false;
    for (0..input_events.size(input_events)) |i| {
        const event = input_events.get(input_events, @intCast(i));
        if (processEvent(plugin, event)) {
            params_did_change = true;
        }
    }

    // Process GUI parameter event changes
    if (plugin.params.mutex.tryLock()) {
        defer plugin.params.mutex.unlock();

        if (plugin.params.events.items.len > 0) {
            params_did_change = true;
        }
        while (plugin.params.events.popOrNull()) |*event| {
            if (!output_events.tryPush(output_events, &event.header)) {
                std.debug.panic("Unable to notify DAW of parameter event changes!", .{});
            }
        }
    }

    if (params_did_change) {
        std.log.debug("Parameters changed, updating voices and filter and notifying host", .{});
        for (plugin.voices.voices.items) |*voice| {
            voice.adsr.attack_time = plugin.params.get(Parameter.Attack).Float;
            voice.adsr.decay_time = plugin.params.get(Parameter.Decay).Float;
            voice.adsr.release_time = plugin.params.get(Parameter.Release).Float;
            voice.adsr.original_sustain_value = plugin.params.get(Parameter.Sustain).Float;
        }
        _ = plugin.notifyHostParamsChanged();

        const filter_type = plugin.params.get(.FilterType).Filter;
        const q: f32 = @floatCast(plugin.params.get(.FilterQ).Float);
        const sample_rate: f32 = @floatCast(plugin.sample_rate.?);
        const cutoff_freq: f32 = @floatCast(plugin.params.get(.FilterFreq).Float);
        plugin.filter_left.update(filter_type, cutoff_freq, sample_rate, q) catch |err| {
            std.log.err("Unable to update filter parameters! {}", .{err});
            return;
        };
        plugin.filter_right.update(filter_type, cutoff_freq, sample_rate, q) catch unreachable;
    }
}
