// YukiPower - ultra low power Control Center module for Dopamine/rootless iOS 15
// Built for arm64 / iPhone 7 class devices.

typedef signed char BOOL;
typedef unsigned long NSUInteger;
typedef long NSInteger;
typedef double CGFloat;
typedef struct objc_class *Class;
typedef struct objc_selector *SEL;
#define YES ((BOOL)1)
#define NO ((BOOL)0)
#define nil ((id)0)

extern Class objc_getClass(const char *name);
extern SEL sel_registerName(const char *str);
extern int kill(int pid, int sig);
extern int getpid(void);
extern unsigned int notify_post(const char *name);

// CoreFoundation preferences APIs, declared minimally to avoid SDK dependency.
typedef const void *CFStringRef;
typedef const void *CFPropertyListRef;
typedef unsigned char Boolean;
extern const void *kCFPreferencesCurrentUser;
extern const void *kCFPreferencesCurrentHost;
extern CFPropertyListRef CFPreferencesCopyValue(CFStringRef key, CFStringRef applicationID, CFStringRef userName, CFStringRef hostName);
extern void CFPreferencesSetValue(CFStringRef key, CFPropertyListRef value, CFStringRef applicationID, CFStringRef userName, CFStringRef hostName);
extern Boolean CFPreferencesSynchronize(CFStringRef applicationID, CFStringRef userName, CFStringRef hostName);
extern void CFRelease(const void *cf);

__attribute__((objc_root_class))
@interface NSObject
+ (id)alloc;
- (id)init;
- (BOOL)respondsToSelector:(SEL)sel;
@end

@interface NSString : NSObject
- (BOOL)isEqualToString:(NSString *)other;
- (BOOL)hasSuffix:(NSString *)suffix;
- (NSString *)stringByDeletingPathExtension;
@end

@interface NSNumber : NSObject
+ (NSNumber *)numberWithBool:(BOOL)value;
+ (NSNumber *)numberWithInteger:(NSInteger)value;
- (BOOL)boolValue;
- (NSInteger)integerValue;
@end

@interface NSArray : NSObject
+ (NSArray *)array;
+ (NSArray *)arrayWithObjects:(const id [])objects count:(NSUInteger)cnt;
- (NSUInteger)count;
- (id)objectAtIndex:(NSUInteger)index;
- (BOOL)containsObject:(id)obj;
@end

@interface NSMutableArray : NSArray
+ (NSMutableArray *)array;
+ (NSMutableArray *)arrayWithArray:(NSArray *)array;
- (void)addObject:(id)obj;
- (void)removeObject:(id)obj;
@end

@interface NSDictionary : NSObject
+ (NSDictionary *)dictionary;
+ (NSDictionary *)dictionaryWithContentsOfFile:(NSString *)path;
- (id)objectForKey:(id)key;
- (BOOL)writeToFile:(NSString *)path atomically:(BOOL)flag;
@end

@interface NSMutableDictionary : NSDictionary
+ (NSMutableDictionary *)dictionary;
+ (NSMutableDictionary *)dictionaryWithDictionary:(NSDictionary *)dict;
- (void)setObject:(id)obj forKey:(id)key;
- (void)removeObjectForKey:(id)key;
@end

@interface NSFileManager : NSObject
+ (NSFileManager *)defaultManager;
- (BOOL)fileExistsAtPath:(NSString *)path;
- (NSArray *)contentsOfDirectoryAtPath:(NSString *)path error:(id *)error;
@end

@interface UIImage : NSObject
+ (UIImage *)systemImageNamed:(NSString *)name;
@end

@interface UIColor : NSObject
+ (UIColor *)systemYellowColor;
@end

// Minimal external superclass declaration provided by ControlCenterUIKit at runtime.
@interface CCUIToggleModule : NSObject
@end

// Private battery saver selectors used on iOS 15.
@interface NSObject (YukiPowerPrivatePower)
+ (id)batterySaver;
- (NSInteger)getPowerMode;
- (BOOL)setPowerMode:(NSInteger)mode error:(id *)error;
@end

static NSString * const kChoicyPrefsPath = @"/var/mobile/Library/Preferences/com.opa334.choicyprefs.plist";
static NSString * const kStatePath = @"/var/mobile/Library/Preferences/com.yukipower.state.plist";
static NSString * const kDynamicLibPath = @"/var/jb/Library/MobileSubstrate/DynamicLibraries";

static NSString * const kPowercuffDomain = @"com.rpetrich.powercuff";
static NSString * const kPowerModeKey = @"PowerMode";
static NSString * const kRequireLPMKey = @"RequireLowPowerMode";

