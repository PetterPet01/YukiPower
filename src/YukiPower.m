#import "YukiPower.h"
#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <CoreFoundation/CoreFoundation.h>
#import <objc/runtime.h>
#import <notify.h>
#import <signal.h>
#import <unistd.h>

// Private iOS 15 battery-saver API. Kept dynamic so the package has no hard link
// against CoreDuet private headers and fails harmlessly if the class is missing.
@interface NSObject (YukiPowerBatterySaver)
+ (id)batterySaver;
- (BOOL)setPowerMode:(NSInteger)mode error:(NSError **)error;
@end

static NSString * const YPChoicyPrefsPath = @"/var/mobile/Library/Preferences/com.opa334.choicyprefs.plist";
static NSString * const YPStatePath = @"/var/mobile/Library/Preferences/com.yukipower.state.plist";
static NSString * const YPDynamicLibrariesPath = @"/var/jb/Library/MobileSubstrate/DynamicLibraries";
static NSString * const YPPowercuffDomain = @"com.rpetrich.powercuff";
static NSString * const YPPowerModeKey = @"PowerMode";
static NSString * const YPRequireLPMKey = @"RequireLowPowerMode";

static NSArray<NSString *> *YPKeepers(void) {
    // These are dylib basenames, which is the representation Choicy uses.
    // Powercuff keeps throttling, Choicy keeps enforcing the list, and CCSupport
    // keeps this tile available after the respring so Ultra can be switched off.
    return @[
        @"Powercuff",
        @"CCSupport",
        @" Choicy",   // Choicy's injected dylib has historically used this basename
        @"Choicy",
        @"ChoicySB",
        @"MobileSafety",
        @"PreferenceLoader",
        @"preferred"
    ];
}

static BOOL YPIsKeeper(NSString *name) {
    return [YPKeepers() containsObject:name];
}

static NSMutableDictionary *YPMutablePlist(NSString *path) {
    NSDictionary *existing = [NSDictionary dictionaryWithContentsOfFile:path];
    return existing ? [existing mutableCopy] : [NSMutableDictionary dictionary];
}

static BOOL YPWritePlist(NSDictionary *plist, NSString *path) {
    return [plist writeToFile:path atomically:YES];
}

static NSArray<NSString *> *YPInstalledTweakNames(void) {
    NSError *error = nil;
    NSArray<NSString *> *files = [[NSFileManager defaultManager]
        contentsOfDirectoryAtPath:YPDynamicLibrariesPath error:&error];
    if (!files) return @[];

    NSMutableArray<NSString *> *names = [NSMutableArray array];
    for (NSString *file in files) {
        if (![file hasSuffix:@".dylib"]) continue;
        NSString *base = file.stringByDeletingPathExtension;
        if (base.length && ![names containsObject:base]) [names addObject:base];
    }
    return names;
}

static id YPCopyPowercuffPref(NSString *key) {
    CFPropertyListRef value = CFPreferencesCopyValue((__bridge CFStringRef)key,
                                                     (__bridge CFStringRef)YPPowercuffDomain,
                                                     kCFPreferencesCurrentUser,
                                                     kCFPreferencesCurrentHost);
    return value ? CFBridgingRelease(value) : nil;
}

static void YPSetPowercuffPref(NSString *key, id value) {
    CFPreferencesSetValue((__bridge CFStringRef)key,
                          value ? (__bridge CFPropertyListRef)value : NULL,
                          (__bridge CFStringRef)YPPowercuffDomain,
                          kCFPreferencesCurrentUser,
                          kCFPreferencesCurrentHost);
}

static BOOL YPSyncPowercuff(void) {
    Boolean ok = CFPreferencesSynchronize((__bridge CFStringRef)YPPowercuffDomain,
                                          kCFPreferencesCurrentUser,
                                          kCFPreferencesCurrentHost);
    notify_post("com.rpetrich.powercuff.settingschanged");
    return (BOOL)ok;
}

static id YPBatterySaver(void) {
    Class cls = objc_getClass("_CDBatterySaver");
    if (!cls || ![cls respondsToSelector:@selector(batterySaver)]) return nil;
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
    return [cls performSelector:@selector(batterySaver)];
#pragma clang diagnostic pop
}

static NSInteger YPLowPowerMode(void) {
    // Reading LPM state uses the public NSProcessInfo API; only the setter needs
    // the private iOS 15 battery-saver class.
    return NSProcessInfo.processInfo.lowPowerModeEnabled ? 1 : 0;
}

static BOOL YPSetLowPowerMode(NSInteger mode) {
    id saver = YPBatterySaver();
    if (!saver || ![saver respondsToSelector:@selector(setPowerMode:error:)]) return NO;
    NSError *error = nil;
    return [saver setPowerMode:mode error:&error];
}

static NSDictionary *YPState(void) {
    return [NSDictionary dictionaryWithContentsOfFile:YPStatePath];
}

static BOOL YPUltraEnabled(void) {
    return [YPState()[@"Enabled"] boolValue];
}

static void YPRespring(void) {
    // The module lives inside SpringBoard. SIGTERM lets launchd cleanly restart it,
    // which is what makes Choicy's new global deny-list take effect in SpringBoard.
    kill(getpid(), SIGTERM);
}

