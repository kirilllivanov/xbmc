#!/usr/bin/env bash
# Use the upstream LLVM release for Android target code while retaining
# NDK r30's Android-specific sysroot, headers and compiler-rt libraries.
set -euo pipefail

: "$ANDROID_HOME"
: "$NDK_VERSION"
: "$LLVM_VERSION"
: "$RUNNER_TEMP"
: "$GITHUB_ENV"
: "$GITHUB_PATH"

NDK_TC="$ANDROID_HOME/ndk/$NDK_VERSION/toolchains/llvm/prebuilt/linux-x86_64"
test -x "$NDK_TC/bin/clang"
test -d "$NDK_TC/sysroot"

LLVM_ROOT="$RUNNER_TEMP/llvm-$LLVM_VERSION"
mkdir -p "$LLVM_ROOT"
ARCHIVE="$RUNNER_TEMP/LLVM-$LLVM_VERSION-Linux-X64.tar.zst"
URL="https://github.com/llvm/llvm-project/releases/download/llvmorg-$LLVM_VERSION/LLVM-$LLVM_VERSION-Linux-X64.tar.zst"

echo "Downloading official LLVM $LLVM_VERSION Linux x86_64 release"
curl --fail --location --retry 5 --retry-all-errors --retry-delay 5 \
  --output "$ARCHIVE" "$URL"

# SHA-256 published in GitHub's llvm/llvm-project release asset metadata.
echo "c3107384835f788768f614db610e87fba7077f125ca950eb02a78bab0a308065  $ARCHIVE" | sha256sum --check -
tar --zstd -xf "$ARCHIVE" -C "$LLVM_ROOT" --strip-components=1
rm -f "$ARCHIVE"

test -x "$LLVM_ROOT/bin/clang"
test -x "$LLVM_ROOT/bin/clang++"
test -x "$LLVM_ROOT/bin/ld.lld"
"$LLVM_ROOT/bin/clang" --version
"$LLVM_ROOT/bin/clang" --version | grep -F "$LLVM_VERSION"

# An upstream LLVM binary lacks Android compiler-rt artifacts. Copy only the
# Android target runtime libraries from the NDK's Clang resource directory.
NDK_RESOURCE_DIR="$("$NDK_TC/bin/clang" -print-resource-dir)"
LLVM_RESOURCE_DIR="$("$LLVM_ROOT/bin/clang" -print-resource-dir)"
test -d "$NDK_RESOURCE_DIR/lib/linux"
test -d "$LLVM_RESOURCE_DIR"
mkdir -p "$LLVM_RESOURCE_DIR/lib/linux"
cp -a -n "$NDK_RESOURCE_DIR/lib/linux/." "$LLVM_RESOURCE_DIR/lib/linux/"
test -f "$LLVM_RESOURCE_DIR/lib/linux/libclang_rt.builtins-aarch64-android.a"

# An overlay keeps the original NDK intact and gives Kodi's ./configure
# and generated CMake Toolchain.cmake a consistent compiler and binutils.
ANDROID_LLVM_TOOLCHAIN="$RUNNER_TEMP/android-llvm-$LLVM_VERSION"
mkdir -p "$ANDROID_LLVM_TOOLCHAIN/bin"
ln -s "$NDK_TC/sysroot" "$ANDROID_LLVM_TOOLCHAIN/sysroot"
ln -s "$NDK_TC/lib" "$ANDROID_LLVM_TOOLCHAIN/lib"
for source in "$NDK_TC/bin/"*; do
  ln -s "$source" "$ANDROID_LLVM_TOOLCHAIN/bin/$(basename "$source")"
done
for name in clang clang++ ld.lld llvm-ar llvm-ranlib llvm-nm llvm-objdump llvm-strip llvm-readelf llvm-objcopy; do
  if test -x "$LLVM_ROOT/bin/$name"; then
    ln -sfn "$LLVM_ROOT/bin/$name" "$ANDROID_LLVM_TOOLCHAIN/bin/$name"
  fi
done

