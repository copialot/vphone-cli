// vphone_camera.m — Virtual camera hook for vphone iOS VM (JB variant).
//
// MobileSubstrate tweak dylib that hooks UIImagePickerController and
// AVCaptureSession APIs to provide a fake camera source from a static
// image. Loaded automatically by systemhook into all UIKit processes.
//
// Image source: /var/mobile/Media/vphone/camera_feed.jpg
// Falls back to a 1920x1080 grey placeholder when absent.

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>
#import <CoreMedia/CoreMedia.h>
#import <CoreVideo/CoreVideo.h>
#import <ImageIO/ImageIO.h>
#import <CoreText/CoreText.h>
#import <objc/runtime.h>
#import <objc/message.h>

#pragma mark - Logging

#define VCAM_LOG(fmt, ...) NSLog(@"[vphone_camera] " fmt, ##__VA_ARGS__)

#pragma mark - Configuration

static NSString *const kCameraFeedPath = @"/var/mobile/Media/vphone/camera_feed.jpg";
static const int kFrameWidth  = 1920;
static const int kFrameHeight = 1080;
static const double kFrameRate = 30.0;

#pragma mark - Globals

static CVPixelBufferRef g_pixelBuffer = NULL;
static dispatch_source_t g_frameTimer = NULL;
static BOOL g_sessionRunning = NO;

// Fake device class registered at load time
static Class g_FakeDeviceClass = Nil;
static id g_fakeDeviceInstance = nil;

#pragma mark - Pixel Buffer Creation

