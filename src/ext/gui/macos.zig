const builtin = @import("builtin");
const std = @import("std");
const objc = @import("objc");
const zgui = @import("zgui");

const glfw = @import("zglfw");
const imgui = @import("imgui.zig");
const GUI = @import("gui.zig");
const Plugin = @import("../../plugin.zig");

pub fn init(gui: *GUI, view: *objc.app_kit.View) !void {
    const window = view.window();

    gui.scale_factor = @floatCast(window.backingScaleFactor());
    imgui.applyScaleFactor(gui);

    const width: f32 = @floatFromInt(gui.width);
    const height: f32 = @floatFromInt(gui.height);
    const framebuffer_width: f32 = width * gui.scale_factor;
    const framebuffer_height: f32 = height * gui.scale_factor;

    const device = objc.metal.createSystemDefaultDevice().?;
    view.setFrameOrigin(.{
        .x = 0,
        .y = 0,
    });
    view.setFrameSize(.{
        .width = width,
        .height = height,
    });
    view.setBoundsOrigin(.{
        .x = 0,
        .y = 0,
    });
    view.setBoundsSize(.{
        .width = framebuffer_width,
        .height = framebuffer_height,
    });

    var layer = objc.quartz_core.MetalLayer.allocInit();
    layer.setDevice(device);
    layer.setDrawableSize(.{
        .width = framebuffer_width,
        .height = framebuffer_height,
    });

    view.setLayer(layer.as(objc.quartz_core.Layer));

    const command_queue = device.newCommandQueue().?;

    gui.platform_data = .{
        .view = view,
        .device = device,
        .layer = layer,
        .command_queue = command_queue,
    };

    zgui.backend.init(view, device);
    errdefer zgui.backend.deinit();
}

pub fn deinit(gui: *GUI) void {
    if (gui.platform_data) |data| {
        data.device.release();
        data.layer.release();
        data.command_queue.release();
    }
    gui.platform_data = null;
}

pub fn update(plugin: *Plugin) !void {
    // Pass events from the NSApp down to the NSWindow and ImGui
    const NSApp = objc.app_kit.Application.sharedApplication();
    while (NSApp.nextEventMatchingMask(
        objc.app_kit.EventMaskAny,
        objc.app_kit.Date.distantPast(),
        objc.app_kit.NSDefaultRunLoopMode,
        true,
    )) |event| {
        NSApp.sendEvent(event);
    }

    if (plugin.gui) |gui| {
        try draw(gui);
    }
}

pub fn draw(gui: *GUI) !void {
    if (gui.platform_data == null) {
        return error.PlatformNotInitialized;
    }

    const data = gui.platform_data.?;

    // Set up the metal render pass
    const descriptor = objc.metal.RenderPassDescriptor.renderPassDescriptor();
    const color_attachment = descriptor.colorAttachments().objectAtIndexedSubscript(0);
    const clear_color = objc.metal.ClearColor.init(0, 0, 0, 1);
    color_attachment.setClearColor(clear_color);
    const attachment_descriptor = color_attachment.as(objc.metal.RenderPassAttachmentDescriptor);
    const drawable_opt = data.layer.nextDrawable();
    if (drawable_opt == null) {
        return;
    }
    const drawable = drawable_opt.?;
    attachment_descriptor.setTexture(drawable.texture());
    attachment_descriptor.setLoadAction(objc.metal.LoadActionClear);
    attachment_descriptor.setStoreAction(objc.metal.StoreActionStore);

    const command_buffer = data.command_queue.commandBuffer().?;
    const command_encoder = command_buffer.renderCommandEncoderWithDescriptor(descriptor).?;

    const framebuffer_width = gui.width * @as(u32, @intFromFloat(gui.scale_factor));
    const framebuffer_height = gui.height * @as(u32, @intFromFloat(gui.scale_factor));
    zgui.backend.newFrame(framebuffer_width, framebuffer_height, data.view, descriptor);
    imgui.draw(gui);

    zgui.backend.draw(command_buffer, command_encoder);
    command_encoder.as(objc.metal.CommandEncoder).endEncoding();
    command_buffer.presentDrawable(drawable.as(objc.metal.Drawable));
    command_buffer.commit();
    command_buffer.waitUntilCompleted();
}
