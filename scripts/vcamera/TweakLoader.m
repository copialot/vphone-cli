// TweakLoader.m — Minimal tweak loader for vphone JB environment.
//
// systemhook.dylib loads this from /var/jb/usr/lib/TweakLoader.dylib.
// Scans /Library/MobileSubstrate/DynamicLibraries/ for .dylib + .plist
// pairs and loads matching tweaks into the current process.

#import <Foundation/Foundation.h>
#import <dlfcn.h>

#define TWEAKLOADER_LOG(fmt, ...) NSLog(@"[TweakLoader] " fmt, ##__VA_ARGS__)

static NSString *const kTweakDir = @"/Library/MobileSubstrate/DynamicLibraries";

static BOOL shouldLoadTweak(NSString *plistPath) {
    NSDictionary *plist = [NSDictionary dictionaryWithContentsOfFile:plistPath];
    if (!plist) return NO;

    NSDictionary *filter = plist[@"Filter"];
    if (!filter) return YES;

    // Check Bundles filter
    NSArray *bundles = filter[@"Bundles"];
    if (bundles) {
        for (NSString *bundleID in bundles) {
            if ([NSBundle bundleWithIdentifier:bundleID]) {
                return YES;
            }
        }
        return NO;
    }

    // Check Executables filter
    NSArray *executables = filter[@"Executables"];
    if (executables) {
        NSString *procName = [[NSProcessInfo processInfo] processName];
        for (NSString *name in executables) {
            if ([procName isEqualToString:name]) {
                return YES;
            }
        }
        return NO;
    }

    return YES;
}

__attribute__((constructor))
static void TweakLoaderInit(void) {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSArray *files = [fm contentsOfDirectoryAtPath:kTweakDir error:nil];
    if (!files || files.count == 0) return;

    for (NSString *file in files) {
        if (![file.pathExtension isEqualToString:@"dylib"]) continue;

        NSString *dylibPath = [kTweakDir stringByAppendingPathComponent:file];
        NSString *plistName = [[file stringByDeletingPathExtension] stringByAppendingPathExtension:@"plist"];
        NSString *plistPath = [kTweakDir stringByAppendingPathComponent:plistName];

        if (![fm fileExistsAtPath:plistPath]) continue;
        if (!shouldLoadTweak(plistPath)) continue;

        void *handle = dlopen(dylibPath.UTF8String, RTLD_NOW | RTLD_GLOBAL);
        if (handle) {
            TWEAKLOADER_LOG("loaded %@", file);
        } else {
            TWEAKLOADER_LOG("failed to load %@: %s", file, dlerror());
        }
    }
}
