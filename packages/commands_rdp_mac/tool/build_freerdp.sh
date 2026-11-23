#!/usr/bin/env bash
# Builds the RDP engine the macOS app draws sessions with: FreeRDP's core and
# client libraries plus OpenSSL, static, for arm64 and x86_64, packed into
# macos/commands_rdp_mac/FreeRDP.xcframework (not tracked in git).
#
# Run once before `flutter build macos` / `flutter run -d macos`; CI runs it in
# the macOS release job. Needs cmake and ninja (`brew install cmake ninja`).
# Only what an embedded session needs is built: no X11/SDL client, no server,
# no ffmpeg, no smartcard or USB redirection, so nothing outside the app bundle
# is ever loaded at run time. The sound channel is built, with only its silent
# ("fake") backend: FreeRDP asks for it whenever network auto-detection is on,
# and a session without it stops before connecting ("A configuration error
# prevented a connection to be established").
set -euo pipefail

# xcodebuild (for the xcframework) needs Xcode, not just the command line tools.
if ! xcodebuild -version >/dev/null 2>&1 && [[ -d /Applications/Xcode.app ]]; then
  export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi

FREERDP_TAG="3.33.1"
OPENSSL_TAG="openssl-3.6.5"
DEPLOY="12.0"

HERE="$(cd "$(dirname "$0")/.." && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
WORK="${FREERDP_WORK:-$ROOT/build/freerdp-work}"
OUT="$HERE/macos/commands_rdp_mac/FreeRDP.xcframework"
# The stamp names this script's hash: a changed option means a rebuild.
STAMP="$OUT/.built-$(shasum -a 256 "$0" | cut -c1-16)"

if [[ -f "$STAMP" ]]; then
  echo "FreeRDP.xcframework is up to date ($FREERDP_TAG, $OPENSSL_TAG)."
  exit 0
fi

mkdir -p "$WORK"
cd "$WORK"
[[ -d openssl-src ]] || git clone --depth 1 --branch "$OPENSSL_TAG" https://github.com/openssl/openssl.git openssl-src
[[ -d freerdp-src ]] || git clone --depth 1 --branch "$FREERDP_TAG" https://github.com/FreeRDP/FreeRDP.git freerdp-src

JOBS="$(sysctl -n hw.ncpu)"

