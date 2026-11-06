#!/usr/bin/env bash
# mihomo-trim-asuswrt —— 华硕路由器 armv8 (aarch64) 专用精简内核
#
# 产物：out/mihomo-trim-asuswrt-arm64
#   仅保留客户端出站协议 · 无 TUN · GOGC=20 已烘焙
#
# 用法：
#   ./build.sh                                  # 克隆上游 + 打补丁 + 编译
#   LOW_MEMORY=1 ./build.sh                     # 缓冲减半，省内存（高吞吐 CPU 略增）
#   PROXY=http://127.0.0.1:7890 ./build.sh      # 克隆/依赖走代理
#   MIHOMO_DIR=/path/to/mihomo ./build.sh       # 复用已有上游源码
#   SKIP_PATCH=1 ./build.sh                     # 源码已打过补丁，跳过打补丁
#   GOCACHE=/path GOMODCACHE=/path ./build.sh   # 缓存目录不可写时指定
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MIHOMO_DIR="${MIHOMO_DIR:-$ROOT/mihomo}"
OUT_DIR="${OUT_DIR:-$ROOT/out}"
REPO="${REPO:-https://github.com/MetaCubeX/mihomo}"
BRANCH="${BRANCH:-Meta}"
PROXY="${PROXY-}"
GOPROXY_V="${GOPROXY_V:-https://goproxy.cn,direct}"
GO_BIN="${GO:-go}"
TAGS="no_tailscale no_zerotier no_easytier"
# 可选：LOW_MEMORY=1 时追加 with_low_memory（缓冲减半，省内存但高吞吐 CPU 略增）
if [ "${LOW_MEMORY:-0}" = "1" ]; then
  TAGS="$TAGS with_low_memory"
fi
OUT_NAME="mihomo-trim-asuswrt-arm64"
PATCH_CLIENTONLY="$ROOT/patches/clientonly.patch"
PATCH_GC="$ROOT/patches/router-gc.patch"

die() { echo "!! $*" >&2; exit 1; }

command -v "$GO_BIN" >/dev/null 2>&1 || die "找不到 go，请设置 GO=<go 路径>"
command -v git      >/dev/null 2>&1 || die "找不到 git"

echo "go  : $($GO_BIN version)"
echo "目标: linux/arm64 (aarch64)"
echo "补丁: $(basename "$PATCH_CLIENTONLY") + $(basename "$PATCH_GC")"
echo "tags: $TAGS"

# ---------- 1. 取上游源码 ----------
if [ ! -e "$MIHOMO_DIR/.git" ]; then
  echo "==> 克隆 $REPO ($BRANCH)"
  if [ -n "$PROXY" ]; then
    git -c "http.proxy=$PROXY" clone --depth 1 -b "$BRANCH" "$REPO" "$MIHOMO_DIR" ||
    git clone --depth 1 -b "$BRANCH" "$REPO" "$MIHOMO_DIR"
  else
    git clone --depth 1 -b "$BRANCH" "$REPO" "$MIHOMO_DIR"
  fi
else
  echo "==> 复用已有源码 $MIHOMO_DIR"
fi

cd "$MIHOMO_DIR"
UPSTREAM_SHA="$(git rev-parse --short HEAD)"
UPSTREAM_TAG="$(git describe --tags --abbrev=0 2>/dev/null || echo v0.0.0)"
echo "==> 上游 $UPSTREAM_TAG ($UPSTREAM_SHA)"

# ---------- 2. 打补丁 ----------
apply_patch() { # apply_patch <补丁> <说明>
  local p="$1" what="$2"
  [ -f "$p" ] || die "补丁不存在：$p"
  if git apply --check "$p" 2>/dev/null; then
    echo "==> 应用补丁：$(basename "$p")（${what}）"
    git apply "$p"
  elif git apply --reverse --check "$p" 2>/dev/null; then
    echo "==> 补丁已应用，跳过：$(basename "$p")（${what}）"
  else
    echo "!! ${what}补丁套不上（上游可能已变动），尝试 3way"
    if [ "$(git rev-parse --is-shallow-repository 2>/dev/null)" = "true" ]; then
      echo "   注意：浅克隆缺少补丁基线 blob，3way 会退化为直接应用"
    fi
    git apply --3way "$p" || die "${what}补丁冲突，请按 README「上游更新」重新生成补丁"
  fi
}

if [ "${SKIP_PATCH:-0}" != "1" ]; then
  apply_patch "$PATCH_CLIENTONLY" "裁剪"
  apply_patch "$PATCH_GC" "GC 调优"
fi

# ---------- 3. 用 stub 替换 sing_tun（摘掉 TUN 及其依赖） ----------
STUB_DIR="listener/sing_tun"
BACKUP_DIR="$(mktemp -d)"
cp -a "$STUB_DIR"/. "$BACKUP_DIR"/
restore_stub() {
  rm -f "$STUB_DIR"/*.go
  cp -a "$BACKUP_DIR"/. "$STUB_DIR"/
  rm -rf "$BACKUP_DIR"
}
trap restore_stub EXIT

rm -f "$STUB_DIR"/*.go
cat > "$STUB_DIR/stub_notun.go" <<'STUB'
package sing_tun

import (
	"errors"

	"github.com/metacubex/mihomo/adapter/inbound" // 注意：不是 listener/inbound（会 import cycle）
	C "github.com/metacubex/mihomo/constant"
	LC "github.com/metacubex/mihomo/listener/config"
)

type Listener struct{}

func New(options LC.Tun, tunnel C.Tunnel, additions ...inbound.Addition) (l *Listener, err error) {
	return nil, errors.New("TUN support is disabled in this build")
}

func (l *Listener) OnReload()       {}
func (l *Listener) Close() error    { return nil }
func (l *Listener) Config() LC.Tun  { return LC.Tun{} }
func (l *Listener) Address() string { return "" }
STUB

# ---------- 4. 编译 ----------
mkdir -p "$OUT_DIR"
VER="${VERSION:-${UPSTREAM_TAG}-trim-asuswrt-${UPSTREAM_SHA}}"
export GOPROXY="$GOPROXY_V" GOSUMDB=off CGO_ENABLED=0 GOOS=linux GOARCH=arm64

echo "==> 编译 $OUT_NAME（$VER）"
"$GO_BIN" build -tags "$TAGS" -trimpath \
  -ldflags "-s -w -buildid= -X github.com/metacubex/mihomo/constant.Version=$VER" \
  -o "$OUT_DIR/$OUT_NAME" .

# ---------- 5. 自检 ----------
if strings "$OUT_DIR/$OUT_NAME" | grep -q 'metacubex/sing-tun'; then
  die "TUN 依赖没被摘掉，sing-tun 仍被链接"
fi

echo
echo "产物: $OUT_DIR/$OUT_NAME"
ls -l "$OUT_DIR/$OUT_NAME" | awk '{print "  大小: " $5 " 字节"}'
echo "  sha256: $(sha256sum "$OUT_DIR/$OUT_NAME" | cut -d' ' -f1)"
