#!/bin/zsh
# Package /Applications/TopNotch.app into a styled drag-to-install TopNotch.dmg. Usage: ./dmg.sh
set -e
cd "${0:a:h}"
VOL=TopNotch; D=/Volumes/$VOL; TMP=$(mktemp -d); RW=$TMP/rw.dmg
hdiutil detach -quiet $D 2>/dev/null || true
hdiutil create -quiet -size 40m -fs HFS+ -volname $VOL -ov $RW
hdiutil attach -quiet -readwrite -noautoopen $RW

cp -R /Applications/TopNotch.app $D/
ln -s /Applications $D/Applications
mkdir $D/.background && cp Resources/dmg-background.tiff $D/.background/bg.tiff

# Finder writes the window layout into the image's .DS_Store
osascript <<AS
tell application "Finder"
    tell disk "$VOL"
        open
        set current view of container window to icon view
        set toolbar visible of container window to false
        set statusbar visible of container window to false
        set bounds of container window to {200, 120, 860, 548}
        set o to icon view options of container window
        set arrangement of o to not arranged
        set icon size of o to 128
        set text size of o to 13
        set background picture of o to file ".background:bg.tiff"
        set position of item "TopNotch.app" of container window to {170, 200}
        set position of item "Applications" of container window to {490, 200}
        close
        open
        update without registering applications
        delay 1
        close
    end tell
end tell
AS

# after Finder: it deletes .VolumeIcon.icns while saving the layout
cp Resources/AppIcon.icns $D/.VolumeIcon.icns  # mounted disk shows the TopNotch logo
xattr -wx com.apple.FinderInfo 0000000000000000040000000000000000000000000000000000000000000000 $D  # kHasCustomIcon
rm -rf $D/.fseventsd
chmod -Rf go-w $D; sync
hdiutil detach -quiet $D
hdiutil convert -quiet $RW -format UDZO -imagekey zlib-level=9 -ov -o TopNotch.dmg
rm -rf $TMP
echo "built: TopNotch.dmg"
