#!/bin/bash
# SPDX-License-Identifier: MIT
# 用 runner 预装的 Go 作为 OpenWrt host 侧 go-bootstrap，跳过源码自举。
#
# 背景：packages feed 的 lang/golang/golang 默认 CONFIG_GOLANG_BUILD_BOOTSTRAP=y，
# 即先用 Go 1.4/C 编一遍 bootstrap，再拿它编目标版本 —— 在 4 核 runner 上
# 这一趟动辄 20~40 分钟，而且产物只服务于 host，与固件本身无关。
# runner 已预装 Go，直接用 CONFIG_GOLANG_EXTERNAL_BOOTSTRAP_ROOT 指过去即可。
#
# 用法（在源码树根目录执行）：
#   USE_HOST_GO_BOOTSTRAP=true bash scripts/prepare-host-go.sh [源码树路径]
#
# ⚠ 必须在 make defconfig 之前执行：本脚本写的是 .config 符号，
#   写完再 defconfig 才会展开成 golang-values.mk 里的实际变量。

set -euo pipefail

OPENWRT_DIR="${1:-$PWD}"
cd "$OPENWRT_DIR"

USE_HOST_GO_BOOTSTRAP="${USE_HOST_GO_BOOTSTRAP:-true}"
SKIP_PYTHON_PGO="${SKIP_PYTHON_PGO:-true}"

if [ "$USE_HOST_GO_BOOTSTRAP" != "true" ]; then
  echo "USE_HOST_GO_BOOTSTRAP != true，跳过（走 feed 自带的源码自举）"
  exit 0
fi

# 没有 golang feed / 没选任何 Go 包时，写这些符号只会让 defconfig 报无用警告
GOLANG_DIR="$(find feeds -maxdepth 4 -type d -path "*lang/golang*" 2>/dev/null | head -1)"
if [ -z "$GOLANG_DIR" ]; then
  echo "::warning::未找到 feeds/**/lang/golang，跳过 Go host 引导（本机型大概率不含 Go 包）"
  exit 0
fi

if ! grep -rq "GOLANG_BUILD_BOOTSTRAP" "$GOLANG_DIR" 2>/dev/null; then
  echo "::warning::$GOLANG_DIR 里没有 GOLANG_BUILD_BOOTSTRAP 符号（旧版 feed），跳过，走源码自举"
  exit 0
fi

if ! command -v go >/dev/null 2>&1; then
  echo "::warning::runner 上没有 go，跳过，Go 包将走源码自举"
  exit 0
fi

GO_ROOT="$(go env GOROOT)"
if [ ! -x "$GO_ROOT/bin/go" ]; then
  echo "::warning::GOROOT=$GO_ROOT 下没有可执行的 go，跳过"
  exit 0
fi

# 用 runner 的 Go 引导 feed 里 pin 的 host 编译器
sed -i '/^CONFIG_GOLANG_BUILD_BOOTSTRAP=/d; /^# CONFIG_GOLANG_BUILD_BOOTSTRAP is not set$/d; /^CONFIG_GOLANG_EXTERNAL_BOOTSTRAP_ROOT=/d' .config
printf '# CONFIG_GOLANG_BUILD_BOOTSTRAP is not set\nCONFIG_GOLANG_EXTERNAL_BOOTSTRAP_ROOT="%s"\n' "$GO_ROOT" >> .config

# host 侧 Python 只是构建工具，PGO 优化纯属浪费时间（数分钟）
if [ "$SKIP_PYTHON_PGO" = "true" ]; then
  PY_MK="$(find feeds -maxdepth 5 -type f -path "*lang/python/python3/Makefile" 2>/dev/null | head -1)"
  if [ -n "$PY_MK" ]; then
    sed -i '/^HOST_CONFIGURE_ARGS[[:space:]]*+=/,/^$/s/--enable-optimizations/--disable-optimizations/' "$PY_MK"
    echo "host Python PGO: disabled"
  fi
fi

REPORT_DIR="${GITHUB_WORKSPACE:-$PWD}/build-reports"
mkdir -p "$REPORT_DIR"
{
  "$GO_ROOT/bin/go" version
  printf 'Go bootstrap root: %s\n' "$GO_ROOT"
} | tee "$REPORT_DIR/host-go.txt"
