#!/bin/bash
# SPDX-License-Identifier: MIT
# 用 runner 预装的 rustup 工具链顶替 OpenWrt host 侧 rustc 编译。
#
# 背景：packages feed 的 lang/rust 是 HostBuild 包，默认行为是
#   下载 rustc 源码 → 用 host gcc 自举编一遍 rustc/cargo → 装进 staging_dir/host/bin
# 在 4 核 runner 上这一趟 30~60 分钟，且产物同样只服务于 host。
# 做法：把 Host/Prepare、Host/Configure 清空、PKG_SOURCE 置空（不下载源码），
# Host/Compile 只打一行版本，Host/Install 把 runner 的 cargo/rustc/rustdoc 软链进去。
#
# 用法（在源码树根目录执行）：
#   USE_HOST_RUST=true bash scripts/prepare-host-rust.sh [源码树路径]
#
# ⚠ 两个必须：
#   1) 必须在 ./scripts/feeds install -a 之后（要 feeds/packages/lang/rust/Makefile）；
#   2) 必须在 make（编译）之前；放在工具链缓存恢复之后最稳，
#      这样无论缓存里有没有 rustc，本脚本都能保证 host bin 可用。

set -euo pipefail

OPENWRT_DIR="${1:-$PWD}"
cd "$OPENWRT_DIR"

USE_HOST_RUST="${USE_HOST_RUST:-true}"
STRICT_HOST_RUST="${STRICT_HOST_RUST:-false}"   # true = rustup 缺失直接失败，不再回退源码编译

if [ "$USE_HOST_RUST" != "true" ]; then
  echo "USE_HOST_RUST != true，跳过（走 feed 自带的 rustc 源码编译）"
  exit 0
fi

REPORT_DIR="${GITHUB_WORKSPACE:-$PWD}/build-reports"
mkdir -p "$REPORT_DIR"

# ---------------------------------------------------------------
# 1. 找 rust feed
# ---------------------------------------------------------------
RUST_FEED="$PWD/feeds/packages/lang/rust"
RUST_MAKEFILE="$RUST_FEED/Makefile"
if [ ! -f "$RUST_MAKEFILE" ]; then
  echo "::warning::未找到 $RUST_MAKEFILE，跳过 Rust host 复用（走源码编译）"
  exit 0
fi

# ---------------------------------------------------------------
# 2. 向 feed 询问目标三元组，保证 CI 与 OpenWrt 用同一套映射
# ---------------------------------------------------------------
RUST_TARGET=""
if [ -f "$RUST_FEED/rust-values.mk" ]; then
  RUST_TARGET=$(make --no-print-directory -s -f - TOPDIR="$PWD" ci-rust-target <<'MAKE' 2>/dev/null || true
include $(TOPDIR)/rules.mk
include $(TOPDIR)/feeds/packages/lang/rust/rust-values.mk
.PHONY: ci-rust-target
ci-rust-target:
	@printf '%s\n' '$(RUSTC_TARGET_ARCH)'
MAKE
)
fi
# 兜底：按 OpenWrt 的 arch → musl 三元组推一个
if [ -z "$RUST_TARGET" ] && [ -f .config ]; then
  ARCH=$(sed -n 's/^CONFIG_TARGET_ARCH="\(.*\)"$/\1/p' .config | head -1)
  case "$ARCH" in
    aarch64)  RUST_TARGET=aarch64-unknown-linux-musl ;;
    arm)      RUST_TARGET=armv7-unknown-linux-musleabihf ;;
    mipsel)   RUST_TARGET=mipsel-unknown-linux-musl ;;
    mips)     RUST_TARGET=mips-unknown-linux-musl ;;
    riscv64)  RUST_TARGET=riscv64gc-unknown-linux-musl ;;
    x86_64)   RUST_TARGET=x86_64-unknown-linux-musl ;;
    i386)     RUST_TARGET=i686-unknown-linux-musl ;;
  esac
fi
if [ -z "$RUST_TARGET" ]; then
  echo "::warning::拿不到 RUSTC_TARGET_ARCH，跳过 Rust host 复用（走源码编译）"
  exit 0
fi

# ---------------------------------------------------------------
# 3. 找 rustup
# ---------------------------------------------------------------
RUSTUP_BIN=$(command -v rustup || true)
if [ -z "$RUSTUP_BIN" ]; then
  for candidate in "$HOME/.cargo/bin/rustup" /usr/local/cargo/bin/rustup /usr/bin/rustup; do
    if [ -x "$candidate" ]; then RUSTUP_BIN=$candidate; break; fi
  done
