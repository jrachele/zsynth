const GUI = @This();

const builtin = @import("builtin");
const std = @import("std");
const clap = @import("clap-bindings");
const options = @import("options");
const static_data = @import("static_data");

const zgui = @import("zgui");
const glfw = @import("zglfw");
const zopengl = @import("zopengl");

const Plugin = @import("../../plugin.zig");
const Params = @import("../params.zig");

const platform_gui = switch (builtin.os.tag) {
    .macos => @import("cocoa.zig"),
    _ => .{},
};

const cocoa = @import("cocoa.zig");

const waves = @import("../../audio/waves.zig");
const voices = @import("../../audio/voices.zig");
const Voice = voices.Voice;
const Wave = waves.Wave;
const Filter = Params.Filter;

plugin: *Plugin,
allocator: std.mem.Allocator,

window: ?*glfw.Window,
is_floating: bool,
daw_window: ?*const clap.ext.gui.Window,

const gl_major = 4;
const gl_minor = 0;

pub fn init(allocator: std.mem.Allocator, plugin: *Plugin, is_floating: bool) !*GUI {
    std.log.debug("GUI init() called", .{});

    if (plugin.gui != null) {
        std.log.err("GUI has already been initialized!", .{});
        return error.AlreadyInitialized;
    }

    const gui = try allocator.create(GUI);
    errdefer allocator.destroy(gui);
    gui.* = .{
        .plugin = plugin,
        .allocator = allocator,
        .is_floating = is_floating,
        .window = null,
        .daw_window = null,
    };

    try gui.createWindow();

    return gui;
}

pub fn deinit(self: *GUI) void {
    std.log.debug("GUI deinit() called", .{});
    if (self.window != null) {
        self.destroyWindow();
    }
    self.plugin.gui = null;
    self.allocator.destroy(self);
}

fn createWindow(self: *GUI) !void {
    std.log.debug("Creating window.", .{});
    if (self.window != null) {
        std.log.err("Window already created! Ignoring...", .{});
        return error.WindowAlreadyCreated;
    }

    // Initialize ImGui
    zgui.init(self.plugin.allocator);
    errdefer zgui.deinit();
    zgui.io.setIniFilename(null);

    // Initialize GLFW
    try glfw.init();
    errdefer glfw.terminate();

    glfw.windowHint(.context_version_major, gl_major);
    glfw.windowHint(.context_version_minor, gl_minor);
    glfw.windowHint(.opengl_profile, .opengl_core_profile);
    glfw.windowHint(.opengl_forward_compat, true);
    glfw.windowHint(.client_api, .opengl_api);
    glfw.windowHint(.doublebuffer, true);
    glfw.windowHint(.visible, self.is_floating);

    const window_title = "ZSynth";
    const window = try glfw.Window.create(800, 500, window_title, null);
    errdefer window.destroy();
    window.setSizeLimits(100, 100, -1, -1);

    glfw.makeContextCurrent(window);
    glfw.swapInterval(1);

    try zopengl.loadCoreProfile(glfw.getProcAddress, gl_major, gl_minor);

    const scale_factor = scale_factor: {
        const scale = window.getContentScale();
        break :scale_factor @max(scale[0], scale[1]);
    };
    _ = zgui.io.addFontFromMemory(static_data.font, std.math.floor(16.0 * scale_factor));

    zgui.getStyle().scaleAllSizes(scale_factor);
    zgui.backend.init(window);
    zgui.plot.init();

    if (builtin.os.tag == .macos) {
        // Hiding the dock by setting the activation policy to accessory prevents a strange focus loss bug
        // https://github.com/glfw/glfw/issues/1766
        // https://old.reddit.com/r/MacOS/comments/1fmmqj7/severe_focus_loss_bug_still_not_fixed_in_macos/
        platform_gui.hideDock();
    }

    self.window = window;
}

fn destroyWindow(self: *GUI) void {
    std.log.debug("Destroying window.", .{});

    var windowWasDestroyed = false;
    if (self.window) |window| {
        zgui.plot.deinit();
        zgui.backend.deinit();
        zgui.deinit();
        window.destroy();
        // glfw.terminate();
        windowWasDestroyed = true;
    }
    self.window = null;

    if (self.plugin.host.getExtension(self.plugin.host, clap.ext.gui.id)) |host_header| {
        var gui_host: *const clap.ext.gui.Host = @ptrCast(@alignCast(host_header));
        gui_host.closed(self.plugin.host, windowWasDestroyed);
    }
}

