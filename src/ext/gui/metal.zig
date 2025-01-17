const std = @import("std");
const objc = @import("objc");
const zgui = @import("zgui");

const glfw = @import("zglfw");
const imgui = @import("imgui.zig");
const GUI = @import("gui.zig");

pub fn init(self: *GUI, view: *objc.app_kit.View) !void {
    try imgui.init(self);
    const device = objc.metal.createSystemDefaultDevice().?;
    view.setFrameOrigin(.{
        .x = 0,
        .y = 0,
    });
    view.setFrameSize(.{
        .width = @floatFromInt(self.width),
        .height = @floatFromInt(self.height),
    });

    var layer = objc.quartz_core.MetalLayer.allocInit();
    layer.setDevice(device);
    layer.setDrawableSize(.{
        .width = @floatFromInt(self.width),
        .height = @floatFromInt(self.height),
    });

    view.setLayer(layer.as(objc.quartz_core.Layer));

    const command_queue = device.newCommandQueue().?;

    self.platform_data = .{
        .view = view,
        .device = device,
        .layer = layer,
        .command_queue = command_queue,
    };

    zgui.backend.init(view, device);
    errdefer zgui.backend.deinit();

    // Use GLFW only for event polling
    try glfw.init();
    errdefer glfw.terminate();
}

pub fn deinit(self: *GUI) void {
    if (self.platform_data) |data| {
        data.device.release();
        data.layer.release();
        data.command_queue.release();
    }
    self.platform_data = null;
}

pub fn update(self: *GUI) !void {
    // Poll events as well
    // const nsapplication = objc.app_kit.Application.sharedApplication();
    // const run_loop_mode = objc.app_kit.NSDefaultRunLoopMode;
    // const run_loop_mode_str = run_loop_mode.UTF8String();
    // std.log.debug("{s}", .{run_loop_mode_str});
    // while (nsapplication.nextEventMatchingMask(objc.app_kit.EventMaskAny, objc.app_kit.Date.distantPast(), run_loop_mode, true)) |event| {
    //     nsapplication.sendEvent(event);
    // }
    // TODO: Figure out why event polling magically works with GLFW but not manually...
    glfw.pollEvents();
    try draw(self);
}

pub fn draw(self: *GUI) !void {
    if (self.platform_data == null) {
        return error.PlatformNotInitialized;
    }

    const data = self.platform_data.?;

    const descriptor = objc.metal.RenderPassDescriptor.renderPassDescriptor();
    const color_attachment = descriptor.colorAttachments().objectAtIndexedSubscript(0);
    const clear_color = objc.metal.ClearColor.init(0, 0, 0, 1);
    color_attachment.setClearColor(clear_color);
    const attachment_descriptor = color_attachment.as(objc.metal.RenderPassAttachmentDescriptor);
    const drawable = data.layer.nextDrawable().?;
    attachment_descriptor.setTexture(drawable.texture());
    attachment_descriptor.setLoadAction(objc.metal.LoadActionClear);
    attachment_descriptor.setStoreAction(objc.metal.StoreActionStore);

    const command_buffer = data.command_queue.commandBuffer().?;
    const command_encoder = command_buffer.renderCommandEncoderWithDescriptor(descriptor).?;

    zgui.backend.newFrame(self.width, self.height, data.view, descriptor);
    imgui.draw(self);

    zgui.backend.draw(command_buffer, command_encoder);
    command_encoder.as(objc.metal.CommandEncoder).endEncoding();
    command_buffer.presentDrawable(drawable.as(objc.metal.Drawable));
    command_buffer.commit();
    command_buffer.waitUntilCompleted();
}
