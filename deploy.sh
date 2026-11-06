#!/usr/bin/env bash
# deploy.sh —— 把 mihomo-trim-asuswrt 二进制部署到路由器
#
# 特点：
#   - 不需要 scp/sftp（路由器通常没有 sftp-server），全程走 ssh 管道
#   - 密码认证不依赖 sshpass（用 SSH_ASKPASS_REQUIRE=force）
#   - 先传 /tmp 自检，通过后才替换；替换失败自动回滚
#   - 替换前把旧内核备份到本地 ./backup/
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BINARY="$ROOT/out/mihomo-trim-asuswrt-arm64"
REMOTE_BIN="/koolshare/bin/clash"
HOST=""; PORT=22; USER_NAME="root"
KEY=""; PASSWORD=""
DRY_RUN=0; ASSUME_YES=0; NO_BACKUP=0; DO_RESTART=0; FORCE=0
SSH_CONFIG=""; KNOWN_HOSTS=""; RESTART_CMD="/koolshare/scripts/clash_config.sh restart"

die() { echo "!! $*" >&2; exit 1; }
info() { echo "==> $*"; }

usage() {
  cat <<'USAGE'
用法: ./deploy.sh -H <host> [选项]

必填:
  -H, --host HOST        路由器地址（IP 或域名）

连接:
  -p, --port PORT        SSH 端口（默认 22）
  -u, --user USER        SSH 用户（默认 root）
  -i, --key FILE         私钥文件
  -P, --password PASS    密码（走 SSH_ASKPASS，无需 sshpass）
                         也可用环境变量 DEPLOY_PASSWORD 传，避免出现在 ps 里
      --ssh-config FILE  传给 ssh -F（系统配置有问题时可用 /dev/null）
      --known-hosts FILE 自定义 known_hosts

部署:
  -b, --binary FILE      要部署的二进制（默认 out/mihomo-trim-asuswrt-arm64）
  -r, --remote-bin PATH  远端路径（默认 /koolshare/bin/clash）
  -d, --dry-run          只检查不写入
  -y, --yes              跳过确认
  -n, --no-backup        不备份旧内核
  -R, --restart          替换后执行插件重启
      --restart-cmd CMD  自定义重启命令
  -f, --force            跳过架构/空间检查
  -h, --help             显示本帮助

示例:
  ./deploy.sh -H 192.168.50.1 -u your-username -i ~/.ssh/id_ed25519 -y
  ./deploy.sh -H 192.168.50.1 -u your-username -P 'my-password' -R
USAGE
}

# ---------- 参数解析 ----------
while [ $# -gt 0 ]; do
  case "$1" in
    -H|--host)         HOST="$2"; shift 2 ;;
    -p|--port)         PORT="$2"; shift 2 ;;
    -u|--user)         USER_NAME="$2"; shift 2 ;;
    -i|--key)          KEY="$2"; shift 2 ;;
    -P|--password)     PASSWORD="$2"; shift 2 ;;
    -b|--binary)       BINARY="$2"; shift 2 ;;
    -r|--remote-bin)   REMOTE_BIN="$2"; shift 2 ;;
    -d|--dry-run)      DRY_RUN=1; shift ;;
    -y|--yes)          ASSUME_YES=1; shift ;;
    -n|--no-backup)    NO_BACKUP=1; shift ;;
    -R|--restart)      DO_RESTART=1; shift ;;
    --restart-cmd)     RESTART_CMD="$2"; DO_RESTART=1; shift 2 ;;
    -f|--force)        FORCE=1; shift ;;
    --ssh-config)      SSH_CONFIG="$2"; shift 2 ;;
    --known-hosts)     KNOWN_HOSTS="$2"; shift 2 ;;
    -h|--help)         usage; exit 0 ;;
    *)                 die "未知参数: $1（用 -h 看帮助）" ;;
  esac
done

[ -n "$HOST" ] || { usage; die "缺少 -H/--host"; }
[ -f "$BINARY" ] || die "二进制不存在: $BINARY（先跑 ./build.sh）"

TARGET="$USER_NAME@$HOST"
BIN_SIZE=$(wc -c < "$BINARY")
BIN_KB=$(( (BIN_SIZE + 1023) / 1024 ))

# ---------- 密码：SSH_ASKPASS ----------
ASKPASS_FILE=""
cleanup() { if [ -n "$ASKPASS_FILE" ]; then rm -f "$ASKPASS_FILE"; fi; }
trap cleanup EXIT

SSH_OPTS=(-o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new -o LogLevel=ERROR)
[ -n "$SSH_CONFIG" ]  && SSH_OPTS=(-F "$SSH_CONFIG" "${SSH_OPTS[@]}")
[ -n "$KNOWN_HOSTS" ] && SSH_OPTS+=(-o "UserKnownHostsFile=$KNOWN_HOSTS")
[ -n "$KEY" ]         && SSH_OPTS+=(-i "$KEY" -o IdentitiesOnly=yes)

