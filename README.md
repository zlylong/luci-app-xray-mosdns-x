# luci-app-xray-mosdns-x

LuCI 管理界面：用 **Xray**（TProxy 透明代理）+ **mosdns-x**（DNS 分流/缓存/去广告）
替代 PassWall、ChinaDNS 和 dnsmasq 解析功能的插件。当前为 **v0.9.7 开发版**，默认 **不启用**：
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
    同时在 direct4_dns 和 proxy4_dns   ──► TProxy，Xray 按嗅探到的域名判定（开启嗅探时）
    direct4_dns（域名规则解析出的地址）  ──► 直连
    proxy4_dns                          ──► TProxy :12345 ──► Xray
    ipg4_0 … ipg4_7（IP 规则，按规则顺序） ──► 直连或 TProxy
    其余                                ──► 默认出口
```

- **内核分流**：直连流量不进 Xray，留在内核转发路径上（可用 flow offload）；只有需要代理的
  流量才 TProxy。`kernel_split=0` 可退回“全部进 Xray 再分流”
- **DNS 接管不改 dnsmasq**：LAN 的 53 端口由 nft 重定向到 mosdns-x，写死 DNS 的客户端也会被接管；
  mosdns 能看到真实客户端 IP。停止服务或删除 nft 表后立即回到 dnsmasq，没有需要还原的配置
- **DNS 看门狗**：53 端口的重定向规则只在 mosdns-x 有应答时才存在。看门狗每 5 秒探测一次，
  连续两次无应答就撤掉规则让 dnsmasq 接管，恢复后自动装回；启动时也是等 mosdns-x 能应答了才接管，
  所以启动和重载期间不会出现解析空窗
- **Xray 看护**：同一个看门狗也看 Xray 的 TProxy 端口。启动后或运行中 Xray 不再监听（崩溃、procd 放弃重启）
  持续 15–20 秒，就在 prerouting / output 链最前面加一条 return，把透明代理撤出路径，流量暂时直连而不是
  送进不通的端口；同一个 nft 事务里 LAN 的 53 端口也交还 dnsmasq（mosdns 的国外上游经 Xray，此时同样不通）。
  概览页显示原因。Xray 恢复监听后自动撤掉这两条规则，DNS 重定向由看门狗在 mosdns 能应答时装回；
  重载时撤出状态保持不变，不会把流量送回不通的端口。procd 能及时拉起的单次崩溃不会触发
- **只处理选中的入口接口**：默认是 LAN，可以在“系统 → 接口”里加上 VPN 等接口；
  从其他接口（包括 WAN）进入的流量、发往路由器自身的流量都不会被 TProxy
- **Xray 不参与解析**：路由策略为 `AsIs`，没有内置 DNS。透明代理的连接自带真实目的地址（就是 mosdns-x 给客户端的那个），
  IP 规则按它匹配，域名规则按嗅探到的域名匹配；“域名没命中时按解析结果判断”由 mosdns-x 在 DNS 阶段完成
- **连接级判定**：一个连接只在首包判定一次，之后集合内容变化不会打断已有连接
- **节点域名不在生成配置时解析**：直接交给 Xray 在拨号时解析，开机 WAN 未就绪也能启动，
  节点 IP 变化无需重启；节点域名在 mosdns 中固定走国内上游
- **重载不断流**：`reload` 重新生成配置，nft 规则在单个事务内替换，procd 只重启配置文件
  发生变化的进程；生成失败、或启动前检查（二进制、geo 数据缺失等）失败时保留上一份可用配置继续运行，
  概览页显示原因。生成的配置旁边有一份 `runtime.env`，记下这份配置用的端口、防火墙标记、二进制路径等；
  防火墙脚本、看门狗、节点组看护、状态页、流量和连通性检查都按它工作，所以没有生效的 UCI 修改不会让它们和
  运行中的配置对不上。新的一套文件要么全部换上，要么整套留在旧的；旧的一套也无法完整放回时服务停止并说明原因。
  启动、重载和停止互相排队，不会同时进行
- 国外 DNS 通过 Xray 的内部 SOCKS inbound 经代理解析；从这个 inbound 进来的流量固定走总节点，不受规则表和默认出口影响。
  可以配置多个国外上游（IP 或 tcp/tls/https 地址）
- AAAA 过滤同时作用于 HTTPS 记录（类型 65）查询，它同样能带出 IPv6 地址
- AAAA 过滤分两个开关：`filter_proxy_ipv6`（代理域名，默认开，防止经 IPv6 绕过代理）和
  `filter_direct_ipv6`（直连域名，默认关，上联没有可用 IPv6 时打开）
- **节点组**：把几个节点组合成一个出口，可以建任意多个，和节点一样能被选作总节点或规则出口。
  策略有 最快 / 按顺序 / 轮询 / 随机；成员由 Xray 的 burstObservatory 探测，全部不可用时走组的兜底出口。
  “按顺序”由一个看护进程（`groups.uc watch`）每 10 秒检查一次：当前成员可用就保持不动，
  不可用时切到列表里最靠前的可用成员。默认不会因为前面的成员恢复而切回，
  需要切回可以打开组的“恢复后切回”；概览页显示每个组当前的出口，并可临时锁定到某个成员
- **路由器自身流量**（可选）：output 链里按同一套分类给路由器发起的连接打标记，策略路由把它们
  绕回 lo，再由 prerouting 送进 TProxy。Xray 和 mosdns 自己发的包带 `self_mark`，不会被再次送回；
  路由器自己的 53 端口查询同时重定向到 mosdns，同样受 DNS 看门狗管理
- **广告过滤订阅**：可以直接从 AdGuard Home 的列表库（内置目录快照，66 个列表）里选，或填自定义地址。
  `adlist.uc` 把列表转换成 mosdns 的域名文件：`||example.com^` → 域名及子域名，hosts 行和纯域名 → 精确匹配，
  `@@` 例外单独存放；通配符、正则和带其他修饰符的规则会被跳过并计数。合并后的文件由 mosdns 自动重载，
  更新列表不需要重启。订阅通过规则表里的“广告（订阅列表）”一行（`adlist:all`）生效。
  来自列表库的订阅按目录编号跟随列表库：每次更新前刷新目录，名称和地址随之同步，被弃用或移除的列表只做标记。
  默认规则里不再包含 `geosite:category-ads-all`；从旧版本升级且原来开着去广告的配置会保留那一行，不需要可以删掉
- **按设备分流**：按 MAC 地址把某台设备的全部流量（或只有 UDP / TCP）送到指定节点或节点组，
  或者让它完全直连，先于规则表生效，适合游戏加速。每个不同的出口对应一个额外的 TProxy 入站，
  nft 按源 MAC 把包送到对应端口，Xray 再按入站选出口
- **备用探测地址**：所有节点组的全部成员同时探测失败并持续约 3 个探测间隔加 1 分钟时，
  看护进程换用另一个探测地址并重启 Xray，两次切换至少间隔 10 分钟
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
│   ├── fw.sh                                 nftables 加载 + 策略路由 apply/clear/status，透明代理撤出/恢复
│   ├── switch.sh                             把检查过的新一套生成文件换上：要么全部换上，要么整套恢复旧的
│   └── dnsmasq.sh                            仅用于还原 ≤0.8 版本改写过的 dnsmasq 配置
├── root/usr/share/ucode/xray_mosdns/
│   ├── config.uc                             UCI → 规范化配置 + 分流计划
│   ├── xray.uc  mosdns.uc  nft.uc            三个后端，各自返回对象/文本
│   ├── geoip.uc                              从 geoip.dat 提取大陆网段（带缓存）
│   └── util.uc                               校验、YAML 输出等
├── root/usr/libexec/xray-mosdns/             状态、流量、测速、更新、导入等辅助脚本
│   ├── groups.uc                             节点组：查询当前出口、锁定、看护进程
│   ├── geoview.uc                            geo 数据查询：tags / lookup / list / dump
│   ├── adlist.uc                             拦截列表：下载、转换为 mosdns 域名文件、定时更新
│   ├── info.sh                               只读查询（节点组出口、拦截列表状态、版本）：只有只读权限的
│   │                                         LuCI 用户也能打开页面，改动类命令仍需写权限
│   └── dns-watchdog.sh                       DNS 看门狗：mosdns 不应答时把 LAN 解析交还 dnsmasq；也看护 Xray
├── htdocs/luci-static/resources/view/xray-mosdns/   LuCI 页面（原生表单组件，无自定义主题）
│   ├── status.js                             概览：运行状态、启停、连通性、节点流量
│   ├── nodelist.js                           节点：列表、导入、测速、节点组
│   ├── routing.js                            分流：总节点、分流模式、规则
│   ├── resolver.js                           DNS：接管、上游、IPv6、缓存、拦截与日志，加上下面两个标签
│   ├── system.js                             系统：运行参数
│   ├── components.js                         更新：Xray / mosdns-x / geo 数据、定时更新
│   ├── geoview.js                            Geo 查询：域名/IP 反查数据集、查看和下载数据集内容
│   └── logview.js                            日志
├── htdocs/luci-static/resources/xray-mosdns/        页面共用的模块
│   ├── common.js                             辅助函数
│   ├── adblock.js                            DNS 页的“广告过滤”标签：订阅拦截列表（AdGuard 列表库或自定义地址）
│   └── querylog.js                           DNS 页的“查询日志”标签：最近的 DNS 查询及其处理方式
├── tests/                                    夹具配置 + 生成/运行/断言脚本
└── .gitea/workflows/ci.yml                   Gitea Actions：推送和合并请求跑测试；版本标签和手动运行时再用 SDK 打包
```

