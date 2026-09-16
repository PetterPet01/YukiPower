#import "YukiPower.h"
#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <CoreFoundation/CoreFoundation.h>
#import <objc/runtime.h>
#import <notify.h>
#import <signal.h>
#import <unistd.h>

#ifndef THEOS_PACKAGE_INSTALL_PREFIX
#define THEOS_PACKAGE_INSTALL_PREFIX "/var/jb"
#endif

#define YPLog(fmt, ...) NSLog(@"[YukiPower] " fmt, ##__VA_ARGS__)

// Private iOS 15 battery-saver API. Kept dynamic so the package has no hard link
// against CoreDuet private headers and fails harmlessly if the class is missing.
@interface NSObject (YukiPowerBatterySaver)
+ (id)batterySaver;
- (BOOL)setPowerMode:(NSInteger)mode error:(NSError **)error;
@end

static NSString * const YPStatePath = @"/var/mobile/Library/Preferences/com.yukipower.state.plist";
static NSString * const YPPowercuffDomain = @"com.rpetrich.powercuff";
static NSString * const YPPowerModeKey = @"PowerMode";
static NSString * const YPRequireLPMKey = @"RequireLowPowerMode";

static NSString *YPJoinRoot(NSString *absolutePath) {
    if (![absolutePath hasPrefix:@"/"]) {
        absolutePath = [@"/" stringByAppendingString:absolutePath];
    }
    return [@THEOS_PACKAGE_INSTALL_PREFIX stringByAppendingString:absolutePath];
}

static NSArray<NSString *> *YPUniquePaths(NSArray<NSString *> *paths) {
    NSMutableArray<NSString *> *out = [NSMutableArray array];
    for (NSString *path in paths) {
        if (path.length && ![out containsObject:path]) [out addObject:path];
    }
    return out;
}

static NSArray<NSString *> *YPChoicyPrefsCandidates(void) {
    // Choicy itself reads JBROOT_PATH("/var/mobile/Library/Preferences/com.opa334.choicyprefs.plist").
    // On Dopamine that is /var/jb/var/mobile/Library/Preferences/..., not the stock iOS prefs dir.
    return YPUniquePaths(@[
        YPJoinRoot(@"/var/mobile/Library/Preferences/com.opa334.choicyprefs.plist"),
        @"/var/jb/var/mobile/Library/Preferences/com.opa334.choicyprefs.plist",
        @"/var/mobile/Library/Preferences/com.opa334.choicyprefs.plist"
    ]);
}

static NSString *YPChoicyPrefsPath(BOOL preferExisting) {
    NSArray<NSString *> *candidates = YPChoicyPrefsCandidates();
    if (preferExisting) {
        for (NSString *path in candidates) {
            if ([NSFileManager.defaultManager fileExistsAtPath:path]) return path;
        }
    }
    return candidates.firstObject;
}

static NSArray<NSString *> *YPTweakDirectoryCandidates(void) {
    return YPUniquePaths(@[
        YPJoinRoot(@"/Library/MobileSubstrate/DynamicLibraries"),
        YPJoinRoot(@"/usr/lib/TweakInject"),
        @"/var/jb/Library/MobileSubstrate/DynamicLibraries",
        @"/var/jb/usr/lib/TweakInject",
        @"/Library/MobileSubstrate/DynamicLibraries",
        @"/usr/lib/TweakInject"
    ]);
}

static NSArray<NSString *> *YPKeepers(void) {
    // Dylib basenames, which is the representation Choicy uses.
    // "   Choicy" (three leading spaces) is the real injected name from Choicy's own sources.
    return @[
        @"Powercuff",
        @"CCSupport",
        @"   Choicy",
        @" Choicy",
        @"Choicy",
        @"ChoicySB",
        @"MobileSafety",
        @"PreferenceLoader",
        @"preferred",
        @"ElleKit",
        @"libellekit"
    ];
}

static BOOL YPIsKeeper(NSString *name) {
    return [YPKeepers() containsObject:name];
}

