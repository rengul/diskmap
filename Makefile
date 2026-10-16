CXX := clang++
CXXFLAGS := -std=c++17 -O2 -Wall -Wextra -fobjc-arc
FRAMEWORKS := -framework Foundation
APP_FRAMEWORKS := -framework AppKit -framework Foundation

.PHONY: all clean test ui release

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
	xcrun actool Assets.xcassets --compile "DiskMap.app/Contents/Resources" --platform macosx --minimum-deployment-target 13.0 --app-icon AppIcon --output-partial-info-plist "DiskMap.app/Contents/asset-info.plist"
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

clean:
	rm -f ddscan
	rm -rf DiskMap.app
	rm -rf DiskMap.iconset
