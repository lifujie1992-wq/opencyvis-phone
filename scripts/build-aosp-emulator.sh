#!/usr/bin/env bash
# ============================================================================
# OpenCyvis AOSP 模拟器镜像一键编译脚本
#
# 目标平台：腾ntu 22.04, 32核 64GB, 500GB SSD)
# 编译目标：Android 14 (AOSP android-14.0.0_r75) + OpenCyvis 预装
# 预计耗时：2-4 小时（含源码下载）
# 产物：模拟器镜像 tar 包（~2GB），下载到本地即可使用
# ============================================================================

set -euo pipefail

# ======================== 配置区 ========================
AOSP_BRANCH="android-14.0.0_r75"
AOSP_DIR="$HOME/aosp"
LUNCH_TARGET="sdk_phone64_arm64-userdebug"
OPENCYVIS_REPO="https://github.com/lifujie1992-wq/opencyvis-phone.git"
OUTPUT_DIR="$HOME/aosp-output"
JOBS=$(nproc)
# ========================================================

log() { echo -e "\n\033[1;32m[$(date '+%H:%M:%S')] $1\033[0m"; }
err() { echo -e "\n\033[1;31m[ERROR] $1\033[0m" >&2; exit 1; }

# ======================== Step 0: 系统检查 ========================
log "Step 0: 检查系统环境..."

if [[ "$(uname)" != "Linux" ]]; then
    err "此脚本仅支持 Linux (Ubuntu 22.04)"
fi

TOTAL_MEM_GB=$(free -g | awk '/^Mem:/{print $2}')
AVAIL_DISK_GB=$(df -BG "$HOME" | tail -1 | awk '{print int($4)}')

echo "  内存: ${TOTAL_MEM_GB}GB"
echo "  可用磁盘: ${AVAIL_DISK_GB}GB"
echo "  CPU 核心: $JOBS"

if [[ $TOTAL_MEM_GB -lt 14 ]]; then
    err "内存不足 16GB，无法编译 AOSP"
fi
if [[ $AVAIL_DISK_GB -lt 180 ]]; then
    err "磁盘空间不足 200GB，无法编译 AOSP"
fi

# ======================== Step 1: 安装依赖 ========================
log "Step 1: 安装编译依赖..."

sudo apt-get update -qq
sudo apt-get install -y -qq \
    git-core gnupg flex bison build-essential zip curl zlib1g-dev \
    libc6-dev-i386 x11proto-core-dev libx11-dev lib32z1-dev \
    libgl1-mesa-dev libxml2-utils xsltproc unzip fontconfig \
    python3 python3-pip openjdk-17-jdk wget bc lz4 libncurses5 2>/dev/null || true

# 确保 repo 可用
if ! command -v repo &>/dev/null; then
    sudo curl -s https://storage.googleapis.com/git-repo-downloads/repo -o /usr/local/bin/repo
    sudo chmod a+x /usr/local/bin/repo
fi

export JAVA_HOME="/usr/lib/jvm/java-17-openjdk-amd64"
export PATH="$JAVA_HOME/bin:$PATH"

# ======================== Step 2: 下载 AOSP 源码 ========================
log "Step 2: 初始化 AOSP 源码仓库 (分支: $AOSP_BRANCH)..."
log "  这一步需要下载约 100GB，预计 30-60 分钟..."

mkdir -p "$AOSP_DIR"
cd "$AOSP_DIR"

if [[ ! -d ".repo" ]]; then
    git config --global user.email "build@opencyvis.ai"
    git config --global user.name "OpenCyvis Builder"
    git config --global color.ui false

    repo init -u https://android.googlesource.com/platform/manifest \
        -b "$AOSP_BRANCH" --depth=1 --partial-clone --clone-filter=blob:limit=10M
fi

log "  开始同步源码..."
repo sync -c -j"$JOBS" --no-tags --no-clone-bundle --optimized-fetch

# ======================== Step 3: 集成 OpenCyvis ========================
log "Step 3: 集成 OpenCyvis 到 AOSP..."

OPENCYVIS_APP_DIR="$AOSP_DIR/packages/apps/OpenCyvis"
mkdir -p "$OPENCYVIS_APP_DIR"

