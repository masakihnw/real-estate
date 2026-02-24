#!/bin/sh
set -e

if [ -n "$CI_BUILD_NUMBER" ]; then
  cd "$CI_PRIMARY_REPOSITORY_PATH/real-estate-ios"

  # Xcode Cloud の CI_BUILD_NUMBER は 1 から始まるため、
  # 既存のビルド番号（46）を超えるようオフセットを加算
  OFFSET=46
  BUILD_NUMBER=$((CI_BUILD_NUMBER + OFFSET))

  plutil -replace CFBundleVersion -string "$BUILD_NUMBER" RealEstateApp/Info.plist

  sed -i '' "s/CURRENT_PROJECT_VERSION = [0-9]*/CURRENT_PROJECT_VERSION = $BUILD_NUMBER/" \
    RealEstateApp.xcodeproj/project.pbxproj
fi
