@@ -22,36 +22,22 @@ mkdir -p "$PKG_DIR"
# 见 files/sbin/tempinfo（概览页「温度」行：CPU / WiFi / PON 温度 + 光功率）
# ---------------------------------------------------------
ADD_AIROHA_NPU=true    # luci-app-airoha-npu：Airoha SoC 状态页（NPU/CPU/Frame Engine/PPE）
ADD_FLUENT=true       # luci-theme-fluent：Fluent 2 风格主题
ADD_FLUENT_LITE=false  # luci-theme-fluent-lite：轻量版（与 fluent 互斥，二选一）
ADD_FLUENT_DASH=false  # luci-mod-fluentdashboard：可选状态概览卡片
ADD_PASSWALL=false     # luci-app-passwall（含依赖源）
ADD_OPENCLASH=false    # luci-app-openclash ⚠ 依赖 Ruby/Rust，编译极慢
ADD_MOSDNS=false       # luci-app-mosdns + v2ray-geodata
ADD_LUCKY=false        # luci-app-lucky（DDNS + socat）
ADD_TAILSCALE=false    # luci-app-tailscale
ADD_OPENLIST=false     # luci-app-openlist2（alist/openlist 挂载）
ADD_SMARTDNS=false     # luci-app-smartdns
ADD_EASYTIER=false     # luci-app-easytier（另需 kmod-tun + easytier 本体，Rust 编译较慢）
ADD_POWEROFF=false     # luci-app-poweroffdevice（关机）
ADD_OWQ_WOL=false      # luci-app-owq-wol（网络唤醒，依赖 etherwake）
ADD_WATCHDOG=false     # luci-app-watchdog（看门狗，包在子目录，需特殊处理）
ADD_TASKPLAN=false     # luci-app-taskplan（定时任务）
ADD_OAF=false          # luci-app-oaf（应用过滤，含内核模块，高风险）
ADD_LUCI_APP=true       # qwe3017/luci-app 仓库（monorepo）
                        #   ├─ luci-app-natmode     NAT 类型三选一（网络 → NAT 类型）
                        #   └─ luci-app-pon-status  PON 光模块卡片（概览页「系统」下一格）
ADD_FTTR=true           # FTTR 全家桶总开关（下面的子开关都受它管）★仅 HM2004-DU
ADD_FMCS=true           # h3c-fmcs：Micro-OLT FPGA 内核驱动（kmod-h3c-fmcs）
ADD_FTTR_TOOLS=true     # h3c-fttr-tools：fttrd 控制器 + fttrctl（Rust 包）
ADD_FMCS_FW=true        # h3c-fmcs-firmware：FPGA 比特流 FTTR_TOP.sbit
                        # （以上三个都来自 openwrt-fttr feed，bitstream 由驱动加载）

# 这四个包只对 HM2004-DU 有意义：驱动按 @(TARGET_airoha_an7581) 限定了
# target，界面和后端都围着重型 FTTR 主从设备转。workflow 会把 PROFILE
# 导出成环境变量，非 2004 机型直接跳过，不白花 clone 时间；本地手工跑
# （PROFILE 为空）按 2004 处理。
FTTR_PROFILE="${PROFILE:-h3c_hm2004-du}"

