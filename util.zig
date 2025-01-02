const std = @import("std");

pub fn copyDirRecursiveAbsolute(allocator: std.mem.Allocator, source_dir: std.fs.Dir, dest_path: []const u8) !void {
    var dest_dir = try std.fs.openDirAbsolute(dest_path, .{});

    var walker = try source_dir.walk(allocator);
    defer walker.deinit();
    while (try walker.next()) |entry| {
        switch (entry.kind) {
            .directory => {
                try dest_dir.makeDir(entry.path);
            },
            .file => {
                try entry.dir.copyFile(entry.basename, dest_dir, entry.path, .{});
            },
            else => {
                return error.UnexpectedEntryKind;
            },
        }
    }
}

test "copy recursive" {
    var buffer: [1024]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&buffer);
    const allocator = fba.allocator();
    const dest_path = try std.fs.realpathAlloc(allocator, "~/Library/Audio/Plug-Ins/CLAP/");
    defer allocator.free(dest_path);
    std.debug.print("{s}", .{dest_path});
}
