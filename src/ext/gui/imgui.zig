const std = @import("std");
const builtin = @import("builtin");
const clap = @import("clap-bindings");
const zgui = @import("zgui");
const static_data = @import("static_data");

const GUI = @import("gui.zig");
const Params = @import("../params.zig");

const audio = @import("../../audio/audio.zig");
const waves = @import("../../audio/waves.zig");
const voices = @import("../../audio/voices.zig");
const Voice = voices.Voice;
const Wave = waves.Wave;
const Filter = Params.Filter;

pub fn init(gui: *GUI) !void {
    if (gui.imgui_initialized) {
        std.log.err("ImGui already initialized! Ignoring", .{});
        return error.ImGuiAlreadyInitialized;
    }

    // Initialize ImGui
    zgui.init(gui.plugin.allocator);
    zgui.io.setIniFilename(null);

    zgui.plot.init();

    gui.imgui_initialized = true;
}

pub fn deinit(gui: *GUI) void {
    zgui.plot.deinit();
    zgui.backend.deinit();
    zgui.deinit();
    gui.imgui_initialized = false;
}

pub fn applyScaleFactor(gui: *GUI) void {
    if (!gui.imgui_initialized) {
        return;
    }

    _ = zgui.io.addFontFromMemory(static_data.font, std.math.floor(16.0 * gui.scale_factor));
    zgui.getStyle().scaleAllSizes(gui.scale_factor);
}

