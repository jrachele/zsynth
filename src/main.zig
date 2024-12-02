const std = @import("std");
const clap = @import("clap-bindings");

var gpa: std.heap.GeneralPurposeAllocator(.{ .thread_safe = true }) = undefined;

const ClapEntry = struct {
    fn createEntry() clap.Entry {
        return clap.Entry{ .version = clap.clap_version, .init = init, .deinit = deinit, .getFactory = getFactory };
    }

    fn init(plugin_path: [*:0]const u8) callconv(.c) bool {
        gpa = .{};
        std.debug.print("Plugin initialized with path {s}\n", .{plugin_path});
        return true;
    }

    fn deinit() callconv(.c) void {
        std.debug.print("Plugin deinitialized\n", .{});
        switch (gpa.deinit()) {
            std.heap.Check.leak => {
                std.debug.print("Leaks happened!", .{});
            },
            else => {},
        }
    }

    const ClapPluginFactoryId: []const u8 = "clap.plugin-factory";

    fn getFactory(factory_id: [*:0]const u8) callconv(.c) ?*const anyopaque {
        if (std.mem.eql(u8, std.mem.span(factory_id), ClapPluginFactoryId)) {
            return &plugin_factory;
        }
        std.debug.print("factory_id: {s} \n", .{factory_id});
        return null;
    }
};

pub export const clap_entry = ClapEntry.createEntry();

const ClapFactory = struct {
    fn create() clap.PluginFactory {
        return clap.PluginFactory{ .getPluginCount = getPluginCount, .getPluginDescriptor = getPluginDescriptor, .createPlugin = createPlugin };
    }

    /// get the number of available plugins.
    fn getPluginCount(_: *const clap.PluginFactory) callconv(.C) u32 {
        return 1;
    }
    /// retrieve a plugin descriptor by its index. returns null in case of error. the descriptor must not be freed.
    fn getPluginDescriptor(_: *const clap.PluginFactory, index: u32) callconv(.C) ?*const clap.Plugin.Descriptor {
        std.debug.print("getPluginDescriptor invoked\n", .{});
        if (index == 0) {
            return &MyPlugin.desc;
        }
        return null;
    }

    /// create a plugin by it's id. the returned pointer must be freed by calling `Plugin.destroy`. the
    /// plugin is not allowed to use host callbacks in the create method. returns null in case of error.
    fn createPlugin(
        _: *const clap.PluginFactory,
        host: *const clap.Host,
        plugin_id: [*:0]const u8,
    ) callconv(.C) ?*const clap.Plugin {
        if (!host.clap_version.isCompatible()) {
            return null;
        }

        if (!std.mem.eql(u8, std.mem.span(plugin_id), std.mem.span(MyPlugin.desc.id))) {
            std.debug.print("Mismatched plugin id: {s}; descriptor id: {s}", .{ plugin_id, MyPlugin.desc.id });
            return null;
        }

        const plugin = MyPlugin.create(host, gpa.allocator()) catch {
            std.debug.print("Error allocating plugin!\n", .{});
            return null;
        };

        return plugin;
    }
};

const plugin_factory = ClapFactory.create();

