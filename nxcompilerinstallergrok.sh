#!/bin/bash
# =============================================
# devkitPro Switch Installer for M4 Pro (v3 - GitHub Fixed)
# =============================================

set -e

echo "=== Nintendo Switch devkitPro Installer for M4 Pro (v3) ==="

# 1. Xcode tools
echo "→ Checking Xcode Command Line Tools..."
xcode-select --install 2>/dev/null || echo "✅ Xcode tools already installed."

# 2. Download from official GitHub
echo "→ Downloading devkitPro pacman installer from GitHub..."
cd ~/Downloads

curl -L -f -o devkitpro-pacman-installer.pkg \
  https://github.com/devkitPro/pacman/releases/download/v6.0.2/devkitpro-pacman-installer.pkg

# Check download
if [ ! -f ~/Downloads/devkitpro-pacman-installer.pkg ]; then
    echo "❌ Download failed! Try downloading manually from:"
    echo "   https://github.com/devkitPro/pacman/releases/latest"
    exit 1
fi
echo "✅ Download complete."

# 3. Install pacman
echo "→ Installing devkitPro pacman..."
sudo installer -pkg ~/Downloads/devkitpro-pacman-installer.pkg -target /

# 4. Install Switch tools
echo "→ Updating packages..."
sudo dkp-pacman -Sy

echo "→ Installing switch-dev (this will take a few minutes)..."
sudo dkp-pacman --noconfirm -S switch-dev

# 5. Environment setup
echo "→ Adding environment variables to ~/.zshrc..."

cat >> ~/.zshrc << 'EOF'

# === devkitPro for Nintendo Switch ===
export DEVKITPRO=/opt/devkitpro
export DEVKITARM=$DEVKITPRO/devkitARM
export DEVKITA64=$DEVKITPRO/devkitA64
export PATH=$PATH:$DEVKITPRO/tools/bin
EOF

echo "→ Done!"

# Final
echo ""
echo "🎉 Installation finished!"
echo "Now **completely close and reopen Terminal**, then test these commands:"
echo ""
echo "   arm-none-eabi-gcc --version"
echo "   aarch64-none-elf-gcc --version"
echo "   echo \$DEVKITPRO"
echo ""
echo "Let me know the output if anything is still broken! ;3"