pub fn show(self: *GUI) !void {
    // Create the window if it doesn't exist
    if (self.window == null) {
        try self.createWindow();
    }

    if (self.window) |window| {
        window.setAttribute(.visible, true);
    }
}

pub fn hide(self: *GUI) void {
    if (self.window) |window| {
        window.setAttribute(.visible, false);
    }
}

pub fn update(self: *GUI) void {
    if (self.window) |window| {
        if (window.shouldClose()) {
            std.log.info("Window requested close, closing!", .{});
            self.destroyWindow();
            return;
        }
        _ = self.draw();
    }
}

fn draw(self: *GUI) bool {
    if (self.window == null) return false;

    var window = self.window.?;
    if (window.getKey(.escape) == .press) {
        glfw.setWindowShouldClose(window, true);
        // window.setShouldClose(true);
        return false;
    }

    const gl = zopengl.bindings;

    glfw.pollEvents();

    gl.clearBufferfv(gl.COLOR, 0, &[_]f32{ 0, 0, 0, 1.0 });

    const fb_size = window.getFramebufferSize();

    zgui.backend.newFrame(@intCast(fb_size[0]), @intCast(fb_size[1]));

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
        zgui.text("ZSynth by Julian Rachele", .{});
        // TODO: calculate and right align this properly if this design is to persist
        zgui.sameLine(.{ .spacing = display_size[0] - 250 });
        zgui.text("Voices: {} / {}", .{ self.plugin.voices.getVoiceCount(), self.plugin.voices.getVoiceCapacity() });

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
                    self.renderMix(true);
                    self.renderParam(Params.Parameter.WaveShape1);
                    self.renderParam(Params.Parameter.Octave1);
                    self.renderParam(Params.Parameter.Pitch1);
                    zgui.endChild();
                }
                if (zgui.beginChild("Oscillator 2##Child", .{ .child_flags = .{
                    .border = true,
                    .auto_resize_y = true,
                    .always_auto_resize = true,
                } })) {
                    zgui.text("Oscillator 2", .{});
                    zgui.sameLine(.{});
                    self.renderMix(false);
                    self.renderParam(Params.Parameter.WaveShape2);
                    self.renderParam(Params.Parameter.Octave2);
                    self.renderParam(Params.Parameter.Pitch2);
                    zgui.endChild();
                }
                if (zgui.beginChild("ADSR##Child", .{ .child_flags = .{
                    .border = true,
                    .auto_resize_y = true,
                    .always_auto_resize = true,
                } })) {
                    zgui.text("Voice Envelope", .{});
                    self.renderParam(Params.Parameter.Attack);
                    self.renderParam(Params.Parameter.Decay);
                    self.renderParam(Params.Parameter.Sustain);
                    self.renderParam(Params.Parameter.Release);
                    zgui.endChild();
                }
                if (zgui.beginChild("Options##Child", .{ .child_flags = .{
                    .border = true,
                    .auto_resize_y = true,
                    .always_auto_resize = true,
                } })) {
                    zgui.text("Options", .{});
                    self.renderParam(Params.Parameter.ScaleVoices);
                    if (builtin.mode == .Debug) {
                        zgui.sameLine(.{});
                        self.renderParam(Params.Parameter.DebugBool1);
                        zgui.sameLine(.{});
                        self.renderParam(Params.Parameter.DebugBool2);
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
                    self.renderParam(Params.Parameter.FilterType);
                    self.renderParam(Params.Parameter.FilterFreq);
                    self.renderParam(Params.Parameter.FilterQ);
                    zgui.endChild();
                }
                zgui.spacing();
                zgui.separatorText("Display##Sep");
                if (zgui.beginChild("Oscillators##Display", .{ .child_flags = .{
                    .border = true,
                    .auto_resize_y = true,
                    .always_auto_resize = true,
                } })) {
                    // Calculate an example of what the audio engine is actually outputting for visualization purposes
                    const resolution = 256;
                    const sample_rate = self.plugin.sample_rate.?;
                    const diag_voice: Voice = .{ .key = @enumFromInt(57) };

                    const osc1_wave_shape = self.plugin.params.get(.WaveShape1).Wave;
                    const osc1_octave = self.plugin.params.get(.Octave1).Float;
                    const osc1_detune = self.plugin.params.get(.Pitch1).Float;
                    const osc2_wave_shape = self.plugin.params.get(.WaveShape2).Wave;
                    const osc2_octave = self.plugin.params.get(.Octave2).Float;
                    const osc2_detune = self.plugin.params.get(.Pitch2).Float;
                    const oscillator_mix = self.plugin.params.get(.Mix).Float;

                    var xv: [resolution]f64 = [_]f64{0} ** resolution;
                    var osc1_yv: [resolution]f64 = [_]f64{0} ** resolution;
                    var osc2_yv: [resolution]f64 = [_]f64{0} ** resolution;
                    var sum_yv: [resolution]f64 = [_]f64{0} ** resolution;
                    for (0..resolution) |i| {
                        xv[i] = @floatFromInt(i);
                        osc1_yv[i] = waves.get(&self.plugin.wave_table, osc1_wave_shape, sample_rate, diag_voice.getTunedKey(osc1_detune, osc1_octave), @as(f64, @floatFromInt(i)));
                        osc2_yv[i] = waves.get(&self.plugin.wave_table, osc2_wave_shape, sample_rate, diag_voice.getTunedKey(osc2_detune, osc2_octave), @as(f64, @floatFromInt(i)));
                        sum_yv[i] = osc1_yv[i] + osc2_yv[i];
                        sum_yv[i] = (osc1_yv[i] * (1 - oscillator_mix)) + (osc2_yv[i] * oscillator_mix);
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
                        } });
                        zgui.plot.plotLine("Both", f64, .{
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

    zgui.backend.draw();

    window.swapBuffers();

    return true;
}

fn renderParam(self: *GUI, param: Params.Parameter) void {
    const index: u32 = @intFromEnum(param);
    var info: clap.ext.params.Info = undefined;
    if (!Params._getInfo(&self.plugin.plugin, index, &info)) {
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
            var val: f32 = @floatCast(self.plugin.params.get(param_type).Float);
            var param_text_buf: [256]u8 = [_]u8{0} ** 256;
            _ = Params._valueToText(&self.plugin.plugin, @enumFromInt(index), val, &param_text_buf, 256);
            if (zgui.sliderFloat(
                value_text,
                .{
                    .v = &val,
                    .min = @floatCast(info.min_value),
                    .max = @floatCast(info.max_value),
                    .cfmt = param_text_buf[0..255 :0],
                },
            )) {
                self.plugin.params.set(param_type, .{ .Float = @as(f64, @floatCast(val)) }, .{
                    .should_notify_host = true,
                }) catch return;
            }
        },
        // Percentage sliders
        .Sustain, .Mix => {
            var val: f32 = @floatCast(self.plugin.params.get(param_type).Float);
            var param_text_buf: [256]u8 = [_]u8{0} ** 256;
            _ = Params._valueToText(&self.plugin.plugin, @enumFromInt(index), val, &param_text_buf, 256);
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
                self.plugin.params.set(param_type, .{ .Float = @as(f64, @floatCast(val)) }, .{
                    .should_notify_host = true,
                }) catch return;
            }
        },
        // Int sliders
        .Octave1, .Octave2 => {
            const val_float: f32 = @floatCast(self.plugin.params.get(param_type).Float);
            var val: i32 = @intFromFloat(val_float);
            var param_text_buf: [256]u8 = [_]u8{0} ** 256;
            _ = Params._valueToText(&self.plugin.plugin, @enumFromInt(index), val_float, &param_text_buf, 256);
            if (zgui.sliderInt(
                value_text,
                .{
                    .v = &val,
                    .min = @intFromFloat(info.min_value),
                    .max = @intFromFloat(info.max_value),
                    .cfmt = param_text_buf[0..255 :0],
                },
            )) {
                self.plugin.params.set(param_type, .{ .Float = @as(f64, @floatFromInt(val)) }, .{
                    .should_notify_host = true,
                }) catch return;
            }
        },
        .ScaleVoices, .DebugBool1, .DebugBool2 => {
            if (builtin.mode == .Debug) {
                var val: bool = self.plugin.params.get(param_type).Bool;
                if (zgui.checkbox(value_text, .{
                    .v = &val,
                })) {
                    self.plugin.params.set(param_type, .{ .Bool = val }, .{
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
                    .active = self.plugin.params.get(param_type).Wave == wave,
                })) {
                    self.plugin.params.set(param_type, .{ .Wave = wave }, .{
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
                    .active = self.plugin.params.get(param_type).Filter == filter,
                })) {
                    self.plugin.params.set(param_type, .{ .Filter = filter }, .{
                        .should_notify_host = true,
                    }) catch return;
                }
            }
        },
    }
}

