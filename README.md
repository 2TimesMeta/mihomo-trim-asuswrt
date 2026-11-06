# mihomo-trim-asuswrt

华硕路由器 **armv8 (aarch64)** 专用的 mihomo 精简内核。只做一件事：给路由器出一个
低内存的透明代理二进制，替换 MerlinClash / Magic Catling 等插件里的 `/koolshare/bin/clash`。

- 只保留客户端出站协议（vless / vmess / trojan / ss / hysteria2 / tuic / anytls / mieru 等）
- **无 TUN**：`listener/sing_tun` 换成 stub，`sing-tun` / `gvisor` / `mipstack` 都不进二进制
- **GOGC=20 已烘焙**：环境变量 `GOGC` / `GOMEMLIMIT` 仍可覆盖
- **低内存模式可选**：`LOW_MEMORY=1 ./build.sh` 把 TCP/UDP 中继缓冲减半（32K→16K、16K→8K），省内存但高吞吐时 CPU 略增，默认关闭

## 要求

- Go 1.21+（开发时用的是 1.27）
- git
- 目标机：运行 Asuswrt / Merlin 固件的 armv8 (aarch64) 路由器
  （部署前用 `uname -m` 确认输出为 `aarch64`；其它架构 `deploy.sh` 会直接拒绝）

## 构建

```bash
./build.sh
```

首次会自动 `git clone --depth 1 -b Meta` 上游 mihomo，然后打两个补丁、编译。

产物：`out/mihomo-trim-asuswrt-arm64`

可覆盖的环境变量：

| 变量 | 说明 |
|---|---|
| `MIHOMO_DIR` | 复用已有上游源码目录（默认 `./mihomo`） |
| `OUT_DIR` | 产物目录（默认 `./out`） |
| `PROXY` | 克隆/依赖走的 HTTP 代理，如 `http://127.0.0.1:7890` |
| `GOPROXY_V` | Go 模块代理（默认 `https://goproxy.cn,direct`） |
| `SKIP_PATCH=1` | 源码已打过补丁时跳过 |
| `LOW_MEMORY=1` | 中继缓冲减半，省内存；高吞吐时 CPU 略增（默认关闭） |
| `VERSION` | 覆盖写入二进制的版本串 |
| `GOCACHE` / `GOMODCACHE` | 缓存目录不可写时指定 |

> `LOW_MEMORY=1` 省的是内存：每条连接的中继缓冲从 32K/16K 降到 16K/8K。代价是同样的流量下
> 读写与 syscall 次数约翻倍，CPU 会略升、流量越大越明显，所以默认不开启。

## 部署到路由器

用自带脚本，一条命令搞定（备份 → 上传 → 自检 → 替换 → 可选重启）：

```bash
./deploy.sh -H 192.168.50.1 -u your-username -i ~/.ssh/id_ed25519 -y
```

`-H` 填路由器的 LAN 地址（华硕默认 `192.168.50.1`），`-u` 填你首次启用路由器时设置的
管理员用户名，`-i` 指向你的私钥。

常用参数：

| 参数 | 说明 |
|---|---|
| `-H, --host` | 路由器地址（必填） |
| `-p, --port` | SSH 端口（默认 22） |
| `-u, --user` | SSH 用户（脚本默认 root，实际填路由器管理员用户名） |
| `-i, --key` | 私钥文件 |
| `-P, --password` | 密码（走 `SSH_ASKPASS`，**不需要 sshpass**） |
| `-d, --dry-run` | 只检查不写入 |
| `-y, --yes` | 跳过确认 |
| `-R, --restart` | 替换后执行 `/koolshare/scripts/clash_config.sh restart` |
| `-r, --remote-bin` | 远端路径（默认 `/koolshare/bin/clash`） |

脚本做的事：

1. 连不上时自动检测系统 ssh 配置权限问题，改用 `-F /dev/null` 重试
2. 校验远端是 aarch64，检查目标分区与 `/tmp` 剩余空间（替换前会先删旧文件，所以旧文件大小可计入可用空间）
3. 把旧内核**下载到本地** `backup/clash-<时间戳>`（大小校验）
4. 上传到 `/tmp/mihomo-trim-asuswrt.new`，在远端跑 `-v` 自检
5. 自检通过才替换；替换后再次自检，失败**自动回滚**到备份
6. 可选执行插件重启命令

> 密码建议用环境变量传，避免出现在 `ps` 里：
> `DEPLOY_PASSWORD='your-password' ./deploy.sh -H 192.168.50.1 -u your-username -y`

不想用脚本时的手工流程（路由器没有 `sftp-server`，`scp` 会失败，用管道）：

```bash
R=your-username@192.168.50.1          # 换成你的路由器地址与管理用户名
ssh $R 'cat /koolshare/bin/clash' > clash-old.bak                      # 备份
ssh $R 'cat > /tmp/clash-new && chmod +x /tmp/clash-new' < out/mihomo-trim-asuswrt-arm64
ssh $R '/tmp/clash-new -v'                                              # 自检
ssh $R 'rm -f /koolshare/bin/clash && cp /tmp/clash-new /koolshare/bin/clash \
        && chmod +x /koolshare/bin/clash && rm -f /tmp/clash-new'
```

然后在插件里**关闭再开启**。

## 配置要点

- 不需要 `tun:` 段；写了也只会打一行错误日志，不会崩。
- 想进一步压内存：精简 `rule-providers`（每个 http provider 都常驻内存）、
  或设 `GOMEMLIMIT=48MiB` 作为硬上限。

## 实测（aarch64 / 4 核 / 1 GB 内存）

配置：36 节点订阅 + 64 个 rule-providers + 101 条规则。下表本项目数据基于 `LOW_MEMORY=1` 构建。

| 形态 | 二进制 | 常驻内存 |
|---|---|---|
| 上游内核 v1.19.24（UPX + gvisor + TUN） | 7.9 MB（UPX） | 78.9 MB |
| 本项目产物 | 24.9 MB（未压缩） | **47–48 MB** |

> **别用 UPX**：UPX 启动时把整镜像解压到匿名内存，RSS 反而更高。未压缩的代码页是
> file-backed，可被内核回收。本项目刻意不压缩。

## 上游更新

```bash
git -C mihomo fetch --depth 1 origin Meta && git -C mihomo reset --hard FETCH_HEAD
./build.sh
```

补丁套不上时（冲突基本来自上游改动了被删文件）：

```bash
cd mihomo
git apply --reject ../patches/clientonly.patch   # 看 .rej 逐个并入
# 改完后重新生成补丁
git diff HEAD > ../patches/clientonly.patch
```

`router-gc.patch` 只动 `main.go`，上游很少改这个文件，通常不用重新生成。

## 目录

```
build.sh                    # 一键构建（单目标 arm64）
deploy.sh                   # 一键部署到路由器（ssh，支持密钥/密码）
patches/clientonly.patch    # 裁剪：删 244 个文件 + 改 10 个文件 + TUN 栈降级
patches/router-gc.patch     # main.go：GOGC=20 烘焙
mihomo/                     # 上游源码（构建时克隆，已 gitignore）
out/                        # 产物（已 gitignore）
backup/                     # deploy.sh 备份的旧内核（已 gitignore）
```

## 许可

mihomo 本身以 GPL-3.0 发布；本项目的补丁与脚本同样按 GPL-3.0 使用与分发。
