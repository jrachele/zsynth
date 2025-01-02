const GUI = @This();

const builtin = @import("builtin");
const std = @import("std");
const clap = @import("clap-bindings");
const options = @import("options");
const static_data = @import("static_data");

const zgui = @import("zgui");
const glfw = @import("zglfw");
const zopengl = @import("zopengl");

const Plugin = @import("../plugin.zig");
const Params = @import("params.zig");

const waves = @import("../audio/waves.zig");
const Wave = waves.Wave;

window: *glfw.Window,
plugin: *Plugin,
allocator: std.mem.Allocator,
is_visible: bool = false,
thread: std.Thread,

fn threadLoop(self: *GUI) void {
    while (self.window.shouldClose() != true) {
        self.plugin.host.requestCallback(self.plugin.host);
    }
}

pub fn init(allocator: std.mem.Allocator, plugin: *Plugin) !*GUI {
    std.log.debug("GUI init() called", .{});
    const gui = try allocator.create(GUI);

    try glfw.init();

    const gl_major = 4;
    const gl_minor = 0;
    glfw.windowHintTyped(.context_version_major, gl_major);
    glfw.windowHintTyped(.context_version_minor, gl_minor);
    glfw.windowHintTyped(.opengl_profile, .opengl_core_profile);
    glfw.windowHintTyped(.opengl_forward_compat, true);
    glfw.windowHintTyped(.client_api, .opengl_api);
    glfw.windowHintTyped(.doublebuffer, true);

    const window_title = "ZSynth";
    const window = try glfw.Window.create(800, 500, window_title, null);
    errdefer window.destroy();

    window.setSizeLimits(100, 100, -1, -1);

    glfw.makeContextCurrent(window);
    glfw.swapInterval(1);

    try zopengl.loadCoreProfile(glfw.getProcAddress, gl_major, gl_minor);

    zgui.init(plugin.allocator);

    const scale_factor = scale_factor: {
        const scale = window.getContentScale();
        break :scale_factor @max(scale[0], scale[1]);
    };
    _ = zgui.io.addFontFromMemory(static_data.font, std.math.floor(16.0 * scale_factor));

    zgui.io.setIniFilename(null);
    zgui.getStyle().scaleAllSizes(scale_factor);
    zgui.backend.init(window);

    const thread = try std.Thread.spawn(.{ .allocator = allocator }, threadLoop, .{gui});

    gui.* = .{
        .window = window,
        .plugin = plugin,
        .allocator = allocator,
        .thread = thread,
    };

    return gui;
}

pub fn deinit(self: *GUI) void {
    std.log.debug("GUI deinit() called", .{});
    zgui.backend.deinit();
    zgui.deinit();
    self.window.setShouldClose(true);
    self.thread.join();
    self.window.destroy();
    glfw.terminate();
    self.plugin.gui = null;
    self.allocator.destroy(self);
}

fn setTitle(self: *GUI, title: [:0]const u8) void {
    self.window.setTitle(title);
}

pub fn show(self: *GUI) void {
    self.is_visible = true;
}

pub fn hide(self: *GUI) void {
    self.is_visible = false;
}

pub fn draw(self: *GUI) bool {
    var window = self.window;
    if (window.shouldClose()) return false;
    if (window.getKey(.escape) == .press) {
        window.setShouldClose(true);
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
            },
        },
    )) {
        // Populate the widgets based on the parameters
        // Mimick what CLAP does
        zgui.text("Parameters", .{});

        for (0..Params.param_count) |i| {
            const index: u32 = @intCast(i);
            var info: clap.ext.params.Info = undefined;
            if (Params._getInfo(&self.plugin.plugin, index, &info)) {
                const param_type = std.meta.intToEnum(Params.Parameter, index) catch {
                    std.debug.panic("Unable to cast index to parameter enum! {d}", .{index});
                };

                const name = std.mem.sliceTo(&info.name, 0);
                const value_text: [:0]u8 = info.name[0..name.len :0];

                switch (param_type) {
                    .Attack, .Release, .Decay, .Sustain => {
                        var val: f32 = @floatCast(self.plugin.params.get(param_type));
                        if (zgui.sliderFloat(
                            value_text,
                            .{
                                .v = &val,
                                .min = @floatCast(info.min_value),
                                .max = @floatCast(info.max_value),
                            },
                        )) {
                            self.plugin.params.set(param_type, @as(f64, @floatCast(val)), .{
                                .should_notify_host = true,
                            }) catch return false;
                        }
                    },
                    .ScaleVoices, .DebugBool1, .DebugBool2 => {
                        if (builtin.mode == .Debug) {
                            var val: bool = self.plugin.params.get(param_type) == 1.0;
                            if (zgui.checkbox(value_text, .{
                                .v = &val,
                            })) {
                                const f: f64 = if (val) 1.0 else 0.0;
                                self.plugin.params.set(param_type, f, .{
                                    .should_notify_host = true,
                                }) catch return false;
                            }
                        }
                    },
                    .WaveShape => {
                        // TODO replace these with iconic buttons
                        inline for (std.meta.fields(Wave)) |field| {
                            if (zgui.radioButton(field.name, .{
                                .active = self.plugin.params.get(.WaveShape) == field.value,
                            })) {
                                self.plugin.params.set(.WaveShape, field.value, .{
                                    .should_notify_host = true,
                                }) catch return false;
                            }
                        }
                    },
                }
            }
        }
    }
    zgui.end();

    zgui.backend.draw();

    window.swapBuffers();

    return true;
}

fn getSize(self: *const GUI) [2]u32 {
    const size = self.window.getSize();
    return [2]u32{ @intCast(size[0]), @intCast(size[1]) };
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

fn _isApiSupported(_: *const clap.Plugin, api: [*:0]const u8, is_floating: bool) callconv(.C) bool {
    _ = api;
    return is_floating;
}
/// returns true if the plugin has a preferred api. the host has no obligation to honor the plugin's preference,
/// this is just a hint. `api` should be explicitly assigned as a pinter to one of the `window_api.*` constants,
/// not copied.
fn _getPreferredApi(_: *const clap.Plugin, _: *[*:0]const u8, is_floating: *bool) callconv(.C) bool {
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

    if (is_floating == false) {
        return false;
    }

    std.log.debug("Host called GUI create!", .{});
    const plugin: *Plugin = Plugin.fromClapPlugin(clap_plugin);
    if (plugin.gui != null) {
        std.log.info("GUI has already been initialized, earlying out", .{});
        return false;
    }

    plugin.gui = GUI.init(plugin.allocator, plugin) catch null;

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
fn _setParent(_: *const clap.Plugin, window: *const clap.ext.gui.Window) callconv(.C) bool {
    _ = window;
    return false;
}
/// sets the plugin window to stay above the given window. returns true on success.
fn _setTransient(_: *const clap.Plugin, window: *const clap.ext.gui.Window) callconv(.C) bool {
    _ = window;
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
    const plugin: *Plugin = Plugin.fromClapPlugin(clap_plugin);
    if (plugin.gui) |gui| {
        gui.show();
        return true;
    }

    return false;
}
/// hide the plugin window. this method does not free the
/// resources, just hides the window content, yet it may be
/// a good idea to stop painting timers. returns true on success.
fn _hide(clap_plugin: *const clap.Plugin) callconv(.C) bool {
    const plugin: *Plugin = Plugin.fromClapPlugin(clap_plugin);
    if (plugin.gui) |gui| {
        gui.hide();
        return true;
    }

    return false;
}
