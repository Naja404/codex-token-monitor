#!/usr/bin/env bash
# Offline control experiment. Only its own process is stopped; settings are unchanged.
set -euo pipefail
cd "$(dirname "$0")/.."

source scripts/diagnostic-prompts.sh

step '请退出旧 Monitor。这次会打开独立的原生诊断窗口，不读取账号或联网。'
swift build
binary_dir="$(swift build --show-bin-path)"
diagnostic_log="$(mktemp "${TMPDIR:-/tmp}/codex-touchbar-native.XXXXXX")"
printf '\n诊断日志：%s\n' "$diagnostic_log"
CODEX_MONITOR_TOUCHBAR_DEBUG=1 CODEX_MONITOR_TOUCHBAR_PROBE=1 "$binary_dir/CodexTokenMonitor" </dev/null >/dev/null 2> >(
  awk -v logfile="$diagnostic_log" '/^\[DEBUG-touchbar\]/ { print >> logfile; fflush(logfile) }'
) &
monitor_pid=$!
trap 'kill "$monitor_pid" 2>/dev/null || true; wait "$monitor_pid" 2>/dev/null || true' EXIT

capture TEXT '点击诊断窗口里的「1. 测试文字按钮」，保持前台 2 秒。Touch Bar：0=没有测试文字，1=出现测试文字，2=其他情况。'
capture CAT '点击「2. 测试动态小猫」，保持前台 2 秒。Touch Bar：0=没有小猫，1=有动态小猫，2=有小猫但静止。'
capture QUOTA '点击「3. 测试完整额度栏」，保持前台 2 秒。Touch Bar：0=全都没有，1=小猫和两组 70% 示例额度都有，2=只显示一部分。'
printf 'OBSERVATION native_text=%s native_cat=%s native_quota=%s\n' "$TEXT" "$CAT" "$QUOTA" >> "$diagnostic_log"
printf '\n对照诊断完成，请把此路径发给我：\n%s\n诊断进程将退出，正常启动方式不变。\n' "$diagnostic_log"
