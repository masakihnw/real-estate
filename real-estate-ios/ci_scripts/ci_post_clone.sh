#!/bin/sh
set -e

if [ -n "$CI_BUILD_NUMBER" ]; then
  cd "$CI_PRIMARY_REPOSITORY_PATH/real-estate-ios"

  # Xcode Cloud の CI_BUILD_NUMBER にオフセットを加算し、
  # App Store Connect の既存ビルド番号を確実に超えるようにする
  OFFSET=100
  BUILD_NUMBER=$((CI_BUILD_NUMBER + OFFSET))

  plutil -replace CFBundleVersion -string "$BUILD_NUMBER" RealEstateApp/Info.plist

  sed -i '' "s/CURRENT_PROJECT_VERSION = [0-9]*/CURRENT_PROJECT_VERSION = $BUILD_NUMBER/" \
    RealEstateApp.xcodeproj/project.pbxproj
fi
