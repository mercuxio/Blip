#!/usr/bin/env bash
# Adds the zipped release for the current version to appcast.xml, signed with the EdDSA key in the
# login Keychain (created once by Sparkle's `generate_keys`). Run after `make zip`, upload
# .build/Blip-<version>.zip to the v<version> GitHub release, then commit and push appcast.xml:
# installed copies read it from the main branch on GitHub.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
APP=".build/Blip.app"
PLIST="$APP/Contents/Info.plist"
VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$PLIST")
ZIP=".build/Blip-$VERSION.zip"
BUILD=$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$PLIST")
MINOS=$(/usr/libexec/PlistBuddy -c "Print :LSMinimumSystemVersion" "$PLIST" 2>/dev/null || echo 14.0)
SIGN=$(.build/artifacts/sparkle/Sparkle/bin/sign_update "$ZIP")   # sparkle:edSignature="…" length="…"
URL="https://github.com/mercuxio/Blip/releases/download/v$VERSION/Blip-$VERSION.zip"
NOTES="https://github.com/mercuxio/Blip/releases/tag/v$VERSION"
DATE=$(LC_ALL=C date -u "+%a, %d %b %Y %H:%M:%S +0000")

grep -q "<sparkle:shortVersionString>$VERSION<" appcast.xml && { echo "appcast.xml already lists $VERSION"; exit 0; }

ITEM="    <item>
      <title>Blip $VERSION</title>
      <pubDate>$DATE</pubDate>
      <sparkle:version>$BUILD</sparkle:version>
      <sparkle:shortVersionString>$VERSION</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>$MINOS</sparkle:minimumSystemVersion>
      <sparkle:releaseNotesLink>$NOTES</sparkle:releaseNotesLink>
      <enclosure url=\"$URL\" type=\"application/octet-stream\" $SIGN/>
    </item>"

python3 - "$ITEM" <<'P'
import sys
item = sys.argv[1]
s = open('appcast.xml').read()
s = s.replace("<title>Blip</title>\n", "<title>Blip</title>\n" + item + "\n", 1)  # newest first
open('appcast.xml', 'w').write(s)
P
echo "Added $VERSION to appcast.xml"
