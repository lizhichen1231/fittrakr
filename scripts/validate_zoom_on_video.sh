#!/bin/bash
# 真实视频 → ZoomController 验证 一键入口
#
#   自检（先跑）：  bash scripts/validate_zoom_on_video.sh <video> --probe
#                   → 生成「摆正后画面 + 检测框」自检图，肉眼确认人正立、框套人身、框是竖高方向
#   全量验证：      bash scripts/validate_zoom_on_video.sh <video>
#                   → 提取 heightRatio CSV → 编译并回放真实 ZoomController → 打印指标 + 导出回放序列
#
# 不修改 ZoomController 任何参数；maxZoom 默认 3.0（= App fitness 预设运行时配置）。

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

VIDEO="${1:-}"
MODE="${2:-}"
[ -z "$VIDEO" ] && { echo "用法: $0 <video> [--probe]"; exit 2; }
[ -f "$VIDEO" ] || { echo "❌ 找不到视频: $VIDEO"; exit 2; }

HR_CSV=/tmp/ft_hr.csv
ZOOM_CSV=/tmp/ft_zoom_out.csv
BIN=/tmp/ft_zoom_replay
ZC="$ROOT/FitTrackr.1/Services/Tracking/ZoomController.swift"

if [ "$MODE" = "--probe" ]; then
  swift "$SCRIPT_DIR/video_to_heightratio.swift" "$VIDEO" "$HR_CSV" --probe-only
  echo "→ 自检图: ${HR_CSV}.probe.png"
  echo "  肉眼确认【人正立 / 红框套在人身上 / 框是竖高方向】无误后，去掉 --probe 跑全量。"
  exit 0
fi

echo "[1/3] 提取 heightRatio ..."
swift "$SCRIPT_DIR/video_to_heightratio.swift" "$VIDEO" "$HR_CSV"
echo "[2/3] 编译 zoom_replay（与真实 ZoomController.swift 一起编译）..."
xcrun --sdk macosx swiftc "$SCRIPT_DIR/zoom_replay.swift" "$ZC" -o "$BIN"
echo "[3/3] 回放 + 指标 ..."
"$BIN" "$HR_CSV" "$ZOOM_CSV"
echo ""
echo "自检图: ${HR_CSV}.probe.png    回放序列(可导入表格画图): $ZOOM_CSV"
