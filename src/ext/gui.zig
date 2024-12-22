const std = @import("std");
const clap = @import("clap-bindings");

pub fn create() clap.extensions.gui.Plugin {
    return .{
        .isApiSupported = _isApiSupported,
        .getPreferredApi = _getPreferredApi,
        .create = _create,
        .destroy = _destroy,
        .setScale = _setScale,
        .getSize = _getSize,
        .canResize = _canResize,
        .getResizeHints = _getResizeHints,
        .adjustSize = _adjustSize,
        .setSize = _setSize,
        .setParent = _setParent,
        .setTransient = _setTransient,
        .suggestTitle = _suggestTitle,
        .show = _show,
        .hide = _hide,
    };
}

fn _isApiSupported(_: *const clap.Plugin, api: [*:0]const u8, is_floating: bool) callconv(.C) bool {
    _ = api;
    _ = is_floating;
    return false;
}
/// returns true if the plugin has a preferred api. the host has no obligation to honor the plugin's preference,
/// this is just a hint. `api` should be explicitly assigned as a pinter to one of the `window_api.*` constants,
/// not copied.
fn _getPreferredApi(_: *const clap.Plugin, api: *[*:0]const u8, is_floating: bool) callconv(.C) bool {
    _ = api;
    _ = is_floating;
    return false;
}
/// create and allocate all resources needed for the gui.
/// if `is_floating` is true then the window will not be managed by the host. the plugin can set its window
/// to stay above the parent window (see `setTransient`). `api` may be null or blank for floating windows.
/// if `is_floating` is false then the plugin has to embed its window into the parent window (see `setParent`).
/// after this call the gui may not be visible yet, don't forget to call `show`.
/// returns true if the gui is successfully created.
fn _create(_: *const clap.Plugin, api: ?[*:0]const u8, is_floating: bool) callconv(.C) bool {
    _ = api;
    _ = is_floating;
    return false;
}
/// free all resources associated with the gui
fn _destroy(_: *const clap.Plugin) callconv(.C) void {}
/// set the absolute gui scaling factor, overriding any os info. should not be
/// used if the windowing api relies upon logical pixels. if the plugin prefers
/// to work out the saling factor itself by quering the os directly, then ignore
/// the call. scale of 2 means 200% scaling. returns true when scaling could be
/// applied. returns false when the call was ignored or scaling was not applied.
fn _setScale(_: *const clap.Plugin, scale: f64) callconv(.C) bool {
    _ = scale;
    return false;
}
/// get the current size of the plugin gui. `Plugin.create` must have been called prior to
/// asking for the size. returns true and populates `width.*` and `height.*` if the plugin
/// successfully got the size.
fn _getSize(_: *const clap.Plugin, width: *u32, height: *u32) callconv(.C) bool {
    _ = width;
    _ = height;
    return false;
}
/// returns true if the window is resizable (mouse drag)
fn _canResize(_: *const clap.Plugin) callconv(.C) bool {
    return false;
}
/// returns true and populates `hints.*` if the plugin can provide hints on how to resize the window.
fn _getResizeHints(_: *const clap.Plugin, hints: *clap.extensions.gui.ResizeHints) callconv(.C) bool {
    _ = hints;
    return false;
}
/// if the plugin gui is resizable, then the plugin will calculate the closest usable size which
/// fits the given size. this method does not resize the gui. returns true and adjusts `width.*`
/// and `height.*` if the plugin could adjust the given size.
fn _adjustSize(_: *const clap.Plugin, width: *u32, height: *u32) callconv(.C) bool {
    _ = width;
    _ = height;
    return false;
}
/// sets the plugin's window size. returns true if the
/// plugin successfully resized its window to the given size.
fn _setSize(_: *const clap.Plugin, width: u32, height: u32) callconv(.C) bool {
    _ = width;
    _ = height;
    return false;
}
/// embeds the plugin window into the given window. returns true on success.
fn _setParent(_: *const clap.Plugin, window: *const clap.extensions.gui.Window) callconv(.C) bool {
    _ = window;
    return false;
}
/// sets the plugin window to stay above the given window. returns true on success.
fn _setTransient(_: *const clap.Plugin, window: *const clap.extensions.gui.Window) callconv(.C) bool {
    _ = window;
    return false;
}
/// suggests a window title. only for floating windows.
fn _suggestTitle(_: *const clap.Plugin, title: [*:0]const u8) callconv(.C) bool {
    _ = title;
    return false;
}
/// show the plugin window. returns true on success.
fn _show(_: *const clap.Plugin) callconv(.C) bool {
    return false;
}
/// hide the plugin window. this method does not free the
/// resources, just hides the window content, yet it may be
/// a good idea to stop painting timers. returns true on success.
fn _hide(_: *const clap.Plugin) callconv(.C) bool {
    return false;
}
