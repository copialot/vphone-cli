// TweakLoader.m — Minimal tweak loader for vphone JB environment.
//
// systemhook.dylib loads this from /var/jb/usr/lib/TweakLoader.dylib.
// Scans tweak directories for .dylib + .plist pairs and loads matching
// tweaks into the current process.
//
// Search paths (in order):
//   1. /var/jb/Library/MobileSubstrate/DynamicLibraries/  (writable, preferred)
//   2. /Library/MobileSubstrate/DynamicLibraries/          (rootfs, read-only)

#import <Foundation/Foundation.h>
#import <dlfcn.h>

static NSString *const kLogPath = @"/var/mobile/Library/Logs/TweakLoader.log";

static void TLLog(NSString *fmt, ...) NS_FORMAT_FUNCTION(1,2) {
    va_list args;
    va_start(args, fmt);
    NSString *msg = [[NSString alloc] initWithFormat:fmt arguments:args];
    va_end(args);

    NSString *line = [NSString stringWithFormat:@"[%@] %@\n",
        [[NSProcessInfo processInfo] processName], msg];

    NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:kLogPath];
    if (fh) {
        [fh seekToEndOfFile];
        [fh writeData:[line dataUsingEncoding:NSUTF8StringEncoding]];
        [fh closeFile];
    } else {
        [line writeToFile:kLogPath atomically:NO encoding:NSUTF8StringEncoding error:nil];
    }
}

static NSArray<NSString *> *tweakSearchDirs(void) {
    return @[
        @"/var/jb/Library/MobileSubstrate/DynamicLibraries",
        @"/Library/MobileSubstrate/DynamicLibraries",
    ];
}

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
    NSString *bundlePath = [[NSBundle mainBundle] bundlePath];
    TLLog(@"init (bundle=%@)", bundlePath);

    for (NSString *tweakDir in tweakSearchDirs()) {
        NSArray *files = [fm contentsOfDirectoryAtPath:tweakDir error:nil];
        if (!files || files.count == 0) continue;

        TLLog(@"scanning %@ (%lu files)", tweakDir, (unsigned long)files.count);

        for (NSString *file in files) {
            if (![file.pathExtension isEqualToString:@"dylib"]) continue;

            NSString *dylibPath = [tweakDir stringByAppendingPathComponent:file];
            NSString *plistName = [[file stringByDeletingPathExtension] stringByAppendingPathExtension:@"plist"];
            NSString *plistPath = [tweakDir stringByAppendingPathComponent:plistName];

            if (![fm fileExistsAtPath:plistPath]) {
                TLLog(@"  skip %@ (no plist)", file);
                continue;
            }
            if (!shouldLoadTweak(plistPath)) {
                TLLog(@"  skip %@ (filter mismatch)", file);
                continue;
            }

            void *handle = dlopen(dylibPath.UTF8String, RTLD_NOW | RTLD_GLOBAL);
            if (handle) {
                TLLog(@"  loaded %@", file);
            } else {
                TLLog(@"  FAILED %@: %s", file, dlerror());
            }
        }
    }
}