# The NDK's target-specific clang entrypoints must not accidentally use the
# NDK-bundled older Clang. These wrappers force LLVM 23 and API 37.
for entry in clang clang++; do
  target="$ANDROID_LLVM_TOOLCHAIN/bin/aarch64-linux-android37-$entry"
  rm -f "$target"
  if [[ "$entry" == "clang++" ]]; then
    cat > "$target" <<'WRAPPER'
#!/usr/bin/env bash
set -euo pipefail
exec "$LLVM_ROOT/bin/clang++" --target=aarch64-linux-android37 \
  --sysroot="$ANDROID_HOME/ndk/$NDK_VERSION/toolchains/llvm/prebuilt/linux-x86_64/sysroot" \
  -resource-dir="$LLVM_RESOURCE_DIR" -B"$ANDROID_LLVM_TOOLCHAIN/bin" \
  -fuse-ld=lld -stdlib=libc++ "$@"
WRAPPER
  else
    cat > "$target" <<'WRAPPER'
#!/usr/bin/env bash
set -euo pipefail
exec "$LLVM_ROOT/bin/clang" --target=aarch64-linux-android37 \
  --sysroot="$ANDROID_HOME/ndk/$NDK_VERSION/toolchains/llvm/prebuilt/linux-x86_64/sysroot" \
  -resource-dir="$LLVM_RESOURCE_DIR" -B"$ANDROID_LLVM_TOOLCHAIN/bin" \
  -fuse-ld=lld "$@"
WRAPPER
  fi
  chmod +x "$target"
done

export LLVM_ROOT LLVM_RESOURCE_DIR ANDROID_LLVM_TOOLCHAIN
printf 'LLVM_ROOT=%s\nLLVM_RESOURCE_DIR=%s\nANDROID_LLVM_TOOLCHAIN=%s\n' \
  "$LLVM_ROOT" "$LLVM_RESOURCE_DIR" "$ANDROID_LLVM_TOOLCHAIN" >> "$GITHUB_ENV"
echo "$ANDROID_LLVM_TOOLCHAIN/bin" >> "$GITHUB_PATH"

CC="$ANDROID_LLVM_TOOLCHAIN/bin/aarch64-linux-android37-clang"
CXX="$ANDROID_LLVM_TOOLCHAIN/bin/aarch64-linux-android37-clang++"
printf 'int main(void) { return 0; }\n' > "$RUNNER_TEMP/llvm-android-probe.c"
printf '#include <vector>\nint main(){std::vector<int> v{1,2}; return v[0] - 1;}\n' > "$RUNNER_TEMP/llvm-android-probe.cpp"

# Native C1-Pro tuning is mandatory. Do not substitute another CPU.
FLAGS="-march=armv9.3-a+sve2+sme2+nomops+nomemtag -mtune=c1-pro -O3"
"$CC" $FLAGS "$RUNNER_TEMP/llvm-android-probe.c" -o "$RUNNER_TEMP/llvm-android-probe"
"$CXX" $FLAGS "$RUNNER_TEMP/llvm-android-probe.cpp" -o "$RUNNER_TEMP/llvm-android-probe-cpp"
file "$RUNNER_TEMP/llvm-android-probe" "$RUNNER_TEMP/llvm-android-probe-cpp"
"$CC" --version | head -n 2
"$CC" -print-resource-dir
test "$("$CC" -print-resource-dir)" = "$LLVM_RESOURCE_DIR"
"$ANDROID_LLVM_TOOLCHAIN/bin/ld.lld" --version | grep '23.1.5'

{
  echo "### Verified C1-Pro Android LLVM toolchain"
  echo "Clang/LLD: $LLVM_VERSION; NDK: $NDK_VERSION; host: Ubuntu 26.04"
  echo "Target: aarch64-linux-android37; C1-Pro flags: $FLAGS"
  echo "The C and C++ probe were compiled and linked with LLVM $LLVM_VERSION."
  df -h .
} >> "$GITHUB_STEP_SUMMARY"