## 测试

生成器可以脱离路由器测试（需要一个带 ucode/uci 的 OpenWrt rootfs，例如官方容器镜像）：

```sh
podman run --rm --network none -v "$PWD":/src:ro -v /tmp/xm-test:/out \
    docker.io/openwrt/rootfs:x86-64-24.10.4 sh /src/tests/gen.sh /src /out
python3 tests/check.py /tmp/xm-test          # 对三套夹具的输出做断言
# tests/migrate.sh（同样在 rootfs 里跑）：升级迁移前后生成结果必须逐字节一致
# tests/scripts.sh /src /out（rootfs 里需装 ucode-mod-socket）：测速、流量、日志、update.sh 版本查询等辅助脚本的输出
# tests/runtime.sh /src /out：用替身 nft/ip/curl/unzip/mv 跑 fw.sh 的撤出/恢复和 status、switch.sh 的整套替换与恢复、
#   groups.uc 和 status.sh 是否按 runtime.env 工作、update.sh 的校验和替换、adlist.uc 的共用目录和合并失败、
#   包的 postrm（升级与卸载）；会写 /var/etc、/etc/config、/etc/crontabs，只能在一次性的 rootfs 里跑
# 以上结果都由 check.py 断言（CI 里加 --all：哪一部分没有输出就算失败）。
# 跑不了的两样需要在路由器上（或带 NET_ADMIN 的容器里）验证：init 脚本和 procd 的启动顺序；
#   nft 规则的语法（测试里的 nft 是替身，不检查语法），用 nft -c -f /var/etc/xray-mosdns/nft.rules
xray run -test -c /tmp/xm-test/chnroute/xray.json
```