static BOOL YPIsKeeper(NSString *name) {
    // Powercuff must keep throttling. Choicy must keep enforcing the deny list.
    // CCSupport must keep this Control Center module available so Ultra mode can be turned back off.
    return [name isEqualToString:@"Powercuff"] ||
           [name isEqualToString:@"CCSupport"] ||
           [name isEqualToString:@" Choicy"] ||
           [name isEqualToString:@"Choicy"] ||
           [name isEqualToString:@"ChoicySB"] ||
           [name isEqualToString:@"MobileSafety"] ||
           [name isEqualToString:@"PreferenceLoader"] ||
           [name isEqualToString:@"preferred"];
}

static NSMutableDictionary *YPMutablePlistAtPath(NSString *path) {
    NSDictionary *existing = [NSDictionary dictionaryWithContentsOfFile:path];
    if (existing) return [NSMutableDictionary dictionaryWithDictionary:existing];
    return [NSMutableDictionary dictionary];
}

static BOOL YPWritePlist(NSDictionary *dict, NSString *path) {
    return [dict writeToFile:path atomically:YES];
}

static NSArray *YPInstalledTweakNames(void) {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSArray *files = [fm contentsOfDirectoryAtPath:kDynamicLibPath error:nil];
    if (!files) return [NSArray array];
    NSMutableArray *names = [NSMutableArray array];
    NSUInteger count = [files count];
    for (NSUInteger i = 0; i < count; i++) {
        NSString *file = [files objectAtIndex:i];
        if (![file hasSuffix:@".dylib"]) continue;
        NSString *base = [file stringByDeletingPathExtension];
        if (base && ![names containsObject:base]) [names addObject:base];
    }
    return names;
}

static id YPCopyPowercuffPref(NSString *key) {
    CFPropertyListRef value = CFPreferencesCopyValue((CFStringRef)key,
                                                     (CFStringRef)kPowercuffDomain,
                                                     (CFStringRef)kCFPreferencesCurrentUser,
                                                     (CFStringRef)kCFPreferencesCurrentHost);
    if (!value) return nil;
    // Property-list scalar objects are toll-free bridged. Return without releasing here;
    // caller stores it in a container immediately, retaining it. Caller then releases.
    return (id)value;
}

static void YPSetPowercuffPref(NSString *key, id value) {
    CFPreferencesSetValue((CFStringRef)key,
                          (CFPropertyListRef)value,
                          (CFStringRef)kPowercuffDomain,
                          (CFStringRef)kCFPreferencesCurrentUser,
                          (CFStringRef)kCFPreferencesCurrentHost);
}

static void YPSyncPowercuff(void) {
    CFPreferencesSynchronize((CFStringRef)kPowercuffDomain,
                             (CFStringRef)kCFPreferencesCurrentUser,
                             (CFStringRef)kCFPreferencesCurrentHost);
    notify_post("com.rpetrich.powercuff.settingschanged");
}

static id YPBatterySaver(void) {
    Class cls = objc_getClass("_CDBatterySaver");
    if (!cls) return nil;
    id obj = [(id)cls batterySaver];
    return obj;
}

static NSInteger YPLowPowerMode(void) {
    id saver = YPBatterySaver();
    if (!saver || ![saver respondsToSelector:sel_registerName("getPowerMode")]) return -1;
    return [saver getPowerMode];
}

static BOOL YPSetLowPowerMode(NSInteger mode) {
    id saver = YPBatterySaver();
    if (!saver || ![saver respondsToSelector:sel_registerName("setPowerMode:error:")]) return NO;
    return [saver setPowerMode:mode error:nil];
}

static BOOL YPUltraEnabled(void) {
    NSDictionary *state = [NSDictionary dictionaryWithContentsOfFile:kStatePath];
    NSNumber *enabled = [state objectForKey:@"Enabled"];
    return enabled ? [enabled boolValue] : NO;
}

static void YPRespring(void) {
    // This module runs inside SpringBoard. Terminating only this process gives us a clean
    // reload where Choicy applies the new global deny-list. launchd restarts SpringBoard.
    kill(getpid(), 15); // SIGTERM
}

