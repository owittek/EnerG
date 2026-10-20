#import <Foundation/Foundation.h>
#import <dlfcn.h>
#import <objc/message.h>
#include "CPlatform.h"

static id client(void) {
    static id shared = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        if (!dlopen("/System/Library/PrivateFrameworks/PowerUI.framework/Versions/A/PowerUI", RTLD_NOW)) return;
        Class cls = NSClassFromString(@"PowerUISmartChargeClient");
        if (!cls) return;
        shared = ((id (*)(id, SEL, id))objc_msgSend)([cls alloc], sel_registerName("initWithClientName:"), @"app.energ.energd");
    });
    return shared;
}

int powerui_get_limit(uint8_t *out_limit, bool *out_enabled) {
    @autoreleasepool {
        id c = client();
        if (!c) return -1;
        NSError *error = nil;
        uint8_t limit = ((uint8_t (*)(id, SEL, NSError **))objc_msgSend)(c, sel_registerName("getMCLLimitWithError:"), &error);
        if (error) return -2;
        unsigned long long enabled = ((unsigned long long (*)(id, SEL, NSError **))objc_msgSend)(c, sel_registerName("isMCLCurrentlyEnabled:"), &error);
        if (error) return -2;
        *out_limit = limit;
        *out_enabled = enabled != 0;
        return 0;
    }
}

int powerui_set_limit(uint8_t limit) {
    @autoreleasepool {
        id c = client();
        if (!c) return -1;
        NSError *error = nil;
        BOOL ok = ((BOOL (*)(id, SEL, uint8_t, NSError **))objc_msgSend)(c, sel_registerName("setMCLLimit:error:"), limit, &error);
        return ok ? 0 : -2;
    }
}

int powerui_set_enabled(bool enabled) {
    @autoreleasepool {
        id c = client();
        if (!c) return -1;
        NSError *error = nil;
        SEL sel = sel_registerName(enabled ? "enableMCL:" : "disableMCL:");
        BOOL ok = ((BOOL (*)(id, SEL, NSError **))objc_msgSend)(c, sel, &error);
        return ok ? 0 : -2;
    }
}
