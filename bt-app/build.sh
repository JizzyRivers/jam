#!/usr/bin/env bash
# Builds jam-bt.apk from source. This is Jam's own code (unlike Amonet/
# Wyoming), so it's fine to commit both the source and the built APK.
#
# Requires: javac, and the Android SDK build-tools (d8, aapt2, apksigner)
# + a platform-22 android.jar (matching this Echo's Android 5.1.1/API 22).
# Get these via the SDK cmdline-tools if you don't already have them:
#   sdkmanager --sdk_root=<dir> "platform-tools" "platforms;android-22" "build-tools;33.0.2"

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
: "${ANDROID_SDK_ROOT:?Set ANDROID_SDK_ROOT to your Android SDK path}"
BUILD_TOOLS="$ANDROID_SDK_ROOT/build-tools/33.0.2"
PLATFORM_JAR="$ANDROID_SDK_ROOT/platforms/android-22/android.jar"

[[ -x "$BUILD_TOOLS/d8" ]] || { echo "ERROR: $BUILD_TOOLS/d8 not found"; exit 1; }
[[ -f "$PLATFORM_JAR" ]] || { echo "ERROR: $PLATFORM_JAR not found"; exit 1; }

BUILD_DIR="$SCRIPT_DIR/.build"
rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR/classes"

echo "Compiling..."
javac -source 8 -target 8 -bootclasspath "$PLATFORM_JAR" \
    -d "$BUILD_DIR/classes" \
    "$SCRIPT_DIR/src/com/jam/bt/JamBtReceiver.java" \
    "$SCRIPT_DIR/src/com/jam/bt/JamBtService.java"

echo "Converting to DEX..."
"$BUILD_TOOLS/d8" --output "$BUILD_DIR/" --min-api 22 "$BUILD_DIR"/classes/com/jam/bt/*.class

echo "Linking resources/manifest..."
"$BUILD_TOOLS/aapt2" link -o "$BUILD_DIR/base.apk" \
    -I "$PLATFORM_JAR" \
    --manifest "$SCRIPT_DIR/AndroidManifest.xml" \
    --min-sdk-version 22 --target-sdk-version 22

echo "Assembling APK..."
python3 -c "
import zipfile, shutil
shutil.copy('$BUILD_DIR/base.apk', '$BUILD_DIR/jam-bt-unsigned.apk')
with zipfile.ZipFile('$BUILD_DIR/jam-bt-unsigned.apk', 'a', zipfile.ZIP_DEFLATED) as z:
    z.write('$BUILD_DIR/classes.dex', 'classes.dex')
"

KEYSTORE="$SCRIPT_DIR/debug.keystore"
if [[ ! -f "$KEYSTORE" ]]; then
    echo "Generating debug keystore (self-signed, not sensitive)..."
    keytool -genkeypair -keystore "$KEYSTORE" -storepass android -alias androiddebugkey \
        -keypass android -keyalg RSA -keysize 2048 -validity 10000 \
        -dname "CN=Jam BT Debug, OU=Jam, O=Jam, L=Unknown, S=Unknown, C=US"
fi

echo "Signing..."
"$BUILD_TOOLS/apksigner" sign --ks "$KEYSTORE" --ks-pass pass:android --key-pass pass:android \
    --min-sdk-version 22 \
    --out "$SCRIPT_DIR/jam-bt.apk" "$BUILD_DIR/jam-bt-unsigned.apk"

echo "Built: $SCRIPT_DIR/jam-bt.apk"
