const std = @import("std");
const options = @import("options");
const builtin = @import("builtin");

const clap = @import("clap-bindings");

const Plugin = @import("plugin.zig");

var gpa: std.heap.GeneralPurposeAllocator(.{ .thread_safe = true }) = undefined;

// Main contains the Clap Entry, and the Clap Plugin factory.
// The entry point initializes the allocator, and it is passed into the plugin
// Within the factory
const ClapEntry = struct {
    fn createEntry() clap.Entry {
        return clap.Entry{
            .version = clap.version,
            .init = _init,
            .deinit = _deinit,
            .getFactory = _getFactory,
        };
    }

    fn _init(plugin_path: [*:0]const u8) callconv(.c) bool {
        if (builtin.mode == .Debug) {
            var wait: bool = options.wait_for_debugger;
            const debuggerMutate: *volatile bool = &wait;
            while (debuggerMutate.*) {}
        }

        gpa = .{};
        std.log.debug("Plugin initialized with path {s}", .{plugin_path});
        return true;
    }

    fn _deinit() callconv(.c) void {
        std.log.debug("Plugin deinitialized", .{});
        switch (gpa.deinit()) {
            std.heap.Check.leak => {
                std.log.debug("Leaks happened!", .{});
            },
            else => {},
        }
    }

    const ClapPluginFactoryId: []const u8 = "clap.plugin-factory";

    fn _getFactory(factory_id: [*:0]const u8) callconv(.c) ?*const anyopaque {
        if (std.mem.eql(u8, std.mem.span(factory_id), ClapPluginFactoryId)) {
            return &plugin_factory;
        }
        std.log.debug("factory_id: {s} ", .{factory_id});
        return null;
    }
};

pub export const clap_entry = ClapEntry.createEntry();

const ClapFactory = struct {
    fn create() clap.PluginFactory {
        return clap.PluginFactory{ .getPluginCount = _getPluginCount, .getPluginDescriptor = _getPluginDescriptor, .createPlugin = _createPlugin };
    }

    /// get the number of available plugins.
    fn _getPluginCount(_: *const clap.PluginFactory) callconv(.C) u32 {
        return 1;
    }
    /// retrieve a plugin descriptor by its index. returns null in case of error. the descriptor must not be freed.
    fn _getPluginDescriptor(_: *const clap.PluginFactory, index: u32) callconv(.C) ?*const clap.Plugin.Descriptor {
        std.log.debug("getPluginDescriptor invoked", .{});
        if (index == 0) {
            return &Plugin.desc;
        }
        return null;
    }

    /// create a plugin by it's id. the returned pointer must be freed by calling `Plugin.destroy`. the
    /// plugin is not allowed to use host callbacks in the create method. returns null in case of error.
    fn _createPlugin(
        _: *const clap.PluginFactory,
        host: *const clap.Host,
        plugin_id: [*:0]const u8,
    ) callconv(.C) ?*const clap.Plugin {
        if (!host.clap_version.isCompatible()) {
            return null;
        }

        if (!std.mem.eql(u8, std.mem.span(plugin_id), std.mem.span(Plugin.desc.id))) {
            std.log.debug("Mismatched plugin id: {s}; descriptor id: {s}", .{ plugin_id, Plugin.desc.id });
            return null;
        }

        const plugin = Plugin.create(host, gpa.allocator()) catch {
            std.log.debug("Error allocating plugin!", .{});
            return null;
        };

        return plugin;
    }
};

const plugin_factory = ClapFactory.create();
