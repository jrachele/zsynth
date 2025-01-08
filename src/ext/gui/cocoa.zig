const std = @import("std");

pub fn setParent(glfw_window: *anyopaque, parent_view: *anyopaque) void {
    cocoaSetParent(glfw_window, parent_view);
}

pub fn hideDock() void {
    cocoaHideDock();
}

// macOS-specific helper functions
extern fn cocoaSetParent(glfw_window: *anyopaque, parent_view: *anyopaque) callconv(.c) void;
extern fn cocoaHideDock() callconv(.c) void;