## 依赖

需要自备、**不作为包依赖**的：

- `xray`（Xray-core ≥ 1.8，TProxy tunnel inbound），可使用手工编译版本
  （手工 xray 与 feed 的 `xray-core` 包会争用 `/usr/bin/xray`，因此不声明依赖）
- `mosdns-x`（pmkol/mosdns-x，mosdns v4 配置格式；需要其 `nftset` 插件和 `_new_empty_response` 等预设）
- `geosite.dat`、`geoip.dat`（Loyalsoldier / v2ray 数据），放在 `global.geo_dir`（默认 `/usr/share/v2ray`），
  “更新”页可以下载。Xray 也从这个目录读取（启动时设置 `XRAY_LOCATION_ASSET`）

已声明为包依赖的（默认固件里大多没有）：

- `nftables`、`ip-full`；`kmod-nft-tproxy` 为安装时依赖（`LUCI_EXTRA_DEPENDS`），由 apk 从 kmods 源安装，
  不会让 SDK/CI 编译内核模块
- `ucode` + `ucode-mod-uci` / `ucode-mod-fs` / `ucode-mod-ubus`（生成器）、`ucode-mod-socket`（节点测速）
- `curl`（组件更新、连通性检测、经代理下载拦截列表）、`unzip`（组件更新）、`resolveip`
- 分享链接里的 base64 由 ucode 解码，不需要 `base64` 命令

