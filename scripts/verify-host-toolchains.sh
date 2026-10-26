#!/bin/bash
# SPDX-License-Identifier: MIT
# 工具链缓存恢复后，校验 host 侧 Go / Rust 是否仍然可用。
#
# 为什么需要这一步：
#   staging_dir/host* 是进缓存的（actions/cache + Release 的 .tzst）。
#   用 runner 预装工具链意味着 cargo/rustc/rustdoc 是**软链**，
#   指向 runner 镜像里的 rustup sysroot（如
#   /usr/local/rustup/toolchains/stable-x86_64-unknown-linux-gnu）。
#   tar / actions/cache 都按软链原样保存，于是：
#     - runner 镜像升级、rustup 换路径 → 恢复出来的软链变悬空；
#     - 缓存是在别的镜像 / 自托管 runner 上建的 → 同样悬空。
#   悬空软链的表现是编译 Rust 包时 "/bin/sh: 1: .../host/bin/rustc: not found"（Error 127）。
#
# 处理：发现悬空就删掉，让 prepare-host-rust.sh 重新链接；
#      只有 Go 缺失（runner 没装 go）时给警告，由 feed 自行源码自举。

set -uo pipefail

OPENWRT_DIR="${1:-$PWD}"
cd "$OPENWRT_DIR" || exit 0

BROKEN=0
for tool in cargo rustc rustdoc; do
  LNK="staging_dir/host/bin/$tool"
  [ -L "$LNK" ] || continue
  if [ ! -e "$(readlink -f "$LNK")" ]; then
    echo "::warning::host/bin/$tool 是悬空软链 -> $(readlink "$LNK")，删除以便重新链接"
    rm -f "$LNK"
    BROKEN=1
  fi
done

if [ "$BROKEN" = "1" ]; then
  # 优先就地重跑准备脚本；没找到就提示
  for s in scripts/prepare-host-rust.sh .github/scripts/prepare-host-rust.sh; do
    if [ -f "$s" ]; then
      echo "重新执行 $s"
      bash "$s" "$OPENWRT_DIR"
      break
    fi
  done
fi

# 最终状态输出（不阻断构建）
for tool in go cargo rustc; do
  BIN="staging_dir/host/bin/$tool"
  if [ -e "$BIN" ]; then
    printf '%-6s %s\n' "$tool" "$("$BIN" --version 2>&1 | head -1)"
  else
    echo "::warning::staging_dir/host/bin/$tool 不存在"
  fi
done
