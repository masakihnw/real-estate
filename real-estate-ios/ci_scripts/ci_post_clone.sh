#!/bin/sh
set -e

if [ -n "$CI_BUILD_NUMBER" ]; then
  cd "$CI_PRIMARY_REPOSITORY_PATH/real-estate-ios"

  plutil -replace CFBundleVersion -string "$CI_BUILD_NUMBER" RealEstateApp/Info.plist

  sed -i '' "s/CURRENT_PROJECT_VERSION = [0-9]*/CURRENT_PROJECT_VERSION = $CI_BUILD_NUMBER/" \
    RealEstateApp.xcodeproj/project.pbxproj
fi