static BOOL YPRestoreFromState(NSDictionary *state, BOOL markDisabled) {
    if (!state) return NO;

    // Restore Choicy exactly, including whether the key existed at all.
    NSMutableDictionary *choicy = YPMutablePlist(YPChoicyPrefsPath);
    BOOL hadGlobalDenied = [state[@"HadGlobalDeniedTweaks"] boolValue];
    if (hadGlobalDenied) {
        NSArray *oldDenied = state[@"OldGlobalDeniedTweaks"];
        if (oldDenied) choicy[@"globalDeniedTweaks"] = oldDenied;
    } else {
        [choicy removeObjectForKey:@"globalDeniedTweaks"];
    }
    if (!YPWritePlist(choicy, YPChoicyPrefsPath)) return NO;

    if ([state[@"HadPowerMode"] boolValue]) {
        YPSetPowercuffPref(YPPowerModeKey, state[@"OldPowerMode"]);
    } else {
        YPSetPowercuffPref(YPPowerModeKey, nil);
    }

    if ([state[@"HadRequireLPM"] boolValue]) {
        YPSetPowercuffPref(YPRequireLPMKey, state[@"OldRequireLPM"]);
    } else {
        YPSetPowercuffPref(YPRequireLPMKey, nil);
    }
    YPSyncPowercuff();

    NSNumber *oldLPM = state[@"OldLowPowerMode"];
    if (oldLPM && oldLPM.integerValue >= 0) {
        (void)YPSetLowPowerMode(oldLPM.integerValue);
    }

    if (markDisabled) {
        NSMutableDictionary *done = [state mutableCopy];
        done[@"Enabled"] = @NO;
        done[@"BackupValid"] = @YES;
        (void)YPWritePlist(done, YPStatePath);
    }
    return YES;
}

static BOOL YPEnableUltra(void) {
    NSFileManager *fm = NSFileManager.defaultManager;
    if (![fm fileExistsAtPath:YPChoicyPrefsPath] ||
        ![fm fileExistsAtPath:YPDynamicLibrariesPath]) {
        return NO;
    }

    NSMutableDictionary *choicy = YPMutablePlist(YPChoicyPrefsPath);
    id rawOldDenied = choicy[@"globalDeniedTweaks"];
    BOOL hadGlobalDenied = [rawOldDenied isKindOfClass:NSArray.class];
    NSArray *oldDenied = hadGlobalDenied ? rawOldDenied : @[];

    id oldPowerMode = YPCopyPowercuffPref(YPPowerModeKey);
    id oldRequireLPM = YPCopyPowercuffPref(YPRequireLPMKey);
    NSInteger oldLPM = YPLowPowerMode();

    // Write the backup first, but do not mark Ultra enabled until every critical
    // change succeeds. This gives us a rollback point if anything fails midway.
    NSMutableDictionary *state = [NSMutableDictionary dictionary];
    state[@"Enabled"] = @NO;
    state[@"BackupValid"] = @YES;
    state[@"HadGlobalDeniedTweaks"] = @(hadGlobalDenied);
    state[@"OldGlobalDeniedTweaks"] = oldDenied;
    state[@"HadPowerMode"] = @(oldPowerMode != nil);
    if (oldPowerMode) state[@"OldPowerMode"] = oldPowerMode;
    state[@"HadRequireLPM"] = @(oldRequireLPM != nil);
    if (oldRequireLPM) state[@"OldRequireLPM"] = oldRequireLPM;
    state[@"OldLowPowerMode"] = @(oldLPM);
    if (!YPWritePlist(state, YPStatePath)) return NO;

    // Merge the user's existing global deny-list with every currently installed
    // tweak dylib, then remove the small keeper set needed for this mode itself.
    NSMutableArray<NSString *> *deny = [oldDenied mutableCopy];
    for (NSString *name in YPInstalledTweakNames()) {
        if (!YPIsKeeper(name) && ![deny containsObject:name]) [deny addObject:name];
    }
    for (NSString *keeper in YPKeepers()) [deny removeObject:keeper];

    choicy[@"globalDeniedTweaks"] = deny;
    if (!YPWritePlist(choicy, YPChoicyPrefsPath)) return NO;

    // Powercuff: 4 == Heavy. RequireLowPowerMode is set false so Heavy remains
    // active even if iOS briefly changes LPM state; iOS LPM is still enabled too.
    YPSetPowercuffPref(YPPowerModeKey, @4);
    YPSetPowercuffPref(YPRequireLPMKey, @NO);
    if (!YPSyncPowercuff()) {
        (void)YPRestoreFromState(state, NO);
        return NO;
    }

    if (oldLPM >= 0 && !YPSetLowPowerMode(1)) {
        (void)YPRestoreFromState(state, NO);
        return NO;
    }

    state[@"Enabled"] = @YES;
    return YPWritePlist(state, YPStatePath);
}

static BOOL YPDisableUltra(void) {
    NSDictionary *state = YPState();
    if (![state[@"BackupValid"] boolValue]) return NO;
    return YPRestoreFromState(state, YES);
}

@implementation YukiPower

- (UIImage *)iconGlyph {
    if (@available(iOS 13.0, *)) return [UIImage systemImageNamed:@"battery.25"];
    return nil;
}

- (UIImage *)selectedIconGlyph {
    if (@available(iOS 13.0, *)) return [UIImage systemImageNamed:@"battery.100.bolt"];
    return nil;
}

- (UIColor *)selectedColor {
    return UIColor.systemYellowColor;
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