clone() {  # clone <url> <dir> [branch]
  local url="$1" dir="$2" br="$3"
@@ -77,6 +63,17 @@ clone() {  # clone <url> <dir> [branch]
#   luci-app/
#   ├── luci-app-natmode/
#   └── luci-app-pon-status/











# =========================================================
if [ "$ADD_LUCI_APP" = "true" ]; then
  LUCI_APP_URL="https://github.com/qwe3017/luci-app"
@@ -100,44 +97,6 @@ if [ "$ADD_LUCI_APP" = "true" ]; then
  rm -rf "$LUCI_APP_TMP"
fi

# =========================================================
# luci-app-fttr —— FTTR 管理界面（网络 → FTTR）★HM2004-DU 专属
#
# 源：LazuliKao/luci-app-fttr（monorepo，包在 package/luci-app-fttr/ 子目录）
#   ⚠ 和 fluent / qwe3017/luci-app 一样是「包在子目录」结构，不能整仓丢进
#     package/custom —— buildroot 扫 package/ 只到 -maxdepth 5，整仓进去
#     会把 src/、package/ 一起扫，包符号还对不上。必须拷子目录。
#
# 依赖（Makefile 里的 LUCI_DEPENDS）：
#   +luci-base +rpcd +ucode +ucode-mod-fs +h3c-fttr-tools
#   前四个 feeds 里有；h3c-fttr-tools（fttrctl 后端 + ucode 运行时）不在
#   ImmortalWrt feeds，也不在 pon_drivers / pon_userspace —— 见下方硬校验。
# =========================================================
if [ "$ADD_FTTR" = "true" ] && [ "$FTTR_PROFILE" = "h3c_hm2004-du" ]; then
  FTTR_TMP="$(mktemp -d)/fttr"
  if ! clone https://github.com/LazuliKao/luci-app-fttr "$FTTR_TMP" main; then
    echo "::error::luci-app-fttr 拉取失败，config 里的 =y 会被 defconfig 剔除"
    exit 1
  fi
  if [ ! -f "$FTTR_TMP/package/luci-app-fttr/Makefile" ]; then
    echo "::error::$FTTR_TMP/package/luci-app-fttr/Makefile 不存在（上游改结构了？）"
    exit 1
  fi

  rm -rf "$PKG_DIR/luci-app-fttr"
  cp -a "$FTTR_TMP/package/luci-app-fttr" "$PKG_DIR/luci-app-fttr"

  # Windows 检出会丢 executable bit，rpcd 插件与 hl202 脚本执行不了 → 页面全空。
  # Makefile 里虽然有 Build/Prepare 的 chmod，这里先在源码树补一道更保险。
  chmod 0755 "$PKG_DIR/luci-app-fttr/root/usr/libexec/fttr-hl202" \
             "$PKG_DIR/luci-app-fttr/root/usr/libexec/rpcd/luci.fttr" 2>/dev/null || true

  # po/zh_Hans 已经是 fttr.po（LUCI_BASENAME 命名），不用像 airoha-npu 那样改名
  echo "✅ 已拷贝: luci-app-fttr (版本 $(grep -m1 '^PKG_VERSION' "$PKG_DIR/luci-app-fttr/Makefile" 2>/dev/null | sed 's/PKG_VERSION:=//'))"
  rm -rf "$FTTR_TMP"
fi


# --- Airoha SoC 状态页（NPU 卸载 / CPU 频率 / Frame Engine / PPE 流表）---
# 包名由目录名决定（luci.mk: PKG_NAME ?= $(notdir ${CURDIR})），
# 目录必须是 luci-app-airoha-npu，否则 config 里的符号对不上。
@@ -184,6 +143,59 @@ if [ "$ADD_AIROHA_NPU" = "true" ]; then
  echo "   po/zh_Hans: $(ls -1 "$PODIR/zh_Hans/" 2>/dev/null | tr '\n' ' ')"
fi






















































# --- passwall ---
if [ "$ADD_PASSWALL" = "true" ]; then
  clone https://github.com/xiaorouji/openwrt-passwall-packages "$PKG_DIR/openwrt-passwall-packages" main
@@ -220,57 +232,12 @@ if [ "$ADD_OPENLIST" = "true" ]; then
  clone https://github.com/sbwml/luci-app-openlist2 "$PKG_DIR/luci-app-openlist2" main
fi


if [ "$ADD_SMARTDNS" = "true" ]; then
  clone https://github.com/pymumu/luci-app-smartdns "$PKG_DIR/luci-app-smartdns" master
  clone https://github.com/pymumu/smartdns "$PKG_DIR/smartdns" master
fi
# --- luci-theme-fluent ---
# ⚠ 包在仓库的 package/ 子目录下，不能直接 clone 到 package/custom，
#   必须把子目录拷出来，否则 buildroot 扫不到 Makefile
if [ "$ADD_FLUENT" = "true" ] || [ "$ADD_FLUENT_LITE" = "true" ] || [ "$ADD_FLUENT_DASH" = "true" ]; then
  FLUENT_TMP="$(mktemp -d)/fluent"
  clone https://github.com/LazuliKao/luci-theme-fluent "$FLUENT_TMP" main

  for p in luci-theme-fluent luci-theme-fluent-lite luci-mod-fluentdashboard; do
    case "$p" in
      luci-theme-fluent)        [ "$ADD_FLUENT" = "true" ] || continue ;;
      luci-theme-fluent-lite)   [ "$ADD_FLUENT_LITE" = "true" ] || continue ;;
      luci-mod-fluentdashboard) [ "$ADD_FLUENT_DASH" = "true" ] || continue ;;
    esac
    [ -d "$FLUENT_TMP/package/$p" ] || { echo "::error::$p 不存在"; continue; }
    rm -rf "$PKG_DIR/$p"
    cp -a "$FLUENT_TMP/package/$p" "$PKG_DIR/$p"
    echo "✅ 已拷贝: $p"
  done
  rm -rf "$FLUENT_TMP"
fi

if [ "$ADD_EASYTIER" = "true" ]; then
  clone https://github.com/EasyTier/luci-app-easytier "$PKG_DIR/luci-app-easytier" main
fi
if [ "$ADD_POWEROFF" = "true" ]; then
  clone https://github.com/sirpdboy/luci-app-poweroffdevice "$PKG_DIR/luci-app-poweroffdevice" main
fi
if [ "$ADD_OWQ_WOL" = "true" ]; then
  clone https://github.com/isalikai/luci-app-owq-wol "$PKG_DIR/luci-app-owq-wol" main
