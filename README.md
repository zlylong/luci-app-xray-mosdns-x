# luci-app-xray-mosdns-x

LuCI 管理界面：用 **Xray**（TProxy 透明代理）+ **mosdns-x**（DNS 分流/缓存/去广告）
替代 PassWall 的插件。项目目前为 **v0.1.0 开发版**，默认 **不启用**：
安装后 `xray-mosdns.global.enabled` 仍为 `0`，不会改动现有代理/DNS 链路。

## 架构

```
客户端 ──► dnsmasq :53 ──► mosdns-x 127.0.0.1:5353
                              ├─ 国内域名 ──► 阿里/腾讯 DoH（直连，可带 ECS）
                              ├─ 广告域名  ──► NXDOMAIN (geosite:category-ads-all)
                              └─ 其它域名  ──► SOCKS5 127.0.0.1:1070 (Xray) ──► VPS ──► 1.1.1.1

客户端 ──► nftables prerouting ──► TProxy :12345 ──► Xray tunnel inbound
                              ├─ geosite:cn / geoip:cn ──► direct
                              ├─ 自定义 proxy 域名      ──► node
                              └─ 默认                  ──► node
```

- TCP/UDP 都走 nft `tproxy` + 策略路由（fwmark → table），不走 REDIRECT
- 国外 DNS 通过 Xray 的内部 SOCKS inbound 经代理解析，避免 DNS 泄漏
- `filter_proxy_ipv6` 会丢弃代理域名的 AAAA 应答，防止 IPv6 绕过代理

## 目录结构

```
├── Makefile                                  OpenWrt 包定义
├── root/etc/config/xray-mosdns               UCI 默认配置（enabled=0）
├── root/etc/init.d/xray-mosdns               procd 服务
├── root/usr/share/xray-mosdns/
│   ├── gen-config.sh                         生成 xray.json / mosdns.yaml / nft.rules
│   ├── fw.sh                                 nftables + 策略路由 apply/clear
│   └── dnsmasq.sh                            dnsmasq 集成/还原（带备份）
├── root/usr/libexec/xray-mosdns/
│   ├── status.sh                             状态 JSON
│   └── log.sh                                日志
├── htdocs/luci-static/resources/view/xray-mosdns/
│   ├── overview.js  settings.js  nodes.js  dns.js  log.js
└── .gitea/workflows/build.yml                Gitea Actions CI
```

## 依赖

运行时（软件包未硬依赖，便于使用手工编译的 xray / mosdns-x）：

- `xray`（Xray-core ≥ 1.8，TProxy tunnel inbound）——**不作为包依赖**，可使用手工编译版本
  （手工 xray 与 feed 的 `xray-core` 包会争用 `/usr/bin/xray`，因此默认不声明依赖）
- `mosdns` 或 `mosdns-x`（≥ v5 配置格式；推荐 pmkol/mosdns-x，带 `_new_empty_response` 等预设）
- `nftables` + `kmod-nft-tproxy` + `ip-full`（nftables/ip-full 已声明为包依赖；
  `kmod-nft-tproxy` 需单独安装，避免 SDK/CI 触发内核编译）
- `/usr/share/v2ray/geosite.dat`、`geoip.dat`（Loyalsoldier / v2ray 数据）

## 代码仓库与 CI

- 仓库：<https://github.com/zlylong/luci-app-xray-mosdns-x>
- CI：push 到 master 后由 Gitea Webhook 触发 构建 VM 编译，
- Gitea Actions 版流水线保留在 `ci/gitea-actions-build.yml`（暂未启用：容器内
  OpenWrt SDK 的 fakeroot 会卡死，需换支持 fakeroot 的 runner 或宿主模式）

## 编译

### 方式一：OpenWrt/ImmortalWrt SDK（推荐，CI 使用）

