#!/bin/sh


SHELL_FOLDER=$(cd "$(dirname "$0")";pwd)
DIST_FOLDER=$SHELL_FOLDER/dist/
if [ ! -d "$DIST_FOLDER" ]; then
  mkdir $DIST_FOLDER
fi
echo $DIST_FOLDER


# ----- Flutter 版本配置（按需修改此处即可）-----
FLUTTER_BIN=flutter
# FLUTTER_BIN=/Users/fred/apps/flutter-3.38.9/bin/flutter
# FLUTTER_BIN=/Users/fred/apps/flutter-3.35.2/bin/flutter
# -------------------------------------------

echo "prod release package for .apk"
echo "$FLUTTER_BIN build apk --dart-define=PACKAGE=prod"

#编译
$FLUTTER_BIN build apk --dart-define=PACKAGE=prod


# 只复制最新的包
LATEST_APK=$(ls -t build/app/outputs/apk/release/*.apk | head -1)
cp "$LATEST_APK" "$DIST_FOLDER"


echo "\n"
# 输出当前 Flutter 版本
echo "======================================"
echo "Flutter path: $FLUTTER_BIN"
echo "Flutter version:"
$FLUTTER_BIN --version | head -3
echo "======================================\n"
# 输出产出物路径
echo "======================================"
echo "Build output copied to: ${DIST_FOLDER}$(basename "$LATEST_APK")"
echo "======================================"
