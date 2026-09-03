#!/usr/bin/env bash
# ============================================================
#  Fcitx5 微信同款输入法 · 通用一键安装脚本
#
#  ● 适用：Ubuntu/Debian x86_64（已装或未装 fcitx5 都行）
#  ● 用途：部署「自编译 SVG 版 fcitx5(5.1.22 + 候选框按钮/托盘补丁)」+
#          微信主题 + 雾凇拼音(rime-ice) + Web 设置面板 + 托盘图标/菜单
#  ● 安全：绝不删除用户数据。
#          - 不 purge 任何输入法（避免误删其他输入法用户配置）
#          - Rime 已有词库(userdb/build) 保留，只补充词典
#  ● 用法：解压仓库后（或 git clone 后）在仓库根目录执行：
#          sudo bash install.sh
#  ● 输出：每步都有日志；末尾有 fcitx5 是否正常启动的提示
# ============================================================
set -euo pipefail

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; CYAN='\033[0;36m'; NC='\033[0m'
info()  { echo -e "${GREEN}[✓]${NC} $1"; }
warn()  { echo -e "${YELLOW}[!]${NC} $1"; }
err()   { echo -e "${RED}[✗]${NC} $1"; }
step()  { echo; echo -e "${CYAN}===== $1 =====${NC}"; }

# ---------------- 基础 ----------------
if [ "$(id -u)" -ne 0 ]; then
  err "请用 sudo 运行：sudo bash install.sh"
  exit 1
fi
HUSER="${SUDO_USER:-${USER:-$(id -un)}}"
HHOME="$(getent passwd "$HUSER" | cut -d: -f6)"; [ -n "$HHOME" ] || HHOME="/root"
HUID="$(id -u "$HUSER")"
START=$(date +%s)

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PKG="$ROOT/packages"
PANEL_SRC="$ROOT/wechat-panel"
LIBDIR="/usr/lib/x86_64-linux-gnu"
FCITX_ADDON="$LIBDIR/fcitx5"

ARCHIVE="$PKG/fcitx5-svg-5.1.22-linux-x86_64.tar.gz"

info "目标用户: $HUSER ($HHOME) 仓库: $ROOT"
info "Note: All existing user data (rime userdb, configs) is preserved and untouched."

# ---------------- 前置检查 ----------------
step "0. 前置检查"
# 先停掉运行中的 fcitx5：覆盖 /usr 下的二进制/共享库前必须让它退出，
# 否则文件被占用，轻则覆盖失败、重则装完仍是旧代码（必须手动 pkill）。
if pgrep -x fcitx5 >/dev/null 2>&1; then
  warn "检测到 fcitx5 正在运行，先停止它（避免覆盖文件冲突）"
  pkill -x fcitx5 2>/dev/null || true
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    pgrep -x fcitx5 >/dev/null 2>&1 || break
    sleep 0.5
  done
  sleep 1
  if pgrep -x fcitx5 >/dev/null 2>&1; then
    warn "fcitx5 仍未退出，继续执行（可能被守护进程拉起）"
  else
    info "fcitx5 已停止"
  fi
else
  info "fcitx5 当前未运行"
fi

# 系统库 + 面板所需 Python 依赖（pywebview 缺了会导致面板打不开）
NEED_PKGS=(librsvg2-2 librsvg2-common libxcb-ewmh2 libxcb-imdkit1 librime1t64 \
           python3-webview python3-pyqt5.qtwebengine)
