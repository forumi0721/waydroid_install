#!/bin/sh

set -eu

#
# 기본 설정
#

#ANDROID_SDK="${ANDROID_SDK:-$HOME/Library/Android/sdk}"
#BUILD_TOOLS_VERSION="${BUILD_TOOLS_VERSION:-37.0.0}"
#
#AAPT2="${ANDROID_SDK}/build-tools/${BUILD_TOOLS_VERSION}/aapt2"
#APKSIGNER="${ANDROID_SDK}/build-tools/${BUILD_TOOLS_VERSION}/apksigner"

AAPT2="/usr/bin/aapt2"
APKSIGNER="$(dirname "${0}")/bin/apksigner"

#FRAMEWORK_APK="${FRAMEWORK_APK:-$HOME/Desktop/framework-res.apk}"
FRAMEWORK_APK="/var/lib/waydroid/rootfs/system/framework/framework-res.apk"
DEBUG_KEYSTORE="${DEBUG_KEYSTORE:-$HOME/.android/debug.keystore}"

PACKAGE_NAME="kr.stonecold.overlay.usertypes"
APK_NAME="UserTypesOverlay.apk"

VERSION_CODE="5"
VERSION_NAME="1.5"
MAX_CLONE_PROFILES="5"

#OUTPUT_DIR="${OUTPUT_DIR:-$HOME/Desktop}"
OUTPUT_DIR="$(dirname "${0}")"
OUTPUT_APK="${OUTPUT_DIR}/${APK_NAME}"

DEPLOY_HOST="${DEPLOY_HOST:-root@StoneColDroid}"
DEPLOY_PATH="${DEPLOY_PATH:-/root/overlayapk/${APK_NAME}}"

WORK_DIR=""
CLEANUP_RUNNING=0


cleanup() {
    EXIT_CODE=$?

    if [ "$CLEANUP_RUNNING" -eq 1 ]; then
        return
    fi

    CLEANUP_RUNNING=1
    trap - EXIT INT TERM HUP

    if [ -n "$WORK_DIR" ] &&
       [ -d "$WORK_DIR" ]; then
        rm -rf "$WORK_DIR"
    fi

    exit "$EXIT_CODE"
}


fail() {
    echo "ERROR: $*" >&2
    exit 1
}


trap cleanup EXIT INT TERM HUP


#
# 필수 도구 검사
#

[ -x "$AAPT2" ] ||
    fail "aapt2 not found: $AAPT2"

[ -x "$APKSIGNER" ] ||
    fail "apksigner not found: $APKSIGNER"

command -v keytool >/dev/null 2>&1 ||
    fail "keytool not found"

[ -f "$FRAMEWORK_APK" ] ||
    fail "framework-res.apk not found: $FRAMEWORK_APK"

mkdir -p "$OUTPUT_DIR"


#
# 임시 빌드 디렉터리 생성
#

WORK_DIR="$(
    mktemp -d "${TMPDIR:-/tmp}/UserTypesOverlay.XXXXXX"
)"

RESOURCE_XML_DIR="${WORK_DIR}/res/xml"
RESOURCE_VALUES_DIR="${WORK_DIR}/res/values"
COMPILED_RESOURCES="${WORK_DIR}/compiled.zip"
UNSIGNED_APK="${WORK_DIR}/UserTypesOverlay-unsigned.apk"
SIGNED_APK="${WORK_DIR}/${APK_NAME}"
MANIFEST="${WORK_DIR}/AndroidManifest.xml"

mkdir -p "$RESOURCE_XML_DIR" "$RESOURCE_VALUES_DIR"


#
# AndroidManifest.xml 생성
#

cat > "$MANIFEST" <<EOF
<?xml version="1.0" encoding="utf-8"?>
<manifest xmlns:android="http://schemas.android.com/apk/res/android"
    package="${PACKAGE_NAME}"
    android:versionCode="${VERSION_CODE}"
    android:versionName="${VERSION_NAME}">

    <application
        android:hasCode="false"
        android:label="StoneCold User Types Overlay" />

    <overlay
        android:targetPackage="android"
        android:isStatic="true"
        android:priority="999" />
