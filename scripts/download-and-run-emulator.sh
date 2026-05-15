#!/usr/bin/env bash
# ============================================================================
# 本地脚本：下载编译好的镜像并启动模拟器
# 在你的 Mac 上运行此脚本
# ============================================================================

set -euo pipefail

ANDROID_HOME="${ANDROID_HOME:-$HOME/Library/Android/sdk}"
IMAGE_DIR="$ANDROID_HOME/system-images/android-14/opencyvis/arm64-v8a"
AVD_NAME="opencyvis-full"

echo "=== OpenCyvis 模拟器本地部署 ==="
echo ""

# Step 1: 检查镜像文件
ARCHIVE="${1:-$HOME/Downloads/opencyvis-emulator-android14-arm64.tar.gz}"
if [[ ! -f "$ARCHIVE" ]]; then
    echo "错误: 找不到镜像文件: $ARCHIVE"
    echo ""
    echo "用法: $0 [镜像tar.gz路径]"
    echo "默认查找: ~/Downloads/opencyvis-emulator-android14-arm64.tar.gz"
    echo ""
    echo "请先从云服务器下载编译好的镜像文件。"
    exit 1
fi

# Step 2: 解压镜像
echo "[1/3] 解压镜像到 SDK 目录..."
mkdir -p "$IMAGE_DIR"
tar -xzf "$ARCHIVE" -C "$IMAGE_DIR/"

# 创建 package.xml 让 avdmanager 识别
cat > "$IMAGE_DIR/../package.xml" << 'XML'
<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<ns2:repository xmlns:ns2="http://schemas.android.com/repository/android/common/02">
    <localPackage path="system-images;android-14;opencyvis;arm64-v8a">
        <type-details xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance" xsi:type="ns2:sysImgDetailsType">
            <api-level>34</api-level>
            <tag><id>opencyvis</id><display>OpenCyvis</display></tag>
            <abi>arm64-v8a</abi>
        </type-details>
        <revision><major>1</major></revision>
        <display-name>OpenCyvis ARM 64 v8a System Image</display-name>
    </localPackage>
</ns2:repository>
XML

echo "  完成"

# Step 3: 创建 AVD
echo "[2/3] 创建模拟器..."
echo "no" | "$ANDROID_HOME/cmdline-tools/latest/bin/avdmanager" create avd \
    -n "$AVD_NAME" \
    -k "system-images;android-14;opencyvis;arm64-v8a" \
    --force 2>/dev/null

echo "  完成"

# Step 4: 启动
echo "[3/3] 启动模拟器..."
echo ""
echo "  模拟器正在启动，OpenCyvis 已预装为系统应用。"
echo "  启动后直接打开 OpenCyvis 即可使用全部功能（截屏、触控注入等）。"
echo ""

"$ANDROID_HOME/emulator/emulator" -avd "$AVD_NAME" -gpu host &

echo "  模拟器 PID: $!"
echo "  等待启动完成..."

# 等待启动
timeout 120 bash -c "
    while ! $ANDROID_HOME/platform-tools/adb shell getprop sys.boot_completed 2>/dev/null | grep -q 1; do
        sleep 3
    done
" && echo "  启动完成！" || echo "  启动超时，请手动检查模拟器窗口。"

echo ""
echo "=== 完成 ==="
echo "OpenCyvis 已就绪，打开模拟器中的 OpenCyvis 应用即可使用。"
