const GUI = @This();

const builtin = @import("builtin");
const std = @import("std");
const clap = @import("clap-bindings");
const objc = @import("objc");

const zgui = @import("zgui");
const glfw = @import("zglfw");
const zopengl = @import("zopengl");

const imgui = @import("imgui.zig");
const Plugin = @import("../../plugin.zig");

const PlatformData = switch (builtin.os.tag) {
    .macos => struct {
        view: *objc.app_kit.View,
        mach_view: *objc.mach.View,
        device: *objc.metal.Device,
        layer: *objc.quartz_core.MetalLayer,
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

scale_factor: f32 = 2.0,
platform_data: ?PlatformData,
imgui_initialized: bool,
visible: bool,

const gl_major = 4;
const gl_minor = 0;

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
    };

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

fn initWindow(self: *GUI) !void {
    std.log.debug("Creating window.", .{});
    try imgui.init(self);
    try self.initPlatform();
}

fn deinitWindow(self: *GUI) void {
    std.log.debug("Destroying window.", .{});

    var windowWasDestroyed = false;
    if (self.platform_data != null) {
        imgui.deinit(self);
        windowWasDestroyed = self.deinitPlatform();
    }

    if (self.plugin.host.getExtension(self.plugin.host, clap.ext.gui.id)) |host_header| {
        var gui_host: *const clap.ext.gui.Host = @ptrCast(@alignCast(host_header));
        gui_host.closed(self.plugin.host, windowWasDestroyed);
    }
}

inline fn initPlatform(self: *GUI) !void {
    switch (builtin.os.tag) {
        .macos => {
            try self.initMetal();
        },
        .linux => {
            try self.initGLFW();
        },
        else => {
            // TODO
        },
    }
}

inline fn deinitPlatform(self: *GUI) bool {
    var did_destroy_window = false;
    switch (builtin.os.tag) {
        .macos => {
            self.deinitMetal();
            // We didn't destroy the window itself, that's handled by the DAW
        },
        .windows => {
            // TODO
        },
        .linux => {
            self.deinitGLFW();
            did_destroy_window = true;
        },
        else => {},
    }

    return did_destroy_window;
}

fn initGLFW(self: *GUI) !void {
    if (self.platform_data != null) {
        std.log.err("Platform already initialized!", .{});
        return error.PlatformAlreadyInitialized;
    }

    // Initialize GLFW
    try glfw.init();
    errdefer glfw.terminate();

    glfw.windowHint(.context_version_major, gl_major);
    glfw.windowHint(.context_version_minor, gl_minor);
    glfw.windowHint(.opengl_profile, .opengl_core_profile);
    glfw.windowHint(.opengl_forward_compat, true);
    glfw.windowHint(.client_api, .opengl_api);
    glfw.windowHint(.doublebuffer, true);

    const window_title = "ZSynth";
    const window = try glfw.Window.create(window_width, window_height, window_title, null);
    errdefer window.destroy();
    window.setSizeLimits(100, 100, -1, -1);

    glfw.makeContextCurrent(window);
    glfw.swapInterval(1);

    try zopengl.loadCoreProfile(glfw.getProcAddress, gl_major, gl_minor);

    zgui.backend.init(window);
    errdefer zgui.backend.deinit();

    self.platform_data = .{
        .window = window,
    };
}

fn deinitGLFW(self: *GUI) void {
    if (self.platform_data) |data| {
        data.window.destroy();
        glfw.terminate();
    }
    self.platform_data = null;
}

fn initMetal(self: *GUI) !void {
    // We need the NSView* from the DAW
    if (self.platform_data == null) {
        return error.NoPlatformData;
    }
    const data = self.platform_data.?;
    const view = data.view;
    const metal_device = data.device;

    zgui.backend.init(view, metal_device);
    errdefer zgui.backend.deinit();
}

fn deinitMetal(self: *GUI) void {
    if (self.platform_data) |data| {
        data.device.release();
        data.layer.release();
    }
    self.platform_data = null;
}

pub fn show(self: *GUI) !void {
    try self.initWindow();
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

pub fn shouldUpdate(self: *const GUI) bool {
    return self.visible and self.platform_data != null;
}

pub fn update(self: *GUI) !void {
    if (self.platform_data) |data| {
        switch (builtin.os.tag) {
            .linux => {
                if (data.window.shouldClose()) {
                    std.log.info("Window requested close, closing!", .{});
                    self.deinitWindow();
                    return;
                }
                try self.drawGLFW();
            },
            .macos => {
                try self.drawMetal();
            },
            else => {},
        }
    }
}

fn drawGLFW(self: *GUI) !void {
    if (self.platform_data == null) {
        return error.PlatformNotInitialized;
    }

    var window = self.platform_data.?.window;
    if (window.getKey(.escape) == .press) {
        glfw.setWindowShouldClose(window, true);
        return;
    }

    const gl = zopengl.bindings;

    glfw.pollEvents();

    gl.clearBufferfv(gl.COLOR, 0, &[_]f32{ 0, 0, 0, 1.0 });

    const fb_size = window.getFramebufferSize();

    zgui.backend.newFrame(@intCast(fb_size[0]), @intCast(fb_size[1]));
    imgui.draw(self);
    zgui.backend.draw();

    window.swapBuffers();
}

fn drawMetal(self: *GUI) !void {
    if (self.platform_data == null) {
        return error.PlatformNotInitialized;
    }

    const data = self.platform_data.?;

    // TODO Find framebuffer size somehow
    // const fb_size = metal.getFrameBufferSize();

    const width: u32 = window_width;
    const height: u32 = window_height;

    const descriptor = objc.metal.RenderPassDescriptor.renderPassDescriptor();
    defer descriptor.release();

    const command_queue = data.device.newCommandQueue().?;
    defer command_queue.release();

    const command_buffer = command_queue.commandBuffer().?;
    defer command_buffer.release();

    const command_encoder = command_buffer.renderCommandEncoderWithDescriptor(descriptor).?;
    defer command_encoder.release();

    zgui.backend.newFrame(width, height, data.view, descriptor);
    imgui.draw(self);
    zgui.backend.draw(command_buffer, command_encoder);
    command_buffer.presentDrawable(data.mach_view.currentDrawable().?.as(objc.metal.Drawable));
    command_buffer.commit();
    command_buffer.waitUntilCompleted();
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
    switch (builtin.os.tag) {
        .macos => {},
        .linux => {
            if (self.platform_data) |data| {
                const size = data.window.getSize();
                return [2]u32{ @intCast(size[0]), @intCast(size[1]) };
            }
        },
        else => {},
    }

    // Assume default
    return [2]u32{ window_width, window_height };
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
fn _setScale(clap_plugin: *const clap.Plugin, scale: f64) callconv(.C) bool {
    const plugin: *Plugin = Plugin.fromClapPlugin(clap_plugin);
    if (plugin.gui) |gui| {
        gui.scale_factor = @floatCast(scale);
    }
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
        switch (builtin.os.tag) {
            .macos => {
                const view: *objc.app_kit.View = @ptrCast(plugin_window.data.cocoa);
                const device = objc.metal.createSystemDefaultDevice().?;
                var layer = objc.quartz_core.MetalLayer.allocInit();
                var mach_view = objc.mach.View.alloc();
                const frame = objc.app_kit.Rect{ .origin = .{
                    .x = 0,
                    .y = 0,
                }, .size = .{
                    .width = window_width,
                    .height = window_height,
                } };

                mach_view = mach_view.initWithFrame(frame);
                mach_view.setLayer(layer);
                view.addSubView(mach_view.as(objc.app_kit.View));
                layer.setDevice(device);
                gui.platform_data = .{
                    .view = view,
                    .mach_view = mach_view,
                    .device = device,
                    .layer = layer,
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
