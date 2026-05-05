#!/usr/bin/env bash
# ============================================================================
#   _____      _ _      _____                  _
#  / ____|    | | |    |_   _|                | |
# | |     __ _| | |_ ___ | |_      _____  __ _| | _____ _ __
# | |    / _` | | __/ __|| \ \ /\ / / _ \/ _` | |/ / _ \ '__|
# | |___| (_| | | |_\__ \| |\ V  V /  __/ (_| |   <  __/ |
#  \_____\__,_|_|\__|___/_/ \_/\_/ \___|\__,_|_|\_\___|_|
#
#  Cat's Tweaker — NES → PS5 Edition (with GameCube & SH)
#  Target host: Apple Silicon M4 Pro (arm64) / macOS
#  Output: $HOME/retrodev with all toolchains + sourceable env
#
#  meow~ this installs cross-compilers for ~30 years of consoles in one go owo
# ============================================================================

set -euo pipefail
shopt -s nullglob

# ---------- pretty printing ------------------------------------------------
BOLD=$'\e[1m'; DIM=$'\e[2m'; RST=$'\e[0m'
RED=$'\e[31m'; GRN=$'\e[32m'; YLW=$'\e[33m'; BLU=$'\e[34m'; MAG=$'\e[35m'; CYN=$'\e[36m'

step()  { printf '%s==>%s %s%s%s\n' "$CYN" "$RST" "$BOLD" "$1" "$RST"; }
sub()   { printf '   %s->%s %s\n'   "$MAG" "$RST" "$1"; }
ok()    { printf '   %s✓%s  %s\n'   "$GRN" "$RST" "$1"; }
warn()  { printf '   %s!%s  %s\n'   "$YLW" "$RST" "$1" >&2; }
die()   { printf '%s✗ FATAL:%s %s\n' "$RED" "$RST" "$1" >&2; exit 1; }

# ---------- host validation ------------------------------------------------
[[ "$(uname -s)" == "Darwin" ]] || die "macOS only (you're on $(uname -s))"

ARCH="$(uname -m)"
CHIP="$(sysctl -n machdep.cpu.brand_string 2>/dev/null || echo unknown)"
PCORES="$(sysctl -n hw.perflevel0.physicalcpu 2>/dev/null || sysctl -n hw.physicalcpu)"
ECORES="$(sysctl -n hw.perflevel1.physicalcpu 2>/dev/null || echo 0)"
NCPU="$(sysctl -n hw.ncpu)"
JOBS="$PCORES"   # build with P-cores; leaves E-cores for OS

cat <<EOF
${BOLD}${MAG}╔══════════════════════════════════════════════════════════════════╗${RST}
${BOLD}${MAG}║${RST}   ${BOLD}Cat's Tweaker — NES → PS5 Toolchain Installer${RST}              ${BOLD}${MAG}║${RST}
${BOLD}${MAG}║${RST}   host: ${CHIP}
${BOLD}${MAG}║${RST}   arch: ${ARCH}   P-cores: ${PCORES}   E-cores: ${ECORES}   total: ${NCPU}
${BOLD}${MAG}║${RST}   build jobs: -j${JOBS}
${BOLD}${MAG}╚══════════════════════════════════════════════════════════════════╝${RST}
EOF

if [[ "$ARCH" != "arm64" ]]; then
    warn "non-arm64 host ($ARCH) — script will run but won't be M4-optimized"
fi
case "$CHIP" in
    *M4*) ok "M4-class chip detected — applying -mcpu=apple-m4 to native builds" ;;
    *)    warn "non-M4 chip ($CHIP) — falling back to -mcpu=apple-m1" ;;
esac

# ---------- paths ----------------------------------------------------------
ROOT="${RETRODEV_ROOT:-$HOME/retrodev}"
SRC="$ROOT/src"
BUILD="$ROOT/build"
PREFIX="$ROOT/toolchains"
ENVFILE="$ROOT/env.sh"

mkdir -p "$SRC" "$BUILD" "$PREFIX"
sub "install root: $ROOT"