static BOOL YPEnableUltra(void) {
    NSFileManager *fm = [NSFileManager defaultManager];
    if (![fm fileExistsAtPath:kChoicyPrefsPath] || ![fm fileExistsAtPath:kDynamicLibPath]) return NO;

    NSMutableDictionary *choicy = YPMutablePlistAtPath(kChoicyPrefsPath);
    NSArray *oldDenied = [choicy objectForKey:@"globalDeniedTweaks"];
    if (!oldDenied) oldDenied = [NSArray array];

    NSMutableDictionary *state = [NSMutableDictionary dictionary];
    [state setObject:[NSNumber numberWithBool:YES] forKey:@"Enabled"];
    [state setObject:oldDenied forKey:@"OldGlobalDeniedTweaks"];

    id oldPowerMode = YPCopyPowercuffPref(kPowerModeKey);
    if (oldPowerMode) {
        [state setObject:oldPowerMode forKey:@"OldPowerMode"];
        [state setObject:[NSNumber numberWithBool:YES] forKey:@"HadPowerMode"];
        CFRelease((const void *)oldPowerMode);
    } else {
        [state setObject:[NSNumber numberWithBool:NO] forKey:@"HadPowerMode"];
    }

    id oldRequire = YPCopyPowercuffPref(kRequireLPMKey);
    if (oldRequire) {
        [state setObject:oldRequire forKey:@"OldRequireLPM"];
        [state setObject:[NSNumber numberWithBool:YES] forKey:@"HadRequireLPM"];
        CFRelease((const void *)oldRequire);
    } else {
        [state setObject:[NSNumber numberWithBool:NO] forKey:@"HadRequireLPM"];
    }

    NSInteger oldLPM = YPLowPowerMode();
    [state setObject:[NSNumber numberWithInteger:oldLPM] forKey:@"OldLowPowerMode"];

    if (!YPWritePlist(state, kStatePath)) return NO;

    NSMutableArray *deny = [NSMutableArray arrayWithArray:oldDenied];
    NSArray *installed = YPInstalledTweakNames();
    NSUInteger count = [installed count];
    for (NSUInteger i = 0; i < count; i++) {
        NSString *name = [installed objectAtIndex:i];
        if (!YPIsKeeper(name) && ![deny containsObject:name]) [deny addObject:name];
    }
    // A user's prior global deny-list may contain a keeper; Ultra mode must temporarily
    // allow these so it stays reversible. The exact old list is restored on exit.
    NSArray *keepers = @[@"Powercuff", @"CCSupport", @" Choicy", @"Choicy", @"ChoicySB", @"MobileSafety", @"PreferenceLoader", @"preferred"];
    for (NSUInteger i = 0; i < [keepers count]; i++) [deny removeObject:[keepers objectAtIndex:i]];

    [choicy setObject:deny forKey:@"globalDeniedTweaks"];
    if (!YPWritePlist(choicy, kChoicyPrefsPath)) return NO;

    YPSetPowercuffPref(kPowerModeKey, [NSNumber numberWithInteger:4]);
    YPSetPowercuffPref(kRequireLPMKey, [NSNumber numberWithBool:NO]);
    YPSyncPowercuff();
    YPSetLowPowerMode(1);
    return YES;
}

static BOOL YPDisableUltra(void) {
    NSDictionary *state = [NSDictionary dictionaryWithContentsOfFile:kStatePath];
    if (!state) return NO;

    NSMutableDictionary *choicy = YPMutablePlistAtPath(kChoicyPrefsPath);
    NSArray *oldDenied = [state objectForKey:@"OldGlobalDeniedTweaks"];
    if (oldDenied) [choicy setObject:oldDenied forKey:@"globalDeniedTweaks"];
    else [choicy removeObjectForKey:@"globalDeniedTweaks"];
    if (!YPWritePlist(choicy, kChoicyPrefsPath)) return NO;

    NSNumber *hadPower = [state objectForKey:@"HadPowerMode"];
    if (hadPower && [hadPower boolValue]) YPSetPowercuffPref(kPowerModeKey, [state objectForKey:@"OldPowerMode"]);
    else YPSetPowercuffPref(kPowerModeKey, nil);

    NSNumber *hadRequire = [state objectForKey:@"HadRequireLPM"];
    if (hadRequire && [hadRequire boolValue]) YPSetPowercuffPref(kRequireLPMKey, [state objectForKey:@"OldRequireLPM"]);
    else YPSetPowercuffPref(kRequireLPMKey, nil);
    YPSyncPowercuff();

    NSNumber *oldLPM = [state objectForKey:@"OldLowPowerMode"];
    if (oldLPM && [oldLPM integerValue] >= 0) YPSetLowPowerMode([oldLPM integerValue]);

    NSMutableDictionary *done = [NSMutableDictionary dictionaryWithDictionary:state];
    [done setObject:[NSNumber numberWithBool:NO] forKey:@"Enabled"];
    YPWritePlist(done, kStatePath);
    return YES;
}

@interface YukiPower : CCUIToggleModule
@end

@implementation YukiPower
- (UIImage *)iconGlyph {
    return [UIImage systemImageNamed:@"battery.25"];
}
- (UIImage *)selectedIconGlyph {
    return [UIImage systemImageNamed:@"battery.100.bolt"];
}
- (UIColor *)selectedColor {
    return [UIColor systemYellowColor];
}
- (BOOL)isSelected {
    return YPUltraEnabled();
}
- (void)setSelected:(BOOL)selected {
    BOOL current = YPUltraEnabled();
    if (selected == current) return;
    BOOL success = selected ? YPEnableUltra() : YPDisableUltra();
    if (success) YPRespring();
}
@end
