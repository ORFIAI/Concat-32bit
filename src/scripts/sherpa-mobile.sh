#!/usr/bin/env bash
# Fetches the sherpa-onnx runtime libraries for a phone: the shared
# libraries k2-fsa publishes, which the app carries with it.
#
#   scripts/sherpa-mobile.sh aarch64-linux-android [out-dir]
#   scripts/sherpa-mobile.sh armv7-linux-androideabi [out-dir]
#   scripts/sherpa-mobile.sh x86_64-linux-android [out-dir]   (the emulator's, never shipped)
#   scripts/sherpa-mobile.sh aarch64-apple-ios     [out-dir]
#
# The version is the one the lockfile resolved for sherpa-onnx-sys, so a
# bump of the crate cannot desynchronise from the libraries.
#
# Android: vendor/sherpa-onnx/jniLibs/<abi>/*.so, the layout an APK's
# native library directory takes, with the NDK's libc++_shared.so beside
# them because onnxruntime loads it. Point SHERPA_ONNX_LIB_DIR at the ABI
# directory to build, and cargo-apk packages the whole tree through
# concat-android's manifest.
#
# iOS: vendor/sherpa-onnx/ios/sherpa-onnx.xcframework, the framework the
# app bundle embeds; SHERPA_ONNX_LIB_DIR is its device slice.
set -euo pipefail

target=${1:?target triple: aarch64-linux-android, armv7-linux-androideabi, x86_64-linux-android or aarch64-apple-ios}
workspace=$(cd "$(dirname "$0")/.." && pwd)
version=$(grep -A1 'name = "sherpa-onnx-sys"' "$workspace/Cargo.lock" | sed -n 's/^version = "\(.*\)"/\1/p')
[ -n "$version" ] || { echo "could not find sherpa-onnx-sys version in $workspace/Cargo.lock" >&2; exit 1; }
release=https://github.com/k2-fsa/sherpa-onnx/releases/download

case "$target" in
  aarch64-linux-android|armv7-linux-androideabi|x86_64-linux-android)
    out=${2:-$workspace/vendor/sherpa-onnx}
    # Android ABI directory and NDK sysroot library directory differ
    # for ARMv7: Rust uses armv7-linux-androideabi, while the NDK
    # sysroot stores libc++ under arm-linux-androideabi.
    case "$target" in
      aarch64-linux-android)
        abi=arm64-v8a
        sysroot_lib=aarch64-linux-android
        ;;
      armv7-linux-androideabi)
        abi=armeabi-v7a
        sysroot_lib=arm-linux-androideabi
        ;;
      x86_64-linux-android)
        abi=x86_64
        sysroot_lib=x86_64-linux-android
        ;;
    esac
    ndk=${ANDROID_NDK_HOME:-${ANDROID_NDK_ROOT:-}}
    if [ -z "$ndk" ]; then
      sdk=${ANDROID_HOME:-${ANDROID_SDK_ROOT:-$HOME/Library/Android/sdk}}
      ndk=$(ls -d "$sdk"/ndk/* 2>/dev/null | sort -V | tail -1 || true)
    fi
    [ -d "$ndk" ] || { echo "no Android NDK: set ANDROID_NDK_HOME" >&2; exit 1; }
    host_tag=$(ls "$ndk/toolchains/llvm/prebuilt" | head -1)
    [ -n "$host_tag" ] || { echo "no NDK LLVM toolchain found under $ndk" >&2; exit 1; }
    echo "Fetching sherpa-onnx $version for Android ($abi)"
    mkdir -p "$out"
    curl -fsSL --retry 5 --retry-all-errors -o "$out/sherpa-onnx-android.tar.bz2" \
      "$release/v$version/sherpa-onnx-v$version-android.tar.bz2"
    tar -xjf "$out/sherpa-onnx-android.tar.bz2" -C "$out"
    rm "$out/sherpa-onnx-android.tar.bz2"
    [ -d "$out/jniLibs/$abi" ] || {
      echo "sherpa-onnx $version archive does not contain Android ABI $abi" >&2
      exit 1
    }
    # Only the ABI the app is built for ships; the rest is removed.
    find "$out/jniLibs" -mindepth 1 -maxdepth 1 -type d ! -name "$abi" -exec rm -rf {} +
    # The C API and its runtime are what the engine loads; the JNI and
    # C++ bindings are for other languages.
    rm -f "$out/jniLibs/$abi/libsherpa-onnx-jni.so" "$out/jniLibs/$abi/libsherpa-onnx-cxx-api.so"
    libcxx="$ndk/toolchains/llvm/prebuilt/$host_tag/sysroot/usr/lib/$sysroot_lib/libc++_shared.so"
    [ -f "$libcxx" ] || { echo "NDK libc++_shared.so not found: $libcxx" >&2; exit 1; }
    cp "$libcxx" "$out/jniLibs/$abi/"
    echo "sherpa-onnx for Android is in $out/jniLibs"
    echo "  export SHERPA_ONNX_LIB_DIR=$out/jniLibs/$abi"
    ;;
  aarch64-apple-ios)
    out=${2:-$workspace/vendor/sherpa-onnx/ios}
    echo "Fetching sherpa-onnx $version for iOS"
    mkdir -p "$out"
    curl -fsSL --retry 5 --retry-all-errors -o "$out/sherpa-onnx-ios.zip" \
      "$release/xcframework/sherpa-onnx-v$version-ios-shared-onnxruntime-static.xcframework.zip"
    (cd "$out" && unzip -qo sherpa-onnx-ios.zip && rm sherpa-onnx-ios.zip)
    framework=$(find "$out" -maxdepth 2 -name '*.xcframework' | head -1)
    [ -n "$framework" ] || { echo "no xcframework in the archive" >&2; exit 1; }
    binary=$framework/ios-arm64/SherpaOnnxC.framework/SherpaOnnxC
    [ -f "$binary" ] || { echo "no device slice in $framework" >&2; exit 1; }
    # The linker looks for the library by its lib-prefixed name; the
    # framework carries the dylib under the framework's own.
    mkdir -p "$out/lib"
    ln -sf "$binary" "$out/lib/libsherpa-onnx-c-api.dylib"
    echo "sherpa-onnx for iOS is $framework"
    echo "  export SHERPA_ONNX_LIB_DIR=$out/lib"
    ;;
  *)
    echo "unknown target $target" >&2; exit 1 ;;
esac