static NSMutableDictionary *YPMutablePlist(NSString *path) {
    NSDictionary *existing = [NSDictionary dictionaryWithContentsOfFile:path];
    return existing ? [existing mutableCopy] : [NSMutableDictionary dictionary];
}

static BOOL YPEnsureParentDirectory(NSString *path) {
    NSString *dir = path.stringByDeletingLastPathComponent;
    NSError *error = nil;
    BOOL ok = [NSFileManager.defaultManager createDirectoryAtPath:dir
                                      withIntermediateDirectories:YES
                                                       attributes:nil
                                                            error:&error];
    if (!ok) YPLog("failed to create %@ (%@)", dir, error);
    return ok;
}

static BOOL YPWritePlist(NSDictionary *plist, NSString *path) {
    if (!YPEnsureParentDirectory(path)) return NO;
    BOOL ok = [plist writeToFile:path atomically:YES];
    if (!ok) YPLog("writeToFile failed: %@", path);
    return ok;
}

static NSArray<NSString *> *YPInstalledTweakNames(void) {
    NSMutableArray<NSString *> *names = [NSMutableArray array];
    for (NSString *dir in YPTweakDirectoryCandidates()) {
        NSError *error = nil;
        NSArray<NSString *> *files = [NSFileManager.defaultManager contentsOfDirectoryAtPath:dir error:&error];
        if (!files) continue;
        YPLog("scanning tweaks in %@", dir);
        for (NSString *file in files) {
            if (![file hasSuffix:@".dylib"]) continue;
            NSString *base = file.stringByDeletingPathExtension;
            if (base.length && ![names containsObject:base]) [names addObject:base];
        }
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

static void YPSyncPowercuff(void) {
    Boolean ok = CFPreferencesSynchronize((__bridge CFStringRef)YPPowercuffDomain,
                                          kCFPreferencesCurrentUser,
                                          kCFPreferencesCurrentHost);
    YPLog("Powercuff synchronize=%d", (int)ok);
    // PreferenceLoader and Powercuff's SpringBoard hook listen for settingschanged.
    // thermalmonitord listens for thermals; LoadSettings posts that after a reload.
    notify_post("com.rpetrich.powercuff.settingschanged");
    notify_post("com.rpetrich.powercuff.thermals");
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
    return NSProcessInfo.processInfo.lowPowerModeEnabled ? 1 : 0;
}

static BOOL YPSetLowPowerMode(NSInteger mode) {
    id saver = YPBatterySaver();
    if (!saver || ![saver respondsToSelector:@selector(setPowerMode:error:)]) {
        YPLog("_CDBatterySaver unavailable");
        return NO;
    }
    NSError *error = nil;
    BOOL ok = [saver setPowerMode:mode error:&error];
    YPLog("setPowerMode:%ld -> %d (%@)", (long)mode, ok, error);
    return ok;
}

static NSDictionary *YPState(void) {
    return [NSDictionary dictionaryWithContentsOfFile:YPStatePath];
}

static BOOL YPUltraEnabled(void) {
    return [YPState()[@"Enabled"] boolValue];
}

static void YPRespring(void) {
    YPLog("respringing SpringBoard");
    kill(getpid(), SIGTERM);
}

static void YPNotifyChoicy(void) {
    CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
                                         CFSTR("com.opa334.choicyprefs/ReloadPrefs"),
                                         NULL, NULL, TRUE);
    notify_post("com.opa334.choicyprefs/ReloadPrefs");
}

static BOOL YPRestoreFromState(NSDictionary *state, BOOL markDisabled) {
    if (!state) return NO;

    NSString *choicyPath = state[@"ChoicyPrefsPath"] ?: YPChoicyPrefsPath(YES);
    NSMutableDictionary *choicy = YPMutablePlist(choicyPath);
    BOOL hadGlobalDenied = [state[@"HadGlobalDeniedTweaks"] boolValue];
    if (hadGlobalDenied) {
        NSArray *oldDenied = state[@"OldGlobalDeniedTweaks"];
        if (oldDenied) choicy[@"globalDeniedTweaks"] = oldDenied;
    } else {
        [choicy removeObjectForKey:@"globalDeniedTweaks"];
    }
    if (!YPWritePlist(choicy, choicyPath)) {
        YPLog("Choicy restore write failed at %@", choicyPath);
    } else {
        YPNotifyChoicy();
    }

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
    NSString *choicyPath = YPChoicyPrefsPath(YES);
    YPLog("enable using Choicy prefs %@", choicyPath);

    NSMutableDictionary *choicy = YPMutablePlist(choicyPath);
    id rawOldDenied = choicy[@"globalDeniedTweaks"];
    BOOL hadGlobalDenied = [rawOldDenied isKindOfClass:NSArray.class];
    NSArray *oldDenied = hadGlobalDenied ? rawOldDenied : @[];

    id oldPowerMode = YPCopyPowercuffPref(YPPowerModeKey);
    id oldRequireLPM = YPCopyPowercuffPref(YPRequireLPMKey);
    NSInteger oldLPM = YPLowPowerMode();

    NSMutableDictionary *state = [NSMutableDictionary dictionary];
    state[@"Enabled"] = @NO;
    state[@"BackupValid"] = @YES;
    state[@"ChoicyPrefsPath"] = choicyPath;
    state[@"HadGlobalDeniedTweaks"] = @(hadGlobalDenied);
    state[@"OldGlobalDeniedTweaks"] = oldDenied;
    state[@"HadPowerMode"] = @(oldPowerMode != nil);
    if (oldPowerMode) state[@"OldPowerMode"] = oldPowerMode;
    state[@"HadRequireLPM"] = @(oldRequireLPM != nil);
    if (oldRequireLPM) state[@"OldRequireLPM"] = oldRequireLPM;
    state[@"OldLowPowerMode"] = @(oldLPM);
    if (!YPWritePlist(state, YPStatePath)) {
        YPLog("failed to write backup state");
        return NO;
    }

    NSMutableArray<NSString *> *deny = [oldDenied mutableCopy];
    NSArray<NSString *> *installed = YPInstalledTweakNames();
    YPLog("installed tweak count=%lu", (unsigned long)installed.count);
    for (NSString *name in installed) {
        if (!YPIsKeeper(name) && ![deny containsObject:name]) [deny addObject:name];
    }
    for (NSString *keeper in YPKeepers()) [deny removeObject:keeper];
    choicy[@"globalDeniedTweaks"] = deny;
    if (!YPWritePlist(choicy, choicyPath)) {
        YPLog("Choicy write failed; continuing with Powercuff/LPM");
    } else {
        YPNotifyChoicy();
        YPLog("Choicy globalDeniedTweaks count=%lu", (unsigned long)deny.count);
    }

    // Powercuff: 4 == Heavy. RequireLowPowerMode false so Heavy stays active
    // independently of iOS LPM. Do not roll these back if LPM later fails —
    // that was wiping a successful write, so Settings never showed a change.
    YPSetPowercuffPref(YPPowerModeKey, @4);
    YPSetPowercuffPref(YPRequireLPMKey, @NO);
    YPSyncPowercuff();
    YPLog("Powercuff PowerMode=%@ RequireLowPowerMode=%@",
          YPCopyPowercuffPref(YPPowerModeKey),
          YPCopyPowercuffPref(YPRequireLPMKey));

    (void)YPSetLowPowerMode(1);

    state[@"Enabled"] = @YES;
    if (!YPWritePlist(state, YPStatePath)) {
        YPLog("failed to mark Enabled=YES after applying prefs");
        return NO;
    }
    return YES;
}

static BOOL YPDisableUltra(void) {
    NSDictionary *state = YPState();
    if (![state[@"BackupValid"] boolValue]) {
        YPLog("disable refused: no valid backup");
        return NO;
    }
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
    YPLog("setSelected:%d current:%d", selected, current);
    if (selected == current) return;

    BOOL success = selected ? YPEnableUltra() : YPDisableUltra();
    YPLog("setSelected:%d success=%d", selected, success);
    if ([self respondsToSelector:@selector(refreshState)]) {
        [self refreshState];
    }
    if (success) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.4 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            YPRespring();
        });
    }
}

@end