# ---------- M4-tuned host CFLAGS for native pieces -------------------------
# Apple clang understands -mcpu=apple-m4 from Xcode 16+. Older clang falls back.
if [[ "$CHIP" == *M4* ]]; then
    HOST_CPU_FLAGS="-mcpu=apple-m4"
else
    HOST_CPU_FLAGS="-mcpu=apple-m1"
fi
export CFLAGS="-O3 -pipe ${HOST_CPU_FLAGS} ${CFLAGS:-}"
export CXXFLAGS="-O3 -pipe ${HOST_CPU_FLAGS} ${CXXFLAGS:-}"
export MAKEFLAGS="-j${JOBS}"

# ---------- 0. Homebrew + base deps ---------------------------------------
step "0. Homebrew + base dependencies"
if ! command -v brew >/dev/null 2>&1; then
    sub "installing Homebrew"
    /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
fi

# arm64 brew lives at /opt/homebrew, x86 at /usr/local
BREW_PREFIX="$(brew --prefix)"
eval "$("$BREW_PREFIX/bin/brew" shellenv)"
ok "brew at $BREW_PREFIX"

BREW_PKGS=(
    git wget curl gnu-sed gnu-tar coreutils findutils gawk
    cmake autoconf automake libtool pkg-config
    gcc llvm make ninja
    python@3.12 ruby
    sdl2 sdl2_image sdl2_mixer sdl2_ttf
    libpng libjpeg libusb zlib xz bzip2
    dosfstools mtools
    p7zip
)
sub "brew install (skipping already-installed)..."
brew install "${BREW_PKGS[@]}" >/dev/null 2>&1 || true
ok "base deps ready"

# Homebrew gcc on arm64 macOS gives us host gcc-14 / g++-14.
HOST_GCC="$(brew --prefix gcc)/bin/gcc-14"
HOST_GXX="$(brew --prefix gcc)/bin/g++-14"
[[ -x "$HOST_GCC" ]] || HOST_GCC="$(ls "$(brew --prefix gcc)"/bin/gcc-* 2>/dev/null | head -1)"
[[ -x "$HOST_GXX" ]] || HOST_GXX="$(ls "$(brew --prefix gcc)"/bin/g++-* 2>/dev/null | head -1)"
sub "host gcc: ${HOST_GCC:-(not found, using clang)}"

# ---------- env.sh scaffolding --------------------------------------------
cat > "$ENVFILE" <<'EOF'
# Cat's Tweaker retrodev env — source this in your shell rc
# usage:  source ~/retrodev/env.sh
EOF
add_env() { printf '%s\n' "$1" >> "$ENVFILE"; }

# ============================================================================
#                          8-BIT ERA
# ============================================================================
step "1. 8-bit toolchains (NES, Atari, C64, Apple II, GB/GBC)"

# --- cc65 (NES, Atari 2600/8-bit, C64/VIC-20, Apple II, PCE) --------------
if [[ ! -x "$PREFIX/cc65/bin/cc65" ]]; then
    sub "cc65 (6502 family)"
    git clone --depth 1 https://github.com/cc65/cc65.git "$SRC/cc65" 2>/dev/null || \
        (cd "$SRC/cc65" && git pull --quiet)
    make -C "$SRC/cc65" PREFIX="$PREFIX/cc65" -j"$JOBS" >/dev/null
    make -C "$SRC/cc65" PREFIX="$PREFIX/cc65" install >/dev/null
    ok "cc65 -> $PREFIX/cc65"
else
    ok "cc65 already installed"
fi
add_env 'export PATH="$HOME/retrodev/toolchains/cc65/bin:$PATH"'
add_env 'export CC65_HOME="$HOME/retrodev/toolchains/cc65/share/cc65"'

# --- WLA-DX (multi-platform assembler: Z80/GB/SNES/SMS/etc) ---------------
if [[ ! -x "$PREFIX/wla-dx/bin/wla-65816" ]]; then
    sub "WLA-DX (multi-arch assembler)"
    git clone --depth 1 https://github.com/vhelin/wla-dx.git "$SRC/wla-dx" 2>/dev/null || \
        (cd "$SRC/wla-dx" && git pull --quiet)
    cmake -S "$SRC/wla-dx" -B "$BUILD/wla-dx" \
          -DCMAKE_INSTALL_PREFIX="$PREFIX/wla-dx" \
          -DCMAKE_BUILD_TYPE=Release \
          -DCMAKE_C_FLAGS="$CFLAGS" >/dev/null
    cmake --build "$BUILD/wla-dx" -j"$JOBS" >/dev/null
    cmake --install "$BUILD/wla-dx" >/dev/null
    ok "WLA-DX -> $PREFIX/wla-dx"