## 代码仓库与 CI

- 仓库：<https://github.com/zlylong/luci-app-xray-mosdns-x>
- Gitea Actions（`.gitea/workflows/ci.yml`）：推送 master 和每个合并请求只在 ImmortalWrt rootfs 里跑 `tests/`，不打包。
  打包只在推送版本标签时，或在 Actions 页面手动运行这个工作流时进行：先跑测试，通过后在官方镜像
  `immortalwrt/sdk:x86-64-openwrt-25.12.2` 里编译，产物作为构建产物上传。改了 Makefile 或包脚本（postrm 等）时，
  发版前可以手动运行一次，提前发现打包问题
- 发版：推送 `v<版本号>` 标签（须与 Makefile 的 `PKG_VERSION` 一致），编译后自动创建发布并附上安装包和校验和。
  发布说明取自带注释标签的内容；带连字符的标签（如 `v1.0.0-rc1`）发布为预发布版本

## 编译

用 ImmortalWrt SDK，和 CI 相同：

```sh
curl -LO https://downloads.immortalwrt.org/releases/25.12.2/targets/x86/64/immortalwrt-sdk-25.12.2-x86-64_gcc-14.3.0_musl.Linux-x86_64.tar.zst
tar --zstd -xf immortalwrt-sdk-25.12.2-*.tar.zst
cp -r luci-app-xray-mosdns-x immortalwrt-sdk-*/package/
cd immortalwrt-sdk-*
./scripts/feeds update -a && ./scripts/feeds install luci
make defconfig
make package/luci-app-xray-mosdns-x/compile V=s
# 产物: bin/packages/x86_64/base/luci-app-xray-mosdns-x-<版本>-r1.apk
```

`scripts/build-in-vm.sh` 把这些步骤包成了一个脚本（下载 SDK、安装 feeds、编译并收集产物）。

## 安装（不启用）

从发布页下载安装包：

```sh
apk add --allow-untrusted luci-app-xray-mosdns-x-<版本>-r1.apk
```

安装后插件处于未启用状态：`uci get xray-mosdns.@global[0].enabled` → `0`。

## 启用步骤（确认要替换 PassWall 后）

