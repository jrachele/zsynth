const builtin = @import("builtin");
const std = @import("std");
const clap = @import("clap-bindings");

const glfw = @import("zglfw");
const objc = @import("objc");
const Plugin = @import("plugin.zig");
const GUI = @import("ext/gui/gui.zig");

const MockHost = struct {
    clap_host: clap.Host,
    allocator: std.mem.Allocator,
    plugin: ?*Plugin,

    pub fn init(allocator: std.mem.Allocator) !*MockHost {
        const host = try allocator.create(MockHost);
        host.* = .{
            .clap_host = .{
                .clap_version = clap.version,
                .host_data = host,
                .name = "Mock Host",
                .version = "0.1",
                .url = null,
                .vendor = null,
                .getExtension = _getExtension,
                .requestCallback = _requestCallback,
                .requestProcess = _requestProcess,
                .requestRestart = _requestRestart,
            },
            .plugin = null,
            .allocator = allocator,
        };
        return host;
    }

    pub fn deinit(self: *MockHost) void {
        self.allocator.destroy(self);
    }

    pub fn fromClapHost(clap_host: *const clap.Host) *MockHost {
        return @ptrCast(@alignCast(clap_host.host_data));
    }

    pub fn setPlugin(self: *MockHost, plugin: *Plugin) void {
        self.plugin = plugin;
    }

    /// query an extension. the returned pointer is owned by the host. it is forbidden to
    /// call it before `Plugin.init`. you may call in within `Plugin.init` call and after.
    fn _getExtension(_: *const clap.Host, _: [*:0]const u8) callconv(.C) ?*const anyopaque {
        return null;
    }

    /// request the host to deactivate then reactivate
    /// the plugin. the host may delay this operation.
    fn _requestRestart(_: *const clap.Host) callconv(.C) void {}
    /// request the host to start processing the plugin. this is useful
    /// if you have external IO and need to wake the plugin up from "sleep"
    fn _requestProcess(_: *const clap.Host) callconv(.C) void {}

    /// request the host to schedule a call to `Plugin.onMainThread`, on the main thread.
    fn _requestCallback(clap_host: *const clap.Host) callconv(.C) void {
        const host = MockHost.fromClapHost(clap_host);
        if (host.plugin) |plugin| {
            plugin.plugin.onMainThread(&plugin.plugin);
        }
    }
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var host = try MockHost.init(allocator);
    defer host.deinit();

    const plugin = try Plugin.init(allocator, &host.clap_host);
    plugin.sample_rate = 48000;
    defer plugin.deinit();

    host.setPlugin(plugin);

    const plugin_gui_ext = GUI.create();

    switch (builtin.os.tag) {
        .macos => {
            // For macOS testing, we'll act like the "host" and create a window using GLFW
            try glfw.init();
            const glfw_window = try glfw.createWindow(800, 500, "ZSynth", null);
            defer glfw_window.destroy();
            const nswindow: *objc.app_kit.Window = @ptrCast(glfw.getCocoaWindow(glfw_window));
            const window = clap.ext.gui.Window{ .api = "cocoa", .data = .{
                .cocoa = nswindow.contentView().?,
            } };
            _ = plugin_gui_ext.create(&plugin.plugin, null, false);
            _ = plugin_gui_ext.setParent(&plugin.plugin, &window);
            glfw_window.show();
            while (plugin.gui) |gui| {
                try gui.update();
            }
        },
        .linux => {
            _ = plugin_gui_ext.create(&plugin.plugin, null, true);
            while (plugin.gui) |gui| {
                try gui.update();
            }
        },
        else => {
            // TODO
        },
    }
}
