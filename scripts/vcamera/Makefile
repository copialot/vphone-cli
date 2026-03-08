# vcamera — Virtual camera hook + TweakLoader (cross-compiled for arm64 iphoneos)

VCAMERA_SRCS := vphone_camera.m
VCAMERA_OUT  := vphone_camera.dylib

LOADER_SRCS := TweakLoader.m
LOADER_OUT  := TweakLoader.dylib

.PHONY: all clean

all: $(VCAMERA_OUT) $(LOADER_OUT)

$(VCAMERA_OUT): $(VCAMERA_SRCS)
	@echo "=== Building vphone_camera.dylib (arm64, iphoneos) ==="
	xcrun -sdk iphoneos clang -arch arm64 -Os -fobjc-arc \
		-dynamiclib \
		-install_name /Library/MobileSubstrate/DynamicLibraries/vphone_camera.dylib \
		-o $@ $(VCAMERA_SRCS) \
		-framework Foundation \
		-framework AVFoundation \
		-framework CoreMedia \
		-framework CoreVideo \
		-framework CoreImage \
		-framework UIKit \
		-framework ImageIO \
		-framework CoreText \
		-framework CoreGraphics \
		-framework QuartzCore
	@echo "  built OK"

$(LOADER_OUT): $(LOADER_SRCS)
	@echo "=== Building TweakLoader.dylib (arm64, iphoneos) ==="
	xcrun -sdk iphoneos clang -arch arm64 -Os -fobjc-arc \
		-dynamiclib \
		-install_name /var/jb/usr/lib/TweakLoader.dylib \
		-o $@ $(LOADER_SRCS) \
		-framework Foundation
	@echo "  built OK"

clean:
	rm -f $(VCAMERA_OUT) $(LOADER_OUT)
