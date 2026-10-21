#!/bin/bash
set -e

# ============================================================================
# LAME 3.100 Build Script for iOS (device + simulator static libraries)
# ============================================================================
# Cross-compiles LAME as a static library for use with FFmpeg's libmp3lame
# encoder on iOS.
#
# Two slices are needed because the iOS app now also builds for the simulator,
# and libmp3lame is linked statically into libavcodec.so:
#
#   device     iphoneos        -> deps/lame-build/      (unchanged)
#   simulator  iphonesimulator -> deps/lame-build-sim/  (only used when FFmpeg's
#                                                      simulator slice is built)
#
# The device slice is produced by exactly the same configure line as before this
# script grew a simulator pass, so existing device builds are unaffected.
#
# Usage:
#   ./build_lame.sh          # device + simulator
#   ./build_lame.sh device   # device only (what CI needs)
#   ./build_lame.sh sim      # simulator only
#   ./build_lame.sh clean
#
# Output:
#   deps/lame-build/lib/libmp3lame.a
#   deps/lame-build/include/lame/lame.h
#   deps/lame-build-sim/lib/libmp3lame.a
#   deps/lame-build-sim/include/lame/lame.h
# ============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LAME_VERSION="3.100"
LAME_TARBALL="lame-${LAME_VERSION}.tar.gz"
LAME_SRC_DIR="$SCRIPT_DIR/lame-${LAME_VERSION}"
LAME_BUILD_DIR="$SCRIPT_DIR/lame-build"
SIM_LAME_BUILD_DIR="$SCRIPT_DIR/lame-build-sim"

IOS_DEPLOYMENT_TARGET="14.0"
SIM_DEPLOYMENT_TARGET="15.0"

# Per-pass flags. The device values are byte-for-byte what this script used
# before the simulator pass existed.
DEVICE_ARCH_FLAGS="-arch arm64 -miphoneos-version-min=$IOS_DEPLOYMENT_TARGET"
DEVICE_BITCODE="-fembed-bitcode"
SIM_ARCH_FLAGS="-target arm64-apple-ios${SIM_DEPLOYMENT_TARGET}-simulator"
SIM_BITCODE=""

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info()    { echo -e "${BLUE}ℹ️  $1${NC}"; }
log_success() { echo -e "${GREEN}✅ $1${NC}"; }
log_error()   { echo -e "${RED}❌ $1${NC}"; exit 1; }

# ============================================================================
# Fetch source
# ============================================================================
fetch_source() {
    if [ ! -d "$LAME_SRC_DIR" ]; then
        log_info "Downloading LAME ${LAME_VERSION}..."
        cd "$SCRIPT_DIR"
        if [ ! -f "$LAME_TARBALL" ]; then
            curl -L -o "$LAME_TARBALL" \
                "https://sourceforge.net/projects/lame/files/lame/${LAME_VERSION}/${LAME_TARBALL}/download"
        fi
        tar xzf "$LAME_TARBALL"
        rm -f "$LAME_TARBALL"
        log_success "LAME source extracted"
    else
        log_info "LAME source already present, skipping download"
    fi
}

# ============================================================================
# Build one slice
# ============================================================================
build_slice() {
    local tag="$1" sdk="$2" arch_flags="$3" bitcode="$4" outdir="$5"
    local sdk_path cc

    sdk_path=$(xcrun --sdk "$sdk" --show-sdk-path)
    cc="$(xcrun --sdk "$sdk" -f clang)"

    log_info "Configuring LAME for $tag ($sdk)..."
    cd "$LAME_SRC_DIR"

    # Autotools does not track CC/CFLAGS as dependencies: without this, a second
    # pass over the same source tree would happily relink the first pass's
    # objects, and the resulting archive would carry the wrong platform tag.
    if [ -f Makefile ]; then
        make distclean >/dev/null 2>&1 || true
    fi

    export CC="$cc"
    export CFLAGS="$arch_flags -isysroot $sdk_path $bitcode -Oz -fPIC -Wno-implicit-function-declaration"
    export LDFLAGS="$arch_flags -isysroot $sdk_path"

    ./configure \
        --prefix="$outdir" \
        --host=aarch64-apple-darwin \
        --disable-shared \
        --enable-static \
        --disable-frontend \
        --disable-decoder \
        --disable-gtktest \
        --with-pic

    log_info "Building LAME ($tag)..."
    make -j$(sysctl -n hw.ncpu)
    make install

    cd "$SCRIPT_DIR"

    if [ -f "$outdir/lib/libmp3lame.a" ]; then
        log_success "LAME ${LAME_VERSION} built successfully ($tag)"
        echo ""
        echo "  Static library: $outdir/lib/libmp3lame.a  ($(du -h "$outdir/lib/libmp3lame.a" | cut -f1))"
        echo "  Headers:        $outdir/include/lame/lame.h"
        echo ""
        file "$outdir/lib/libmp3lame.a"
    else
        log_error "Build failed — $outdir/lib/libmp3lame.a not found"
    fi
}

# ============================================================================
# Main
# ============================================================================
case "${1:-all}" in
    clean)
        log_info "Cleaning LAME build artifacts..."
        rm -rf "$LAME_SRC_DIR" "$LAME_BUILD_DIR" "$SIM_LAME_BUILD_DIR"
        log_success "Clean completed"
        exit 0
        ;;
    all)
        fetch_source
        build_slice "device" iphoneos "$DEVICE_ARCH_FLAGS" "$DEVICE_BITCODE" "$LAME_BUILD_DIR"
        build_slice "simulator" iphonesimulator "$SIM_ARCH_FLAGS" "$SIM_BITCODE" "$SIM_LAME_BUILD_DIR"
        ;;
    device)
        fetch_source
        build_slice "device" iphoneos "$DEVICE_ARCH_FLAGS" "$DEVICE_BITCODE" "$LAME_BUILD_DIR"
        ;;
    sim|simulator)
        fetch_source
        build_slice "simulator" iphonesimulator "$SIM_ARCH_FLAGS" "$SIM_BITCODE" "$SIM_LAME_BUILD_DIR"
        ;;
    *)
        echo "usage: $0 [device|sim|clean]" >&2
        exit 2
        ;;
esac
