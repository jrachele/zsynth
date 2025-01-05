const std = @import("std");

pub fn setParent(glfw_window: *anyopaque, parent_view: *anyopaque) void {
    cocoaSetParent(glfw_window, parent_view);
}

pub fn setVisibility(window: *anyopaque, visibility: bool) void {
    cocoaSetVisibility(window, visibility);
}

// macOS-specific helper functions
extern fn cocoaSetParent(glfw_window: *anyopaque, parent_view: *anyopaque) callconv(.c) void;
extern fn cocoaSetVisibility(parent_window: *anyopaque, visibility: bool) callconv(.c) void;
