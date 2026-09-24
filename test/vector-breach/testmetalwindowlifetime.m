/*
 * Vector Breach fork Metal window lifetime regression.
 * Distributed under the same zlib license as SDL.
 *
 * Exercises CAMetalLayer ownership without acquiring a drawable. This does not
 * independently prove drawable or swapchain texture cleanup or measure speed.
 */
#define SDL_MAIN_HANDLED
#include <SDL3/SDL.h>
#include <SDL3/SDL_main.h>
#import <Cocoa/Cocoa.h>
#import <QuartzCore/CAMetalLayer.h>
#import <QuartzCore/CATransaction.h>
#include <stdio.h>
#include <string.h>

@interface LayerObservation : NSObject
@property(nonatomic, weak) CAMetalLayer *layer;
@property(nonatomic, weak) NSView *view;
@end
@implementation LayerObservation
@end

static void DrainCocoa(void)
{
    @autoreleasepool {
        SDL_Event event;
        while (SDL_PollEvent(&event)) {
        }
        [CATransaction flush];
        [[NSRunLoop mainRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
    }
}

static unsigned LiveLayers(NSArray<LayerObservation *> *observations)
{
    unsigned live = 0;
    @autoreleasepool {
        for (LayerObservation *observation in observations) {
            if (observation.layer != nil) {
                ++live;
            }
        }
    }
    return live;
}

static unsigned LiveViews(NSArray<LayerObservation *> *observations)
{
    unsigned live = 0;
    @autoreleasepool {
        for (LayerObservation *observation in observations) {
            if (observation.view != nil) {
                ++live;
            }
        }
    }
    return live;
}

int main(int argc, char **argv)
{
    const bool show = argc == 2 && strcmp(argv[1], "--show") == 0;
    if (argc > 2 || (argc == 2 && !show)) {
        fprintf(stderr, "usage: %s [--show]\n", argv[0]);
        return 2;
    }

    @autoreleasepool {
        SDL_SetMainReady();
        SDL_SetHint(SDL_HINT_VIDEO_DRIVER, "cocoa");
        if (!SDL_Init(SDL_INIT_VIDEO)) {
            fprintf(stderr, "SKIP: Cocoa unavailable: %s\n", SDL_GetError());
            return 77;
        }
        SDL_GPUDevice *device = SDL_CreateGPUDevice(SDL_GPU_SHADERFORMAT_MSL, false, "metal");
        if (!device) {
            fprintf(stderr, "SKIP: Metal GPU unavailable: %s\n", SDL_GetError());
            SDL_Quit();
            return 77;
        }

        NSMutableArray<LayerObservation *> *observations = [NSMutableArray array];
        bool setupFailed = false;
        for (unsigned cycle = 0; cycle < 8; ++cycle) {
            @autoreleasepool {
                SDL_WindowFlags flags = SDL_WINDOW_RESIZABLE;
                if (!show) {
                    flags |= SDL_WINDOW_HIDDEN;
                }
                SDL_Window *window = SDL_CreateWindow("SDL Metal lifetime probe", 96, 64, flags);
                if (!window) {
                    fprintf(stderr, "FAIL: window creation: %s\n", SDL_GetError());
                    setupFailed = true;
                    break;
                }
                if (!SDL_ClaimWindowForGPUDevice(device, window)) {
                    fprintf(stderr, "FAIL: GPU window claim: %s\n", SDL_GetError());
                    SDL_DestroyWindow(window);
                    setupFailed = true;
                    break;
                }

                SDL_PropertiesID properties = SDL_GetWindowProperties(window);
                NSWindow *nativeWindow = (__bridge NSWindow *)SDL_GetPointerProperty(
                    properties, SDL_PROP_WINDOW_COCOA_WINDOW_POINTER, NULL);
                NSInteger tag = (NSInteger)SDL_GetNumberProperty(
                    properties, SDL_PROP_WINDOW_COCOA_METAL_VIEW_TAG_NUMBER, 0);
                NSView *metalView = tag ? [nativeWindow.contentView viewWithTag:tag] : nil;
                CALayer *layer = metalView.layer;
                if (![layer isKindOfClass:[CAMetalLayer class]]) {
                    fprintf(stderr, "FAIL: cannot inspect the claimed GPU window's CAMetalLayer\n");
                    setupFailed = true;
                } else {
                    LayerObservation *observation = [[LayerObservation alloc] init];
                    observation.layer = (CAMetalLayer *)layer;
                    observation.view = metalView;
                    [observations addObject:observation];
                }

                SDL_ReleaseWindowFromGPUDevice(device, window);
                SDL_DestroyWindow(window);
                // The local strong nativeWindow, metalView and layer references
                // expire with this scope, before the weak references are tested.
            }
            DrainCocoa();
            if (setupFailed) {
                break;
            }
        }

        // Drain deferred Cocoa/CA cleanup, independently of the retained device.
        // This is a bounded cleanup allowance, not a performance assertion.
        for (unsigned attempt = 0; attempt < 200 && LiveLayers(observations) != 0; ++attempt) {
            DrainCocoa();
        }
        unsigned beforeDeviceDestroy = LiveLayers(observations);
        SDL_DestroyGPUDevice(device);
        for (unsigned attempt = 0; attempt < 200 && LiveLayers(observations) != 0; ++attempt) {
            DrainCocoa();
        }
        unsigned afterDeviceDestroy = LiveLayers(observations);
        unsigned liveViews = LiveViews(observations);
        printf("cycles=%lu retained_layers_before_device_destroy=%u retained_layers_after_device_destroy=%u retained_views=%u\n",
               (unsigned long)observations.count, beforeDeviceDestroy, afterDeviceDestroy, liveViews);
        SDL_Quit();

        if (setupFailed) {
            return 1;
        }
        if (liveViews != 0) {
            fprintf(stderr, "INCONCLUSIVE: Cocoa still retains a Metal view; its layer may be retained legitimately\n");
            return 77;
        }
        if (afterDeviceDestroy != 0 || beforeDeviceDestroy != 0) {
            fprintf(stderr, "FAIL: layers outlive released windows after their Metal views are gone; compare baseline and patched libraries\n");
            return 1;
        }
        puts("PASS: all eight claimed GPU window layers were released while the device remained alive");
        return 0;
    }
}
