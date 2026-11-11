#!/bin/bash

APP_NAME="Sustur"
BINARY_NAME="Sustur"
BUNDLE_ID="com.emre.sustur"
APP_ICON="AppIcon.icns"

echo "🔨 Compiling..."
swiftc sustur.swift -o $BINARY_NAME -target arm64-apple-macos26.0 -framework Cocoa -framework CoreAudio -framework UserNotifications

if [ "$1" == "--dmg" ]; then
    echo "📦 Creating DMG Package..."
    rm -rf Sustur.app Sustur.dmg dist
    mkdir -p Sustur.app/Contents/MacOS
    mkdir -p Sustur.app/Contents/Resources
    cp $BINARY_NAME Sustur.app/Contents/MacOS/
    cp AppIcon.icns Sustur.app/Contents/Resources/AppIcon.icns
    cp Info.plist Sustur.app/Contents/Info.plist
    
    codesign --force --deep --sign - Sustur.app
    echo "🔏 Application has been signed locally"

    mkdir dist
    cp -R Sustur.app dist/
    ln -s /Applications dist/Applications
    hdiutil create -volname "$APP_NAME Setup" -srcfolder dist -ov -format UDZO Sustur.dmg
    
    rm -rf dist Sustur.app Sustur
    echo "✅ Sustur.dmg is ready!"
else
    echo "✅ Only ($BINARY_NAME) binary created."
fi
