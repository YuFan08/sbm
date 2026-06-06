# sbm

一个简体中文菜单式 Linux/WSL 系统工具脚本。

## 一键安装

```bash
curl -fsSL https://raw.githubusercontent.com/YuFan08/sbm/main/install.sh | bash
```

安装完成后运行：

```bash
sbm
```

## 本地运行

```bash
chmod +x system-tool.sh
./system-tool.sh
```

## 功能

- 查看基本系统信息、CPU、内存、磁盘、本机 IP
- 使用 `ufw` 放行端口
- 一键部署 sing-box 节点
  - 一键同时部署 VLESS Reality、TUIC v5、Hysteria2、AnyTLS、CF VMess 五个节点
  - CF VMess 使用 WebSocket + TLS，支持填写 Cloudflare 优选 IP，可导入 Clash / v2ray 客户端
  - 默认使用自签名证书
  - 支持手动添加/替换已准备好的域名证书
  - 支持自动申请域名证书并生成节点
  - 支持使用 Cloudflare API Token 通过 DNS-01 申请域名证书
  - 支持查看证书到期状态
  - 支持 certbot 管理证书的自动检查/续期，并在续期后同步到 sing-box
  - 部署后输出通用分享链接，可一次复制全部节点导入客户端
  - 随时查看所有节点通用链接，直接输出纯节点地址
  - Purge 删除节点配置和节点信息，便于重新部署
  - 开启 BBR 加速
- 新机开机工具
  - 一键更新系统
  - 安装 `wget`、`curl`、`git`、`vim`、`jq`、`net-tools`、`iproute2` 等常用工具
- 一键安装 Docker
  - 使用 Docker 官方 apt 仓库安装 Docker Engine
  - 安装 Docker CLI、Buildx、Compose 插件
- 证书一键迁移
  - 复制完整 `/etc/letsencrypt` 到新机器后自动接管
  - 同步证书到 sing-box
  - 自动安装续期 hook
  - 启用系统 certbot timer，或在缺失时创建 `sbm-certbot-renew.timer`

## 说明

部署 sing-box 节点时，脚本会按需安装 sing-box，生成 `/etc/sing-box/config.json`，备份旧配置，执行配置检查，并通过 systemd 重启 `sing-box` 服务。节点信息保存到 `/etc/sbm/node-links.txt`。

手动添加域名证书时，请提前准备好已解析域名对应的证书文件和私钥文件。脚本会复制到 `/etc/sing-box/certs/server.crt` 和 `/etc/sing-box/certs/server.key`。

自动申请域名证书使用 `certbot --standalone`，请确保域名已经解析到当前服务器，并且公网可以访问本机 80 端口。使用真实域名证书时，生成的 TUIC、Hysteria2、AnyTLS 链接不会携带 `insecure=1`。

Cloudflare API Token 方式使用 DNS-01 验证，不需要开放 80 端口。Token 需要 `Zone:DNS:Edit` 权限，建议只授权目标域名所在 Zone。脚本会把 Token 写入 `/etc/letsencrypt/cloudflare.ini` 并设置为 `600` 权限。

证书自动续期功能会安装 certbot deploy hook 到 `/etc/letsencrypt/renewal-hooks/deploy/sbm-sync-sing-box.sh`。certbot 会定期检查证书是否接近到期，续期成功后，脚本会把新证书复制到 `/etc/sing-box/certs/` 并重启 `sing-box`。

自动续期只适用于 certbot 管理的证书，例如 `certbot --standalone` 和 Cloudflare DNS-01 方式申请的证书。手动导入的证书可以检查到期时间，但脚本无法自动向原签发方续期。

证书迁移时请复制完整 `/etc/letsencrypt`，至少包含：

```bash
/etc/letsencrypt/live/你的域名/
/etc/letsencrypt/archive/你的域名/
/etc/letsencrypt/renewal/你的域名.conf
```

迁移后进入“一键部署 sing-box 节点”子菜单，运行“证书一键迁移”，脚本会接管后续检查和续期。若系统没有原生 `certbot.timer`，脚本会创建自己的 `sbm-certbot-renew.timer`。

部分功能需要 `sudo` 权限。如果运行在 WSL 中，外部访问还可能受 Windows 防火墙和端口转发影响。