# 密码也可以从环境变量传，避免出现在 ps 里
if [ -z "$PASSWORD" ] && [ -n "${DEPLOY_PASSWORD:-}" ]; then
  PASSWORD="$DEPLOY_PASSWORD"
fi

if [ -n "$PASSWORD" ]; then
  ASKPASS_FILE="$(mktemp)"
  {
    printf '#!/bin/sh\n'
    printf 'printf %%s %s | base64 -d\n' "'$(printf '%s' "$PASSWORD" | base64 | tr -d '\n')'"
  } > "$ASKPASS_FILE"
  chmod 700 "$ASKPASS_FILE"
  export SSH_ASKPASS="$ASKPASS_FILE" SSH_ASKPASS_REQUIRE=force
  SSH_OPTS+=(-o PreferredAuthentications=password,keyboard-interactive -o PubkeyAuthentication=no)
fi

rsh() { ssh -p "$PORT" "${SSH_OPTS[@]}" "$TARGET" "$@"; }

# ---------- 连接测试（系统 ssh 配置损坏时自动绕过）----------
info "连接 $TARGET:$PORT"
if ! rsh true 2>/tmp/deploy-ssh-err; then
  if grep -q "Bad owner or permissions" /tmp/deploy-ssh-err 2>/dev/null; then
    echo "   检测到系统 ssh 配置权限异常，改用 -F /dev/null 重试"
    SSH_OPTS=(-F /dev/null "${SSH_OPTS[@]}")
    rsh true 2>/tmp/deploy-ssh-err || { cat /tmp/deploy-ssh-err >&2; die "SSH 连接失败"; }
  else
    cat /tmp/deploy-ssh-err >&2
    if grep -q "Permission denied" /tmp/deploy-ssh-err 2>/dev/null; then
      echo "   提示：认证被拒。若刚发生过多次失败尝试，Asuswrt 的 SSH 防爆破保护可能已临时封禁该来源，" >&2
      echo "        等待封禁到期、或在路由界面「系统管理 → 系统设置」检查 SSH 设置后再试。" >&2
    fi
    die "SSH 连接失败"
  fi
fi
rm -f /tmp/deploy-ssh-err
info "连接成功"

# ---------- 远端环境检查 ----------
REMOTE_ARCH="$(rsh 'uname -m' 2>/dev/null || echo unknown)"
info "远端架构: $REMOTE_ARCH"
case "$REMOTE_ARCH" in
  aarch64|arm64) ;;
  *) [ "$FORCE" = "1" ] || die "远端不是 aarch64（$REMOTE_ARCH），本项目只支持 armv8；确需继续加 --force" ;;
esac

OLD_EXISTS=0
OLD_SIZE=0
if rsh "test -f '$REMOTE_BIN'"; then
  OLD_EXISTS=1
  OLD_SIZE="$(rsh "wc -c < '$REMOTE_BIN'" 2>/dev/null | tr -d ' ')"
  OLD_VER="$(rsh "'$REMOTE_BIN' -v 2>/dev/null | head -1" || true)"
  info "现有内核: $REMOTE_BIN（$OLD_SIZE 字节）"
  [ -n "$OLD_VER" ] && echo "   $OLD_VER"
else
  info "现有内核不存在（$REMOTE_BIN），将全新安装"
fi

REMOTE_DIR="$(dirname "$REMOTE_BIN")"
AVAIL_KB="$(rsh "df -k '$REMOTE_DIR' | tail -1 | awk '{print \$4}'" 2>/dev/null | tr -d ' ')"
AVAIL_KB="${AVAIL_KB:-0}"
TMP_AVAIL_KB="$(rsh "df -k /tmp | tail -1 | awk '{print \$4}'" 2>/dev/null | tr -d ' ')"
TMP_AVAIL_KB="${TMP_AVAIL_KB:-0}"
# 替换时会先删旧文件，所以可用空间可以加上旧文件大小
EFFECTIVE_KB=$AVAIL_KB
if [ "$OLD_EXISTS" = "1" ]; then
  EFFECTIVE_KB=$(( AVAIL_KB + (OLD_SIZE + 1023) / 1024 ))
fi
info "空间: $REMOTE_DIR 可用 ${AVAIL_KB} KB（删旧后可释放约 $(( (OLD_SIZE + 1023) / 1024 )) KB）；/tmp 可用 ${TMP_AVAIL_KB} KB"
if [ "$FORCE" != "1" ]; then
  [ "$EFFECTIVE_KB" -ge $(( BIN_KB + 512 )) ] || die "目标分区空间不足：需要约 ${BIN_KB} KB + 512 KB 余量"
  [ "$TMP_AVAIL_KB" -ge "$BIN_KB" ] || die "/tmp 空间不足，无法暂存：需要 ${BIN_KB} KB"