fn renderMix(self: *GUI, osc1: bool) void {
    const index: u32 = @intFromEnum(Params.Parameter.Mix);
    var info: clap.ext.params.Info = undefined;
    if (!Params._getInfo(&self.plugin.plugin, index, &info)) {
        return;
    }

    var val: f32 = @floatCast(self.plugin.params.get(.Mix).Float);
    if (osc1) {
        val = 1 - val;
    }

    var param_text_buf: [256]u8 = [_]u8{0} ** 256;
    _ = Params._valueToText(&self.plugin.plugin, @enumFromInt(index), val, &param_text_buf, 256);
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
        self.plugin.params.set(.Mix, .{ .Float = @as(f64, @floatCast(val)) }, .{
            .should_notify_host = true,
        }) catch return;
    }
}

fn setTitle(self: *GUI, title: [:0]const u8) void {
    if (self.window) |window| {
        window.setTitle(title);
    }
}

fn getSize(self: *const GUI) [2]u32 {
    if (self.window) |window| {
        const size = window.getSize();
        return [2]u32{ @intCast(size[0]), @intCast(size[1]) };
    }
    return [2]u32{ 0, 0 };
}

// Clap specific stuff
pub fn create() clap.ext.gui.Plugin {
    return .{
        .isApiSupported = _isApiSupported,
        .getPreferredApi = _getPreferredApi,
        .create = _create,
        .destroy = _destroy,
        .setScale = _setScale,
        .getSize = _getSize,
        .canResize = _canResize,
        .getResizeHints = _getResizeHints,
        .adjustSize = _adjustSize,
        .setSize = _setSize,
        .setParent = _setParent,
        .setTransient = _setTransient,
        .suggestTitle = _suggestTitle,
        .show = _show,
        .hide = _hide,
    };
}