# 克隆 OpenCyvis 仓库获取集成文件
OPENCYVIS_TMP="$HOME/opencyvis-phone"
if [[ ! -d "$OPENCYVIS_TMP" ]]; then
    git clone --depth=1 "$OPENCYVIS_REPO" "$OPENCYVIS_TMP"
fi

# 复制 AOSP 集成文件
cp "$OPENCYVIS_TMP/aosp-integration/OpenCyvis/Android.bp" "$OPENCYVIS_APP_DIR/"
cp "$OPENCYVIS_TMP/aosp-integration/OpenCyvis/privapp-permissions-opencyvis.xml" "$OPENCYVIS_APP_DIR/"

# 编译 OpenCyvis APK
log "  编译 OpenCyvis APK..."
cd "$OPENCYVIS_TMP/android"
export ANDROID_HOME="$HOME/android-sdk"
if [[ ! -d "$ANDROID_HOME" ]]; then
    mkdir -p "$ANDROID_HOME"
    CMDLINE_TOOLS_URL="https://dl.google.com/android/repository/commandlinetools-linux-11076708_latest.zip"
    wget -q "$CMDLINE_TOOLS_URL" -O /tmp/cmdline-tools.zip
    unzip -q /tmp/cmdline-tools.zip -d "$ANDROID_HOME/cmdline-tools-tmp"
    mkdir -p "$ANDROID_HOME/cmdline-tools/latest"
    mv "$ANDROID_HOME/cmdline-tools-tmp/cmdline-tools/"* "$ANDROID_HOME/cmdline-tools/latest/"
    rm -rf "$ANDROID_HOME/cmdline-tools-tmp" /tmp/cmdline-tools.zip
    yes | "$ANDROID_HOME/cmdline-tools/latest/bin/sdkmanager" \
        "platforms;android-34" "build-tools;34.0.0" "platform-tools" 2>/dev/null || true
fi
export PATH="$ANDROID_HOME/cmdline-tools/latest/bin:$ANDROID_HOME/platform-tools:$PATH"

./gradlew assembleRelease -q 2>/dev/null || ./gradlew assembleDebug -q

# 复制 APK 到 AOSP 集成目录
APK_PATH=$(find "$OPENCYVIS_TMP/android/app/build/outputs/apk" -name "*.apk" | head -1)
cp "$APK_PATH" "$OPENCYVIS_APP_DIR/OpenCyvis.apk"

log "  APK 已复制到 $OPENCYVIS_APP_DIR/OpenCyvis.apk"

# ======================== Step 4: 修改 device makefile ========================
log "Step 4: 修改设备配置，添加 OpenCyvis..."

cd "$AOSP_DIR"

# 找到 emulator 的 device makefile 并添加 OpenCyvis
DEVICE_MK="$AOSP_DIR/device/generic/car/common/car.mk"
EMU_MK=""

# Android 14 emulator makefile 位置
for candidate in \
    "build/make/target/product/sdk_phone64_arm64.mk" \
    "build/make/target/product/sdk_phone_arm64.mk" \
    "device/generic/goldfish/64bitonly/product/sdk_phone64_arm64.mk"; do
    if [[ -f "$AOSP_DIR/$candidate" ]]; then
        EMU_MK="$AOSP_DIR/$candidate"
        break
    fi
done

if [[ -z "$EMU_MK" ]]; then
    # 如果找不到特定文件，用通用方式：创建一个 overlay makefile
    EMU_MK="$AOSP_DIR/device/generic/goldfish/opencyvis.mk"
    cat > "$EMU_MK" << 'MKEOF'
# OpenCyvis integration
PRODUCT_PACKAGES += OpenCyvis

PRODUCT_COPY_FILES += \
    packages/apps/OpenCyvis/privapp-permissions-opencyvis.xml:$(TARGET_COPY_OUT_SYSTEM_EXT)/etc/permissions/privapp-permissions-opencyvis.xml
MKEOF
    # Include it from the main product makefile
    MAIN_MK=$(find "$AOSP_DIR/build/make/target/product" -name "sdk_phone64_arm64.mk" 2>/dev/null | head -1)
    if [[ -n "$MAIN_MK" ]]; then
        echo '-include device/generic/goldfish/opencyvis.mk' >> "$MAIN_MK"
    fi
