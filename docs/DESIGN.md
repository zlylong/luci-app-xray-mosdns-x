# 设计说明

面向想了解内部做法或参与开发的人。使用说明见 [README](../README.md)，配置项和已知限制见 [CONFIG](CONFIG.md)。

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
      （默认出口为直连、且有走代理的域名规则时：TProxy :12346，入站 tproxy-dns。
        嗅探不出域名的连接——SSH、邮件、多数游戏——在这里走代理，否则 Xray 没有域名可匹配，会按默认出口直连）
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
  发生变化的进程。Xray 的分流规则不算在内：只有规则变了时，新规则通过 Xray 的 API 加进正在运行的 Xray
  （先加新的、再删旧的，中间没有无规则的时刻），不重启，已有连接和节点组的状态都保留；
  节点、端口等其他设置变了，或者 API 调用失败，才重启 Xray。规则里直接写的域名也不在 mosdns.yaml 里，
  而是每条规则一个文件（`rule_<n>.domains`），由 `rule-files.sh` 原地改写到 `/var/etc/xray-mosdns.rules/`，
  mosdns-x 自动重载：改规则里的域名不重启 mosdns，缓存保留（增删规则、改 geosite 引用仍会重启）。
  从 DNS 学到的地址集合只在分流判定变了时清空（`dns-rules.sum`），换上游、ECS 地址变化不再清空；开启嗅探时只清空直连的集合
  （进了 Xray 的连接按现在的规则和嗅探到的域名判定，代理集合里留着旧地址无妨；清空它反而会让还缓存着解析结果的设备在重新查询之前直连代理域名）；生成失败、或启动前检查（二进制、geo 数据缺失等）失败时保留上一份可用配置继续运行，
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
  策略有 最快 / 按顺序 / 轮询 / 随机；全部成员不可用时走组的兜底出口。最快、轮询、随机的成员由 Xray 的
  burstObservatory 探测。“按顺序”的成员由看护进程（`groups.uc watch`）自己探测：经 Xray 的 `probe-in` 入站
  （本机 SOCKS，每个成员一个账号，账号对应的请求只走那个节点）向探测地址发请求。启动后立刻探一次，之后每个探测间隔一次；
  失败的请求在随后的每一轮（5 秒）重试，连续 3 次失败才算不可用，所以丢一次探测不会切换，节点真的不通时约在
  探测间隔加半分钟内切走；不可用的成员至少每 30 秒探一次，连续 2 次成功即恢复。主探测地址没有应答时接着试备用地址，不用重启。
  所有成员同时失败、路由器又连国内网站都打不开时，判定为上联故障，不计入失败。当前成员可用就保持不动，
  不可用时切到列表里最靠前的可用成员。默认不会因为前面的成员恢复而切回，
  需要切回可以打开组的“恢复后切回”；概览页显示每个组当前的出口，并可临时锁定到某个成员
- **路由器自身流量**（可选）：output 链里按同一套分类给路由器发起的连接打标记，策略路由把它们
  绕回 lo，再由 prerouting 送进 TProxy。Xray 和 mosdns 自己发的包带 `self_mark`，不会被再次送回；
  路由器自己的 53 端口查询同时重定向到 mosdns，同样受 DNS 看门狗管理
- **广告过滤订阅**：可以直接从 AdGuard Home 的列表库（内置目录快照，66 个列表）里选，或填自定义地址。
  `adlist.uc` 把列表转换成 mosdns 的域名文件：`||example.com^` → 域名及子域名，hosts 行和纯域名 → 精确匹配，
  `@@` 例外单独存放；`$dnsrewrite` 指向“域名不存在”、拒绝、空地址或 AdGuard 拦截主机的规则也按拦截处理
  （AdGuard DNS 系列列表这样写拦截）；以 `^|` 结尾的规则与不带 `|` 的等同；`$badfilter` 把同一个列表里的
  那条规则撤掉（合并自多个来源的列表用它收回某个来源的规则）。带通配符或不完整的规则（`||ad*.example.org^`、`||example.*^`、
  `.example.org^`、`||example.`）转成正则表达式，另存为 `wild.txt`；mosdns 对正则是逐条尝试的（每条每次查询约 2 微秒），
  所以每条规则再取一段匹配到的域名必然包含的文字放进 `keys.txt`，只有包含其中某一段的域名才去试正则，平常的查询几乎不受影响。
  正则规则（`/…/`）、带其他修饰符的规则会被跳过并计数。
  每个订阅的数据记着它来自哪个地址：匿名小节的名字随它在配置文件里的位置变化（在它前面增删一条规则，
  后面的列表就都换了名字）。数据在别的名字下面时，启动和更新前按地址把它挪到列表现在的名字下，不重新下载；
  哪里都没有这个地址的数据才重新下载。下载走代理优先、直连兜底，传输停住（30 秒内低于 1 KB/s）就放弃这一次；
  更新期间页面显示正在处理第几个列表。每天的自动更新在整点运行。合并后的文件由 mosdns 自动重载，
  更新列表不需要重启：新内容先完整写好，再就地改写 mosdns 正在读的那个文件（mosdns-x 只监视它打开的文件，
  换成另一个文件只会重载一次），两份列表要么都换、要么都不换。mosdns 启动时缺合并后的列表会直接起不来，
  所以每次启动前先用已有的列表把它们合并出来。订阅通过规则表里的“广告（订阅列表）”一行（`adlist:all`）生效。
  来自列表库的订阅按目录编号跟随列表库：每次更新前刷新目录，名称和地址随之同步，被弃用或移除的列表只做标记。
  默认规则里不再包含 `geosite:category-ads-all`；从旧版本升级且原来开着去广告的配置会保留那一行，不需要可以删掉
