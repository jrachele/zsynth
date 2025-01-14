const builtin = @import("builtin");
const std = @import("std");
const Step = std.Build.Step;

const util = @import("util.zig");

pub fn build(b: *std.Build) void {
    const generate_wavetables_comptime = b.option(
        bool,
        "generate_wavetables_comptime",
        "Generate and embed the wavetables at compile time. Will significantly impact compile times, but will reduce initial plugin start time.",
    ) orelse false;

    const wait_for_debugger = b.option(
        bool,
        "wait_for_debugger",
        "Stall when creating a plugin from the factory until a debugger mutates wait variable",
    ) orelse false;

    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const clap_bindings = b.dependency("clap-bindings", .{});
    const regex = b.dependency("regex", .{});
    const zgui = b.dependency("zgui", .{
        .shared = false,
        .with_implot = true,
        .backend = .glfw_opengl3,
    });
    const zglfw = b.dependency("zglfw", .{
        .shared = false,
        .x11 = true,
        .wayland = false,
    });
    const zopengl = b.dependency("zopengl", .{});

    const lib = b.addSharedLibrary(
        .{
            .name = "zsynth",
            .target = target,
            .optimize = optimize,
            .root_source_file = .{ .cwd_relative = "src/main.zig" },
        },
    );

    const exe = b.addExecutable(
        .{
            .name = "zsynth",
            .target = target,
            .optimize = optimize,
            .root_source_file = .{ .cwd_relative = "src/diag.zig" },
        },
    );

    // Allow options to be passed in to source files
    var options = Step.Options.create(b);
    options.addOption(bool, "generate_wavetables_comptime", generate_wavetables_comptime);
    options.addOption(bool, "wait_for_debugger", wait_for_debugger);

    // Something about this is very wrong...
    const font_data = @embedFile("assets/Roboto-Medium.ttf");
    var static_data = Step.Options.create(b);
    static_data.addOption([]const u8, "font", font_data);
    const build_targets = [_]*Step.Compile{ lib, exe };
    for (build_targets) |pkg| {
        // Libraries
        pkg.root_module.addImport("clap-bindings", clap_bindings.module("clap-bindings"));
        pkg.root_module.addImport("regex", regex.module("regex"));

        // GUI Related pkgraries
        pkg.root_module.addImport("zgui", zgui.module("root"));
        pkg.linkLibrary(zgui.artifact("imgui"));
        pkg.root_module.addImport("zglfw", zglfw.module("root"));
        pkg.linkLibrary(zglfw.artifact("glfw"));
        pkg.root_module.addImport("zopengl", zopengl.module("root"));

        pkg.root_module.addOptions("options", options);
        pkg.root_module.addOptions("static_data", static_data);

        if (builtin.os.tag == .macos) {
            pkg.addCSourceFiles(.{
                .files = &.{
                    "src/ext/gui/cocoa_helper.m",
                },
                .flags = &.{},
            });
        }
    }

    // Specific steps for different targets
    // Library
    const rename_dll_step = CreateClapPluginStep.create(b, lib);
    rename_dll_step.step.dependOn(&b.addInstallArtifact(lib, .{}).step);
    b.getInstallStep().dependOn(&rename_dll_step.step);

    // Also create executable for testing
    if (optimize == .Debug) {
        b.installArtifact(exe);
        const run_exe = b.addRunArtifact(exe);

        const run_step = b.step("run", "Run the application");
        run_step.dependOn(&run_exe.step);
    }
}

pub const CreateClapPluginStep = struct {
    pub const base_id = .top_level;

    const Self = @This();

    step: Step,
    build: *std.Build,
    artifact: *Step.Compile,

    pub fn create(b: *std.Build, artifact: *Step.Compile) *Self {
        const self = b.allocator.create(Self) catch unreachable;
        const name = "create clap plugin";
        self.* = Self{
            .step = Step.init(Step.StepOptions{ .id = .top_level, .name = name, .owner = b, .makeFn = make }),
            .build = b,
            .artifact = artifact,
        };
        return self;
    }

    fn make(step: *Step, _: Step.MakeOptions) !void {
        const self: *Self = @fieldParentPtr("step", step);
        if (self.build.build_root.path) |path| {
            var dir = try std.fs.openDirAbsolute(path, .{});
            switch (builtin.os.tag) {
                .macos => {
                    _ = try dir.updateFile("zig-out/lib/libzsynth.dylib", dir, "zig-out/lib/ZSynth.clap/Contents/MacOS/ZSynth", .{});
                    _ = try dir.updateFile("macos/info.plist", dir, "zig-out/lib/ZSynth.clap/Contents/info.plist", .{});
                    _ = try dir.updateFile("macos/PkgInfo", dir, "zig-out/lib/ZSynth.clap/Contents/PkgInfo", .{});
                    // var buffer: [1024]u8 = undefined;
                    // var fba = std.heap.FixedBufferAllocator.init(&buffer);
                    // const allocator = fba.allocator();
                    // const source_dir = try dir.openDir("zig-out/lib/ZSynth.clap/", .{});
                    // const dest_path = try std.fs.realpathAlloc(allocator, "~/Library/Audio/Plug-Ins/CLAP/ZSynth.clap");
                    // defer allocator.free(dest_path);
                    // try util.copyDirRecursiveAbsolute(allocator, source_dir, dest_path);
                },
                .linux => {
                    _ = try dir.updateFile("zig-out/lib/libzsynth.so", dir, "zig-out/lib/zsynth.clap", .{});
                },
                .windows => {
                    _ = try dir.updateFile("zig-out\\lib\\libzsynth.dll", dir, "zig-out\\lib\\zsynth.clap", .{});
                },
                else => {},
            }
        }
    }
};
