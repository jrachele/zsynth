const std = @import("std");

pub fn initMetalDevice() *const anyopaque {
    return createMetalDevice();
}

pub fn deinitMetalDevice(device: *const anyopaque) void {
    releaseMetalDevice(device);
}

pub fn initMetalLayer(device: *const anyopaque, view: *const anyopaque) *const anyopaque {
    return createMetalLayer(device, view);
}

pub fn deinitMetalLayer(metal_layer: *const anyopaque, view: *const anyopaque) void {
    releaseMetalLayer(metal_layer, view);
}

pub fn initRenderPassDescriptor() *const anyopaque {
    return createRenderPassDescriptor();
}

pub fn deinitRenderPassDescriptor(render_pass_descriptor: *const anyopaque) void {
    releaseRenderPassDescriptor(render_pass_descriptor);
}

pub fn initCommandQueue(device: *const anyopaque) *const anyopaque {
    return createCommandQueue(device);
}

pub fn deinitCommandQueue(command_queue: *const anyopaque) void {
    releaseCommandQueue(command_queue);
}

pub fn initCommandBuffer(command_queue: *const anyopaque) *const anyopaque {
    return createCommandBuffer(command_queue);
}

pub fn deinitCommandBuffer(command_buffer: *const anyopaque) void {
    releaseCommandBuffer(command_buffer);
}

pub fn initCommandEncoder(command_buffer: *const anyopaque, descriptor: *const anyopaque) *const anyopaque {
    return createCommandEncoder(command_buffer, descriptor);
}

pub fn deinitCommandEncoder(command_encoder: *const anyopaque) void {
    releaseCommandEncoder(command_encoder);
}

pub fn present(command_buffer: *const anyopaque, view: *const anyopaque) void {
    presentBuffer(command_buffer, view);
}

// macOS-specific helper functions
extern fn createMetalDevice() callconv(.c) *const anyopaque;
extern fn releaseMetalDevice(device: *const anyopaque) callconv(.c) void;
extern fn createMetalLayer(device: *const anyopaque, view: *const anyopaque) callconv(.c) *const anyopaque;
extern fn releaseMetalLayer(metal_layer: *const anyopaque, view: *const anyopaque) callconv(.c) void;
extern fn createRenderPassDescriptor() callconv(.c) *const anyopaque;
extern fn releaseRenderPassDescriptor(render_pass_descriptor: *const anyopaque) callconv(.c) void;
extern fn createCommandQueue(device: *const anyopaque) callconv(.c) *const anyopaque;
extern fn releaseCommandQueue(command_queue: *const anyopaque) callconv(.c) void;
extern fn createCommandBuffer(command_queue: *const anyopaque) callconv(.c) *const anyopaque;
extern fn releaseCommandBuffer(command_buffer: *const anyopaque) callconv(.c) void;
extern fn createCommandEncoder(command_buffer: *const anyopaque, descriptor: *const anyopaque) *const anyopaque;
extern fn releaseCommandEncoder(command_encoder: *const anyopaque) callconv(.c) void;
extern fn presentBuffer(command_buffer: *const anyopaque, view: *const anyopaque) callconv(.c) void;