fn _isApiSupported(_: *const clap.Plugin, _: [*:0]const u8, _: bool) callconv(.C) bool {
    return true;
}
/// returns true if the plugin has a preferred api. the host has no obligation to honor the plugin's preference,
/// this is just a hint. `api` should be explicitly assigned as a pinter to one of the `window_api.*` constants,
/// not copied.
fn _getPreferredApi(_: *const clap.Plugin, _: *[*:0]const u8, is_floating: *bool) callconv(.C) bool {
    // _ = is_floating;
    is_floating.* = true;
    return true;
}
/// create and allocate all resources needed for the gui.
/// if `is_floating` is true then the window will not be managed by the host. the plugin can set its window
/// to stay above the parent window (see `setTransient`). `api` may be null or blank for floating windows.
/// if `is_floating` is false then the plugin has to embed its window into the parent window (see `setParent`).
/// after this call the gui may not be visible yet, don't forget to call `show`.
/// returns true if the gui is successfully created.
fn _create(clap_plugin: *const clap.Plugin, api: ?[*:0]const u8, is_floating: bool) callconv(.C) bool {
    _ = api;

    std.log.debug("Host called GUI create!", .{});
    const plugin: *Plugin = Plugin.fromClapPlugin(clap_plugin);
    if (plugin.gui != null) {
        std.log.info("GUI has already been initialized, earlying out", .{});
        return false;
    }

    plugin.gui = GUI.init(plugin.allocator, plugin, is_floating) catch null;

    return plugin.gui != null;
}
/// free all resources associated with the gui
fn _destroy(clap_plugin: *const clap.Plugin) callconv(.C) void {
    std.log.debug("Host called GUI destroy!", .{});
    const plugin: *Plugin = Plugin.fromClapPlugin(clap_plugin);

    if (plugin.gui) |gui| {
        gui.deinit();
    }
    plugin.gui = null;
}
/// set the absolute gui scaling factor, overriding any os info. should not be
/// used if the windowing api relies upon logical pixels. if the plugin prefers
/// to work out the saling factor itself by quering the os directly, then ignore
/// the call. scale of 2 means 200% scaling. returns true when scaling could be
/// applied. returns false when the call was ignored or scaling was not applied.
fn _setScale(_: *const clap.Plugin, scale: f64) callconv(.C) bool {
    _ = scale;
    return true;
}
/// get the current size of the plugin gui. `Plugin.create` must have been called prior to
/// asking for the size. returns true and populates `width.*` and `height.*` if the plugin
/// successfully got the size.
fn _getSize(clap_plugin: *const clap.Plugin, width: *u32, height: *u32) callconv(.C) bool {
    const plugin: *Plugin = Plugin.fromClapPlugin(clap_plugin);
    if (plugin.gui) |gui| {
        const window_size = gui.getSize();
        width.* = window_size[0];
        height.* = window_size[1];
        return true;
    }
    return false;
}
/// returns true if the window is resizable (mouse drag)
fn _canResize(_: *const clap.Plugin) callconv(.C) bool {
    return false;
}
/// returns true and populates `hints.*` if the plugin can provide hints on how to resize the window.
fn _getResizeHints(_: *const clap.Plugin, hints: *clap.ext.gui.ResizeHints) callconv(.C) bool {
    _ = hints;
    return false;
}
/// if the plugin gui is resizable, then the plugin will calculate the closest usable size which
/// fits the given size. this method does not resize the gui. returns true and adjusts `width.*`
/// and `height.*` if the plugin could adjust the given size.
fn _adjustSize(_: *const clap.Plugin, width: *u32, height: *u32) callconv(.C) bool {
    _ = width;
    _ = height;
    return false;
}
/// sets the plugin's window size. returns true if the
/// plugin successfully resized its window to the given size.
fn _setSize(_: *const clap.Plugin, width: u32, height: u32) callconv(.C) bool {
    _ = width;
    _ = height;
    return false;
}