</manifest>
EOF


#
# config_user_types.xml 생성
#

cat > "${RESOURCE_XML_DIR}/config_user_types.xml" <<EOF
<?xml version="1.0" encoding="utf-8"?>
<user-types version="0">

    <profile-type
        name="android.os.usertype.profile.MANAGED"
        max-allowed="${MAX_CLONE_PROFILES}"
        max-allowed-per-parent="${MAX_CLONE_PROFILES}" />

    <profile-type
        name="android.os.usertype.profile.CLONE"
        max-allowed="${MAX_CLONE_PROFILES}"
        max-allowed-per-parent="${MAX_CLONE_PROFILES}" />

</user-types>
EOF


#
# config.xml 생성
#

cat > "${RESOURCE_VALUES_DIR}/config.xml" <<EOF
<?xml version="1.0" encoding="utf-8"?>
<resources>
    <integer name="config_multiuserMaxRunningUsers">${MAX_CLONE_PROFILES}</integer>
</resources>
EOF


#
# RRO 리소스 컴파일
#

echo "Compiling resources"

"$AAPT2" compile \
    --dir "${WORK_DIR}/res" \
    -o "$COMPILED_RESOURCES"


#
# RRO APK 링크
#

echo "Linking RRO APK"

"$AAPT2" link \
    -o "$UNSIGNED_APK" \
    -I "$FRAMEWORK_APK" \
    --manifest "$MANIFEST" \
    --auto-add-overlay \
    "$COMPILED_RESOURCES"


#
# 디버그 서명키 생성
#

if [ ! -f "$DEBUG_KEYSTORE" ]; then
    echo "Creating Android debug keystore"

    mkdir -p "$(dirname "$DEBUG_KEYSTORE")"

    keytool -genkeypair \
        -keystore "$DEBUG_KEYSTORE" \
        -storepass android \
        -keypass android \
        -alias androiddebugkey \
        -dname "CN=Android Debug,O=Android,C=US" \
        -keyalg RSA \
        -keysize 2048 \
        -validity 10000
fi


#
# APK 서명
#

echo "Signing RRO APK"

"$APKSIGNER" sign \
    --ks "$DEBUG_KEYSTORE" \
    --ks-key-alias androiddebugkey \
    --ks-pass pass:android \
    --key-pass pass:android \
    --out "$SIGNED_APK" \
    "$UNSIGNED_APK"


#
# 서명과 APK 구조 검증
#

echo "Verifying APK signature"

"$APKSIGNER" verify \
    --verbose \
    --print-certs \
    "$SIGNED_APK"

echo "Verifying RRO manifest"

"$AAPT2" dump badging "$SIGNED_APK" |
    grep -E "package:|overlay:"


#
# 완성 APK 저장
#

cp -f "$SIGNED_APK" "$OUTPUT_APK"
chmod 644 "$OUTPUT_APK"

echo
echo "Build completed"
echo "Output: $OUTPUT_APK"
echo "Package: $PACKAGE_NAME"
echo "Version: $VERSION_NAME ($VERSION_CODE)"
echo "Maximum clone profiles: $MAX_CLONE_PROFILES"


#
# --deploy 지정 시 StoneColDroid로 전송
#

if [ "${1:-}" = "--deploy" ]; then
    command -v ssh >/dev/null 2>&1 ||
        fail "ssh not found"

    command -v scp >/dev/null 2>&1 ||
        fail "scp not found"

    echo
    echo "Creating remote overlay directory"

    ssh "$DEPLOY_HOST" \
        "mkdir -p /root/overlayapk && chmod 755 /root/overlayapk"

    echo "Deploying APK"

    scp "$OUTPUT_APK" \
        "${DEPLOY_HOST}:${DEPLOY_PATH}"

    ssh "$DEPLOY_HOST" \
        "chown root:root '${DEPLOY_PATH}' && chmod 644 '${DEPLOY_PATH}'"

    echo "Deployed: ${DEPLOY_HOST}:${DEPLOY_PATH}"
fi
