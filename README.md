# luci-app-xray-mosdns-x

OpenWrt / ImmortalWrt 的 LuCI 插件：用 **Xray**（TProxy 透明代理）和 **mosdns-x**（DNS 分流、缓存、去广告）
替代 PassWall、ChinaDNS 和 dnsmasq 的解析功能。当前为 **v1.0.10**，安装后默认 **不启用**，不会改动现有的代理和 DNS。

## 功能

- **一张规则表**：按域名、IP、端口、协议分流到总节点、指定节点、节点组、直连或阻断，第一条命中的生效。
  DNS 用哪个上游、内核怎么转发、Xray 怎么路由，都从这张表生成，不会各走各的
- **内核分流**：直连流量留在内核转发，不进 Xray；只有要代理的流量才送进 TProxy
- **DNS**：LAN 的 53 端口由 nftables 重定向到 mosdns-x，不改 dnsmasq 的配置。mosdns-x 不应答时自动交还 dnsmasq，
  Xray 不监听时自动把透明代理撤出，停止服务即恢复原状
- **节点**：vless / vmess / trojan / shadowsocks / hysteria2，支持粘贴分享链接导入、测速
- **节点组**：最快、按顺序（主备）、轮询、随机四种策略，可以当作总节点或规则出口；切换和恢复写进系统日志
- **广告过滤**：订阅 AdGuard 格式、hosts 或纯域名的拦截列表（内置 AdGuard 列表库目录），每天自动更新
- **按设备分流**：按 MAC 地址把某台设备送到指定出口或完全直连
- **改规则不断流**：规则通过 Xray 的 API 热加载，不重启 Xray；重载只重启配置变了的进程
- **其他**：查询日志和排行、解析与拦截统计、geo 数据查询、Xray / mosdns-x / geo 数据的在线更新和定时更新

做法和细节见 [docs/DESIGN.md](docs/DESIGN.md)。

## 需要什么

- OpenWrt / ImmortalWrt（apk 包管理，在 ImmortalWrt 25.12.2 x86_64 上开发和测试），nftables 防火墙
- `xray`（Xray-core，热加载规则需要 26.x）和 `mosdns-x`（[pmkol/mosdns-x](https://github.com/pmkol/mosdns-x)，
  不是 mosdns v5）。两者不是包依赖，可以用完整包安装、在“更新”页下载，或自己放到 `/usr/bin`
- `geosite.dat`、`geoip.dat`，默认放在 `/usr/share/v2ray`，同样可以用完整包或“更新”页获得
- 包依赖（`kmod-nft-tproxy`、`ucode-mod-socket`、`curl`、`unzip`、`ip-full` 等）由 apk 从软件源自动安装

## 安装

[发布页](https://github.com/zlylong/luci-app-xray-mosdns-x/releases)每个版本有两种文件。

**只装插件**（路由器能访问软件源）：

```sh
apk add --allow-untrusted luci-app-xray-mosdns-x-<版本>-r1.apk
```

**完整包**（路由器不能联网，或下载不到 Xray、mosdns-x、依赖包时）：`luci-app-xray-mosdns-x-<版本>-full-x86_64.tar.gz`
里带有插件、全部依赖包、Xray、mosdns-x 和 geo 数据，安装时不需要网络：

```sh
tar -xzf luci-app-xray-mosdns-x-<版本>-full-x86_64.tar.gz -C /tmp
sh /tmp/luci-app-xray-mosdns-x-<版本>-full-x86_64/install.sh
```

- 只适用于 x86_64。依赖包取自官方 ImmortalWrt 25.12.2 x86/64；固件不同时内核模块 `kmod-nft-tproxy` 配不上，
  安装会失败并说明原因，这时联网后加 `--online`
- 已有的 Xray、mosdns-x、geo 数据会保留，`--replace` 才换成包里的版本
- 解压后约 80 MB，装完可以删除

升级用同样的方式，配置保留。升级后页面没有变化时刷新浏览器缓存。

## 启用

1. LuCI → 服务 → Xray + mosdns-x：在“节点”页添加节点，在“分流”页选择总节点
2. 停用 PassWall 等其他透明代理：`/etc/init.d/passwall stop; /etc/init.d/passwall disable`
3. 在“概览”页启用并启动。启动或重载失败时，原因显示在“概览”页和“日志 → 插件服务”

检查：

```sh
/usr/libexec/xray-mosdns/status.sh
nslookup www.google.com 127.0.0.1#5335     # mosdns-x；路由器自己的 53 端口仍是 dnsmasq
logread | grep xray-mosdns                 # 每次重载的原因和结果、节点组的切换
```

回滚：`/etc/init.d/xray-mosdns stop`。nft 表和策略路由随即删除，DNS 回到 dnsmasq。
命令行改了配置后用 `/etc/init.d/xray-mosdns reload` 生效。

## 主要限制

- 内核按目的 IP 分流：端口、协议规则只对进入 Xray 的流量生效（例如开了“国内 IP 直连”，“22 端口走代理”对国内 IP 不生效）
- 设备绕过本机 DNS（自带 DoH/DoT）时，它的流量只能按 IP 规则和默认出口判定
- 按设备分流只改出口，不改 DNS；使用随机 MAC 的手机要先对这个 Wi-Fi 关闭“私有地址”
- IPv6 透明代理是实验性功能
- 不支持 TUIC / SSR，不支持订阅地址（分享链接要粘贴进来）

完整的列表和全部配置项见 [docs/CONFIG.md](docs/CONFIG.md)。

## 开发

- 测试、目录结构、编译和 CI：[docs/DESIGN.md](docs/DESIGN.md)
- 计划中：按设备的 DNS 策略、订阅地址自动更新节点。已完成的内容见各版本的发布说明

## 许可

MIT，见 [LICENSE](LICENSE)。完整包里的 Xray、mosdns-x、geo 数据和系统包是各自上游发布的原样文件，许可见包内的 README.txt。