// Platform-agnostic draw function
pub fn draw(gui: *GUI) void {
    zgui.setNextWindowPos(.{ .x = 0, .y = 0, .cond = .always });
    const display_size = zgui.io.getDisplaySize();
    zgui.setNextWindowSize(.{ .w = display_size[0], .h = display_size[1], .cond = .always });

    if (zgui.begin(
        "Tool window",
        .{
            .flags = .{
                .no_collapse = true,
                .no_move = true,
                .no_resize = true,
                .no_title_bar = true,
                .always_auto_resize = true,
            },
        },
    )) {
        zgui.text("ZSynth by juge", .{});
        zgui.sameLine(.{});
        zgui.text("Voices: {} / {}", .{ gui.plugin.voices.getVoiceCount(), gui.plugin.voices.getVoiceCapacity() });

        {
            zgui.separatorText("Parameters##Sep");
            if (zgui.beginChild("Parameters##Child", .{
                .w = zgui.getContentRegionAvail()[0] * 0.5,
                // .h = 300.0,
                .child_flags = .{
                    // .border = true,
                },
                .window_flags = .{},
            })) {
                if (zgui.beginChild("Oscillator 1##Child", .{ .child_flags = .{
                    .border = true,
                    .auto_resize_y = true,
                    .always_auto_resize = true,
                } })) {
                    zgui.text("Oscillator 1", .{});
                    zgui.sameLine(.{});
                    renderMix(gui, true);
                    renderParam(gui, Params.Parameter.WaveShape1);
                    renderParam(gui, Params.Parameter.Octave1);
                    renderParam(gui, Params.Parameter.Pitch1);
                    zgui.endChild();
                }
                if (zgui.beginChild("Oscillator 2##Child", .{ .child_flags = .{
                    .border = true,
                    .auto_resize_y = true,
                    .always_auto_resize = true,
                } })) {
                    zgui.text("Oscillator 2", .{});
                    zgui.sameLine(.{});
                    renderMix(gui, false);
                    renderParam(gui, Params.Parameter.WaveShape2);
                    renderParam(gui, Params.Parameter.Octave2);
                    renderParam(gui, Params.Parameter.Pitch2);
                    zgui.endChild();
                }
                if (zgui.beginChild("ADSR##Child", .{ .child_flags = .{
                    .border = true,
                    .auto_resize_y = true,
                    .always_auto_resize = true,
                } })) {
                    zgui.text("Voice Envelope", .{});
                    renderParam(gui, Params.Parameter.Attack);
                    renderParam(gui, Params.Parameter.Decay);
                    renderParam(gui, Params.Parameter.Sustain);
                    renderParam(gui, Params.Parameter.Release);
                    zgui.endChild();
                }
                if (zgui.beginChild("Options##Child", .{ .child_flags = .{
                    .border = true,
                    .auto_resize_y = true,
                    .always_auto_resize = true,
                } })) {
                    zgui.text("Options", .{});
                    renderParam(gui, Params.Parameter.ScaleVoices);
                    if (builtin.mode == .Debug) {
                        zgui.sameLine(.{});
                        renderParam(gui, Params.Parameter.DebugBool1);
                        zgui.sameLine(.{});
                        renderParam(gui, Params.Parameter.DebugBool2);
                    }
                    zgui.endChild();
                }
                zgui.endChild();
            }
            zgui.sameLine(.{});
            if (zgui.beginChild("Display##Child", .{})) {
                if (zgui.beginChild("Filter##Child", .{ .child_flags = .{
                    .border = true,
                    .auto_resize_y = true,
                    .always_auto_resize = true,
                } })) {
                    zgui.text("Filter", .{});
                    zgui.sameLine(.{});
                    renderParam(gui, Params.Parameter.FilterEnable);
                    renderParam(gui, Params.Parameter.FilterType);
                    renderParam(gui, Params.Parameter.FilterFreq);
                    renderParam(gui, Params.Parameter.FilterQ);
                    zgui.endChild();
                }
                zgui.spacing();
                zgui.separatorText("Display##Sep");
                if (zgui.beginChild("Oscillators##Display", .{ .child_flags = .{
                    .border = true,
                    .auto_resize_y = true,
                    .always_auto_resize = true,
                } })) {
                    // TODO: Potentially separate out the calculation part of the engine
                    // Calculate an example of what the audio engine is actually outputting for visualization purposes
                    const resolution = 256;
                    const sample_rate = gui.plugin.sample_rate.?;
                    const diag_voice: Voice = .{ .key = @enumFromInt(57) };

                    const osc1_wave_shape = gui.plugin.params.get(.WaveShape1).Wave;
                    const osc1_octave = gui.plugin.params.get(.Octave1).Float;
                    const osc1_detune = gui.plugin.params.get(.Pitch1).Float;
                    const osc2_wave_shape = gui.plugin.params.get(.WaveShape2).Wave;
                    const osc2_octave = gui.plugin.params.get(.Octave2).Float;
                    const osc2_detune = gui.plugin.params.get(.Pitch2).Float;
                    const oscillator_mix: f32 = @floatCast(gui.plugin.params.get(.Mix).Float);

                    var xv: [resolution]f32 = [_]f32{0} ** resolution;
                    var osc1_yv: [resolution]f32 = [_]f32{0} ** resolution;
                    var osc2_yv: [resolution]f32 = [_]f32{0} ** resolution;
                    var sum_yv: [resolution]f32 = [_]f32{0} ** resolution;
                    for (0..resolution) |i| {
                        xv[i] = @floatFromInt(i);
                        osc1_yv[i] = @floatCast(waves.get(&gui.plugin.wave_table, osc1_wave_shape, sample_rate, diag_voice.getTunedKey(osc1_detune, osc1_octave), @as(f64, @floatFromInt(i))));
                        osc2_yv[i] = @floatCast(waves.get(&gui.plugin.wave_table, osc2_wave_shape, sample_rate, diag_voice.getTunedKey(osc2_detune, osc2_octave), @as(f64, @floatFromInt(i))));
                        sum_yv[i] = osc1_yv[i] + osc2_yv[i];
                        sum_yv[i] = (osc1_yv[i] * (1 - oscillator_mix)) + (osc2_yv[i] * oscillator_mix);
                    }

                    const enable_filtering = gui.plugin.params.get(.FilterEnable).Bool;
                    const filter_type = gui.plugin.params.get(.FilterType).Filter;
                    const q: f32 = @floatCast(gui.plugin.params.get(.FilterQ).Float);
                    if (enable_filtering) {
                        const cutoff_freq: f32 = @floatCast(gui.plugin.params.get(.FilterFreq).Float);
                        const sample_rate_f32: f32 = @floatCast(sample_rate);
                        audio.filter(filter_type, sum_yv[0..], sample_rate_f32, cutoff_freq, q);
                    }

                    if (zgui.plot.beginPlot("Wave Form##Plot", .{
                        .flags = .{
                            .no_box_select = true,
                            .no_mouse_text = true,
                            .no_inputs = true,
                            .no_legend = true,
                            .no_menus = true,
                            .no_frame = true,
                        },
                        .h = 200,
                    })) {
                        zgui.plot.setupAxis(.x1, .{ .flags = .{
                            .no_label = true,
                            .no_tick_labels = true,
                            .no_tick_marks = true,
                        } });
                        zgui.plot.setupAxis(.y1, .{ .flags = .{
                            .no_label = true,
                            .no_tick_labels = true,
                            .no_tick_marks = true,
                            .auto_fit = true,
                        } });
                        zgui.plot.plotLine("Both", f32, .{
                            .xv = &xv,
                            .yv = &sum_yv,
                        });
                        zgui.plot.endPlot();
                    }
                    zgui.endChild();
                }
                zgui.endChild();
            }
        }
    }
    zgui.end();
}

