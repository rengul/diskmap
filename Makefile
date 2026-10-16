CXX := clang++
# Do not inherit the host OS as the deployment target. This project is built
# on macOS 27, while a notarized build must also launch on earlier supported
# systems such as macOS Tahoe 26.
MACOS_MIN_VERSION := 13.0
CXXFLAGS := -std=c++17 -O2 -Wall -Wextra -fobjc-arc -mmacosx-version-min=$(MACOS_MIN_VERSION)
FRAMEWORKS := -framework Foundation
APP_FRAMEWORKS := -framework AppKit -framework Foundation
# The Documents folder can be managed by a File Provider which re-adds Finder
# metadata to application bundles. Developer ID signing is performed on this
# clean, local staging copy instead.
SIGNING_OUTPUT := /private/tmp/DiskMap-signed.app

.PHONY: all clean test ui sign notarize release

all: ddscan

ddscan: Scanner.mm
	$(CXX) $(CXXFLAGS) Scanner.mm $(FRAMEWORKS) -o $@

test: ddscan
	./ddscan --threads 4 .

ui: ddscan UI.mm Info.plist Version.plist icon-concepts/diskmap-platter.png splash-concepts/diskmap-splash.png Assets.xcassets/AppIcon.appiconset/Contents.json
	rm -rf "DiskMap.app"
	mkdir -p "DiskMap.app/Contents/MacOS" "DiskMap.app/Contents/Resources"
	$(CXX) $(CXXFLAGS) UI.mm $(APP_FRAMEWORKS) -o "DiskMap.app/Contents/MacOS/DiskMap"
	cp ddscan "DiskMap.app/Contents/Resources/ddscan"
	cp Version.plist "DiskMap.app/Contents/Resources/Version.plist"
	cp splash-concepts/diskmap-splash.png "DiskMap.app/Contents/Resources/DiskMapSplash.png"
	sips -z 16 16 icon-concepts/diskmap-platter.png --out Assets.xcassets/AppIcon.appiconset/icon_16x16.png >/dev/null
	sips -z 32 32 icon-concepts/diskmap-platter.png --out Assets.xcassets/AppIcon.appiconset/icon_16x16@2x.png >/dev/null
	sips -z 32 32 icon-concepts/diskmap-platter.png --out Assets.xcassets/AppIcon.appiconset/icon_32x32.png >/dev/null
	sips -z 64 64 icon-concepts/diskmap-platter.png --out Assets.xcassets/AppIcon.appiconset/icon_32x32@2x.png >/dev/null
	sips -z 128 128 icon-concepts/diskmap-platter.png --out Assets.xcassets/AppIcon.appiconset/icon_128x128.png >/dev/null
	sips -z 256 256 icon-concepts/diskmap-platter.png --out Assets.xcassets/AppIcon.appiconset/icon_128x128@2x.png >/dev/null
	sips -z 256 256 icon-concepts/diskmap-platter.png --out Assets.xcassets/AppIcon.appiconset/icon_256x256.png >/dev/null
	sips -z 512 512 icon-concepts/diskmap-platter.png --out Assets.xcassets/AppIcon.appiconset/icon_256x256@2x.png >/dev/null
	sips -z 512 512 icon-concepts/diskmap-platter.png --out Assets.xcassets/AppIcon.appiconset/icon_512x512.png >/dev/null
	sips -z 1024 1024 icon-concepts/diskmap-platter.png --out Assets.xcassets/AppIcon.appiconset/icon_512x512@2x.png >/dev/null
	# `asset-info.plist` is build metadata, not an application resource. Keeping
	# it inside the bundle makes codesign treat it as an unsigned subcomponent.
	xcrun actool Assets.xcassets --compile "DiskMap.app/Contents/Resources" --platform macosx --minimum-deployment-target $(MACOS_MIN_VERSION) --app-icon AppIcon --output-partial-info-plist "/private/tmp/DiskMap-asset-info.plist"
	cp Info.plist "DiskMap.app/Contents/Info.plist"
	/usr/libexec/PlistBuddy -c "Add :CFBundleShortVersionString string $$(/usr/libexec/PlistBuddy -c 'Print :ShortVersion' Version.plist)" "DiskMap.app/Contents/Info.plist"
	/usr/libexec/PlistBuddy -c "Add :CFBundleVersion string $$(/usr/libexec/PlistBuddy -c 'Print :Build' Version.plist)" "DiskMap.app/Contents/Info.plist"
	xattr -cr "DiskMap.app"
	xattr -d 'com.apple.fileprovider.fpfs#P' "DiskMap.app" 2>/dev/null || true
	xattr -d com.apple.FinderInfo "DiskMap.app" 2>/dev/null || true
	codesign --force --deep --sign - "DiskMap.app"
	# File Provider can immediately restore FinderInfo on bundles inside Documents.
	# The regular deep verification still validates the complete ad-hoc signature.
	codesign --verify --deep --verbose=2 "DiskMap.app"

release: ui distribution/package-release.sh
	./distribution/package-release.sh

# A development build is deliberately signed ad-hoc by `ui`.  Use this target
# only with a Developer ID Application certificate before distribution.
# Example:
#   make sign SIGNING_IDENTITY='Developer ID Application: Name (TEAMID)'
sign: ui
	@test -n "$(SIGNING_IDENTITY)" || { echo "SIGNING_IDENTITY is required" >&2; exit 2; }
	rm -rf "$(SIGNING_OUTPUT)"
	ditto --norsrc "DiskMap.app" "$(SIGNING_OUTPUT)"
	xattr -cr "$(SIGNING_OUTPUT)"
	xattr -d com.apple.FinderInfo "$(SIGNING_OUTPUT)" 2>/dev/null || true
	xattr -d 'com.apple.fileprovider.fpfs#P' "$(SIGNING_OUTPUT)" 2>/dev/null || true
	codesign --force --timestamp --options runtime --sign "$(SIGNING_IDENTITY)" "$(SIGNING_OUTPUT)/Contents/Resources/ddscan"
	codesign --force --timestamp --options runtime --sign "$(SIGNING_IDENTITY)" "$(SIGNING_OUTPUT)"
	codesign --verify --deep --strict --verbose=2 "$(SIGNING_OUTPUT)"
	@echo "Signed app: $(SIGNING_OUTPUT)"

# Credentials are supplied through environment variables and are never stored
# in source control. See distribution/README.md for the one-command test.
notarize: distribution/notarize.sh
	./distribution/notarize.sh

clean:
	rm -f ddscan
	rm -rf DiskMap.app
	rm -rf DiskMap.iconset
