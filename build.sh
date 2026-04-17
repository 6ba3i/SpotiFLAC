#!/usr/bin/env bash
set -euo pipefail

fvm install 3.38.1
fvm use 3.38.1 --force

fvm flutter --version
fvm flutter doctor

rm -rf .dart_tool build
fvm flutter clean

fvm flutter pub get
fvm dart run build_runner build --delete-conflicting-outputs

cd go_backend
gomobile init
mkdir -p ../android/app/libs
gomobile bind -target=android -androidapi 24 -o ../android/app/libs/gobackend.aar .
cd ..

fvm flutter build apk --debug