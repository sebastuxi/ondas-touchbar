#import "TouchBarPrivate.h"
#import <dlfcn.h>

// Métodos que existen en AppKit pero no están en los headers públicos.
@interface NSTouchBarItem (OndasPrivate)
+ (void)addSystemTrayItem:(NSTouchBarItem *)item;
+ (void)removeSystemTrayItem:(NSTouchBarItem *)item;
@end

@interface NSTouchBar (OndasPrivate)
+ (void)presentSystemModalTouchBar:(NSTouchBar *)touchBar systemTrayItemIdentifier:(nullable NSTouchBarItemIdentifier)identifier;
+ (void)presentSystemModalFunctionBar:(NSTouchBar *)touchBar systemTrayItemIdentifier:(nullable NSTouchBarItemIdentifier)identifier;
+ (void)presentSystemModalTouchBar:(NSTouchBar *)touchBar placement:(long long)placement systemTrayItemIdentifier:(nullable NSTouchBarItemIdentifier)identifier;
+ (void)presentSystemModalFunctionBar:(NSTouchBar *)touchBar placement:(long long)placement systemTrayItemIdentifier:(nullable NSTouchBarItemIdentifier)identifier;
+ (void)minimizeSystemModalTouchBar:(NSTouchBar *)touchBar;
+ (void)minimizeSystemModalFunctionBar:(NSTouchBar *)touchBar;
+ (void)dismissSystemModalTouchBar:(NSTouchBar *)touchBar;
+ (void)dismissSystemModalFunctionBar:(NSTouchBar *)touchBar;
@end

// Las funciones DFR* viven en un framework privado: se cargan en tiempo de ejecución.
static void *OBDFRFoundation(void) {
    static void *handle = NULL;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        handle = dlopen("/System/Library/PrivateFrameworks/DFRFoundation.framework/DFRFoundation", RTLD_LAZY);
    });
    return handle;
}

BOOL OBSystemModalAvailable(void) {
    return [NSTouchBar respondsToSelector:@selector(presentSystemModalTouchBar:placement:systemTrayItemIdentifier:)] ||
           [NSTouchBar respondsToSelector:@selector(presentSystemModalFunctionBar:placement:systemTrayItemIdentifier:)];
}

void OBPresentSystemModal(NSTouchBar *touchBar, long long placement, NSTouchBarItemIdentifier identifier) {
    // placement < 0: variante sin "placement" (la que usa MTMR para conservar la Control Strip).
    if (placement < 0 && [NSTouchBar respondsToSelector:@selector(presentSystemModalTouchBar:systemTrayItemIdentifier:)]) {
        [NSTouchBar presentSystemModalTouchBar:touchBar systemTrayItemIdentifier:identifier];
    } else if (placement < 0 && [NSTouchBar respondsToSelector:@selector(presentSystemModalFunctionBar:systemTrayItemIdentifier:)]) {
        [NSTouchBar presentSystemModalFunctionBar:touchBar systemTrayItemIdentifier:identifier];
    } else if ([NSTouchBar respondsToSelector:@selector(presentSystemModalTouchBar:placement:systemTrayItemIdentifier:)]) {
        [NSTouchBar presentSystemModalTouchBar:touchBar placement:MAX(placement, 0) systemTrayItemIdentifier:identifier];
    } else if ([NSTouchBar respondsToSelector:@selector(presentSystemModalFunctionBar:placement:systemTrayItemIdentifier:)]) {
        [NSTouchBar presentSystemModalFunctionBar:touchBar placement:MAX(placement, 0) systemTrayItemIdentifier:identifier];
    }
}

void OBMinimizeSystemModal(NSTouchBar *touchBar) {
    if ([NSTouchBar respondsToSelector:@selector(minimizeSystemModalTouchBar:)]) {
        [NSTouchBar minimizeSystemModalTouchBar:touchBar];
    } else if ([NSTouchBar respondsToSelector:@selector(minimizeSystemModalFunctionBar:)]) {
        [NSTouchBar minimizeSystemModalFunctionBar:touchBar];
    }
}

void OBDismissSystemModal(NSTouchBar *touchBar) {
    if ([NSTouchBar respondsToSelector:@selector(dismissSystemModalTouchBar:)]) {
        [NSTouchBar dismissSystemModalTouchBar:touchBar];
    } else if ([NSTouchBar respondsToSelector:@selector(dismissSystemModalFunctionBar:)]) {
        [NSTouchBar dismissSystemModalFunctionBar:touchBar];
    }
}

void OBAddSystemTrayItem(NSTouchBarItem *item) {
    if ([NSTouchBarItem respondsToSelector:@selector(addSystemTrayItem:)]) {
        [NSTouchBarItem addSystemTrayItem:item];
    }
}

void OBRemoveSystemTrayItem(NSTouchBarItem *item) {
    if ([NSTouchBarItem respondsToSelector:@selector(removeSystemTrayItem:)]) {
        [NSTouchBarItem removeSystemTrayItem:item];
    }
}