1. 在 LuCI → 服务 → Xray + mosdns-x → “节点”页添加节点，在“分流”页选择总节点
2. 停用 PassWall：`/etc/init.d/passwall stop; /etc/init.d/passwall disable`
3. 启用本插件：`uci set xray-mosdns.@global[0].enabled=1; uci set xray-mosdns.@global[0].main_target=<节点或节点组名>; uci commit xray-mosdns`
4. 启动：`/etc/init.d/xray-mosdns start`（启动或重载失败时，原因显示在“概览”页，并写入“日志 → 插件服务”）
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
| global | fwmark / route_table | 策略路由标记/表号，默认 0x1 / 100（与其他插件共用时启动日志会提示） |
| global | main_target | 总节点：节点或节点组的 section 名，或 direct |
| global | log_level | Xray 日志级别：debug / info / warning（默认）/ error / none |
| global | socks_port | 内部 SOCKS 端口（给 mosdns 转发国外 DNS），默认 1070 |
| global | proxy_router | 代理路由器自身的流量：0（默认）/ tcp / tcp,udp |
| global | self_mark | Xray 和 mosdns 自身流量的标记，默认 0xff |
| global | kernel_split | 内核分流（默认 1）；0 = 所有流量进 Xray 再分流 |
| global | lan_ifaces | 被代理的逻辑接口列表，默认 `lan`；可以加 VPN 等接口，界面里从系统接口中选择 |
| global | lan_devices | 直接指定设备名（如 `br-lan`），设置后不再查询 lan_ifaces |
| dns | listen_port | mosdns 监听端口，默认 5335（不要用 5353，mDNS 占用） |
| dns | redirect | nft 把 LAN 的 53 端口重定向到 mosdns（默认 1） |
| dns | fallback | DNS 看门狗（默认 1）：mosdns 不应答时撤掉重定向，由 dnsmasq 接管 |
| dns | remote_dns | 国外上游列表：IP（TCP 53）或 tcp:// tls:// https:// 地址，全部经代理 |
| dns | block_mode | 拦截方式：nxdomain（默认）/ zero（返回 0.0.0.0 和 ::） |
| dns | min_ttl | 最小 TTL，0 = 不改动（默认） |
| dns | query_log | 记录每次查询，在 DNS 页的“查询日志”标签里查看（默认 0） |
| dns | filter_proxy_ipv6 | 代理域名不返回 AAAA（默认 1） |
| dns | filter_direct_ipv6 | 直连域名不返回 AAAA（默认 0） |
| dns | domestic_dns | 国内 DoH/DoT/明文上游列表 |
| dns | hosts | 静态域名映射（节点域名/VPS 域名解析用） |
| global | default_action | 没有命中任何规则的流量：proxy（走总节点）/ direct |
| group | remarks / strategy / member / fallback | 节点组：名称；fastest / ordered / roundrobin / random；成员列表（ordered 时即挑选顺序）；全部不可用时的出口 |
| group | failback | 仅 ordered：0（默认）切换后只有当前成员不可用才再切；1 前面的成员恢复后立即切回 |
| global | probe_url / probe_interval | 节点组的探测地址与间隔，默认 gstatic generate_204 / 1m |
| global | probe_url_backup | 备用探测地址（可选）：所有组的全部成员同时探测失败时自动换用 |
| adblock | dir / auto_update / update_hour | 拦截列表的存放目录、是否每天自动更新、更新钟点。/etc/xray-mosdns 以外的目录可以和别的程序共用：列表放在其中的 xray-mosdns 子目录里（≤0.9.8 放在目录顶层的，在新配置成功换上之后搬进去；回退到上一份配置的启动不搬，上一份配置仍从顶层读取），卸载时只删除这个子目录 |
| adlist | enabled / name / url | 一条订阅：AdGuard 规则、hosts 或纯域名格式的列表地址 |
| adlist | catalog_id | 来自 AdGuard 列表库的订阅记录的目录编号；有它时 name 和 url 跟随目录 |
| device | mac / network / outbound | 按设备分流：MAC 地址列表；tcp,udp / udp / tcp；main / direct / 节点 / 节点组 |
| global | schema | 配置版本，由包维护，不要改 |
| global | ipv6_enabled | 启用 IPv6 TProxy（实验性） |
| node | type/address/port/uuid/... | vless / vmess / trojan / shadowsocks / hysteria2 节点 |
| global | api_port | Xray 本地统计 API 端口（默认 10085，用于节点流量） |
| global | geo_dir | geosite.dat / geoip.dat 所在目录（默认 `/usr/share/v2ray`），mosdns-x、内核集合、Xray 和更新页共用 |
| rule | rule_type/value/outbound | 分流规则，从上到下匹配：domain/ip/port/network → main/节点/节点组/direct/block；`value` 是列表 |
| rule | builtin_ads / builtin_cn_domain / builtin_cn_ip / builtin_noncn / builtin_gfw | 预置规则行，和普通规则完全一样，“快速预设”只是开关它们 |