/// embeds the plugin window into the given window. returns true on success.
fn _setParent(clap_plugin: *const clap.Plugin, plugin_window: *const clap.ext.gui.Window) callconv(.C) bool {
    const plugin: *Plugin = Plugin.fromClapPlugin(clap_plugin);
    if (plugin.gui) |gui| {
        gui.daw_window = plugin_window;
        if (gui.window) |window| {
            switch (builtin.os.tag) {
                .macos => {
                    if (glfw.getCocoaWindow(window)) |cocoa_window| {
                        platform_gui.setParent(cocoa_window, plugin_window.data.cocoa);
                        return true;
                    }
                },
                else => {
                    return false;
                },
            }
        }
    }

    return false;
}
/// sets the plugin window to stay above the given window. returns true on success.
fn _setTransient(clap_plugin: *const clap.Plugin, window: *const clap.ext.gui.Window) callconv(.C) bool {
    const plugin: *Plugin = Plugin.fromClapPlugin(clap_plugin);
    if (plugin.gui) |gui| {
        gui.daw_window = window;
    }
    return true;
}
/// suggests a window title. only for floating windows.
fn _suggestTitle(clap_plugin: *const clap.Plugin, title: [*:0]const u8) callconv(.C) bool {
    const plugin: *Plugin = Plugin.fromClapPlugin(clap_plugin);
    if (plugin.gui) |gui| {
        gui.setTitle(std.mem.span(title));
        return true;
    }
    return false;
}
/// show the plugin window. returns true on success.
fn _show(clap_plugin: *const clap.Plugin) callconv(.C) bool {
    std.log.debug("GUI show() called", .{});
    const plugin: *Plugin = Plugin.fromClapPlugin(clap_plugin);
    if (plugin.gui) |gui| {
        gui.show() catch return false;
        return true;
    }

    return false;
}

/// hide the plugin window. this method does not free the
/// resources, just hides the window content, yet it may be
/// a good idea to stop painting timers. returns true on success.
fn _hide(clap_plugin: *const clap.Plugin) callconv(.C) bool {
    std.log.debug("GUI hide() called", .{});
    const plugin: *Plugin = Plugin.fromClapPlugin(clap_plugin);
    if (plugin.gui) |gui| {
        gui.hide();
        return true;
    }

    return false;
}