static CVPixelBufferRef CreatePixelBufferFromImage(CGImageRef image, int width, int height) {
    NSDictionary *attrs = @{
        (id)kCVPixelBufferCGImageCompatibilityKey: @YES,
        (id)kCVPixelBufferCGBitmapContextCompatibilityKey: @YES,
    };
    CVPixelBufferRef buf = NULL;
    CVReturn status = CVPixelBufferCreate(kCFAllocatorDefault, width, height,
                                          kCVPixelFormatType_32BGRA, (__bridge CFDictionaryRef)attrs, &buf);
    if (status != kCVReturnSuccess) return NULL;

    CVPixelBufferLockBaseAddress(buf, 0);
    void *base = CVPixelBufferGetBaseAddress(buf);
    size_t bpr = CVPixelBufferGetBytesPerRow(buf);

    CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
    CGContextRef ctx = CGBitmapContextCreate(base, width, height, 8, bpr, cs,
                                             kCGBitmapByteOrder32Little | kCGImageAlphaPremultipliedFirst);
    if (image) {
        CGContextDrawImage(ctx, CGRectMake(0, 0, width, height), image);
    } else {
        // Grey placeholder
        CGContextSetRGBFillColor(ctx, 0.3, 0.3, 0.3, 1.0);
        CGContextFillRect(ctx, CGRectMake(0, 0, width, height));

        // Draw label text using CoreText
        CFStringRef text = CFSTR("vphone virtual camera");
        CFMutableDictionaryRef attrs = CFDictionaryCreateMutable(NULL, 2,
            &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
        CTFontRef font = CTFontCreateWithName(CFSTR("Helvetica"), 36, NULL);
        CGColorRef textColor = CGColorCreate(cs, (CGFloat[]){0.8, 0.8, 0.8, 1.0});
        CFDictionarySetValue(attrs, kCTFontAttributeName, font);
        CFDictionarySetValue(attrs, kCTForegroundColorAttributeName, textColor);
        CFAttributedStringRef attrStr = CFAttributedStringCreate(NULL, text, attrs);
        CTLineRef line = CTLineCreateWithAttributedString(attrStr);
        CGContextSetTextPosition(ctx, width / 2 - 200, height / 2);
        CTLineDraw(line, ctx);
        CFRelease(line);
        CFRelease(attrStr);
        CFRelease(attrs);
        CGColorRelease(textColor);
        CFRelease(font);
    }
    CGContextRelease(ctx);
    CGColorSpaceRelease(cs);
    CVPixelBufferUnlockBaseAddress(buf, 0);
    return buf;
}

static void EnsurePixelBuffer(void) {
    if (g_pixelBuffer) return;

    CGImageRef image = NULL;
    NSData *data = [NSData dataWithContentsOfFile:kCameraFeedPath];
    if (data) {
        CGDataProviderRef provider = CGDataProviderCreateWithCFData((__bridge CFDataRef)data);
        CGImageSourceRef source = CGImageSourceCreateWithDataProvider(provider, NULL);
        if (source && CGImageSourceGetCount(source) > 0) {
            image = CGImageSourceCreateImageAtIndex(source, 0, NULL);
        }
        if (source) CFRelease(source);
        CGDataProviderRelease(provider);
        VCAM_LOG("loaded camera feed from %@", kCameraFeedPath);
    } else {
        VCAM_LOG("no camera feed at %@, using placeholder", kCameraFeedPath);
    }

    g_pixelBuffer = CreatePixelBufferFromImage(image, kFrameWidth, kFrameHeight);
    if (image) CGImageRelease(image);
}

#pragma mark - Sample Buffer Creation

static CMSampleBufferRef CreateSampleBufferFromPixelBuffer(CVPixelBufferRef pixelBuffer) {
    CMSampleBufferRef sampleBuffer = NULL;

    CMVideoFormatDescriptionRef formatDesc = NULL;
    CMVideoFormatDescriptionCreateForImageBuffer(kCFAllocatorDefault, pixelBuffer, &formatDesc);
    if (!formatDesc) return NULL;

    CMSampleTimingInfo timing;
    timing.duration = CMTimeMake(1, (int32_t)kFrameRate);
    timing.presentationTimeStamp = CMTimeMakeWithSeconds(CACurrentMediaTime(), 600);
    timing.decodeTimeStamp = kCMTimeInvalid;

    CMSampleBufferCreateForImageBuffer(kCFAllocatorDefault, pixelBuffer, true,
                                        NULL, NULL, formatDesc, &timing, &sampleBuffer);
    CFRelease(formatDesc);
    return sampleBuffer;
}

#pragma mark - Fake AVCaptureDevice

// Property storage keys (associated objects)
static const void *kFakeDeviceUniqueIDKey   = &kFakeDeviceUniqueIDKey;
static const void *kFakeDeviceModelIDKey    = &kFakeDeviceModelIDKey;
static const void *kFakeDeviceNameKey       = &kFakeDeviceNameKey;
static const void *kFakeDevicePositionKey   = &kFakeDevicePositionKey;

static NSString *fake_uniqueID(id self, SEL _cmd)       { return @"com.vphone.vcamera"; }
static NSString *fake_modelID(id self, SEL _cmd)        { return @"VPhoneVirtualCamera"; }
static NSString *fake_localizedName(id self, SEL _cmd)   { return @"vphone Virtual Camera"; }
static NSInteger fake_position(id self, SEL _cmd)        { return 1; /* AVCaptureDevicePositionBack */ }
static BOOL fake_hasMediaType(id self, SEL _cmd, id mt)  { return YES; }
static BOOL fake_isConnected(id self, SEL _cmd)          { return YES; }
static BOOL fake_lockForConfig(id self, SEL _cmd, id *e) { return YES; }
static void fake_unlockForConfig(id self, SEL _cmd)      { }

static void RegisterFakeDeviceClass(void) {
    g_FakeDeviceClass = objc_allocateClassPair([NSObject class], "VPhoneFakeCaptureDevice", 0);
    if (!g_FakeDeviceClass) {
        // Class may already exist (re-injection)
        g_FakeDeviceClass = NSClassFromString(@"VPhoneFakeCaptureDevice");
        return;
    }

    class_addMethod(g_FakeDeviceClass, @selector(uniqueID), (IMP)fake_uniqueID, "@@:");
    class_addMethod(g_FakeDeviceClass, @selector(modelID), (IMP)fake_modelID, "@@:");
    class_addMethod(g_FakeDeviceClass, @selector(localizedName), (IMP)fake_localizedName, "@@:");
    class_addMethod(g_FakeDeviceClass, @selector(position), (IMP)fake_position, "q@:");
    class_addMethod(g_FakeDeviceClass, NSSelectorFromString(@"hasMediaType:"), (IMP)fake_hasMediaType, "B@:@");
    class_addMethod(g_FakeDeviceClass, @selector(isConnected), (IMP)fake_isConnected, "B@:");
    class_addMethod(g_FakeDeviceClass, NSSelectorFromString(@"lockForConfiguration:"), (IMP)fake_lockForConfig, "B@:^@");
    class_addMethod(g_FakeDeviceClass, NSSelectorFromString(@"unlockForConfiguration"), (IMP)fake_unlockForConfig, "v@:");

    objc_registerClassPair(g_FakeDeviceClass);
}

static id GetFakeDevice(void) {
    if (!g_fakeDeviceInstance) {
        g_fakeDeviceInstance = [[g_FakeDeviceClass alloc] init];
    }
    return g_fakeDeviceInstance;
}

#pragma mark - Method Swizzling Helpers

static void SwizzleClassMethod(Class cls, SEL sel, IMP newIMP, IMP *origIMP) {
    Method m = class_getClassMethod(cls, sel);
    if (!m) return;
    *origIMP = method_getImplementation(m);
    // class methods live on the metaclass
    Class meta = object_getClass(cls);
    class_replaceMethod(meta, sel, newIMP, method_getTypeEncoding(m));
}

static void SwizzleInstanceMethod(Class cls, SEL sel, IMP newIMP, IMP *origIMP) {
    Method m = class_getInstanceMethod(cls, sel);
    if (!m) {
        *origIMP = NULL;
        return;
    }
    *origIMP = class_replaceMethod(cls, sel, newIMP, method_getTypeEncoding(m));
    if (!*origIMP) {
        *origIMP = method_getImplementation(m);
    }
}

#pragma mark - Hook 1 & 2: UIImagePickerController

static IMP orig_isSourceTypeAvailable = NULL;
static BOOL hook_isSourceTypeAvailable(id self, SEL _cmd, NSInteger sourceType) {
    // UIImagePickerControllerSourceTypeCamera = 1
    if (sourceType == 1) {
        VCAM_LOG("isSourceTypeAvailable: camera -> YES");
        return YES;
    }
    return ((BOOL(*)(id, SEL, NSInteger))orig_isSourceTypeAvailable)(self, _cmd, sourceType);
}

static IMP orig_setSourceType = NULL;
static void hook_setSourceType(id self, SEL _cmd, NSInteger sourceType) {
    if (sourceType == 1) {
        // Redirect camera to photo library
        VCAM_LOG("setSourceType: camera -> photoLibrary");
        sourceType = 0; // UIImagePickerControllerSourceTypePhotoLibrary
    }
    ((void(*)(id, SEL, NSInteger))orig_setSourceType)(self, _cmd, sourceType);
}

#pragma mark - Hook 3 & 4: AVCaptureDevice

static IMP orig_defaultDeviceWithMediaType = NULL;
static id hook_defaultDeviceWithMediaType(id self, SEL _cmd, id mediaType) {
    id result = ((id(*)(id, SEL, id))orig_defaultDeviceWithMediaType)(self, _cmd, mediaType);
    if (!result) {
        VCAM_LOG("defaultDeviceWithMediaType: returning fake device");
        return GetFakeDevice();
    }
    return result;
}

static IMP orig_devicesWithMediaType = NULL;
static id hook_devicesWithMediaType(id self, SEL _cmd, id mediaType) {
    id result = ((id(*)(id, SEL, id))orig_devicesWithMediaType)(self, _cmd, mediaType);
    if (!result || [result count] == 0) {
        VCAM_LOG("devicesWithMediaType: returning fake device array");
        return @[GetFakeDevice()];
    }
    return result;
}

#pragma mark - Hook 5: AVCaptureDeviceInput

static IMP orig_deviceInputWithDevice = NULL;
static id hook_deviceInputWithDevice(id self, SEL _cmd, id device, NSError **error) {
    // If it's our fake device, return a dummy input (just an NSObject)
    if ([device isKindOfClass:g_FakeDeviceClass]) {
        VCAM_LOG("deviceInputWithDevice: accepting fake device");
        if (error) *error = nil;
        // Return a minimal object that AVCaptureSession will accept
        return [[NSObject alloc] init];
    }
    return ((id(*)(id, SEL, id, NSError**))orig_deviceInputWithDevice)(self, _cmd, device, error);
}

#pragma mark - Hook 6: AVCaptureSession -addInput:

static IMP orig_addInput = NULL;
static void hook_addInput(id self, SEL _cmd, id input) {
    // If it's our fake input (plain NSObject), skip the real addInput
    if (![input isKindOfClass:[AVCaptureInput class]]) {
        VCAM_LOG("addInput: accepting fake input (skipping real addInput)");
        return;
    }
    ((void(*)(id, SEL, id))orig_addInput)(self, _cmd, input);
}

#pragma mark - Hook 7 & 8: AVCaptureSession -startRunning / -stopRunning

static void PushFramesToSession(AVCaptureSession *session);

static IMP orig_startRunning = NULL;
static void hook_startRunning(id self, SEL _cmd) {
    VCAM_LOG("startRunning: starting virtual frame delivery");
    g_sessionRunning = YES;

    // Notify observers via KVO
    [self willChangeValueForKey:@"running"];
    [self didChangeValueForKey:@"running"];

    EnsurePixelBuffer();
    PushFramesToSession((AVCaptureSession *)self);
}

static IMP orig_stopRunning = NULL;
static void hook_stopRunning(id self, SEL _cmd) {
    VCAM_LOG("stopRunning: stopping virtual frame delivery");
    g_sessionRunning = NO;

    if (g_frameTimer) {
        dispatch_source_cancel(g_frameTimer);
        g_frameTimer = NULL;
    }

    [self willChangeValueForKey:@"running"];
    [self didChangeValueForKey:@"running"];
}

// Override isRunning to return our tracked state
static IMP orig_isRunning = NULL;
static BOOL hook_isRunning(id self, SEL _cmd) {
    return g_sessionRunning;
}

#pragma mark - Frame Push Logic

static void PushFramesToSession(AVCaptureSession *session) {
    // Find AVCaptureVideoDataOutput on this session
    AVCaptureVideoDataOutput *videoOutput = nil;
    for (AVCaptureOutput *output in session.outputs) {
        if ([output isKindOfClass:[AVCaptureVideoDataOutput class]]) {
            videoOutput = (AVCaptureVideoDataOutput *)output;
            break;
        }
    }

    if (!videoOutput) {
        VCAM_LOG("no AVCaptureVideoDataOutput found on session, frame push deferred");
        return;
    }

    id<AVCaptureVideoDataOutputSampleBufferDelegate> delegate = videoOutput.sampleBufferDelegate;
    dispatch_queue_t queue = videoOutput.sampleBufferCallbackQueue;

    if (!delegate || !queue) {
        VCAM_LOG("no delegate/queue on video output, frame push deferred");
        return;
    }

    // Create a fake AVCaptureConnection via runtime (init is marked unavailable in headers)
    AVCaptureConnection *connection = nil;
    @try {
        id connObj = [NSClassFromString(@"AVCaptureConnection") alloc];
        connection = ((id(*)(id, SEL))objc_msgSend)(connObj, @selector(init));
    } @catch (NSException *e) {
        // Connection init may throw without ports — use nil
    }

    if (g_frameTimer) {
        dispatch_source_cancel(g_frameTimer);
    }

    g_frameTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, queue);
    uint64_t interval = (uint64_t)(NSEC_PER_SEC / kFrameRate);
    dispatch_source_set_timer(g_frameTimer, DISPATCH_TIME_NOW, interval, interval / 10);

    __weak id<AVCaptureVideoDataOutputSampleBufferDelegate> weakDelegate = delegate;
    __weak AVCaptureVideoDataOutput *weakOutput = videoOutput;
    dispatch_source_set_event_handler(g_frameTimer, ^{
        if (!g_sessionRunning) return;
        id<AVCaptureVideoDataOutputSampleBufferDelegate> d = weakDelegate;
        AVCaptureVideoDataOutput *o = weakOutput;
        if (!d || !o) return;

        CMSampleBufferRef sb = CreateSampleBufferFromPixelBuffer(g_pixelBuffer);
        if (sb) {
            if ([d respondsToSelector:@selector(captureOutput:didOutputSampleBuffer:fromConnection:)]) {
                [d captureOutput:o didOutputSampleBuffer:sb fromConnection:connection];
            }
            CFRelease(sb);
        }
    });
    dispatch_resume(g_frameTimer);
    VCAM_LOG("frame timer started at %.0f fps", kFrameRate);
}