fi
if [ -z "$RUSTUP_BIN" ]; then
  if [ "$STRICT_HOST_RUST" = "true" ]; then
    echo "::error::runner 上没有 rustup，且 STRICT_HOST_RUST=true" >&2
    exit 1
  fi
  echo "::warning::runner 上没有 rustup，跳过 Rust host 复用（走源码编译）"
  exit 0
fi
PATH="$(dirname "$RUSTUP_BIN"):$PATH"
export PATH

RUST_TOOLCHAIN=$(rustup show active-toolchain | awk '{print $1}')
# 没有 default 工具链时挑一个装了的
if [ -z "$RUST_TOOLCHAIN" ] || [ "$RUST_TOOLCHAIN" = "no" ]; then
  RUST_TOOLCHAIN=$(rustup toolchain list | awk '{print $1}' | grep -v system | head -1)
fi
printf 'Rust toolchain: %s\nRust target: %s\n' "$RUST_TOOLCHAIN" "$RUST_TARGET" | tee "$REPORT_DIR/rust-toolchain.txt"

# ---------------------------------------------------------------
# 4. 补齐目标 std（rustup 侧）
# ---------------------------------------------------------------
if ! rustup target add --toolchain "$RUST_TOOLCHAIN" "$RUST_TARGET"; then
  if [ "$STRICT_HOST_RUST" = "true" ]; then echo "::error::rustup target add $RUST_TARGET 失败" >&2; exit 1; fi
  echo "::warning::rustup 装不上 $RUST_TARGET 的 std，回退源码编译"
  exit 0
fi

RUST_ROOT=$(rustup run "$RUST_TOOLCHAIN" rustc --print sysroot)
if [ ! -d "$RUST_ROOT/lib/rustlib/$RUST_TARGET/lib" ]; then
  if [ "$STRICT_HOST_RUST" = "true" ]; then echo "::error::$RUST_ROOT 里没有 $RUST_TARGET 的 std" >&2; exit 1; fi
  echo "::warning::sysroot 缺 $RUST_TARGET/std，回退源码编译"
  exit 0
fi
for tool in cargo rustc rustdoc; do
  if [ ! -x "$RUST_ROOT/bin/$tool" ]; then
    echo "::warning::$RUST_ROOT/bin/$tool 不可用，回退源码编译"
    exit 0
  fi
done

# ---------------------------------------------------------------
# 5. 把预编译逻辑塞进 rust 包的 HostBuild
#    插在 $(eval $(call HostBuild)) 之前，覆盖 Host/Prepare/Compile/Install
# ---------------------------------------------------------------
SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
{
  printf 'CI_RUST_ROOT:=%s\n' "$RUST_ROOT"
  cat "$SCRIPT_DIR/rust-prebuilt.mk"
} > "$RUST_FEED/ci-prebuilt.mk"
# shellcheck disable=SC2016 # 匹配字面的 Make 表达式
sed -i '/^include \.\/ci-prebuilt.mk$/d; /^$(eval $(call HostBuild))$/i include ./ci-prebuilt.mk' "$RUST_MAKEFILE"
if ! grep -Fxq 'include ./ci-prebuilt.mk' "$RUST_MAKEFILE"; then
  echo "::warning::注入 ci-prebuilt.mk 失败（Makefile 里没有 \$(eval \$(call HostBuild)) 这一行），回退源码编译"
  rm -f "$RUST_FEED/ci-prebuilt.mk"
  exit 0
fi

# ---------------------------------------------------------------
# 6. 立刻把 host bin 备好，不等 make
#    工具链缓存命中时 make tools/install 会被跳过，rust 包的 Host/Install
#    也可能因为 stamp 存在而不跑 —— 这里直接落软链，保证任何路径下都在。
#    ⚠ 若缓存里已有「源码编译出来的真 rustc」（普通文件），不要覆盖它，
#      只在本来就是软链（上次由本脚本生成）或缺失时才链接。
# ---------------------------------------------------------------
mkdir -p staging_dir/host/bin
for tool in cargo rustc rustdoc; do
  DST="staging_dir/host/bin/$tool"
  if [ -e "$DST" ] && [ ! -L "$DST" ]; then
    echo "保留缓存中已编译的 $tool（非软链，不覆盖）"
    continue
  fi
  ln -sfn "$RUST_ROOT/bin/$tool" "$DST"
done

"$RUST_ROOT/bin/rustc" --version | tee -a "$REPORT_DIR/rust-toolchain.txt"
echo "Using runner Rust $RUST_TOOLCHAIN for $RUST_TARGET" | tee -a "$REPORT_DIR/rust-toolchain.txt"
sha256sum "$RUST_MAKEFILE" >> "$REPORT_DIR/rust-toolchain.txt"
