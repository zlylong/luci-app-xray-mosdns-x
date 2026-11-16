# luci-app-xray-mosdns-x

LuCI 管理界面：用 **Xray**（TProxy 透明代理）+ **mosdns-x**（DNS 分流/缓存/去广告）
替代 PassWall、ChinaDNS 和 dnsmasq 解析功能的插件。当前为 **v0.9.2 开发版**，默认 **不启用**：
安装后 `xray-mosdns.global.enabled` 仍为 `0`，不会改动现有代理/DNS 链路。

## 架构

所有后端都从同一份“分流计划”生成：每条规则归为 代理 / 直连 / 阻断 三类，分流模式决定
默认类别。mosdns、nftables、Xray 读的是同一份计划，DNS 的判断和转发的判断不会各走各的。

```
DNS：
LAN 客户端 :53 ──nft redirect──► mosdns-x :5335
                 ├─ 本地域名 / 反向解析 ──► dnsmasq 127.0.0.1:53（DHCP 主机名）
                 ├─ 规则：阻断          ──► NXDOMAIN
                 ├─ 规则：直连          ──► 国内上游 ──► 应答 IP 写入 direct4_dns
                 ├─ 规则：代理          ──► SOCKS5 → Xray → 国外 DNS ──► 应答 IP 写入 proxy4_dns
                 ├─ 广告域名            ──► NXDOMAIN
                 └─ 未命中任何规则：按默认出口（直连走国内上游，代理走国外上游）

转发（nft prerouting，只处理从 LAN 接口进入的 TCP/UDP）：
  已交给 Xray 的连接（conntrack 标记）──► TProxy
  非新建连接                            ──► 内核直接转发
  新连接按目的地址判定一次：
    保留地址 / 节点地址 / bypass_ips   ──► 直连
    direct4_dns（域名规则解析出的地址）  ──► 直连
    proxy4_dns                          ──► TProxy :12345 ──► Xray
    ipg4_0 … ipg4_7（IP 规则，按规则顺序） ──► 直连或 TProxy
    其余                                ──► 默认出口
```

- **内核分流**：直连流量不进 Xray，留在内核转发路径上（可用 flow offload）；只有需要代理的
  流量才 TProxy。`kernel_split=0` 可退回“全部进 Xray 再分流”
- **DNS 接管不改 dnsmasq**：LAN 的 53 端口由 nft 重定向到 mosdns-x，写死 DNS 的客户端也会被接管；
  mosdns 能看到真实客户端 IP。停止服务或删除 nft 表后立即回到 dnsmasq，没有需要还原的配置
- **只处理选中的入口接口**：默认是 LAN，可以在“系统 → 接口”里加上 VPN 等接口；
  从其他接口（包括 WAN）进入的流量、发往路由器自身的流量都不会被 TProxy
- **连接级判定**：一个连接只在首包判定一次，之后集合内容变化不会打断已有连接
- **节点域名不在生成配置时解析**：直接交给 Xray 在拨号时解析，开机 WAN 未就绪也能启动，
  节点 IP 变化无需重启；节点域名在 mosdns 中固定走国内上游
- **重载不断流**：`reload` 重新生成配置，nft 规则在单个事务内替换，procd 只重启配置文件
  发生变化的进程；生成失败时保留上一份可用配置继续运行
- 国外 DNS 通过 Xray 的内部 SOCKS inbound 经代理解析，避免 DNS 泄漏
- AAAA 过滤分两个开关：`filter_proxy_ipv6`（代理域名，默认开，防止经 IPv6 绕过代理）和
  `filter_direct_ipv6`（直连域名，默认关，上联没有可用 IPv6 时打开）
- **节点组**：把几个节点组合成一个出口，可以建任意多个，和节点一样能被选作总节点或规则出口。
  策略有 最快 / 按顺序 / 轮询 / 随机；成员由 Xray 的 burstObservatory 探测，全部不可用时走组的兜底出口。
  “按顺序”由一个看护进程（`groups.uc watch`）每 10 秒检查一次：当前成员可用就保持不动，
  不可用时切到列表里最靠前的可用成员。默认不会因为前面的成员恢复而切回，
  需要切回可以打开组的“恢复后切回”；概览页显示每个组当前的出口，并可临时锁定到某个成员
- **节点的“启用”**就是字面意思：未启用的节点不生成出站、不能被选用，和是否属于某个组无关
- **没有“分流模式”**：只有一张规则表和一个默认出口。“国内直连”“GFW 列表”“去广告”都是表里
  看得见的普通规则行，可以开关、修改、拖动排序；“大陆白名单 / GFW 列表 / 全局”是一键预设，
  只负责设置默认出口并开关这几行