else
    # 直接追加到已有 makefile
    if ! grep -q "OpenCyvis" "$EMU_MK"; then
        cat >> "$EMU_MK" << 'MKEOF'

# OpenCyvis integration
PRODUCT_PACKAGES += OpenCyvis

PRODUCT_COPY_FILES += \
    packages/apps/OpenCyvis/privapp-permissions-opencyvis.xml:$(TARGET_COPY_OUT_SYSTEM_EXT)/etc/permissions/privapp-permissions-opencyvis.xml
MKEOF
    fi
fi

log "  设备配置已更新"

# ======================== Step 5: 编译 AOSP ========================
log "Step 5: 开始编译 AOSP (目标: $LUNCH_TARGET)..."
log "  使用 $JOBS 个并行任务，预计 1.5-3 小时..."

cd "$AOSP_DIR"
source build/envsetup.sh
lunch "$LUNCH_TARGET"

# 开始编译
m -j"$JOBS" 2>&1 | tee "$HOME/aosp-build.log" | grep -E "^\[|^####|Install:|Error:" || true

BUILD_EXIT=${PIPESTATUS[0]}
if [[ $BUILD_EXIT -ne 0 ]]; then
    err "AOSP 编译失败！查看日志: $HOME/aosp-build.log"
fi

# ======================== Step 6: 打包模拟器镜像 ========================
log "Step 6: 打包模拟器镜像..."

mkdir -p "$OUTPUT_DIR"

# 模拟器镜像文件位置
IMG_DIR="$AOSP_DIR/out/target/product/emulator64_arm64"
if [[ ! -d "$IMG_DIR" ]]; then
    IMG_DIR=$(find "$AOSP_DIR/out/target/product" -maxdepth 1 -type d | grep -v "^$AOSP_DIR/out/target/product$" | head -1)
fi

if [[ -z "$IMG_DIR" || ! -d "$IMG_DIR" ]]; then
    err "找不到编译产物目录"
fi

log "  产物目录: $IMG_DIR"

# 打包需要的文件
ARCHIVE="$OUTPUT_DIR/opencyvis-emulator-android14-arm64.tar.gz"
tar -czf "$ARCHIVE" -C "$IMG_DIR" \
    system.img \
    system_ext.img \
    vendor.img \
    userdata.img \
    ramdisk.img \
    kernel-ranchu \
    encryptionkey.img \
    VerifiedBootParams.textproto \
    advancedFeatures.ini \
    build.prop \
    2>/dev/null || true

# 如果上面的文件列表不完整，打包所有 .img 文件
if [[ ! -f "$ARCHIVE" ]] || [[ $(stat -c%s "$ARCHIVE" 2>/dev/null || echo 0) -lt 1000000 ]]; then
    tar -czf "$ARCHIVE" -C "$IMG_DIR" $(ls "$IMG_DIR"/*.img "$IMG_DIR"/kernel* "$IMG_DIR"/*.prop "$IMG_DIR"/*.ini "$IMG_DIR"/*.textproto 2>/dev/null | xargs -I{} basename {})
fi

ARCHIVE_SIZE=$(du -h "$ARCHIVE" | cut -f1)

log "=========================================="
log "编译完成！"
log "=========================================="
echo ""
echo "  镜像文件: $ARCHIVE"
echo "  文件大小: $ARCHIVE_SIZE"
echo ""
echo "  下载到本地后，使用方法："
echo ""
echo "    # 1. 解压到本地 SDK 目录"
echo "    mkdir -p ~/Library/Android/sdk/system-images/android-14/opencyvis/arm64-v8a"
echo "    tar -xzf opencyvis-emulator-android14-arm64.tar.gz \\"
echo "        -C ~/Library/Android/sdk/system-images/android-14/opencyvis/arm64-v8a/"
echo ""
echo "    # 2. 创建模拟器"
echo "    avdmanager create avd -n opencyvis-full \\"
echo "        -k 'system-images;android-14;opencyvis;arm64-v8a'"
echo ""
echo "    # 3. 启动模拟器"
echo "    emulator -avd opencyvis-full"
echo ""
echo "  OpenCyvis 已预装为系统应用，启动后即可使用全部功能。"
echo ""
log "=========================================="
