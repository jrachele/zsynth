const builtin = @import("builtin");
const std = @import("std");
const Step = std.Build.Step;

pub fn build(b: *std.Build) void {
    const generate_wavetables_comptime = b.option(
        bool,
        "generate_wavetables_comptime",
        "Generate and embed the wavetables at compile time. Will significantly impact compile times, but will reduce initial plugin start time.",
    ) orelse false;

    const wait_for_debugger = b.option(
        bool,
        "wait_for_debugger",
        "Stall when creating a plugin from the factory",
    ) orelse false;

    const profiling = b.option(
        bool,
        "profiling",
        "Enable profiling with tracy. Profiling is enabled by default in debug builds, but not in release builds.",
    ) orelse false;

    const disable_profiling = b.option(
        bool,
        "disable_profiling",
        "Disable profiling. This will override the enable profiling flag",
    ) orelse false;

    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const clap_bindings = b.dependency("clap-bindings", .{});
    const regex = b.dependency("regex", .{});
    const zgui = b.dependency("zgui", .{
        .shared = false,
        .with_implot = true,
        .backend = switch (builtin.os.tag) {
            .macos => .osx_metal,
            .windows => .win32_dx12,
            else => .glfw_opengl3,
        },
    });
    const zglfw = b.dependency("zglfw", .{
        .shared = false,
        .x11 = true,
        .wayland = false,
    });
    const zopengl = b.dependency("zopengl", .{});
    const objc = b.dependency("mach-objc", .{});

    const ztracy = b.dependency("ztracy", .{
        .enable_ztracy = (builtin.mode == .Debug or profiling == true) and !disable_profiling,
        .callstack = 20,
        .on_demand = true,
    });

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

        // GUI Related libraries
        pkg.root_module.addImport("zgui", zgui.module("root"));
        pkg.linkLibrary(zgui.artifact("imgui"));
        pkg.root_module.addImport("zglfw", zglfw.module("root"));
        pkg.linkLibrary(zglfw.artifact("glfw"));
        pkg.root_module.addImport("zopengl", zopengl.module("root"));
        pkg.linkLibrary(zopengl.artifact("zopengl"));

        // Profiling
        pkg.root_module.addImport("tracy", ztracy.module("root"));
        pkg.linkLibrary(ztracy.artifact("tracy"));

        pkg.root_module.addOptions("options", options);
        pkg.root_module.addOptions("static_data", static_data);

        if (builtin.os.tag == .macos) {
            pkg.root_module.addImport("objc", objc.module("mach-objc"));
            pkg.linkFramework("AppKit");
            pkg.linkFramework("Cocoa");
            pkg.linkFramework("CoreGraphics");
            pkg.linkFramework("Foundation");
            pkg.linkFramework("Metal");
            pkg.linkFramework("QuartzCore");
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
        var gpa = std.heap.GeneralPurposeAllocator(.{}){};
        const allocator = gpa.allocator();
        defer switch (gpa.deinit()) {
            .ok => {},
            .leak => {
                std.log.err("Memory leaks when building!", .{});
            },
        };

        const self: *Self = @fieldParentPtr("step", step);
        if (self.build.build_root.path) |path| {
            var dir = try std.fs.openDirAbsolute(path, .{});
            switch (builtin.os.tag) {
                .macos => {
                    _ = try dir.updateFile("zig-out/lib/libzsynth.dylib", dir, "zig-out/lib/ZSynth.clap/Contents/MacOS/ZSynth", .{});
                    _ = try dir.updateFile("macos/info.plist", dir, "zig-out/lib/ZSynth.clap/Contents/info.plist", .{});
                    _ = try dir.updateFile("macos/PkgInfo", dir, "zig-out/lib/ZSynth.clap/Contents/PkgInfo", .{});
                    if (builtin.mode == .Debug) {
                        // Also generate dynamic symbols for Tracy
                        var child = std.process.Child.init(&.{ "dsymutil", "zig-out/lib/ZSynth.clap/Contents/MacOS/ZSynth" }, allocator);
                        _ = try child.spawnAndWait();
                    }
                    // Copy the CLAP plugin to the library folder
                    try copyDirRecursiveToHome(allocator, "zig-out/lib/ZSynth.clap/", "Library/Audio/Plug-Ins/CLAP/ZSynth.clap");
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

fn copyDirRecursiveToHome(allocator: std.mem.Allocator, source_dir: []const u8, dest_path_from_home: []const u8) !void {
    const home = try std.process.getEnvVarOwned(allocator, "HOME");
    defer allocator.free(home);
    const dest_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ home, dest_path_from_home });
    defer allocator.free(dest_path);
    var cp = std.process.Child.init(&.{
        "cp",
        "-R",
        source_dir,
        dest_path,
    }, allocator);
    _ = try cp.spawnAndWait();
}
