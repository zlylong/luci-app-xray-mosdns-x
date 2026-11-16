# luci-app-xray-mosdns-x

LuCI 管理界面：用 **Xray**（TProxy 透明代理）+ **mosdns-x**（DNS 分流/缓存/去广告）
替代 PassWall、ChinaDNS 和 dnsmasq 解析功能的插件。当前为 **v0.9.0 开发版**，默认 **不启用**：
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
                 └─ 分流模式内置规则（大陆白名单 / GFW / 全局 / 自定义）

转发（nft prerouting，只处理从 LAN 接口进入的 TCP/UDP）：
  已交给 Xray 的连接（conntrack 标记）──► TProxy
  非新建连接                            ──► 内核直接转发
  新连接按目的地址判定一次：
    保留地址 / 节点地址 / bypass_ips   ──► 直连
    direct4 / direct4_dns               ──► 直连
    proxy4 / proxy4_dns                 ──► TProxy :12345 ──► Xray
    chnroute4（大陆白名单模式）         ──► 直连
    其余                                ──► 按模式默认（GFW 模式直连，其它模式 TProxy）
```

- **内核分流**：直连流量不进 Xray，留在内核转发路径上（可用 flow offload）；只有需要代理的
  流量才 TProxy。`kernel_split=0` 可退回“全部进 Xray 再分流”
- **DNS 接管不改 dnsmasq**：LAN 的 53 端口由 nft 重定向到 mosdns-x，写死 DNS 的客户端也会被接管；
  mosdns 能看到真实客户端 IP。停止服务或删除 nft 表后立即回到 dnsmasq，没有需要还原的配置
- **只处理 LAN 入口**：从 WAN 进入的流量、发往路由器自身的流量都不会被 TProxy
- **连接级判定**：一个连接只在首包判定一次，之后集合内容变化不会打断已有连接
- **节点域名不在生成配置时解析**：直接交给 Xray 在拨号时解析，开机 WAN 未就绪也能启动，
  节点 IP 变化无需重启；节点域名在 mosdns 中固定走国内上游
- **重载不断流**：`reload` 重新生成配置，nft 规则在单个事务内替换，procd 只重启配置文件
  发生变化的进程；生成失败时保留上一份可用配置继续运行
- 国外 DNS 通过 Xray 的内部 SOCKS inbound 经代理解析，避免 DNS 泄漏
- `filter_proxy_ipv6` 会丢弃代理域名的 AAAA 应答，防止 IPv6 绕过代理
- **多节点**：负载均衡（leastLoad/roundRobin/random，带 burstObservatory 健康检查与备用节点）、
  主备模型（主节点探测失败时切到备节点）
- **规则**：按 域名/IP/端口/协议 分流到 总节点/指定节点/负载均衡/主备/直连/阻断，按顺序匹配，
  优先级高于分流模式；域名规则同时决定 DNS 上游，命中的用户规则不受去广告拦截
- **GFW 模式**：只有 `geosite:gfw` 和规则指定的目标走代理，其余全部直连

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
├── htdocs/luci-static/resources/view/xray-mosdns/   LuCI 页面
├── tests/                                    夹具配置 + 生成/断言脚本
└── ci/gitea-actions-build.yml                Gitea Actions CI（暂未启用）
```

## 测试

生成器可以脱离路由器测试（需要一个带 ucode/uci 的 OpenWrt rootfs，例如官方容器镜像）：

```sh
podman run --rm --network none -v "$PWD":/src:ro -v /tmp/xm-test:/out \
    docker.io/openwrt/rootfs:x86-64-24.10.4 sh /src/tests/gen.sh /src /out
python3 tests/check.py /tmp/xm-test          # 对三套夹具的输出做断言
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
- `python3`（仅流量统计页和 geo 标签选择器使用，未声明为包依赖）
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
| global | lan_ifaces | 被代理的逻辑接口列表，默认 `lan` |
| global | lan_devices | 直接指定设备名（如 `br-lan`），设置后不再查询 lan_ifaces |
| dns | listen_port | mosdns 监听端口，默认 5335（不要用 5353，mDNS 占用） |
| dns | redirect | nft 把 LAN 的 53 端口重定向到 mosdns（默认 1） |
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

## 已知限制

- 内核分流按目的 IP 判定：端口/协议规则、`geoip:` 标签规则只对进入 Xray 的流量生效。
  例如大陆白名单模式下“22 端口走代理”对国内 IP 不生效（国内 IP 在内核已直连）
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
- [ ] 路由器自身流量代理（output 链）
- [ ] 去广告订阅列表 / 查询日志（替代 ADG）
- [ ] 订阅 URL 自动更新、按设备访问控制
- [ ] Gitea Actions 构建产物发布（未包含）

## 许可

MIT
