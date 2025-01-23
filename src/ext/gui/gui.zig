const GUI = @This();

const builtin = @import("builtin");
const std = @import("std");
const tracy = @import("tracy");

const clap = @import("clap-bindings");
const objc = @import("objc");
const glfw = @import("zglfw");

const imgui = @import("imgui.zig");
const macos = @import("macos.zig");
const linux = @import("linux.zig");

const Plugin = @import("../../plugin.zig");

const PlatformData = switch (builtin.os.tag) {
    .macos => struct {
        view: *objc.app_kit.View,
        device: *objc.metal.Device,
        layer: *objc.quartz_core.MetalLayer,
        command_queue: *objc.metal.CommandQueue,
    },
    .linux => struct {
        window: *glfw.Window,
    },
    .windows => struct {},
    else => struct {},
};

const window_width = 800;
const window_height = 500;

plugin: *Plugin,
allocator: std.mem.Allocator,

scale_factor: f32 = 1.0,
platform_data: ?PlatformData,
imgui_initialized: bool,
visible: bool,
width: u32,
height: u32,

pub fn init(allocator: std.mem.Allocator, plugin: *Plugin, is_floating: bool) !*GUI {
    std.log.debug("GUI init() called", .{});

    if (plugin.gui != null) {
        std.log.err("GUI has already been initialized!", .{});
        return error.AlreadyInitialized;
    }

    if (is_floating and builtin.os.tag != .linux) {
        std.log.err("Floating windows are only supported on Linux!", .{});
        return error.FloatingWindowNotSupported;
    }

    const gui = try allocator.create(GUI);
    errdefer allocator.destroy(gui);
    gui.* = .{
        .plugin = plugin,
        .allocator = allocator,
        .platform_data = null,
        .visible = true,
        .imgui_initialized = false,
        .width = window_width,
        .height = window_height,
    };

    try gui.initWindow();

    return gui;
}

pub fn deinit(self: *GUI) void {
    std.log.debug("GUI deinit() called", .{});
    if (self.platform_data != null) {
        self.deinitWindow();
    }
    self.plugin.gui = null;
    self.allocator.destroy(self);
}

pub fn update(self: *GUI) !void {
    const zone = tracy.ZoneN(@src(), "GUI update");
    defer zone.End();

    switch (builtin.os.tag) {
        .linux => {
            try linux.update(self.plugin);
        },
        .macos => {
            try macos.update(self.plugin);
        },
        else => {},
    }
}

fn initWindow(self: *GUI) !void {
    std.log.debug("Creating window.", .{});
    try imgui.init(self);
    // Only init GLFW here with the window, other platforms will be inited with setParent()
    if (builtin.os.tag == .linux) {
        try linux.init(self);
    }
}

fn deinitWindow(self: *GUI) void {
    std.log.debug("Destroying window.", .{});

    if (self.platform_data != null) {
        imgui.deinit(self);
        switch (builtin.os.tag) {
            .macos => {
                macos.deinit(self);
            },
            .linux => {
                linux.deinit(self);
            },
            .windows => {
                // TODO
            },
            else => {},
        }
    }

    // I'm not sure if this is necessary, and on REAPER this keeps resulting in a crash no matter what
    // if (self.plugin.host.getExtension(self.plugin.host, clap.ext.gui.id)) |host_header| {
    //     var gui_host: *const clap.ext.gui.Host = @ptrCast(@alignCast(host_header));
    //     gui_host.closed(self.plugin.host, true);
    // }
}

pub fn show(self: *GUI) !void {
    self.visible = true;
    // Only set on GLFW, otherwise this will be handled by the DAW
    if (builtin.os.tag == .linux) {
        if (self.platform_data) |data| {
            data.window.setAttribute(.visible, true);
        }
    }
}

pub fn hide(self: *GUI) void {
    self.visible = false;
    if (builtin.os.tag == .linux) {
        if (self.platform_data) |data| {
            data.window.setAttribute(.visible, true);
        }
    }
}

fn setTitle(self: *GUI, title: [:0]const u8) void {
    switch (builtin.os.tag) {
        .macos => {},
        .linux => {
            if (self.platform_data) |data| {
                data.window.setTitle(title);
            }
        },
        else => {},
    }
}

fn getSize(self: *const GUI) [2]u32 {
    return [2]u32{ self.width, self.height };
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

fn _isApiSupported(_: *const clap.Plugin, _: [*:0]const u8, is_floating: bool) callconv(.C) bool {
    if (is_floating) return builtin.os.tag == .linux;
    return true;
}

/// returns true if the plugin has a preferred api. the host has no obligation to honor the plugin's preference,
/// this is just a hint. `api` should be explicitly assigned as a pinter to one of the `window_api.*` constants,
/// not copied.
fn _getPreferredApi(_: *const clap.Plugin, _: *[*:0]const u8, is_floating: *bool) callconv(.C) bool {
    // We only support floating windows on Linux for the time being
    // I don't see how this can change given we can only have 1 ImGui backend at a time with ZGui
    // I could make a PR to change that but I am fine with this for now
    is_floating.* = builtin.os.tag == .linux;
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
fn _setScale(_: *const clap.Plugin, _: f64) callconv(.C) bool {
    return false;
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
        switch (builtin.os.tag) {
            .macos => {
                const view: *objc.app_kit.View = @ptrCast(plugin_window.data.cocoa);

                macos.init(gui, view) catch |err| {
                    std.log.err("Error initializing window! {}", .{err});
                    return false;
                };
                return true;
            },
            else => {},
        }
    }

    return false;
}

/// sets the plugin window to stay above the given window. returns true on success.
fn _setTransient(_: *const clap.Plugin, _: *const clap.ext.gui.Window) callconv(.C) bool {
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