fi

if [ "$DRY_RUN" = "1" ]; then
  echo
  info "dry-run：检查通过，未做任何写入"
  echo "   将上传 $BINARY（$BIN_SIZE 字节）→ /tmp/mihomo-trim-asuswrt.new → $REMOTE_BIN"
  exit 0
fi

# ---------- 确认 ----------
if [ "$ASSUME_YES" != "1" ]; then
  [ -t 0 ] || die "非交互环境请加 -y 确认"
  printf "即将替换 %s 上的 %s，继续？[y/N] " "$TARGET" "$REMOTE_BIN"
  read -r ans
  case "$ans" in y|Y|yes|YES) ;; *) die "已取消" ;; esac
fi

# ---------- 备份 ----------
BACKUP_FILE=""
if [ "$OLD_EXISTS" = "1" ] && [ "$NO_BACKUP" != "1" ]; then
  mkdir -p "$ROOT/backup"
  BACKUP_FILE="$ROOT/backup/clash-$(date +%Y%m%d-%H%M%S)"
  info "备份旧内核到 $BACKUP_FILE"
  rsh "cat '$REMOTE_BIN'" > "$BACKUP_FILE"
  BAK_SIZE=$(wc -c < "$BACKUP_FILE")
  [ "$BAK_SIZE" = "$OLD_SIZE" ] || die "备份大小不符（本地 $BAK_SIZE / 远端 $OLD_SIZE）"
  echo "   备份完成（$BAK_SIZE 字节）"
fi

# ---------- 上传到 /tmp ----------
STAGE="/tmp/mihomo-trim-asuswrt.new"
info "上传到 $STAGE（$BIN_SIZE 字节）"
rsh "cat > '$STAGE' && chmod +x '$STAGE'" < "$BINARY"
REMOTE_SIZE="$(rsh "wc -c < '$STAGE'" | tr -d ' ')"
[ "$REMOTE_SIZE" = "$BIN_SIZE" ] || die "上传大小不符（远端 $REMOTE_SIZE / 本地 $BIN_SIZE）"

# ---------- 远端自检 ----------
info "远端自检"
VER_OUT="$(rsh "'$STAGE' -v 2>&1 | head -2" || true)"
echo "$VER_OUT" | grep -q "Mihomo Meta" || { rsh "rm -f '$STAGE'" || true; die "新二进制无法运行：$VER_OUT"; }
echo "$VER_OUT" | sed 's/^/   /'

# ---------- 替换 ----------
info "替换 $REMOTE_BIN"
if ! rsh "rm -f '$REMOTE_BIN' && cp '$STAGE' '$REMOTE_BIN' && chmod +x '$REMOTE_BIN' && rm -f '$STAGE'"; then
  echo "!! 替换失败"
  if [ -n "$BACKUP_FILE" ]; then
    echo "   正在从本地备份回滚"
    rsh "cat > '$STAGE' && chmod +x '$STAGE'" < "$BACKUP_FILE" || true
    rsh "rm -f '$REMOTE_BIN' && cp '$STAGE' '$REMOTE_BIN' && chmod +x '$REMOTE_BIN' && rm -f '$STAGE'" || true
    echo "   已回滚"
  fi
  die "部署失败"
fi

NEW_VER="$(rsh "'$REMOTE_BIN' -v 2>&1 | head -1" || true)"
echo "$NEW_VER" | grep -q "Mihomo Meta" || {
  echo "!! 替换后自检失败：$NEW_VER"
  [ -n "$BACKUP_FILE" ] && { echo "   正在回滚"; rsh "cat > '$STAGE' && chmod +x '$STAGE'" < "$BACKUP_FILE" || true; rsh "rm -f '$REMOTE_BIN' && cp '$STAGE' '$REMOTE_BIN' && chmod +x '$REMOTE_BIN' && rm -f '$STAGE'" || true; }
  die "部署失败，已回滚"
}
echo "   $NEW_VER"

# ---------- 重启 ----------
if [ "$DO_RESTART" = "1" ]; then
  info "重启插件：$RESTART_CMD"
  rsh "$RESTART_CMD" 2>&1 | tail -5 || echo "   重启命令返回非 0，请到插件界面确认"
else
  echo
  info "完成。请到插件界面关闭再开启，或手动执行："
  echo "   ssh -p $PORT $TARGET '$RESTART_CMD'"
fi

echo
info "部署成功"
echo "   版本: $(echo "$NEW_VER" | awk '{print $3}')"
echo "   路径: $REMOTE_BIN"
[ -n "$BACKUP_FILE" ] && echo "   备份: $BACKUP_FILE"