fn renderParam(gui: *GUI, param: Params.Parameter) void {
    const index: u32 = @intFromEnum(param);
    var info: clap.ext.params.Info = undefined;
    if (!Params._getInfo(&gui.plugin.plugin, index, &info)) {
        return;
    }

    const param_type = std.meta.intToEnum(Params.Parameter, index) catch {
        std.debug.panic("Unable to cast index to parameter enum! {d}", .{index});
        return;
    };

    const name = std.mem.sliceTo(&info.name, 0);
    const value_text: [:0]u8 = info.name[0..name.len :0];
    switch (param_type) {
        .Attack,
        .Release,
        .Decay,
        .Pitch1,
        .Pitch2,
        .FilterFreq,
        .FilterQ,
        => {
            var val: f32 = @floatCast(gui.plugin.params.get(param_type).Float);
            var param_text_buf: [256]u8 = [_]u8{0} ** 256;
            _ = Params._valueToText(&gui.plugin.plugin, @enumFromInt(index), val, &param_text_buf, 256);
            if (zgui.sliderFloat(
                value_text,
                .{
                    .v = &val,
                    .min = @floatCast(info.min_value),
                    .max = @floatCast(info.max_value),
                    .cfmt = param_text_buf[0..255 :0],
                    .flags = .{
                        .logarithmic = param_type == .FilterFreq,
                    },
                },
            )) {
                gui.plugin.params.set(param_type, .{ .Float = @as(f64, @floatCast(val)) }, .{
                    .should_notify_host = true,
                }) catch return;
            }
        },
        // Percentage sliders
        .Sustain, .Mix => {
            var val: f32 = @floatCast(gui.plugin.params.get(param_type).Float);
            var param_text_buf: [256]u8 = [_]u8{0} ** 256;
            _ = Params._valueToText(&gui.plugin.plugin, @enumFromInt(index), val, &param_text_buf, 256);
            if (std.mem.indexOf(u8, &param_text_buf, "%")) |percent_index| {
                if (percent_index < 255) {
                    // Add an extra percent to not confuse ImGui
                    param_text_buf[percent_index + 1] = '%';
                }
            }
            if (zgui.sliderFloat(
                value_text,
                .{
                    .v = &val,
                    .min = @floatCast(info.min_value),
                    .max = @floatCast(info.max_value),
                    .cfmt = param_text_buf[0..255 :0],
                },
            )) {
                gui.plugin.params.set(param_type, .{ .Float = @as(f64, @floatCast(val)) }, .{
                    .should_notify_host = true,
                }) catch return;
            }
        },
        // Int sliders
        .Octave1, .Octave2 => {
            const val_float: f32 = @floatCast(gui.plugin.params.get(param_type).Float);
            var val: i32 = @intFromFloat(val_float);
            var param_text_buf: [256]u8 = [_]u8{0} ** 256;
            _ = Params._valueToText(&gui.plugin.plugin, @enumFromInt(index), val_float, &param_text_buf, 256);
            if (zgui.sliderInt(
                value_text,
                .{
                    .v = &val,
                    .min = @intFromFloat(info.min_value),
                    .max = @intFromFloat(info.max_value),
                    .cfmt = param_text_buf[0..255 :0],
                },
            )) {
                gui.plugin.params.set(param_type, .{ .Float = @as(f64, @floatFromInt(val)) }, .{
                    .should_notify_host = true,
                }) catch return;
            }
        },
        .FilterEnable, .ScaleVoices, .DebugBool1, .DebugBool2 => {
            if (builtin.mode == .Debug) {
                var val: bool = gui.plugin.params.get(param_type).Bool;
                if (zgui.checkbox(value_text, .{
                    .v = &val,
                })) {
                    gui.plugin.params.set(param_type, .{ .Bool = val }, .{
                        .should_notify_host = true,
                    }) catch return;
                }
            }
        },
        .WaveShape1, .WaveShape2 => {
            // TODO replace these with iconic buttons
            inline for (std.meta.fields(Wave), 0..) |field, i| {
                if (i > 0) {
                    zgui.sameLine(.{});
                }
                const wave: Wave = @enumFromInt(field.value);
                if (zgui.radioButton(field.name, .{
                    .active = gui.plugin.params.get(param_type).Wave == wave,
                })) {
                    gui.plugin.params.set(param_type, .{ .Wave = wave }, .{
                        .should_notify_host = true,
                    }) catch return;
                }
            }
        },
        .FilterType => {
            inline for (std.meta.fields(Filter), 0..) |field, i| {
                if (i > 0) {
                    zgui.sameLine(.{});
                }
                const filter: Filter = @enumFromInt(field.value);
                if (zgui.radioButton(field.name, .{
                    .active = gui.plugin.params.get(param_type).Filter == filter,
                })) {
                    gui.plugin.params.set(param_type, .{ .Filter = filter }, .{
                        .should_notify_host = true,
                    }) catch return;
                }
            }
        },
    }
}

