const std = @import("std");
const Step = std.Build.Step;

const gui_supported = false;

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const clap_bindings = b.dependency("clap-bindings", .{});
    const regex = b.dependency("regex", .{});

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

    const lib = b.addSharedLibrary(
        .{
            .name = "zsynth",
            .target = target,
            .optimize = optimize,
            .root_source_file = .{ .cwd_relative = "src/main.zig" },
        },
    );

    // Add CLAP headers
    lib.root_module.addImport("clap-bindings", clap_bindings.module("clap-bindings"));
    lib.root_module.addImport("regex", regex.module("regex"));

    var options = Step.Options.create(b);
    options.addOption(bool, "generate_wavetables_comptime", generate_wavetables_comptime);
    options.addOption(bool, "wait_for_debugger", wait_for_debugger);
    lib.root_module.addOptions("options", options);

    // if (gui_supported) {
    //     const dvui = b.dependency("dvui", .{});
    //     lib.root_module.addImport("dvui", dvui.module("dvui_sdl"));
    // }

    const rename_dll_step = CreateClapPluginStep.create(b, lib);
    rename_dll_step.step.dependOn(&b.addInstallArtifact(lib, .{}).step);
    b.getInstallStep().dependOn(&rename_dll_step.step);

    // Also create executable for testing
    if (optimize == .Debug) {
        const exe = b.addExecutable(
            .{
                .name = "zsynth",
                .target = target,
                .optimize = optimize,
                .root_source_file = .{ .cwd_relative = "src/diag.zig" },
            },
        );

        exe.root_module.addImport("clap-bindings", clap_bindings.module("clap-bindings"));
        const zigplotlib = b.dependency("zigplotlib", .{
            .target = target,
            .optimize = optimize,
        });

        exe.root_module.addImport("plotlib", zigplotlib.module("zigplotlib"));

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
            _ = try dir.updateFile("zig-out/lib/libzsynth.dylib", dir, "zig-out/lib/ZSynth.clap/Contents/MacOS/ZSynth", .{});
            _ = try dir.updateFile("macos/info.plist", dir, "zig-out/lib/ZSynth.clap/Contents/info.plist", .{});
            _ = try dir.updateFile("macos/PkgInfo", dir, "zig-out/lib/ZSynth.clap/Contents/PkgInfo", .{});
        }
    }
};
