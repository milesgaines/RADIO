#!/bin/bash
# RADIO (RADIOSPLUS, Apple ID 6794523437) → TestFlight. Same proven chain as
# the other Onesync apps: xcodebuild archive (+authKey automatic cloud
# signing) → exportArchive → altool upload.
#
# GOTCHA (inherited from AIDAR's ship.sh): Apple-managed entitlements (App
# Groups, CarPlay) CANNOT be provisioned via ASC API keys — they make
# xcodebuild fail with a bogus "Authentication failed". CarPlay is therefore
# stripped from Swell.entitlements until Apple grants it.
set -euo pipefail
cd "$(dirname "$0")"

ASC_KEY_ID="${ASC_KEY_ID:-5UMQNTGT38}"
ASC_ISSUER_ID="${ASC_ISSUER_ID:-407602e0-c72b-40dc-9686-ee2e5276b8d2}"
PROV_KEY_ID="A55T5U7K95"
PROV_KEY_P8="$HOME/.appstoreconnect/private_keys/AuthKey_A55T5U7K95.p8"
TEAM_ID="4XMMKU4W89"

BUILD_NUMBER="$(date +%Y%m%d%H%M)"
ARCHIVE="build/RADIO.xcarchive"
EXPORT="build/export"

~/.local/bin/xcodegen generate

echo "▸ Archiving (Release, build $BUILD_NUMBER)…"
xcodebuild -project Swell.xcodeproj -scheme Swell -configuration Release \
  -destination 'generic/platform=iOS' -archivePath "$ARCHIVE" \
  CURRENT_PROJECT_VERSION="$BUILD_NUMBER" DEVELOPMENT_TEAM="$TEAM_ID" \
  -allowProvisioningUpdates \
  -authenticationKeyPath "$PROV_KEY_P8" \
  -authenticationKeyID "$PROV_KEY_ID" \
  -authenticationKeyIssuerID "$ASC_ISSUER_ID" \
  archive

echo "▸ Exporting signed .ipa…"
xcodebuild -exportArchive -archivePath "$ARCHIVE" \
  -exportOptionsPlist ExportOptions.plist -exportPath "$EXPORT" \
  -allowProvisioningUpdates \
  -authenticationKeyPath "$PROV_KEY_P8" \
  -authenticationKeyID "$PROV_KEY_ID" \
  -authenticationKeyIssuerID "$ASC_ISSUER_ID"

IPA=$(/usr/bin/find "$EXPORT" -name '*.ipa' -newer "$ARCHIVE" | head -1)  # never grab a stale export
echo "▸ Uploading $IPA…"
xcrun altool --upload-app -f "$IPA" -t ios \
  --apiKey "$ASC_KEY_ID" --apiIssuer "$ASC_ISSUER_ID"

echo "✅ Uploaded build $BUILD_NUMBER — appears in TestFlight after processing (5–15 min)."