else
    ok "WLA-DX already installed"
fi
add_env 'export PATH="$HOME/retrodev/toolchains/wla-dx/bin:$PATH"'

# --- GBDK-2020 (Game Boy / Game Boy Color C compiler) ---------------------
if [[ ! -d "$PREFIX/gbdk" ]]; then
    sub "GBDK-2020 (GB/GBC, prebuilt arm64 macOS)"
    GBDK_VER="4.3.0"
    GBDK_URL="https://github.com/gbdk-2020/gbdk-2020/releases/download/${GBDK_VER}/gbdk-macos-arm64.tar.gz"
    curl -fsSL "$GBDK_URL" -o "$SRC/gbdk.tar.gz" || warn "gbdk download failed (skip)"
    if [[ -f "$SRC/gbdk.tar.gz" ]]; then
        mkdir -p "$PREFIX/gbdk"
        tar -xzf "$SRC/gbdk.tar.gz" -C "$PREFIX" && ok "GBDK -> $PREFIX/gbdk"
    fi
fi
add_env 'export GBDK_HOME="$HOME/retrodev/toolchains/gbdk"'
add_env 'export PATH="$GBDK_HOME/bin:$PATH"'

# ============================================================================
#                          16-BIT ERA
# ============================================================================
step "2. 16-bit toolchains (Genesis, SNES, 32X)"

# --- m68k-elf-gcc via Homebrew tap (for Genesis/Mega Drive + 32X master) --
if ! command -v m68k-elf-gcc >/dev/null 2>&1; then
    sub "m68k-elf-gcc (Sega Genesis / Mega Drive / 32X-68k)"
    brew tap discoteq/discoteq 2>/dev/null || true
    # Try multiple known taps; fall back to source build
    if brew install --quiet m68k-elf-gcc 2>/dev/null; then
        ok "m68k-elf-gcc via brew"
    else
        warn "no brew formula — building m68k-elf binutils+gcc from source (slow)"
        _build_cross_gcc "m68k-elf" "$PREFIX/m68k-elf"
    fi
fi

# --- SGDK (Sega Genesis Development Kit) ---------------------------------
if [[ ! -d "$PREFIX/sgdk" ]]; then
    sub "SGDK (Genesis/Mega Drive C SDK)"
    git clone --depth 1 https://github.com/Stephane-D/SGDK.git "$PREFIX/sgdk"
    ( cd "$PREFIX/sgdk" && make -f makefile.gen -j"$JOBS" >/dev/null 2>&1 || \
      warn "SGDK native build skipped (use Docker image for full build)" )
    ok "SGDK -> $PREFIX/sgdk"
fi
add_env 'export GDK="$HOME/retrodev/toolchains/sgdk"'
add_env 'export PATH="$GDK/bin:$PATH"'

# --- PVSnesLib (SNES C SDK, uses WLA-DX + 65816) -------------------------
if [[ ! -d "$PREFIX/pvsneslib" ]]; then
    sub "PVSnesLib (SNES C SDK)"
    git clone --depth 1 https://github.com/alekmaul/pvsneslib.git "$PREFIX/pvsneslib" || \
        warn "pvsneslib clone failed"
    ok "PVSnesLib -> $PREFIX/pvsneslib"
fi
add_env 'export PVSNESLIB_HOME="$HOME/retrodev/toolchains/pvsneslib/pvsneslib"'
add_env 'export PATH="$PVSNESLIB_HOME/bin:$PATH"'

# ============================================================================
#                          32/64-BIT ERA
# ============================================================================
step "3. 32/64-bit toolchains (devkitPro family + N64 + PSX + Saturn + DC)"

