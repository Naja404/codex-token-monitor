#!/usr/bin/env bash
# Shared by the two interactive diagnostic scripts; prompts never consume a result as a separate step.
step() {
  printf '\n>>> %s\n' "$1" >&2
  if ! read -r -p '    [准备好后按 Enter] ' _; then
    printf '\n无法读取输入，请在交互式终端中运行脚本。\n' >&2
    return 1
  fi
}

capture() {
  local var="$1" question="$2" answer
  printf '\n>>> %s\n' "$question" >&2
  while true; do
    if ! read -r -p '    [回到此终端，输入 0 / 1 / 2 后按 Enter] ' answer; then
      printf '\n输入已结束，未记录本项结果。\n' >&2
      return 1
    fi
    case "$answer" in
      0|1|2) printf -v "$var" '%s' "$answer"; return 0 ;;
      *) printf '    请输入 0、1 或 2；直接回车不会跳过。\n' >&2 ;;
    esac
  done
}