fn renderMix(gui: *GUI, osc1: bool) void {
    const index: u32 = @intFromEnum(Params.Parameter.Mix);
    var info: clap.ext.params.Info = undefined;
    if (!Params._getInfo(&gui.plugin.plugin, index, &info)) {
        return;
    }

    var val: f32 = @floatCast(gui.plugin.params.get(.Mix).Float);
    if (osc1) {
        val = 1 - val;
    }

    var param_text_buf: [256]u8 = [_]u8{0} ** 256;
    _ = Params._valueToText(&gui.plugin.plugin, @enumFromInt(index), val, &param_text_buf, 256);
    if (std.mem.indexOf(u8, &param_text_buf, "%")) |percent_index| {
        if (percent_index < 255) {
            // Add an extra percent to not confuse ImGui
            param_text_buf[percent_index + 1] = '%';
        }
    }
    if (zgui.sliderFloat(
        if (osc1) "Mix##Osc1" else "Mix##Osc2",
        .{
            .v = &val,
            .min = @floatCast(info.min_value),
            .max = @floatCast(info.max_value),
            .cfmt = param_text_buf[0..255 :0],
        },
    )) {
        if (osc1) {
            val = 1 - val;
        }
        gui.plugin.params.set(.Mix, .{ .Float = @as(f64, @floatCast(val)) }, .{
            .should_notify_host = true,
        }) catch return;
    }
}