## 已知限制

- 内核分流按目的 IP 判定：端口/协议规则只对进入 Xray 的流量生效。
  例如启用“国内 IP 直连”时，“22 端口走代理”对国内 IP 不生效（国内 IP 在内核已直连）
- 内核里域名规则解析出的地址先于 IP 规则判定，IP 规则之间保持表中的顺序（最多 8 组连续同类规则）；
  进入 Xray 的流量再按完整的规则顺序判定一次
- 预置行可以被拖到自己的规则前面从而盖住它们，顺序由你负责
- 按设备分流只改变流量的出口，不改变 DNS：该设备查询域名时仍按规则表和默认出口选上游。
  使用随机 MAC 的手机需要先对这个 Wi-Fi 关闭“私有地址”；经过三层转发（隔了一个路由器）的设备
  看不到原始 MAC，无法识别
- “按顺序”的切换延迟约等于探测间隔加看护周期（默认 1 分钟 + 10 秒）；看护进程退出时组会停在
  最后锁定的成员上，由 procd 拉起后恢复
- “按顺序”组记住的当前成员保存在 Xray 进程里：Xray 重启（改配置、更新、重启路由器）后，
  会重新从列表最靠前的可用成员开始
- 轮询和随机会让同一网站看到多个出口 IP，可能触发登录验证；节点组的锁定是临时的，重启后恢复自动
- 多个域名共用同一 IP（CDN）且分属代理与直连时，以先写入集合的一方为准，直连集合优先
- 客户端若绕过本机 DNS（DoH/DoT），其流量只能按 IP 集合和模式默认值判定
- 开启“代理路由器自身的流量”且默认出口为代理时，路由器上的 VPN 客户端、内网穿透等连接也会进代理，
  需要把它们的服务器地址加进“不代理的目标”
- DNS 回退到 dnsmasq 期间，内核集合不再更新：域名规则只对之前学到的地址有效，新解析的代理域名
  可能拿到被污染的地址。回退是为了保住国内访问，不是完整的降级方案
- *_dns 集合元素 3 天过期；DNS 规则变化时集合会清空并随 mosdns 重启重新学习

- IPv6 TProxy 为实验性功能，需要节点本身可达 IPv6；IPv6 分流规则与 IPv4 共用 geosite/geoip 规则
- Xray 26.x 已移除 `allowInsecure`（跳过证书校验），插件不再生成也不再保存该字段（导入时忽略链接里的
  `allowInsecure`，升级时删除旧值）；需要绕过证书校验的场景请改用可信证书/域名
- Hysteria2 节点依赖 Xray 的 `hysteria` 协议 + hysteria 传输（Xray 26.x 起），测速对 UDP 节点会先试 TCP，失败后回退 ICMP
- 分享链接导入支持 vless / vmess / trojan / shadowsocks（SIP002）/ hysteria2（hy2://），不支持 TUIC / SSR，
  也不支持订阅地址（需要把链接粘贴进来）
- 规则管理为简单表单（每条规则一个域名/IP/端口集合），复杂表达式请直接编辑

## 路线图

- [x] 查询日志
- [ ] 查询统计（按客户端、按域名的排行）
- [ ] 按设备的 DNS 策略
- [ ] 订阅 URL 自动更新节点

已完成的内容见各版本的发布说明。

## 许可

MIT
