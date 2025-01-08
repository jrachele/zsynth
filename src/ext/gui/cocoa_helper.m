#import <Foundation/Foundation.h>
#import <Cocoa/Cocoa.h>

void cocoaSetParent(void *_glfwWindow, void *_pluginView) {
	NSWindow *glfwWindow = (NSWindow *) _glfwWindow;
	NSView *pluginView = (NSView *) _pluginView;
	NSWindow* pluginWindow = pluginView.window;
	NSView *glfwView = glfwWindow.contentView;
	[pluginView addSubview:glfwView];
//     [pluginWindow addChildWindow:glfwWindow ordered:NSWindowBelow];
}

void cocoaHideDock() {
    NSApp.activationPolicy = NSApplicationActivationPolicyAccessory;
}