for ARCH in arm64 x86_64; do
  PREFIX="$WORK/prefix-$ARCH"
  if [[ ! -f "$PREFIX/lib/libcrypto.a" ]]; then
    rm -rf "$WORK/openssl-$ARCH" && cp -R openssl-src "$WORK/openssl-$ARCH"
    (
      cd "$WORK/openssl-$ARCH"
      if [[ $ARCH == arm64 ]]; then TARGET=darwin64-arm64-cc; else TARGET=darwin64-x86_64-cc; fi
      MACOSX_DEPLOYMENT_TARGET=$DEPLOY ./Configure "$TARGET" no-shared no-tests no-docs no-apps no-module \
        --prefix="$PREFIX" --libdir=lib -mmacosx-version-min=$DEPLOY
      make -j"$JOBS" build_libs >/dev/null
      make install_dev >/dev/null
    )
  fi

  if [[ ! -f "$PREFIX/lib/libfreerdp3.a" || ! -f "$STAMP" ]]; then
    rm -rf "$WORK/freerdp-build-$ARCH"
    rm -f "$PREFIX"/lib/libfreerdp* "$PREFIX"/lib/libwinpr*
    cmake -S freerdp-src -B "$WORK/freerdp-build-$ARCH" -G Ninja \
      -DCMAKE_BUILD_TYPE=Release \
      -DCMAKE_INSTALL_PREFIX="$PREFIX" \
      -DCMAKE_PREFIX_PATH="$PREFIX" \
      -DCMAKE_OSX_ARCHITECTURES="$ARCH" \
      -DCMAKE_OSX_DEPLOYMENT_TARGET="$DEPLOY" \
      -DCMAKE_IGNORE_PREFIX_PATH="/opt/homebrew;/usr/local;/opt/local" \
      -DOPENSSL_ROOT_DIR="$PREFIX" -DOPENSSL_USE_STATIC_LIBS=ON \
      -DBUILD_SHARED_LIBS=OFF -DBUILD_TESTING=OFF -DWITH_WINPR_TOOLS=OFF \
      -DCMAKE_INTERPROCEDURAL_OPTIMIZATION=OFF \
      -DWITH_CLIENT=OFF -DWITH_CLIENT_COMMON=ON -DWITH_CLIENT_CHANNELS=ON \
      -DWITH_SERVER=OFF -DWITH_SERVER_CHANNELS=OFF -DWITH_SAMPLE=OFF \
      -DWITH_PROXY=OFF -DWITH_SHADOW=OFF -DWITH_PLATFORM_SERVER=OFF \
      -DWITH_CLIENT_SDL=OFF -DWITH_X11=OFF -DWITH_WAYLAND=OFF -DWITH_CLIENT_MAC=OFF \
      -DWITH_FFMPEG=OFF -DWITH_SWSCALE=OFF -DWITH_DSP_FFMPEG=OFF -DWITH_VIDEO_FFMPEG=OFF \
      -DWITH_OPENH264=OFF -DWITH_JPEG=OFF -DWITH_CAIRO=OFF -DWITH_LAME=OFF \
      -DWITH_FAAD2=OFF -DWITH_FAAC=OFF -DWITH_SOXR=OFF -DWITH_GSM=OFF -DWITH_OPUS=OFF \
      -DWITH_PULSE=OFF -DWITH_OSS=OFF -DWITH_ALSA=OFF -DWITH_MACAUDIO=OFF \
      -DWITH_CUPS=OFF -DWITH_PCSC=OFF -DWITH_SMARTCARD_EMULATE=OFF -DWITH_FUSE=OFF \
      -DWITH_KRB5=OFF -DWITH_AAD=OFF -DWITH_CJSON_REQUIRED=OFF -DWITH_WEBVIEW=OFF \
      -DWITH_MANPAGES=OFF -DWITH_LIBSYSTEMD=OFF -DWITH_UNICODE_BUILTIN=ON \
      -DWITH_INTERNAL_MD4=ON -DWITH_INTERNAL_MD5=ON -DWITH_INTERNAL_RC4=ON \
      -DWITH_ICU=OFF -DWITH_URIPARSER=OFF -DWITH_FDK_AAC=OFF -DWITH_LODEPNG=OFF \
      -DCHANNEL_URBDRC=OFF -DCHANNEL_AUDIN=OFF -DCHANNEL_TSMF=OFF \
      -DCHANNEL_PRINTER=OFF -DCHANNEL_SMARTCARD=OFF -DCHANNEL_PARALLEL=OFF \
      -DCHANNEL_SERIAL=OFF -DCHANNEL_RDPEI=OFF -DCHANNEL_VIDEO=OFF -DCHANNEL_GEOMETRY=OFF \
      -DCHANNEL_RDPECAM=OFF -DCHANNEL_LOCATION=OFF -DCHANNEL_DRIVE=OFF \
      -DCHANNEL_RDPEMSC=OFF -DCHANNEL_ENCOMSP=OFF -DCHANNEL_REMDESK=OFF -DCHANNEL_RAIL=OFF
    cmake --build "$WORK/freerdp-build-$ARCH" -j"$JOBS"
    cmake --install "$WORK/freerdp-build-$ARCH" >/dev/null
  fi

  # One archive per architecture: FreeRDP, its channel and codec pieces, WinPR
  # and OpenSSL, so the plugin links a single library.
  LIBS=()
  while IFS= read -r lib; do LIBS+=("$lib"); done < <(find "$PREFIX/lib" -name '*.a' ! -name 'libwinpr-tools*' | sort)
  libtool -static -no_warning_for_no_symbols -o "$WORK/libfreerdp-all-$ARCH.a" "${LIBS[@]}"
done

lipo -create "$WORK/libfreerdp-all-arm64.a" "$WORK/libfreerdp-all-x86_64.a" -output "$WORK/libfreerdp-all.a"

# Headers are the same for both architectures; flatten them into one tree.
HDR="$WORK/headers"
rm -rf "$HDR" && mkdir -p "$HDR"
cp -R "$WORK/prefix-arm64/include/freerdp3/." "$HDR/"
cp -R "$WORK/prefix-arm64/include/winpr3/." "$HDR/"

rm -rf "$OUT"
xcodebuild -create-xcframework -library "$WORK/libfreerdp-all.a" -headers "$HDR" -output "$OUT"
touch "$STAMP"
echo "Built $OUT"
