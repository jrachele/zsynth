#import <Foundation/Foundation.h>
#import <Cocoa/Cocoa.h>
#import <Metal/Metal.h>
#import <QuartzCore/CAMetalLayer.h>
#import <QuartzCore/QuartzCore.h>

id<MTLDevice> createMetalDevice() {
    return MTLCreateSystemDefaultDevice();
}

void releaseMetalDevice(id<MTLDevice> device) {
    [device release];
}

CAMetalLayer* createMetalLayer(id<MTLDevice> metalDevice, NSView* view) {
    CAMetalLayer* metalLayer = [CAMetalLayer layer];
    metalLayer.device = metalDevice;
    metalLayer.pixelFormat = MTLPixelFormatBGRA8Unorm;
//     view.device = metalDevice;
    view.layer = metalLayer;
    view.wantsLayer = YES;
    return metalLayer;
}

void releaseMetalLayer(CAMetalLayer* metalLayer, NSView* view) {
    view.layer = nil;
    view.wantsLayer = NO;
    [metalLayer release];
}

MTLRenderPassDescriptor* createRenderPassDescriptor() {
    return [MTLRenderPassDescriptor renderPassDescriptor];
}

void releaseRenderPassDescriptor(MTLRenderPassDescriptor* renderPassDescriptor) {
    [renderPassDescriptor release];
}

id<MTLCommandQueue> createCommandQueue(id<MTLDevice> device) {
    // This could become the source of woes
//     MTLCommandQueueDescriptor* descriptor = [[MTLCommandQueueDescriptor alloc] init];
    return [device newCommandQueue];
}

void releaseCommandQueue(id<MTLCommandQueue> commandQueue) {
    [commandQueue release];
}

id<MTLCommandBuffer> createCommandBuffer(id<MTLCommandQueue> commandQueue) {
    return [commandQueue commandBuffer];
}

void releaseCommandBuffer(id<MTLCommandBuffer> commandBuffer) {
    [commandBuffer release];
}

id<MTLCommandEncoder> createCommandEncoder(id<MTLCommandBuffer> commandBuffer, MTLRenderPassDescriptor* descriptor) {
    return [commandBuffer renderCommandEncoder:descriptor];
}

void releaseCommandEncoder(id<MTLCommandEncoder> commandEncoder) {
    [commandEncoder release];
}

void presentBuffer(id<MTLCommandBuffer> commandBuffer, NSView* view) {
//     [commandBuffer presentDrawable:view.currentDrawable];
    [commandBuffer commit];
}

// void cocoaHideDock() {
//     NSApp.activationPolicy = NSApplicationActivationPolicyAccessory;
// }