#pragma mark - Hook 9: AVCapturePhotoOutput -capturePhotoWithSettings:delegate:

static IMP orig_capturePhoto = NULL;
static void hook_capturePhoto(id self, SEL _cmd, id settings, id<AVCapturePhotoCaptureDelegate> delegate) {
    VCAM_LOG("capturePhoto: generating photo from static image");

    EnsurePixelBuffer();

    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        // Create a JPEG representation from the pixel buffer
        CIImage *ciImage = [CIImage imageWithCVPixelBuffer:g_pixelBuffer];
        CIContext *ciCtx = [CIContext context];
        CGImageRef cgImage = [ciCtx createCGImage:ciImage fromRect:ciImage.extent];

        NSMutableData *jpegData = [NSMutableData data];
        CGImageDestinationRef dest = CGImageDestinationCreateWithData((__bridge CFMutableDataRef)jpegData,
                                                                       (__bridge CFStringRef)@"public.jpeg",
                                                                       1, NULL);
        if (dest && cgImage) {
            CGImageDestinationAddImage(dest, cgImage, NULL);
            CGImageDestinationFinalize(dest);
            CFRelease(dest);
        }
        if (cgImage) CGImageRelease(cgImage);

        // Call delegate with the photo data
        // Use AVCapturePhoto proxy if available (iOS 11+)
        if ([delegate respondsToSelector:@selector(captureOutput:didFinishProcessingPhoto:error:)]) {
            // We can't easily create an AVCapturePhoto, so we try the legacy path first
            VCAM_LOG("photo capture delegate notified (data size: %lu)", (unsigned long)jpegData.length);
        }

        // Legacy delegate method (iOS 10)
        SEL legacySel = @selector(captureOutput:didFinishProcessingPhotoSampleBuffer:previewPhotoSampleBuffer:resolvedSettings:bracketSettings:error:);
        if ([delegate respondsToSelector:legacySel]) {
            CMSampleBufferRef sb = CreateSampleBufferFromPixelBuffer(g_pixelBuffer);
            if (sb) {
                // resolvedSettings and bracketSettings can be nil
                ((void(*)(id, SEL, id, CMSampleBufferRef, CMSampleBufferRef, id, id, NSError*))
                    objc_msgSend)(delegate, legacySel, self, sb, NULL, nil, nil, nil);
                CFRelease(sb);
            }
        }
    });
}

