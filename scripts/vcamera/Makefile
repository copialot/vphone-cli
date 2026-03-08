# vcamera — Virtual camera hook dylib (cross-compiled for arm64 iphoneos)

SRCS := vphone_camera.m
OUT  := vphone_camera.dylib

.PHONY: all clean

all: $(OUT)

$(OUT): $(SRCS)
	@echo "=== Building vphone_camera.dylib (arm64, iphoneos) ==="
	xcrun -sdk iphoneos clang -arch arm64 -Os -fobjc-arc \
		-dynamiclib \
		-install_name /Library/MobileSubstrate/DynamicLibraries/vphone_camera.dylib \
		-o $@ $(SRCS) \
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

clean:
	rm -f $(OUT)