fi
if [ "$ADD_TASKPLAN" = "true" ]; then
  clone https://github.com/sirpdboy/luci-app-taskplan "$PKG_DIR/luci-app-taskplan" main
fi
if [ "$ADD_WATCHDOG" = "true" ]; then   # 包在子目录，必须拷出子目录，不能整仓丢进去
  WD_TMP="$(mktemp -d)/wd"
  clone https://github.com/sirpdboy/luci-app-watchdog "$WD_TMP" main
  rm -rf "$PKG_DIR/luci-app-watchdog"
  cp -r "$WD_TMP/luci-app-watchdog" "$PKG_DIR/luci-app-watchdog"
  rm -rf "$WD_TMP"
fi
if [ "$ADD_OAF" = "true" ]; then
  clone https://github.com/destan19/OpenAppFilter "$PKG_DIR/OpenAppFilter" master
  for p in luci-app-oaf open-app-filter oaf; do
    cp -r "$PKG_DIR/OpenAppFilter/$p" "$PKG_DIR/" 2>/dev/null
  done
  rm -rf "$PKG_DIR/OpenAppFilter"
fi
# ---------------------------------------------------------
# 校验：默认开启的两个插件必须拉到，否则 defconfig 会静默剔除，
#       编出来的固件缺少状态页还不易察觉
@@ -356,8 +323,11 @@ if [ -n "$(ls -A "$PKG_DIR" 2>/dev/null)" ]; then
      continue
    fi
    # 目录名即包名：buildroot 约定 PKG_NAME ?= $(notdir ${CURDIR})

    if grep -qx "Package: $n" tmp/.packageinfo 2>/dev/null; then
      echo "  ✅ $n"


    else
      echo "  ❌ $n —— tmp/.packageinfo 里查不到"
      INDEX_MISS="$INDEX_MISS $n"
@@ -378,44 +348,10 @@ if [ -n "$(ls -A "$PKG_DIR" 2>/dev/null)" ]; then
  if [ "$ADD_LUCI_APP" = "true" ]; then
    REQUIRED="$REQUIRED luci-app-natmode luci-app-pon-status"
  fi
  if [ "$ADD_FTTR" = "true" ] && [ "$FTTR_PROFILE" = "h3c_hm2004-du" ]; then
    # KernelPackage 生成的包名带 kmod- 前缀，索引里写的是 kmod-h3c-fmcs
    if [ "$ADD_FMCS" = "true" ]; then
      REQUIRED="$REQUIRED kmod-h3c-fmcs"
    fi
    if [ "$ADD_FMCS_FW" = "true" ]; then
      REQUIRED="$REQUIRED h3c-fmcs-firmware"
    fi
    if [ "$ADD_FTTR_TOOLS" = "true" ]; then
      REQUIRED="$REQUIRED h3c-fttr-tools"
    fi
    REQUIRED="$REQUIRED luci-app-fttr"
    # =========================================================
    # luci-app-fttr 的 LUCI_DEPENDS 里有 +h3c-fttr-tools（fttrctl 后端），
    # 而 h3c-fttr-tools 又依赖 +kmod-h3c-fmcs。链条上任何一节不在树里，
    # defconfig 都会静默把整条 FTTR 剔掉 —— 与其编出一个「没有 FTTR 界面」
    # 的固件还不易察觉，不如在这里直接报错。
    #
    # h3c-fttr-tools 进不了索引的最常见原因是缺 Rust 支持：它 include 了
    # feeds/packages/lang/rust/rust-package.mk，没有 packages feed（或没装
    # rust）时这个包根本不会被扫到。kmod-h3c-fmcs 则受
    # @(TARGET_airoha_an7581) 限制，非该 target 时同样不进索引。
    # =========================================================
    if [ "$ADD_FTTR_TOOLS" = "true" ] &&
       ! grep -qx "Package: h3c-fttr-tools" tmp/.packageinfo 2>/dev/null; then
      echo "::error::h3c-fttr-tools 不在包索引里（luci-app-fttr 的后端，Rust 包）"
      echo "        多半是缺 rust feed：确认 feeds.conf 里有 packages，且"
      echo "        ./scripts/feeds install 装到了 lang/rust。"
      echo "        不需要 FTTR 就把 diy-part1.sh 的 ADD_FTTR 改成 false。"
      exit 1
    fi
    if [ "$ADD_FMCS" = "true" ] &&
       ! grep -qx "Package: kmod-h3c-fmcs" tmp/.packageinfo 2>/dev/null; then
      echo "::error::kmod-h3c-fmcs 不在包索引里（h3c-fttr-tools 依赖它）"
      echo "        DEPENDS 是 @(TARGET_airoha_an7581)：非该 target 时包不会进索引。"
      echo "        不需要 FTTR 就把 diy-part1.sh 的 ADD_FTTR 改成 false。"
      exit 1
    fi
  fi
  HARD_MISS=""
  for r in $REQUIRED; do