- **规则**：按 域名/IP/端口/协议 分流到 总节点/指定节点/节点组/直连/阻断，第一条命中的生效；
  域名规则同时决定 DNS 上游；IP 规则里的任何 `geoip:` 标签都会从 geoip.dat 提取进内核集合

## 目录结构

```
├── Makefile                                  OpenWrt 包定义
├── root/etc/config/xray-mosdns               UCI 默认配置（enabled=0）
├── root/etc/init.d/xray-mosdns               procd 服务（start 幂等，兼作 reload）
├── root/usr/share/xray-mosdns/
│   ├── gen-config.uc                         生成器入口：xray.json / mosdns.yaml / nft.rules
│   ├── fw.sh                                 nftables 加载 + 策略路由 apply/clear/status
│   └── dnsmasq.sh                            仅用于还原 ≤0.8 版本改写过的 dnsmasq 配置
├── root/usr/share/ucode/xray_mosdns/
│   ├── config.uc                             UCI → 规范化配置 + 分流计划
│   ├── xray.uc  mosdns.uc  nft.uc            三个后端，各自返回对象/文本
│   ├── geoip.uc                              从 geoip.dat 提取大陆网段（带缓存）
│   └── util.uc                               校验、YAML 输出等
├── root/usr/libexec/xray-mosdns/             状态、流量、测速、更新、导入等辅助脚本
│   ├── groups.uc                             节点组：查询当前出口、锁定、看护进程
│   └── geoview.uc                            geo 数据查询：tags / lookup / list / dump
├── htdocs/luci-static/resources/view/xray-mosdns/   LuCI 页面（原生表单组件，无自定义主题）
│   ├── status.js                             概览：运行状态、启停、连通性、节点流量
│   ├── nodelist.js                           节点：列表、导入、测速、节点组
│   ├── routing.js                            分流：总节点、分流模式、规则
│   ├── resolver.js                           DNS：接管、上游、缓存与过滤
│   ├── system.js                             系统：运行参数
│   ├── components.js                         更新：Xray / mosdns-x / geo 数据、定时更新
│   ├── geoview.js                            Geo 查询：域名/IP 反查数据集、查看和下载数据集内容
│   └── logview.js                            日志
├── tests/                                    夹具配置 + 生成/断言脚本
└── ci/gitea-actions-build.yml                Gitea Actions CI（暂未启用）
```

## 测试

生成器可以脱离路由器测试（需要一个带 ucode/uci 的 OpenWrt rootfs，例如官方容器镜像）：

```sh
podman run --rm --network none -v "$PWD":/src:ro -v /tmp/xm-test:/out \
    docker.io/openwrt/rootfs:x86-64-24.10.4 sh /src/tests/gen.sh /src /out
python3 tests/check.py /tmp/xm-test          # 对三套夹具的输出做断言
# tests/migrate.sh（同样在 rootfs 里跑）：升级迁移前后生成结果必须逐字节一致
xray run -test -c /tmp/xm-test/chnroute/xray.json
```

## 依赖

运行时（软件包未硬依赖，便于使用手工编译的 xray / mosdns-x）：

- `xray`（Xray-core ≥ 1.8，TProxy tunnel inbound）——**不作为包依赖**，可使用手工编译版本
  （手工 xray 与 feed 的 `xray-core` 包会争用 `/usr/bin/xray`，因此默认不声明依赖）
- `mosdns-x`（pmkol/mosdns-x，mosdns v4 配置格式；需要其 `nftset` 插件和 `_new_empty_response` 等预设）
- `nftables` + `kmod-nft-tproxy` + `ip-full`（nftables/ip-full 已声明为包依赖；
  `kmod-nft-tproxy` 需单独安装，避免 SDK/CI 触发内核编译）
- `ucode` + `ucode-mod-uci` / `ucode-mod-fs` / `ucode-mod-ubus`（生成器；LuCI 本身已依赖）
- `python3`（仅概览页的节点流量和节点测速使用，未声明为包依赖）
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
6. 验证 DNS：`nslookup www.baidu.com 127.0.0.1#5335`、`nslookup www.google.com 127.0.0.1#5335`
   （路由器本机的 53 端口仍是 dnsmasq，只有 LAN 客户端的查询被重定向）
7. 查看集合：`nft list set inet xray-mosdns proxy4_dns`

