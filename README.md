# luci-app-xray-mosdns-x

LuCI 管理界面：用 **Xray**（TProxy 透明代理）+ **mosdns-x**（DNS 分流/缓存/去广告）
替代 PassWall 的插件。项目目前为 **v0.2.0 开发版**，默认 **不启用**：
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
- **多节点**：`node_mode=balance` 时所有 enabled 节点进入 Xray balancer
  （leastLoad/roundRobin/random，leastLoad 带 burstObservatory 健康检查，支持 fallback 节点）
- **规则管理**：`config rule` 段或 LuCI Rules 页按 域名/IP/端口/协议 分流到 proxy/direct/block
- **IPv6**：`ipv6_enabled=1` 时同时下发 IPv6 nft tproxy 规则与 `ip -6 rule/route`
- **节点流量**：Xray StatsService 按节点统计上下行（仅代理节点）
- **节点列表**：表格只显示 启用/备注/地址/延迟，点“详情”弹窗编辑全部参数，支持单节点测速、全部测速
- **订阅导入**：节点页“导入节点”弹窗粘贴 vless/vmess/trojan/ss/hysteria2 链接，批量生成（默认禁用）节点
- **分流逻辑（PassWall 风格）**：分流总节点（直连/指定节点/负载均衡）→ 分流模式内置规则（大陆白名单/GFW/全局/自定义）→ 自定义规则（规则优先级最高，可指向总节点、指定节点、负载均衡、直连、阻断）
- **规则页**：从 geosite.dat/geoip.dat 自动提取标签（本机 1562 个 geosite + 260 个 geoip），支持搜索、多选、chips 展示
- **首页看板**：运行状态磁贴 + 连通性检测（阿里/谷歌/GitHub/YouTube，先经代理、未运行时直连）
- **负载均衡说明**：平衡模式会把所有“启用”节点纳入 Xray balancer；leastLoad 每分钟健康检查一次，
  自动选择当前延迟最低的可用节点（选路/故障切换，不是按连接数分摊），无可用节点时使用备用节点
- **主备模型**：主节点 + 备节点；balancer 只包含主节点（单独 `fo-` 标签做健康检查），
  主节点探测失败时通过 `fallbackTag` 自动切换到备节点（备节点未配置则回落到直连）

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
- CI：构建 VM 每 2 分钟轮询 Gitea master 分支，有新提交则编译，
  并通过 Gitea Commit Status 回写结果（`build (build vm)` = pending/success/failure），
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
| dns | xray_dns_port | 兼容字段，v0.2 使用 SOCKS 方式转发，暂未使用 |
| dns | adblock | geosite:category-ads-all 拦截 |
| dns | filter_proxy_ipv6 | 代理域名丢弃 AAAA |
| dns | domestic_dns | 国内 DoH/DoT/明文上游列表 |
| dns | hosts | 静态域名映射（节点域名/VPS 域名解析用） |
| global | rule_mode | chnroute（大陆白名单）/ gfw（仅 GFW 列表走代理）/ global / custom |
| global | node_mode | single / balance（负载均衡） |
| global | balancer_strategy | leastLoad / roundRobin / random |
| global | fallback_node | balancer 无健康节点时的兜底节点 |
| global | ipv6_enabled | 启用 IPv6 TProxy（实验性） |
| node | type/address/port/uuid/... | vless / vmess / trojan / shadowsocks / hysteria2 节点 |
| global | api_port | Xray 本地统计 API 端口（默认 10085，用于节点流量） |
| rule | rule_type/value/outbound | 自定义分流规则：domain/ip/port/network → proxy/direct/block |

## 已知限制（v0.2）

- IPv6 TProxy 为实验性功能，需要节点本身可达 IPv6；IPv6 分流规则与 IPv4 共用 geosite/geoip 规则
- Xray 26.x 已移除 `allowInsecure`（跳过证书校验），插件不再生成该字段；需要绕过证书校验的场景请改用可信证书/域名
- Hysteria2 节点依赖 Xray 的 `hysteria` 协议 + hysteria 传输（Xray 26.x 起），测速对 UDP 节点会先试 TCP，失败后回退 ICMP
- 订阅导入支持 vless/vmess/trojan/shadowsocks（SIP002），不支持 Hysteria2/TUIC/SSR
- 规则管理为简单表单（每条规则一个域名/IP/端口集合），复杂表达式请直接编辑

## 路线图

- [x] 多节点 + 负载均衡 / 故障切换（Xray balancer + burstObservatory）
- [x] 规则管理 UI（域名/IP/端口分流可视化）
- [x] IPv6 TProxy（实验性）
- [x] 流量统计（复用 nlbwmon）
- [x] 订阅导入（vless/vmess/trojan/ss 链接）
- [x] Hysteria2 节点（协议 + 导入 + 生成配置）
- [x] 节点表格化：地址/延迟列、测速、详情弹窗、导入合并进节点页
- [x] PassWall 式分流模式（大陆白名单 / GFW 列表 / 全局 / 自定义）
- [x] 规则页 geo 标签搜索/多选（含 geosite/geoip 自动提取）
- [x] 备用节点可选全部节点（修复只能选“直连”的问题）
- [x] 分流总节点 / 负载均衡 / 规则 三级结构（PassWall 风格）
- [x] 节点页合并负载均衡设置，设置页移除旧版域名列表
- [x] 在线更新（Xray / mosdns-x / geo 数据，带备份）+ 远端版本对比
- [x] geo 数据定时更新（每日 cron，对比 release 版本，一致则跳过）
- [x] 分流规则可排序（↑/↓，序号即为匹配顺序）
- [x] 主备模型（主节点 + 备节点自动切换）
- [x] 更新页修正 mosdns-x 版本识别与远端版本对比
- [x] v0.8.0 UI 重设计：线路图式首页、统一的技图风格（等宽数据、方形端子、主题自适应）
- [x] 节点流量统计（Xray StatsService）
- [x] DNS 页面中文化、日志等级可选
- [ ] Gitea Actions 构建产物发布（未包含）

## 许可

MIT
