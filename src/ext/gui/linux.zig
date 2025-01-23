const builtin = @import("builtin");
const std = @import("std");
const zgui = @import("zgui");
const zopengl = @import("zopengl");
const glfw = @import("zglfw");

const imgui = @import("imgui.zig");
const GUI = @import("gui.zig");
const Plugin = @import("../../plugin.zig");

const gl_major = 4;
const gl_minor = 0;

pub fn init(gui: *GUI) !void {
    if (gui.platform_data != null) {
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
    const window = try glfw.Window.create(@intCast(gui.width), @intCast(gui.height), window_title, null);
    errdefer window.destroy();
    window.setSizeLimits(100, 100, -1, -1);

    glfw.makeContextCurrent(window);
    glfw.swapInterval(1);

    try zopengl.loadCoreProfile(glfw.getProcAddress, gl_major, gl_minor);

    gui.scale_factor = window.getContentScale()[1];
    imgui.applyScaleFactor(gui);

    zgui.backend.init(window);
    errdefer zgui.backend.deinit();

    gui.platform_data = .{
        .window = window,
    };
}

pub fn deinit(gui: *GUI) void {
    if (gui.platform_data) |data| {
        data.window.destroy();
        glfw.terminate();
    }
    gui.platform_data = null;
}

pub fn update(plugin: *Plugin) !void {
    if (plugin.gui) |gui| {
        if (gui.platform_data) |data| {
            if (data.window.shouldClose()) {
                std.log.info("Window requested close, closing!", .{});
                gui.deinit();
                return;
            }
            try draw(gui);
        }
    }
}

pub fn draw(gui: *GUI) !void {
    if (gui.platform_data == null) {
        return error.PlatformNotInitialized;
    }

    var window = gui.platform_data.?.window;
    if (window.getKey(.escape) == .press) {
        glfw.setWindowShouldClose(window, true);
        return;
    }

    const gl = zopengl.bindings;

    glfw.pollEvents();

    gl.clearBufferfv(gl.COLOR, 0, &[_]f32{ 0, 0, 0, 1.0 });

    const fb_size = window.getFramebufferSize();

    zgui.backend.newFrame(@intCast(fb_size[0]), @intCast(fb_size[1]));
    imgui.draw(gui);
    zgui.backend.draw();

    window.swapBuffers();
}
