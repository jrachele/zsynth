const std = @import("std");
const Step = std.Build.Step;

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const clap_bindings = b.dependency("clap-bindings", .{});
    const exe = b.addSharedLibrary(.{ .name = "zig_audio_plugin", .target = target, .optimize = std.builtin.OptimizeMode.Debug, .root_source_file = .{ .cwd_relative = "src/main.zig" } });

    // Add CLAP headers
    exe.root_module.addImport("clap-bindings", clap_bindings.module("clap-bindings"));

    const rename_dll_step = CreateClapPluginStep.create(b, exe);
    rename_dll_step.step.dependOn(&b.addInstallArtifact(exe, .{}).step);
    b.getInstallStep().dependOn(&rename_dll_step.step);
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
            _ = try dir.updateFile("zig-out/lib/libzig_audio_plugin.dylib", dir, "zig-out/lib/Zig Audio Plugin.clap/Contents/MacOS/Zig Audio Plugin", .{});
            _ = try dir.updateFile("macos/info.plist", dir, "zig-out/lib/Zig Audio Plugin.clap/Contents/info.plist", .{});
            _ = try dir.updateFile("macos/PkgInfo", dir, "zig-out/lib/Zig Audio Plugin.clap/Contents/PkgInfo", .{});
        }
    }
};
