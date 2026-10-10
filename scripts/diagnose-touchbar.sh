#!/usr/bin/env bash
# Temporary human-in-the-loop diagnostics; no preferences or credentials are changed.
set -euo pipefail
cd "$(dirname "$0")/.."

source scripts/diagnostic-prompts.sh

step '请先退出旧的 Monitor（包括其他终端里的 swift run），避免点到旧进程。'
swift build
binary_dir="$(swift build --show-bin-path)"
diagnostic_log="$(mktemp "${TMPDIR:-/tmp}/codex-touchbar.XXXXXX")"
printf '\n诊断日志：%s\n' "$diagnostic_log"

# Store only our typed diagnostic records, never general application/API output.
CODEX_MONITOR_TOUCHBAR_DEBUG=1 "$binary_dir/CodexTokenMonitor" </dev/null >/dev/null 2> >(
  awk -v logfile="$diagnostic_log" '/^\[DEBUG-touchbar\]/ { print >> logfile; fflush(logfile) }'
) &
monitor_pid=$!
trap 'kill "$monitor_pid" 2>/dev/null || true; wait "$monitor_pid" 2>/dev/null || true' EXIT

capture POPOVER '点击 Monitor 菜单栏，保持弹窗打开 2 秒。Touch Bar：0=只有系统按钮，1=能看到额度和小猫，2=其他情况。'
capture SETTINGS '点击弹窗底部「供应商设置」，保持设置窗口打开 2 秒。Touch Bar：0=只有系统按钮，1=能看到额度和小猫，2=其他情况。'
capture REOPEN '切到其他应用，再点击 Monitor 菜单栏，保持弹窗打开 2 秒。Touch Bar：0=只有系统按钮，1=能看到额度和小猫，2=其他情况。'
printf 'OBSERVATION popover=%s settings=%s reopen=%s\n' "$POPOVER" "$SETTINGS" "$REOPEN" >> "$diagnostic_log"
printf '\n诊断完成；请把这个日志文件发给我：\n%s\n此次诊断进程将退出，正常启动不会开启诊断。\n' "$diagnostic_log"