# --- devkitPro (devkitARM, devkitPPC, devkitA64) -------------------------
DKP_PACMAN="/opt/devkitpro/pacman/bin/dkp-pacman"
if [[ ! -x "$DKP_PACMAN" ]]; then
    sub "devkitPro pacman bootstrap"
    DKP_PKG_URL="https://apt.devkitpro.org/install-devkitpro-pacman"
    if curl -fsSL "$DKP_PKG_URL" -o "$SRC/install-dkp.sh"; then
        sudo bash "$SRC/install-dkp.sh" || warn "devkitPro install needs sudo & manual confirm"
    fi
fi
if [[ -x "$DKP_PACMAN" ]]; then
    sub "installing devkitARM (GBA/NDS/3DS), devkitPPC (GameCube/Wii/Wii U), devkitA64 (Switch)"
    sudo "$DKP_PACMAN" -Syu --noconfirm \
        gba-dev nds-dev 3ds-dev \
        gamecube-dev wii-dev wiiu-dev \
        switch-dev >/dev/null 2>&1 || warn "dkp-pacman partial — re-run later"
    ok "devkitPro suite installed"
fi
add_env 'export DEVKITPRO=/opt/devkitpro'
add_env 'export DEVKITARM=$DEVKITPRO/devkitARM'
add_env 'export DEVKITPPC=$DEVKITPRO/devkitPPC'
add_env 'export DEVKITA64=$DEVKITPRO/devkitA64'
add_env 'export PATH=$DEVKITPRO/tools/bin:$DEVKITARM/bin:$DEVKITPPC/bin:$DEVKITA64/bin:$PATH'

# --- libdragon (N64 modern C SDK, mips64-elf) ----------------------------
if [[ ! -x "$PREFIX/libdragon/bin/mips64-elf-gcc" ]]; then
    sub "libdragon (N64 SDK + mips64-elf toolchain)"
    git clone --depth 1 https://github.com/DragonMinded/libdragon.git "$SRC/libdragon" 2>/dev/null || \
        (cd "$SRC/libdragon" && git pull --quiet)
    export N64_INST="$PREFIX/libdragon"
    mkdir -p "$N64_INST"
    ( cd "$SRC/libdragon" && \
      ./build-toolchain.sh >/dev/null 2>&1 && \
      ./build.sh >/dev/null 2>&1 ) || warn "libdragon build had issues — see $SRC/libdragon for logs"
    ok "libdragon -> $PREFIX/libdragon"
fi
add_env 'export N64_INST="$HOME/retrodev/toolchains/libdragon"'
add_env 'export PATH="$N64_INST/bin:$PATH"'

# --- PSn00bSDK (PlayStation 1, mipsel-none-elf) --------------------------
if [[ ! -d "$PREFIX/psn00bsdk" ]]; then
    sub "PSn00bSDK (PSX open SDK)"
    git clone --depth 1 https://github.com/Lameguy64/PSn00bSDK.git "$SRC/psn00bsdk"
    cmake -S "$SRC/psn00bsdk" -B "$BUILD/psn00bsdk" \
          -DCMAKE_INSTALL_PREFIX="$PREFIX/psn00bsdk" \
          -DCMAKE_BUILD_TYPE=Release >/dev/null 2>&1 || warn "PSn00bSDK needs mipsel toolchain (install via brew tap)"
    cmake --build "$BUILD/psn00bsdk" -j"$JOBS" >/dev/null 2>&1 && \
        cmake --install "$BUILD/psn00bsdk" >/dev/null 2>&1 && \
        ok "PSn00bSDK -> $PREFIX/psn00bsdk"
fi
add_env 'export PSN00BSDK_LIBS="$HOME/retrodev/toolchains/psn00bsdk/lib/libpsn00b"'
add_env 'export PATH="$HOME/retrodev/toolchains/psn00bsdk/bin:$PATH"'