```sh
curl -LO https://downloads.immortalwrt.org/releases/25.12.2/targets/x86/64/immortalwrt-sdk-25.12.2-x86-64_gcc-14.3.0_musl.Linux-x86_64.tar.zst
tar --zstd -xf immortalwrt-sdk-25.12.2-*.tar.zst
cp -r luci-app-xray-mosdns-x immortalwrt-sdk-*/package/
cd immortalwrt-sdk-*
./scripts/feeds update -a && ./scripts/feeds install -a
make package/luci-app-xray-mosdns-x/compile V=s
# 产物: bin/packages/x86_64/luci/luci-app-xray-mosdns-x-0.1.0-r1.apk
```

### 方式二：本仓库自带脚本（在构建 VM 上）

```sh
scripts/build-in-vm.sh   # 下载 SDK、安装 feeds、编译并收集产物
```

## 安装（不启用）

```sh
apk add --allow-untrusted luci-app-xray-mosdns-x-0.1.0-r1.apk
# 或 opkg install ...
```

安装后插件处于未启用状态：`uci get xray-mosdns.@global[0].enabled` → `0`。

## 启用步骤（确认要替换 PassWall 后）

1. 在 LuCI → 服务 → Xray + mosdns-x → Settings 中选择节点（先到 Nodes 页添加）
2. 停用 PassWall：`/etc/init.d/passwall stop; /etc/init.d/passwall disable`
3. 启用本插件：`uci set xray-mosdns.@global[0].enabled=1; uci set xray-mosdns.@global[0].node=<节点名>; uci commit xray-mosdns`
4. 启动：`/etc/init.d/xray-mosdns start`
5. 检查：`/usr/libexec/xray-mosdns/status.sh`、`/usr/share/xray-mosdns/fw.sh status`
6. 验证 DNS：`nslookup www.baidu.com 127.0.0.1`、`nslookup www.google.com 127.0.0.1`

回滚：`/etc/init.d/xray-mosdns stop`（会还原 dnsmasq 配置、清空 nft/策略路由），
再启动 PassWall 即可。

## UCI 配置参考

`/etc/config/xray-mosdns`：

| section | option | 说明 |
|---|---|---|
| global | enabled | 总开关（默认 0） |
| global | tproxy_port | TProxy 监听端口，默认 12345 |
| global | fwmark / route_table | 策略路由标记/表号，默认 0x1 / 100 |
| global | default_outbound | 默认出口 proxy / direct |
| global | bypass_chn | 国内目的地直连（geosite:cn / geoip:cn） |
| global | node | 选中的节点 section 名 |
| global | socks_port | 内部 SOCKS 端口（给 mosdns 转发国外 DNS），默认 1070 |
| dns | listen_port | mosdns 监听端口，默认 5353（dnsmasq 指向它） |
| dns | xray_dns_port | 兼容字段，v0.1 使用 SOCKS 方式转发，暂未使用 |
| dns | adblock | geosite:category-ads-all 拦截 |
| dns | filter_proxy_ipv6 | 代理域名丢弃 AAAA |
| dns | domestic_dns | 国内 DoH/DoT/明文上游列表 |
| dns | hosts | 静态域名映射（节点域名/VPS 域名解析用） |
| node | type/address/port/uuid/... | vless / vmess / trojan / shadowsocks 节点 |

## 已知限制（v0.1）

- 只支持 IPv4 透明代理（IPv6 客户端流量不劫持）
- 只有单个选中节点，未实现负载均衡/多节点自动切换（路线图）
- dnsmasq 集成会替换 `dhcp.@dnsmasq[0].server` 列表（备份可还原）
- 与 PassWall 同时运行会被拒绝启动（`global.allow_coexist=1` 可强制）
- WebSocket 传输在 Xray 26 中已弃用，建议使用 XHTTP

## 路线图

- [ ] 多节点 + 负载均衡 / 故障切换（Xray balancer）
- [ ] 规则管理 UI（域名/IP/端口分流可视化）
- [ ] IPv6 TProxy
- [ ] 流量统计（复用 nlbwmon）
- [ ] 订阅导入（clash/v2ray 链接解析）
- [ ] Gitea Actions 构建产物发布

## 许可

MIT
