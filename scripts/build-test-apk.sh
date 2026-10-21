#!/bin/bash
# Builds Tests/TestApp into .build/test-apk/moorbox-hello.apk with the SDK's own tools.
# Needs: an Android SDK with build-tools and a platform (android.jar), and a JDK 17+
# for javac/d8. Only used by the opt-in integration tests; never shipped.
set -euo pipefail
cd "$(dirname "$0")/.."
SDK="${ANDROID_HOME:-$HOME/Library/Android/sdk}"
BT="$SDK/build-tools/$(ls "$SDK/build-tools" | sort -V | tail -1)"
JAR="$SDK/platforms/$(ls "$SDK/platforms" | sort -V | tail -1)/android.jar"
JAVA_HOME="${JAVA_HOME:-$(/usr/libexec/java_home -v 17+ 2>/dev/null || true)}"
[[ -x "$JAVA_HOME/bin/javac" ]] || { echo "A JDK 17+ is required (set JAVA_HOME or install one, e.g. from adoptium.net)." >&2; exit 1; }
export PATH="$JAVA_HOME/bin:$PATH" JAVA_HOME
OUT=.build/test-apk
rm -rf "$OUT" && mkdir -p "$OUT/classes" "$OUT/dex"

javac --release 11 -classpath "$JAR" -d "$OUT/classes" Tests/TestApp/src/org/moorbox/hello/MainActivity.java
"$BT/d8" --min-api 24 --lib "$JAR" --output "$OUT/dex" $(find "$OUT/classes" -name '*.class')
"$BT/aapt2" link -o "$OUT/unsigned.apk" -I "$JAR" --manifest Tests/TestApp/AndroidManifest.xml
(cd "$OUT/dex" && zip -q ../unsigned.apk classes.dex)
"$BT/zipalign" -f 4 "$OUT/unsigned.apk" "$OUT/aligned.apk"

# Throwaway test key, generated locally; never the user's debug keystore.
KS="$OUT/test.keystore"
keytool -genkeypair -keystore "$KS" -storepass moorboxtest -keypass moorboxtest -alias test \
  -keyalg RSA -keysize 2048 -validity 365 -dname "CN=Moorbox Test" >/dev/null 2>&1
"$BT/apksigner" sign --ks "$KS" --ks-pass pass:moorboxtest --out "$OUT/moorbox-hello.apk" "$OUT/aligned.apk"
"$BT/apksigner" verify "$OUT/moorbox-hello.apk"
echo "$OUT/moorbox-hello.apk"