void OBSetControlStripPresence(NSTouchBarItemIdentifier identifier, BOOL present) {
    void *handle = OBDFRFoundation();
    if (!handle) return;
    void (*fn)(NSTouchBarItemIdentifier, BOOL) = dlsym(handle, "DFRElementSetControlStripPresenceForIdentifier");
    if (fn) fn(identifier, present);
}

// MARK: - Luz del teclado (CoreBrightness)

@protocol OBKeyboardBrightnessClient <NSObject>
- (NSArray *)copyKeyboardBacklightIDs;
- (float)brightnessForKeyboard:(unsigned long long)keyboardID;
- (BOOL)setBrightness:(float)brightness forKeyboard:(unsigned long long)keyboardID;
- (BOOL)setBrightness:(float)brightness fadeSpeed:(int)speed commit:(bool)commit forKeyboard:(unsigned long long)keyboardID;
- (BOOL)isAutoBrightnessEnabledForKeyboard:(unsigned long long)keyboardID;
- (BOOL)enableAutoBrightness:(BOOL)enable forKeyboard:(unsigned long long)keyboardID;
- (BOOL)suspendIdleDimming:(BOOL)suspend forKeyboard:(unsigned long long)keyboardID;
@end

static id<OBKeyboardBrightnessClient> OBKeyboardClient(void) {
    static id<OBKeyboardBrightnessClient> client = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        if (dlopen("/System/Library/PrivateFrameworks/CoreBrightness.framework/CoreBrightness", RTLD_LAZY)) {
            Class cls = NSClassFromString(@"KeyboardBrightnessClient");
            if (cls) client = (id<OBKeyboardBrightnessClient>)[[cls alloc] init];
        }
    });
    return client;
}

static unsigned long long OBKeyboardID(void) {
    static unsigned long long keyboard = 1;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        id<OBKeyboardBrightnessClient> client = OBKeyboardClient();
        if ([client respondsToSelector:@selector(copyKeyboardBacklightIDs)]) {
            NSArray *ids = [client copyKeyboardBacklightIDs];
            id first = ids.firstObject;
            if ([first isKindOfClass:[NSNumber class]]) keyboard = [first unsignedLongLongValue];
        }
    });
    return keyboard;
}

BOOL OBKeyboardLightAvailable(void) {
    id<OBKeyboardBrightnessClient> client = OBKeyboardClient();
    return [client respondsToSelector:@selector(brightnessForKeyboard:)] &&
           ([client respondsToSelector:@selector(setBrightness:fadeSpeed:commit:forKeyboard:)] ||
            [client respondsToSelector:@selector(setBrightness:forKeyboard:)]);
}

float OBKeyboardLightGet(void) {
    id<OBKeyboardBrightnessClient> client = OBKeyboardClient();
    if (![client respondsToSelector:@selector(brightnessForKeyboard:)]) return 0;
    return [client brightnessForKeyboard:OBKeyboardID()];
}

void OBKeyboardLightSet(float level, BOOL commit) {
    id<OBKeyboardBrightnessClient> client = OBKeyboardClient();
    if ([client respondsToSelector:@selector(setBrightness:fadeSpeed:commit:forKeyboard:)]) {
        [client setBrightness:level fadeSpeed:0 commit:(commit ? true : false) forKeyboard:OBKeyboardID()];
    } else if ([client respondsToSelector:@selector(setBrightness:forKeyboard:)]) {
        [client setBrightness:level forKeyboard:OBKeyboardID()];
    }
}

BOOL OBKeyboardAutoBrightnessEnabled(void) {
    id<OBKeyboardBrightnessClient> client = OBKeyboardClient();
    if (![client respondsToSelector:@selector(isAutoBrightnessEnabledForKeyboard:)]) return NO;
    return [client isAutoBrightnessEnabledForKeyboard:OBKeyboardID()];
}

void OBKeyboardSetAutoBrightness(BOOL enabled) {
    id<OBKeyboardBrightnessClient> client = OBKeyboardClient();
    if ([client respondsToSelector:@selector(enableAutoBrightness:forKeyboard:)]) {
        [client enableAutoBrightness:enabled forKeyboard:OBKeyboardID()];
    }
}

void OBKeyboardSuspendIdleDimming(BOOL suspend) {
    id<OBKeyboardBrightnessClient> client = OBKeyboardClient();
    if ([client respondsToSelector:@selector(suspendIdleDimming:forKeyboard:)]) {
        [client suspendIdleDimming:suspend forKeyboard:OBKeyboardID()];
    }
}

// MARK: - X del sistema

void OBSetShowsCloseBoxWhenFrontMost(BOOL shows) {
    void *handle = OBDFRFoundation();
    if (!handle) return;
    void (*fn)(BOOL) = dlsym(handle, "DFRSystemModalShowsCloseBoxWhenFrontMost");
    if (fn) fn(shows);
}