const MyPlugin = struct {
    sample_rate: ?f64 = null,
    allocator: std.mem.Allocator,
    plugin: clap.Plugin,
    host: *const clap.Host,

    pub const desc = clap.Plugin.Descriptor{
        .clap_version = clap.clap_version,
        .id = "com.juge.zig-audio-plugin",
        .name = "Zig Audio Plugin",
        .vendor = "juge",
        .url = "",
        .manual_url = "",
        .support_url = "",
        .version = "1.0.0",
        .description = "Test CLAP Plugin written in Zig",
        .features = &.{clap.Plugin.features.audio_effect},
    };

    pub fn fromPlugin(plugin: *const clap.Plugin) *@This() {
        return @ptrCast(@alignCast(plugin.plugin_data));
    }

    pub fn create(host: *const clap.Host, allocator: std.mem.Allocator) !*const clap.Plugin {
        const clap_demo = try allocator.create(@This());
        errdefer allocator.destroy(clap_demo);
        clap_demo.* = .{
            .allocator = allocator,
            .plugin = .{
                .descriptor = &desc,
                .plugin_data = clap_demo,
                .init = init,
                .destroy = destroy,
                .activate = activate,
                .deactivate = deactivate,
                .startProcessing = startProcessing,
                .stopProcessing = stopProcessing,
                .reset = reset,
                .process = process,
                .getExtension = getExtension,
                .onMainThread = onMainThread,
            },
            .host = host,
        };

        return &clap_demo.plugin;
    }

    fn init(_: *const clap.Plugin) callconv(.C) bool {
        return true;
    }

    fn destroy(plugin: *const clap.Plugin) callconv(.C) void {
        var clap_demo = fromPlugin(plugin);
        clap_demo.allocator.destroy(clap_demo);
    }

    fn activate(
        plugin: *const clap.Plugin,
        sample_rate: f64,
        _: u32,
        _: u32,
    ) callconv(.C) bool {
        var clap_demo = fromPlugin(plugin);
        clap_demo.sample_rate = sample_rate;
        return true;
    }

    fn deactivate(_: *const clap.Plugin) callconv(.C) void {}

    fn startProcessing(_: *const clap.Plugin) callconv(.C) bool {
        return true;
    }

    fn stopProcessing(_: *const clap.Plugin) callconv(.C) void {}

    fn reset(_: *const clap.Plugin) callconv(.C) void {}

    fn process(_: *const clap.Plugin, clap_process: *const clap.Process) callconv(.C) clap.Process.Status {
        // Somehow turn this into an adjustable parameter
        const gain = 0.5;
        var i: u32 = 0;
        // std.debug.panic("test", .{});

        while (i < clap_process.audio_inputs_count) : (i += 1) {
            const input_buffer = &clap_process.audio_inputs[i];
            const output_buffer = &clap_process.audio_outputs[i];

            var channel: u32 = 0;
            while (channel < input_buffer.channel_count) : (channel += 1) {
                const is32 = input_buffer.data32 != null;
                const is64 = input_buffer.data64 != null;
                if (is32) {
                    const input_samples = input_buffer.data32.?[channel];
                    var output_samples = output_buffer.data32.?[channel];
                    var frame: u32 = 0;
                    while (frame < clap_process.frames_count) : (frame += 1) {
                        output_samples[frame] = input_samples[frame] * gain;
                    }
                } else if (is64) {
                    const input_samples = input_buffer.data64.?[channel];
                    var output_samples = output_buffer.data64.?[channel];
                    var frame: u32 = 0;
                    while (frame < clap_process.frames_count) : (frame += 1) {
                        output_samples[frame] = input_samples[frame] * gain;
                    }
                } else {
                    std.debug.panic("Received no input or output samples for channel {d}", .{channel});
                }
            }
        }

        return clap.Process.Status.@"continue";
    }

    fn getExtension(_: *const clap.Plugin, id: [*:0]const u8) callconv(.C) ?*const anyopaque {
        if (std.mem.eql(u8, std.mem.span(id), clap.extensions.audio_ports.id)) {
            return &audio_ports;
        }

        return null;
    }

    fn onMainThread(_: *const clap.Plugin) callconv(.C) void {}
};

const audio_ports = AudioPorts.create();

// Audio Ports Extension
const AudioPorts = struct {
    fn create() clap.extensions.audio_ports.Plugin {
        return .{
            .count = count,
            .get = get,
        };
    }

    /// number of ports for either input or output
    fn count(_: *const clap.Plugin, is_input: bool) callconv(.C) u32 {
        return if (is_input) 1 else 1;
    }
    /// get info about an audio port. returns true on success and stores the result into `info`.
    fn get(_: *const clap.Plugin, index: u32, is_input: bool, info: *clap.extensions.audio_ports.Info) callconv(.C) bool {
        var nameBuf: [clap.name_capacity]u8 = undefined;
        if (is_input) {
            const name = std.fmt.bufPrint(&nameBuf, "Audio Input {}", .{index}) catch {
                return false;
            };
            std.mem.copyForwards(u8, &info.name, name);

            std.debug.print("{s}", .{name});

            info.id = @enumFromInt(index);
            info.channel_count = 1;
            info.flags = .{
                .is_main = true,
                .supports_64bits = false,
            };
            info.port_type = "mono";
            info.in_place_pair = .invalid_id;
        } else {
            const name = std.fmt.bufPrint(&nameBuf, "Audio Output {}", .{index}) catch {
                return false;
            };
            std.mem.copyForwards(u8, &info.name, name);
            std.debug.print("{s}", .{name});

            info.id = @enumFromInt(index);
            info.channel_count = 1;
            info.flags = .{
                .is_main = true,
                .supports_64bits = false,
            };
            info.port_type = "mono";
            info.in_place_pair = .invalid_id;
        }

        return true;
    }
};
