#import <Foundation/Foundation.h>
#import <Cocoa/Cocoa.h>
#import <AppKit/AppKit.h>

// Adapted from mach-objc's MACHWindowDelegate code
@interface ZSynthWindowDelegate : NSObject
@end

@implementation ZSynthWindowDelegate {
    void (^_windowDidResize_block)(void);
    bool (^_windowShouldClose_block)(void);
}

- (void)setBlock_windowDidResize:(void (^)(void))windowDidResize_block __attribute__((objc_direct)) {
    _windowDidResize_block = windowDidResize_block;
}

- (void)setBlock_windowShouldClose:(bool (^)(void))windowShouldClose_block __attribute__((objc_direct)) {
    _windowShouldClose_block = windowShouldClose_block;
}

- (void) windowDidResize:(NSNotification *) notification {
    if (self->_windowDidResize_block) self->_windowDidResize_block();
}

- (BOOL)windowShouldClose:(NSWindow *)sender {
    if (self->_windowShouldClose_block) return self->_windowShouldClose_block();
    return NO;
}
@end