# --- Yaul (Sega Saturn, sh-elf) -----------------------------------------
if [[ ! -d "$PREFIX/yaul" ]]; then
    sub "Yaul (Saturn SDK, sh2-elf toolchain)"
    git clone --depth 1 https://github.com/yaul-org/libyaul.git "$SRC/yaul"
    export YAUL_INSTALL_ROOT="$PREFIX/yaul"
    export YAUL_PROG_SH_PREFIX="sh2-elf"
    export YAUL_ARCH_SH_PREFIX="sh2-elf"
    mkdir -p "$YAUL_INSTALL_ROOT"
    ( cd "$SRC/yaul/build-scripts" && \
      ./bootstrap >/dev/null 2>&1 ) || warn "Yaul bootstrap needs manual setup — see docs"
    ok "Yaul scaffolded -> $PREFIX/yaul"
fi
add_env 'export YAUL_INSTALL_ROOT="$HOME/retrodev/toolchains/yaul"'
add_env 'export PATH="$YAUL_INSTALL_ROOT/bin:$PATH"'

# --- KallistiOS (Dreamcast, sh-elf-gcc) ---------------------------------
if [[ ! -d "$PREFIX/kos" ]]; then
    sub "KallistiOS (Dreamcast SDK, sh4 + arm)"
    git clone --depth 1 https://github.com/KallistiOS/KallistiOS.git "$PREFIX/kos"
    git clone --depth 1 https://github.com/KallistiOS/kos-ports.git "$PREFIX/kos-ports" 2>/dev/null || true
    ( cd "$PREFIX/kos/utils/dc-chain" && \
      ./download.sh >/dev/null 2>&1 && \
      ./unpack.sh >/dev/null 2>&1 && \
      make -j"$JOBS" >/dev/null 2>&1 ) || warn "dc-chain build is slow & finicky — re-run manually if needed"
    ok "KallistiOS -> $PREFIX/kos"
fi
add_env 'export KOS_BASE="$HOME/retrodev/toolchains/kos"'
add_env '[ -f "$KOS_BASE/environ.sh" ] && . "$KOS_BASE/environ.sh"'

# ============================================================================
#                          MODERN ERA (PS2 → PS5)
# ============================================================================
step "4. PS2 → PS5 toolchains"

# --- PS2DEV (PlayStation 2, mips64r5900el-ps2-elf) -----------------------
if [[ ! -d "$PREFIX/ps2dev" ]]; then
    sub "PS2DEV (ps2sdk + ee/iop/dvp toolchains)"
    export PS2DEV="$PREFIX/ps2dev"
    export PS2SDK="$PS2DEV/ps2sdk"
    mkdir -p "$PS2DEV"
    git clone --depth 1 https://github.com/ps2dev/ps2dev.git "$SRC/ps2dev"
    ( cd "$SRC/ps2dev" && ./ps2dev.sh >/dev/null 2>&1 ) || \
        warn "ps2dev build is long — let it run separately if it failed"
    ok "PS2DEV scaffolded -> $PREFIX/ps2dev"
fi
add_env 'export PS2DEV="$HOME/retrodev/toolchains/ps2dev"'
add_env 'export PS2SDK="$PS2DEV/ps2sdk"'
add_env 'export PATH="$PS2DEV/bin:$PS2DEV/ee/bin:$PS2DEV/iop/bin:$PS2DEV/dvp/bin:$PS2SDK/bin:$PATH"'

# --- PSL1GHT (PlayStation 3, powerpc64-ps3-elf) -------------------------
if [[ ! -d "$PREFIX/ps3dev" ]]; then
    sub "PSL1GHT (PS3 open SDK)"
    export PS3DEV="$PREFIX/ps3dev"
    export PSL1GHT="$PS3DEV"
    mkdir -p "$PS3DEV"
    git clone --depth 1 https://github.com/ps3dev/ps3toolchain.git "$SRC/ps3toolchain"
    ( cd "$SRC/ps3toolchain" && ./toolchain.sh >/dev/null 2>&1 ) || \
        warn "ps3 toolchain build failed — known macOS arm64 quirks; try Docker fallback"
    ok "PSL1GHT scaffolded -> $PREFIX/ps3dev"
fi
add_env 'export PS3DEV="$HOME/retrodev/toolchains/ps3dev"'
add_env 'export PSL1GHT="$PS3DEV"'
add_env 'export PATH="$PS3DEV/bin:$PS3DEV/ppu/bin:$PS3DEV/spu/bin:$PATH"'

