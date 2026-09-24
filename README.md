# tuic-singbox-installer

基于 [sing-box](https://sing-box.sagernet.org/) 的 **TUIC v5** 一键安装脚本。

- 通过 sing-box **官方 APT 源**安装，之后可以直接用 `apt upgrade` 跟随官方更新
- 使用 sing-box 1.14 新增的 **certificate provider（ACME）** 自动申请、续期 Let's Encrypt 证书，不需要另外装 acme.sh 或 certbot
- 已适配 sing-box 1.14 的新写法：旧的 TLS 内联 `acme` 写法在 1.14 已弃用，1.16 将被移除
- 安装完成后自动输出分享链接、Clash Verge（Mihomo）配置和 sing-box 客户端配置

> 配套图文教程：[TUIC v5 搭建教程：基于 sing-box 1.14，从零到客户端连接](https://main.suduwuxian.top/tuic-v5-sing-box-tutorial/)

## 准备工作

1. 一台海外 VPS，系统为 **Debian 11+ 或 Ubuntu 20.04+**，有 root 权限
2. 一个域名，添加一条 **A 记录**指向 VPS 的 IP
   - 如果用 Cloudflare 管理 DNS，这条记录必须设置为 **「仅 DNS」（灰色云朵）**，否则证书会申请失败
3. 在云服务商控制台的安全组 / 防火墙里放行：
   - `80/tcp`、`443/tcp`：申请证书时使用（HTTP-01 / TLS-ALPN-01 验证）
   - `443/udp`（或你自定义的端口）：TUIC 本身走 UDP

## 一键安装

```bash
curl -fsSL https://raw.githubusercontent.com/suduwuxiantop/tuic-singbox-installer/main/install.sh -o install.sh
bash install.sh install -d tuic.example.com -e you@example.com
```

参数说明：

| 参数 | 说明 | 默认值 |
|------|------|--------|
| `-d` | 已解析到本机的域名 | 必填（不填会交互询问） |
| `-e` | 申请证书用的邮箱 | 必填（不填会交互询问） |
| `-p` | TUIC 监听的 UDP 端口 | `443` |

安装完成后，客户端连接信息会显示在屏幕上，并保存在 `/etc/sing-box/tuic-client-info.txt`。

## 其他命令

```bash
bash install.sh info        # 重新显示客户端连接信息
bash install.sh uninstall   # 停止服务并移除配置（原配置会改名备份）
```

查看日志、重启服务：

```bash
journalctl -u sing-box --output cat -e
systemctl restart sing-box
```

## 脚本做了什么

1. 检查系统（Debian / Ubuntu + systemd）和 root 权限
2. 检查域名是否解析到本机 IP，以及 UDP 端口是否被占用
3. 通过官方 APT 源安装 sing-box，并要求版本 ≥ 1.14.0
4. 用 `sing-box generate` 生成随机 UUID 和密码，写入 `/etc/sing-box/config.json`（原文件会先备份）
5. 用 `sing-box check` 校验配置
6. 如果检测到 ufw / firewalld，自动放行所需端口
7. 启动服务，并等待证书签发（最长 120 秒）

生成的服务端配置和 [`examples/server.json`](examples/server.json) 结构一致，可以对照阅读。

## 客户端

| 平台 | 推荐客户端 | 导入方式 |
|------|-----------|---------|
| Windows | v2rayN（sing-box 内核）/ Clash Verge Rev | 分享链接 / Mihomo 配置 |
| macOS | Clash Verge Rev / sing-box 官方客户端（SFM） | Mihomo 配置 / sing-box 配置 |
| Android | NekoBox / sing-box 官方客户端（SFA） | 分享链接 / sing-box 配置 |
| iOS | sing-box 官方客户端（SFI） | sing-box 配置 |

配置示例：

- [`examples/client-mihomo.yaml`](examples/client-mihomo.yaml)：Clash Verge Rev 等 Mihomo 内核客户端
- [`examples/client-sing-box.json`](examples/client-sing-box.json)：sing-box 客户端，在本地 `127.0.0.1:2080` 开一个 SOCKS/HTTP 混合代理端口

## 关键参数说明

| 参数 | 本项目取值 | 说明 |
|------|-----------|------|
| `congestion_control` | `bbr` | QUIC 拥塞控制算法，可选 `cubic`（sing-box 默认）、`new_reno`、`bbr`。在丢包较多的跨境线路上 BBR 通常更稳 |
| `zero_rtt_handshake` | `false` | 0-RTT 握手存在重放攻击风险，官方文档强烈建议关闭 |
| `alpn` | `h3` | 服务端和客户端必须一致 |
| `udp_relay_mode` | `native` | 客户端 UDP 转发模式，可选 `native` / `quic` |
| `heartbeat` | `10s` | 保活心跳间隔 |

## 常见问题

**证书一直签发不下来**
按顺序检查：安全组是否放行了 `80/tcp` 和 `443/tcp`；域名是否解析到本机、是否开启了 Cloudflare 代理；80 和 443 TCP 端口是否都被 Nginx 等程序占用。

**服务启动了，客户端连不上**
TUIC 走的是 **UDP**，最常见的原因是安全组只放行了 TCP。另外确认客户端的 SNI、ALPN（`h3`）、UUID、密码和服务端完全一致。

**有些网络下完全连不上**
部分运营商或公司网络会限制 UDP / QUIC 流量，这种环境下所有基于 QUIC 的协议（TUIC、Hysteria2）都会受影响，需要换用基于 TCP 的协议。

## 参考文档

- [sing-box 安装（包管理器）](https://sing-box.sagernet.org/installation/package-manager/)
- [TUIC inbound](https://sing-box.sagernet.org/configuration/inbound/tuic/) / [TUIC outbound](https://sing-box.sagernet.org/configuration/outbound/tuic/)
- [TLS](https://sing-box.sagernet.org/configuration/shared/tls/)
- [Certificate Provider](https://sing-box.sagernet.org/configuration/shared/certificate-provider/) / [ACME](https://sing-box.sagernet.org/configuration/shared/certificate-provider/acme/)

## 免责声明

本项目仅供学习网络协议与服务器运维使用。请遵守你所在地区的法律法规，以及服务器提供商的使用条款。

## License

[MIT](LICENSE)