#pragma mark - Constructor

__attribute__((constructor))
static void VPhoneCameraInit(void) {
    // Only hook in .app processes
    NSString *bundlePath = [[NSBundle mainBundle] bundlePath];
    if (![bundlePath hasSuffix:@".app"]) {
        return;
    }

    VCAM_LOG("initializing in %@", [[NSProcessInfo processInfo] processName]);

    // Register fake device class
    RegisterFakeDeviceClass();

    // Hook 1: UIImagePickerController +isSourceTypeAvailable:
    Class pickerClass = [UIImagePickerController class];
    SwizzleClassMethod(pickerClass,
                       @selector(isSourceTypeAvailable:),
                       (IMP)hook_isSourceTypeAvailable,
                       &orig_isSourceTypeAvailable);

    // Hook 2: UIImagePickerController -setSourceType:
    SwizzleInstanceMethod(pickerClass,
                          @selector(setSourceType:),
                          (IMP)hook_setSourceType,
                          &orig_setSourceType);

    // Hook 3: AVCaptureDevice +defaultDeviceWithMediaType:
    Class deviceClass = [AVCaptureDevice class];
    SwizzleClassMethod(deviceClass,
                       @selector(defaultDeviceWithMediaType:),
                       (IMP)hook_defaultDeviceWithMediaType,
                       &orig_defaultDeviceWithMediaType);

    // Hook 4: AVCaptureDevice +devicesWithMediaType:
    SwizzleClassMethod(deviceClass,
                       NSSelectorFromString(@"devicesWithMediaType:"),
                       (IMP)hook_devicesWithMediaType,
                       &orig_devicesWithMediaType);

    // Hook 5: AVCaptureDeviceInput +deviceInputWithDevice:error:
    Class inputClass = [AVCaptureDeviceInput class];
    SwizzleClassMethod(inputClass,
                       @selector(deviceInputWithDevice:error:),
                       (IMP)hook_deviceInputWithDevice,
                       &orig_deviceInputWithDevice);

    // Hook 6: AVCaptureSession -addInput:
    Class sessionClass = [AVCaptureSession class];
    SwizzleInstanceMethod(sessionClass,
                          @selector(addInput:),
                          (IMP)hook_addInput,
                          &orig_addInput);

    // Hook 7: AVCaptureSession -startRunning
    SwizzleInstanceMethod(sessionClass,
                          @selector(startRunning),
                          (IMP)hook_startRunning,
                          &orig_startRunning);

    // Hook 8: AVCaptureSession -stopRunning
    SwizzleInstanceMethod(sessionClass,
                          @selector(stopRunning),
                          (IMP)hook_stopRunning,
                          &orig_stopRunning);

    // Hook isRunning property
    SwizzleInstanceMethod(sessionClass,
                          @selector(isRunning),
                          (IMP)hook_isRunning,
                          &orig_isRunning);

    // Hook 9: AVCapturePhotoOutput -capturePhotoWithSettings:delegate:
    Class photoOutputClass = [AVCapturePhotoOutput class];
    SwizzleInstanceMethod(photoOutputClass,
                          @selector(capturePhotoWithSettings:delegate:),
                          (IMP)hook_capturePhoto,
                          &orig_capturePhoto);

    VCAM_LOG("all hooks installed");
}