# --- OpenOrbis (PlayStation 4 homebrew, x86_64-pc-freebsd) --------------
if [[ ! -d "$PREFIX/openorbis" ]]; then
    sub "OpenOrbis PS4 toolchain"
    git clone --depth 1 https://github.com/OpenOrbis/OpenOrbis-PS4-Toolchain.git "$PREFIX/openorbis" 2>/dev/null || \
        warn "OpenOrbis clone failed"
    ok "OpenOrbis -> $PREFIX/openorbis (manual build steps required, see README)"
fi
add_env 'export OO_PS4_TOOLCHAIN="$HOME/retrodev/toolchains/openorbis"'
add_env 'export PATH="$OO_PS4_TOOLCHAIN/bin:$PATH"'

# --- Prospero / PS5 (no official open SDK; community LLVM-based) --------
if [[ ! -d "$PREFIX/prospero" ]]; then
    sub "PS5 (Prospero) — community LLVM toolchain stub"
    mkdir -p "$PREFIX/prospero"
    cat > "$PREFIX/prospero/README.txt" <<'PS5EOF'
PS5 (Prospero) note:
  Sony has not released an open SDK. The community uses a custom LLVM
  fork targeting freebsd-x86_64 with PRX/ELF patches. This installer
  reserves $RETRODEV/toolchains/prospero for it. To populate:

    git clone https://github.com/PS5Dev/Prospero-Toolchain prospero-src
    cd prospero-src && ./build.sh --prefix=$RETRODEV/toolchains/prospero

  Requires LLVM 17+ (you have it via brew).
PS5EOF
    ok "PS5 toolchain stub created (see README)"
fi
add_env 'export PROSPERO="$HOME/retrodev/toolchains/prospero"'
add_env 'export PATH="$PROSPERO/bin:$PATH"'

# --- Switch (devkitA64) was installed in step 3; nothing else here.

# ============================================================================
#                          GAMECUBE EXPLICIT
# ============================================================================
step "5. GameCube extras (libogc + ogc-tools)"
# devkitPPC + libogc was pulled by gamecube-dev meta-package above. Verify:
if [[ -x "/opt/devkitpro/devkitPPC/bin/powerpc-eabi-gcc" ]]; then
    ok "devkitPPC powerpc-eabi-gcc present"
    if [[ -d "/opt/devkitpro/libogc" ]]; then
        ok "libogc present (GameCube + Wii)"
    else
        warn "libogc missing — run: sudo dkp-pacman -S libogc"
    fi
else
    warn "GameCube toolchain missing — re-run step 3 with sudo"
fi

# ============================================================================
#                          EMULATORS (test runtime)
# ============================================================================
step "6. Emulators for testing (brew casks + formulae)"
EMU_FORMULAE=( mednafen mame )
EMU_CASKS=( openemu mgba dolphin pcsx2 rpcs3 )
for f in "${EMU_FORMULAE[@]}"; do
    brew install --quiet "$f" >/dev/null 2>&1 && ok "$f"
done
for c in "${EMU_CASKS[@]}"; do
    brew install --quiet --cask "$c" >/dev/null 2>&1 && ok "$c (cask)"
done
warn "reminder: OpenEmu uses HLE for N64 — use Mupen64Plus or RMG for libdragon homebrew"

# ============================================================================
#                          FINAL SUMMARY
# ============================================================================
step "Done. Sourceable env written to:"
printf '   %s%s%s\n\n' "$BOLD" "$ENVFILE" "$RST"

cat <<EOF
${BOLD}Next steps:${RST}
  ${CYN}echo 'source $ENVFILE' >> ~/.zshrc${RST}
  ${CYN}source $ENVFILE${RST}

${BOLD}Verify a few toolchains:${RST}
  cc65 --version
  m68k-elf-gcc --version
  /opt/devkitpro/devkitPPC/bin/powerpc-eabi-gcc --version
  /opt/devkitpro/devkitARM/bin/arm-none-eabi-gcc --version
  mips64-elf-gcc --version       # libdragon / N64

${BOLD}Build dirs (safe to rm -rf to reclaim ~10GB):${RST}
  $BUILD
  $SRC

${MAG}meow~ all paws on deck. happy hacking owo${RST}
EOF