- **按设备分流**：按 MAC 地址把某台设备的全部流量（或只有 UDP / TCP）送到指定节点或节点组，
  或者让它完全直连，先于规则表生效，适合游戏加速。每个不同的出口对应一个额外的 TProxy 入站，
  nft 按源 MAC 把包送到对应端口，Xray 再按入站选出口
- **备用探测地址**：“按顺序”的组每次探测主地址没有应答就接着试备用地址。其他策略的组由 Xray 探测：全部成员同时探测失败
  并持续约 3 个探测间隔加 1 分钟时，看护进程换用另一个探测地址并重启 Xray，两次切换至少间隔 10 分钟
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
│   ├── xray-rules.sh                         把新的分流规则通过 API 换进正在运行的 Xray（不重启）
│   ├── rule-files.sh                         把规则的域名文件原地改写到 mosdns-x 读取的目录（自动重载）
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
│   ├── components.js                         更新：Xray / mosdns-x / geo 数据、定时更新；本插件有没有新版本
│   ├── geoview.js                            Geo 查询：域名/IP 反查数据集、查看和下载数据集内容
│   └── logview.js                            日志
├── htdocs/luci-static/resources/xray-mosdns/        页面共用的模块
│   ├── common.js                             辅助函数
│   ├── adblock.js                            DNS 页的“广告过滤”标签：订阅拦截列表（AdGuard 列表库或自定义地址）
│   ├── querylog.js                           DNS 页的“查询日志”标签：最近的 DNS 查询及其结果
│   └── stats.js                              DNS 页“拦截与日志”标签：最近 30 天的解析和拦截计数
├── bundle/                                   完整包：make.sh 在打包任务里生成它，install.sh 是包里的离线安装脚本，
│                                             components 写着所带 Xray、mosdns-x 的版本和校验和
├── docs/                                     本文和配置参考
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
# python3 tests/jslint.py：编译时页面会被 jsmin 压缩，它会误读紧跟在 return 等关键字后面的正则，检查页面里没有这种写法；
#   打包任务还会对压缩后的页面逐个做语法检查
# 跑不了的两样需要在路由器上（或带 NET_ADMIN 的容器里）验证：init 脚本和 procd 的启动顺序；
#   nft 规则的语法（测试里的 nft 是替身，不检查语法），用 nft -c -f /var/etc/xray-mosdns/nft.rules
xray run -test -c /tmp/xm-test/chnroute/xray.json
```

## 代码仓库与 CI

- 仓库：<https://github.com/zlylong/luci-app-xray-mosdns-x>
- Gitea Actions（`.gitea/workflows/ci.yml`）：推送 master 和每个合并请求只在 ImmortalWrt rootfs 里跑 `tests/`，不打包。
  打包只在推送版本标签时，或在 Actions 页面手动运行这个工作流时进行：先跑测试，通过后在官方镜像
  `immortalwrt/sdk:x86-64-openwrt-25.12.2` 里编译，产物作为构建产物上传。改了 Makefile 或包脚本（postrm 等）时，
  发版前可以手动运行一次，提前发现打包问题
- 发版：推送 `v<版本号>` 标签（须与 Makefile 的 `PKG_VERSION` 一致），编译后自动创建发布并附上安装包和校验和。
  发布说明取自带注释标签的内容；带连字符的标签（如 `v1.0.0-rc1`）发布为预发布版本

## 完整包

打包任务在编译出安装包之后运行 `bundle/make.sh`，生成 `luci-app-xray-mosdns-x-<版本>-full-x86_64.tar.gz`：

- 依赖包：Makefile 里列的依赖及其全部依赖，由同一版本 ImmortalWrt rootfs 自己的 apk 下载（按它的密钥验签），
  再用 SDK 的 apk 生成索引 `apks/packages.adb`。路由器上 `install.sh` 把这个目录当作唯一的软件源，
  apk 只从中取本机缺少的包，已装的不动
- Xray、mosdns-x：`bundle/components` 里固定的版本，下载后与其中记的 SHA-256 比对。换版本时改这个文件
- geo 数据：打包当天的最新版，与同时发布的 `.sha256sum` 比对
- Xray、mosdns-x、geo 数据由 `update.sh xray-file / mosdns-file / geo-dir` 安装，和“更新”页走同一套
  校验、备份、替换的代码，只是文件来自本地

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