回滚：`/etc/init.d/xray-mosdns stop`（删除 nft 表和策略路由，DNS 随即回到 dnsmasq），
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
| global | kernel_split | 内核分流（默认 1）；0 = 所有流量进 Xray 再分流 |
| global | lan_ifaces | 被代理的逻辑接口列表，默认 `lan`；可以加 VPN 等接口，界面里从系统接口中选择 |
| global | lan_devices | 直接指定设备名（如 `br-lan`），设置后不再查询 lan_ifaces |
| dns | listen_port | mosdns 监听端口，默认 5335（不要用 5353，mDNS 占用） |
| dns | redirect | nft 把 LAN 的 53 端口重定向到 mosdns（默认 1） |
| dns | filter_proxy_ipv6 | 代理域名不返回 AAAA（默认 1） |
| dns | filter_direct_ipv6 | 直连域名不返回 AAAA（默认 0） |
| dns | domestic_dns | 国内 DoH/DoT/明文上游列表 |
| dns | hosts | 静态域名映射（节点域名/VPS 域名解析用） |
| global | default_action | 没有命中任何规则的流量：proxy（走总节点）/ direct |
| group | remarks / strategy / member / fallback | 节点组：名称；fastest / ordered / roundrobin / random；成员列表（ordered 时即挑选顺序）；全部不可用时的出口 |
| group | failback | 仅 ordered：0（默认）切换后只有当前成员不可用才再切；1 前面的成员恢复后立即切回 |
| global | probe_url / probe_interval | 节点组的探测地址与间隔，默认 gstatic generate_204 / 1m |
| global | schema | 配置版本，由包维护，不要改 |
| global | ipv6_enabled | 启用 IPv6 TProxy（实验性） |
| node | type/address/port/uuid/... | vless / vmess / trojan / shadowsocks / hysteria2 节点 |
| global | api_port | Xray 本地统计 API 端口（默认 10085，用于节点流量） |
| rule | rule_type/value/outbound | 分流规则，从上到下匹配：domain/ip/port/network → main/节点/balance/failover/direct/block；`value` 是列表 |
| rule | builtin_ads / builtin_cn_domain / builtin_cn_ip / builtin_noncn / builtin_gfw | 预置规则行，和普通规则完全一样，“快速预设”只是开关它们 |

## 已知限制

- 内核分流按目的 IP 判定：端口/协议规则只对进入 Xray 的流量生效。
  例如启用“国内 IP 直连”时，“22 端口走代理”对国内 IP 不生效（国内 IP 在内核已直连）
- 内核里域名规则解析出的地址先于 IP 规则判定，IP 规则之间保持表中的顺序（最多 8 组连续同类规则）；
  进入 Xray 的流量再按完整的规则顺序判定一次
- 预置行可以被拖到自己的规则前面从而盖住它们，顺序由你负责
- “按顺序”的切换延迟约等于探测间隔加看护周期（默认 1 分钟 + 10 秒）；看护进程退出时组会停在
  最后锁定的成员上，由 procd 拉起后恢复
- “按顺序”组记住的当前成员保存在 Xray 进程里：Xray 重启（改配置、更新、重启路由器）后，
  会重新从列表最靠前的可用成员开始
- 轮询和随机会让同一网站看到多个出口 IP，可能触发登录验证；节点组的锁定是临时的，重启后恢复自动
- 多个域名共用同一 IP（CDN）且分属代理与直连时，以先写入集合的一方为准，直连集合优先
- 客户端若绕过本机 DNS（DoH/DoT），其流量只能按 IP 集合和模式默认值判定
- 路由器自身发出的流量不经过 TProxy（未挂 output 链）
- `dns.enabled=0` 时无法填充集合，内核分流自动关闭
- *_dns 集合元素 3 天过期；DNS 规则变化时集合会清空并随 mosdns 重启重新学习

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
- [x] v0.9.0 数据面重构：ucode 生成器、单一分流计划、内核分流、nft 重定向接管 DNS、无断流重载
- [x] v0.9.0 前端重做：改用 LuCI 原生组件，10 个页面合并为 5 个
- [x] v0.9.1 取消分流模式：默认出口 + 可见的预置规则行 + 一键预设；去广告并入规则表
- [x] v0.9.2 节点组：取代单一的负载均衡和主备，支持多组、多级按顺序切换、查看与锁定当前出口
- [ ] 路由器自身流量代理（output 链）
- [ ] 去广告订阅列表 / 查询日志（替代 ADG）
- [ ] 订阅 URL 自动更新、按设备访问控制
- [ ] Gitea Actions 构建产物发布（未包含）

## 许可

MIT