MISS=()
for p in "${NEED_PKGS[@]}"; do dpkg-query -W -f='${Status}' "$p" 2>/dev/null | grep -q "install ok installed" || MISS+=("$p"); done
if [ ${#MISS[@]} -gt 0 ]; then
  warn "缺少系统库：${MISS[*]}  → 将尝试 apt 安装"
  apt-get update -qq
  apt-get install -y -qq "${MISS[@]}" || warn "部分库安装失败（可稍后手动 apt install ${MISS[*]}）"
else
  info "系统库依赖已满足"
fi

# ---------------- 全局输入法环境变量（XWayland 应用必需） ----------------
# 微信/QQ 等 Electron 应用走 XWayland（X11 兼容层），它们不认 Wayland 的
# text-input 协议，必须通过 XMODIFIERS + fcitx5 的 XIM 服务才能输入。
# 向 /etc/environment 追加三件套（所有用户/所有应用全局生效，幂等，
# 不覆盖已有内容）。
# 安全性：GTK 应用的批量崩溃由 GTK4 枚举 immodules 目录加载
# libim-fcitx5.so 引起（下方会移除模块文件），与这些环境变量无关；
# 模块移除后 GTK_IM_MODULE=fcitx 只会让 GTK fallback 到默认输入，无崩溃路径。
ENVF="/etc/environment"
append_env() {
  local key="$1" val="$2"
  if grep -qE "^${key}=" "$ENVF" 2>/dev/null; then
    info "$key 已存在于 /etc/environment（跳过）"
  else
    echo "${key}=${val}" >> "$ENVF"
    info "已追加 ${key}=${val} → /etc/environment（全局生效，重新登录后对 XWayland 应用生效）"
  fi
}
append_env "XMODIFIERS" "@im=fcitx"
append_env "GTK_IM_MODULE" "fcitx"
append_env "QT_IM_MODULE" "fcitx"

# ---------------- 移除 GTK IM 模块（GTK4 应用批量崩溃修复） ----------------
# 根因：GTK4 启动时枚举 gtk-4.0/immodules/ 目录并加载其中全部模块。
# 自编译的 libim-fcitx5.so 初始化时出现空指针跳转（nautilus 的
# "segfault at 6cd0" 即此），导致所有 GTK4 应用批量崩溃；即使清空
# GTK_IM_MODULE 也无效，因为 GTK4 不走该变量、固定使用 text-input。
# Wayland 下 GTK2/3/4 都不需要 fcitx 的 GTK IM 模块——直接移除，
# 再重建 GTK3 缓存保持目录一致。
for f in \
  "/usr/lib/x86_64-linux-gnu/gtk-4.0/4.0.0/immodules/libim-fcitx5.so" \
  "/usr/lib/x86_64-linux-gnu/gtk-3.0/3.0.0/immodules/im-fcitx5.so" \
  "/usr/lib/x86_64-linux-gnu/gtk-2.0/2.10.0/immodules/im-fcitx5.so"; do
  if [ -f "$f" ]; then
	    rm -f "$f"
	    info "已移除 GTK IM 模块：$f（修复 GTK 应用崩溃）"
  fi
done

# 重建 GTK3 输入法模块缓存，与目录保持一致（不含 fcitx 模块）
GTK3_Q=""
for cand in /usr/lib/x86_64-linux-gnu/libgtk-3-0/gtk-query-immodules-3.0 \
           /usr/lib/x86_64-linux-gnu/libgtk-3-0t64/gtk-query-immodules-3.0; do
  [ -x "$cand" ] && { GTK3_Q="$cand"; break; }
done
if [ -n "$GTK3_Q" ]; then
	  GTK3_IM="/usr/lib/x86_64-linux-gnu/libgtk-3-0/gtk-3.0"
	  if ls "$GTK3_IM"/immodules/im-*.so >/dev/null 2>&1; then
	    "$GTK3_Q" "$GTK3_IM"/immodules/im-*.so > "$GTK3_IM"/immodules.cache 2>/dev/null \
	      && info "GTK3 输入法模块缓存已重建（与目录一致）" \
	      || warn "GTK3 模块缓存重建失败（可忽略，Wayland 下不依赖它）"
	  fi
	fi

[ -f "$ARCHIVE" ] || { err "缺少 $ARCHIVE（SVG fcitx5 压缩包）"; exit 1; }
[ -d "$PKG/rime-ice" ] || { err "缺少 $PKG/rime-ice/ 词库"; exit 1; }
[ -d "$ROOT/fcitx5/themes/wechat-light" ] || { err "缺少主题 wechat-light"; exit 1; }

# ---------------- 1. 部署 SVG fcitx5 + 补丁模块 ----------------
step "1. 部署自编译 SVG fcitx5 (5.1.22 + 补丁)"
TMP="$(mktemp -d)"
tar -xzf "$ARCHIVE" -C "$TMP"
cp -a "$TMP/usr/bin"/*        /usr/bin/
cp -a "$TMP/usr/lib/x86_64-linux-gnu/." "$LIBDIR/"
cp -a "$TMP/usr/share/fcitx5/." /usr/share/fcitx5/
rm -rf "$TMP"
ldconfig
info "fcitx5 已部署"
if ldd "$FCITX_ADDON/libclassicui.so" 2>/dev/null | grep -qi librsvg; then
  info "SVG 圆角渲染 OK (classicui 带 librsvg)"
else
  warn "未检测到 librsvg，圆角皮肤可能退化（不影响打字）"
fi

# ---------------- 2. 安装主题 ----------------
step "2. 安装微信主题 (wechat-light / wechat-dark)"
THEME_DIR="$HHOME/.local/share/fcitx5/themes"
mkdir -p "$THEME_DIR"
cp -r "$ROOT/fcitx5/themes/wechat-light" "$THEME_DIR/"
cp -r "$ROOT/fcitx5/themes/wechat-dark"  "$THEME_DIR/"
info "主题已安装"

# ---------------- 3. Rime 词库（雾凇拼音，不删用户数据） ----------------
step "3. 安装雾凇拼音词库 (rime-ice)"
RIME_DIR="$HHOME/.local/share/fcitx5/rime"
mkdir -p "$RIME_DIR"
# 只补充词典，不覆盖 userdb/build（用户输入记忆、自造词全保留）
cp -a "$PKG/rime-ice/." "$RIME_DIR/"
[ -f "$ROOT/fcitx5/rime_ice.custom.yaml" ] && cp -f "$ROOT/fcitx5/rime_ice.custom.yaml" "$RIME_DIR/"
cat > "$RIME_DIR/installation.yaml" <<EOF
distribution_code: fcitx5
distribution_name: Rime
distribution_version: 5.1.22
install_time: "$(date +%s)"
EOF
info "雾凇拼音词库已就绪（已有 userdb/build 已保留）"

# ---------------- 4. 配置 fcitx5（只启用 rime，不删其它） ----------------
step "4. 配置 fcitx5 (经典UI + 仅启雾凇拼音)"
CFG_DIR="$HHOME/.config/fcitx5"
mkdir -p "$CFG_DIR/conf"
cat > "$CFG_DIR/conf/classicui.conf" <<'EOF'
# Fcitx5 经典UI(候选框) —— 微信风格
Font="Noto Sans CJK SC 16"
Theme=wechat-light
PerScreenDPI=False
EOF
# 输入法表：保留已有组外，确保 rime 可用（不删除用户自建的其它输入法组）
cat > "$CFG_DIR/profile" <<'EOF'
[Groups/0]
Name=Default
Default Layout=us
DefaultIM=rime

[Groups/0/Items/0]
Name=rime

[GroupOrder]
0=Default
EOF
# 仅启用 rime 引擎 + 默认中文（只影响新引擎启用名单；不强制禁其它已启用输入法）
mkdir -p "$CFG_DIR/conf"
cat > "$CFG_DIR/conf/classicui.ini" <<'EOF'
Enabled=True
EOF
chown -R "$HUSER":"$(id -gn "$HUSER")" "$HHOME/.config/fcitx5" "$HHOME/.local/share/fcitx5" 2>/dev/null || true
info "fcitx5 配置完成"

# ---------------- 5. 安装设置面板（pywebview + QtWebEngine） ----------------
step "5. 安装 Web 设置面板"
PANEL_DEST="/opt/fcitx5-wechat-panel"
# 停掉可能在运行的老面板进程 + 清锁，确保升级后打开的是新代码
pkill -f "webpanel.py" 2>/dev/null || true
rm -f /tmp/ime-panel.lock /tmp/ime-panel.wake
mkdir -p "$PANEL_DEST"
cp -a "$PANEL_SRC"/. "$PANEL_DEST/"
chmod +x "$PANEL_DEST/run-panel.sh" 2>/dev/null || true
# 预编译补丁模块（候选框齿轮按钮 + 托盘 Preference）固定以
# $HOME/fcitx5-wechat-panel/run-panel.sh 启动面板 → 在家目录建兼容符号链接。
# 注意：家目录已有真实目录时保留不动（可能是不想被覆盖的旧面板）。
if [ -L "$HHOME/fcitx5-wechat-panel" ]; then
  rm -f "$HHOME/fcitx5-wechat-panel"
fi
if [ ! -e "$HHOME/fcitx5-wechat-panel" ]; then
  ln -s "$PANEL_DEST" "$HHOME/fcitx5-wechat-panel"
  chown -h "$HUSER":"$(id -gn "$HUSER")" "$HHOME/fcitx5-wechat-panel" 2>/dev/null || true
  info "兼容路径 $HHOME/fcitx5-wechat-panel -> $PANEL_DEST（齿轮/托盘按钮可打开面板）"
else
  warn "已存在 $HHOME/fcitx5-wechat-panel（真实目录），保留不动"
fi
# 校验面板运行依赖（pywebview + QtWebEngine，透明圆角必需）
if /usr/bin/python3 -c "import webview, PyQt5.QtWebEngineWidgets" 2>/dev/null; then
  info "面板依赖 OK (pywebview + QtWebEngine)，支持透明圆角"
else
  warn "面板依赖未就绪：sudo apt install -y python3-webview python3-pyqt5.qtwebengine"
fi

# ---------------- 6. 托盘图标 ----------------
step "6. 安装托盘图标 (雾凇图标)"
ICON_SRC="$ROOT/icons/fcitx-wusong.svg"
if [ -f "$ICON_SRC" ]; then
  mkdir -p /usr/share/icons/hicolor/scalable/apps
  cp -f "$ICON_SRC" /usr/share/icons/hicolor/scalable/apps/fcitx-wusong.svg
  for s in 16 22 24 32 48 64 128; do
    [ -f "$ROOT/icons/${s}x${s}/fcitx-wusong.png" ] && { mkdir -p "/usr/share/icons/hicolor/${s}x${s}/apps"; cp -f "$ROOT/icons/${s}x${s}/fcitx-wusong.png" "/usr/share/icons/hicolor/${s}x${s}/apps/fcitx-wusong.png"; }
  done
  gtk-update-icon-cache -f /usr/share/icons/hicolor 2>/dev/null || true
  info "雾凇托盘图标已安装"
else
  warn "未找到图标资源，跳过（托盘将用默认图标）"
fi

# ---------------- 7. 桌面自启动（面板 + 输入法） ----------------
step "7. 配置自启动"
AUTOSTART="$HHOME/.config/autostart"
mkdir -p "$AUTOSTART"
# fcitx5 自启动
cat > "$AUTOSTART/fcitx5.desktop" <<EOF
[Desktop Entry]
Type=Application
Name=Fcitx 5
Comment=Start Input Method
Exec=fcitx5 -d
X-GNOME-Autostart-enabled=true
EOF
# 面板自启动（引用 /opt 下实际安装路径）
cat > "$AUTOSTART/ime-panel.desktop" <<EOF
[Desktop Entry]
Type=Application
Name=IME Panel
Name[zh_CN]=输入法面板
Comment=Adjust IME font size and theme
Exec=$PANEL_DEST/run-panel.sh
Icon=fcitx-wusong
Terminal=false
X-GNOME-Autostart-enabled=true
EOF
chown -R "$HUSER":"$(id -gn "$HUSER")" "$AUTOSTART" 2>/dev/null || true
info "已配置 fcitx5 与设置面板自启动"

# ---------------- 8. 重启 fcitx5 ----------------
step "8. 重启 fcitx5"
if pgrep -x fcitx5 >/dev/null 2>&1; then pkill -x fcitx5 2>/dev/null || true; sleep 1; fi
sudo -u "$HUSER" env DISPLAY="${DISPLAY:-:0}" XDG_RUNTIME_DIR="/run/user/$HUID" nohup fcitx5 -d >/dev/null 2>&1 & 
sleep 3
if pgrep -x fcitx5 >/dev/null 2>&1; then
  info "fcitx5 已启动 (PID $(pgrep -x fcitx5))"
else
  warn "fcitx5 未自动启动，请注销重新登录或手动运行 fcitx5 -d"
fi

# ---------------- 完成 ----------------
DUR=$(( $(date +%s) - START ))
echo
echo "=============================================================="
info "安装完成！用时 ${DUR}s"
echo "  - fcitx5 5.1.22 (SVG 圆角 + 候选框齿轮按钮 + 托盘补丁)"
echo "  - 输入法: 雾凇拼音 (rime-ice)"
echo "  - 主题:   wechat-light / wechat-dark"
echo "  - 面板:   /opt/fcitx5-wechat-panel  (自启动)"
echo "  - 托盘:   菜单 = Preference(设置面板) + Restart"
echo "  - 提示:   注销重新登录一次，让输入法环境变量彻底生效"
echo "  - 安全:   All existing user data (rime userdb, configs) is preserved"
echo "=============================================================="
