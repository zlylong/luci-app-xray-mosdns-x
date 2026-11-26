# 配置参考与已知限制

## UCI 配置参考

`/etc/config/xray-mosdns`：

| section | option | 说明 |
|---|---|---|
| global | enabled | 总开关（默认 0） |
| global | tproxy_port | TProxy 监听端口，默认 12345 |
| global | fwmark / route_table | 策略路由标记/表号，默认 0x1 / 100（与其他插件共用时启动日志会提示） |
| global | main_target | 总节点：节点或节点组的 section 名，或 direct |
| global | log_level | Xray 日志级别：debug / info / warning（默认）/ error / none；debug 和 info 还记录访问日志（每条连接一行，写进系统日志，很快会占满它），其余级别不记 |
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
| dns | query_log_size | 查询日志（mosdns-x 的日志文件，在内存里）最多占用的大小，1–64 MB，默认 4；超过时只保留较新的一半 |
| dns | stats_port | mosdns-x 的本机 HTTP 接口端口（默认 5336，只监听 127.0.0.1）：解析和拦截计数从这里读，DNS 页“拦截与日志”标签显示最近 30 天的汇总和今天的数字 |
| dns | filter_proxy_ipv6 | 代理域名不返回 AAAA（默认 1） |
| dns | filter_direct_ipv6 | 直连域名不返回 AAAA（默认 0） |
| dns | ipv4_only | 只返回 IPv4 的域名列表：这些域名的 AAAA 和 HTTPS 查询返回空，不管按哪条规则解析（example.com 含子域名，也可以加 full: / keyword:） |
| dns | domestic_dns | 国内 DoH/DoT/明文上游列表 |
| dns | ecs / ecs_ip | EDNS 客户端子网：国内查询附带路由器所在的网段（默认 0 关）；ecs_ip 可填一个 IPv4 和一个 IPv6 固定下来，不填时用默认路由所在接口的公网地址，地址变化（拨号重连）后自动重新生成配置。走代理的查询不附带 |
| dns | bootstrap | 引导解析器列表：解析 DoH/DoT 上游自身域名用的明文 DNS（IP，国内可直连）；多个时各个用域名的上游轮流分到一个（默认 223.5.5.5） |
| dns | hosts | 静态域名映射（节点域名/VPS 域名解析用） |
| global | default_action | 没有命中任何规则的流量：proxy（走总节点）/ direct |
| group | remarks / strategy / member / fallback | 节点组：名称；fastest / ordered / roundrobin / random；成员列表（ordered 时即挑选顺序）；全部不可用时的出口 |
| group | failback | 仅 ordered：0（默认）切换后只有当前成员不可用才再切；1 前面的成员恢复后立即切回 |
| global | probe_url / probe_interval | 节点组的探测地址与间隔，默认 gstatic generate_204 / 1m |
| global | probe_url_backup | 备用探测地址（可选）：所有组的全部成员同时探测失败时自动换用 |
| adblock | dir / auto_update / update_hour | 拦截列表的存放目录、是否每天自动更新、更新钟点（整点）。/etc/xray-mosdns 以外的目录可以和别的程序共用：列表放在其中的 xray-mosdns 子目录里（≤0.9.7 放在目录顶层的，在新配置成功换上之后搬进去；回退到上一份配置的启动不搬，上一份配置仍从顶层读取），卸载时只删除这个子目录 |
| adlist | enabled / name / url | 一条订阅：AdGuard 规则、hosts 或纯域名格式的列表地址 |
| adlist | catalog_id | 来自 AdGuard 列表库的订阅记录的目录编号；有它时 name 和 url 跟随目录 |
| device | mac / network / outbound | 按设备分流：MAC 地址列表；tcp,udp / udp / tcp；main / direct / 节点 / 节点组 |
| global | schema | 配置版本，由包维护，不要改 |
| global | ipv6_enabled | 启用 IPv6 TProxy（实验性） |
| node | type/address/port/uuid/... | vless / vmess / trojan / shadowsocks / hysteria2 节点 |
| global | api_port | Xray 本地统计 API 端口（默认 10085，用于节点流量） |
| global | geo_dir | geosite.dat / geoip.dat 所在目录（默认 `/usr/share/v2ray`），mosdns-x、内核集合、Xray 和更新页共用 |
| global | log_days | 插件自己的日志（mosdns-x 日志和查询日志、geo 定时更新日志、拦截列表更新日志）保留的天数（默认 30，1–365），每 6 小时清理一次；这些日志都在内存里，另有大小上限（mosdns-x 4 MB，其余 256 KB） |
| global | geo_auto_update / geo_update_hour / geo_update_day | geo 数据定时更新：是否开启、钟点（0–23，默认 4）、星期几（0 = 周日 … 6，`*` = 每天，默认每天） |
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
- “按顺序”的切换延迟最多约等于探测间隔加半分钟（3 次失败的重试）；看护进程退出时组会停在
  最后锁定的成员上，由 procd 拉起后恢复
- “按顺序”组记住的当前成员保存在 Xray 进程里：Xray 重启（改节点或端口、更新、重启路由器）后，
  会重新从列表最靠前的可用成员开始，不管是否开了“恢复后切回”；看护进程启动后几秒内探完所有成员再决定，
  排在前面的成员状态还没确定时不会先占用后面的。只改规则不重启 Xray，组保持不动
- 轮询和随机会让同一网站看到多个出口 IP，可能触发登录验证；节点组的锁定是临时的，重启后恢复自动
- 多个域名共用同一 IP（CDN）且分属代理与直连时，以先写入集合的一方为准，直连集合优先
- 客户端若绕过本机 DNS（DoH/DoT），其流量只能按 IP 集合和模式默认值判定
- 开启“代理路由器自身的流量”且默认出口为代理时，路由器上的 VPN 客户端、内网穿透等连接也会进代理，
  需要把它们的服务器地址加进“不代理的目标”
- DNS 回退到 dnsmasq 期间，内核集合不再更新：域名规则只对之前学到的地址有效，新解析的代理域名
  可能拿到被污染的地址。回退是为了保住国内访问，不是完整的降级方案
- *_dns 集合元素 3 天过期；DNS 规则变化时集合会清空（开启嗅探时只清空直连的）并重新学习
- 只为代理域名解析出过的地址，嗅探不出域名的连接走代理：走的是这些域名规则共同的出口，规则的出口不止一个时走主出口；
  排在前面的 IP、端口、协议规则仍然先匹配。同一个地址上的其他站点（嗅探得出域名、又没有规则命中）照旧走默认出口

- IPv6 TProxy 为实验性功能，需要节点本身可达 IPv6；IPv6 分流规则与 IPv4 共用 geosite/geoip 规则
- Xray 26.x 已移除 `allowInsecure`（跳过证书校验），插件不再生成也不再保存该字段（导入时忽略链接里的
  `allowInsecure`，升级时删除旧值）；需要绕过证书校验的场景请改用可信证书/域名
- Hysteria2 节点依赖 Xray 的 `hysteria` 协议 + hysteria 传输（Xray 26.x 起），测速对 UDP 节点会先试 TCP，失败后回退 ICMP
- 分享链接导入支持 vless / vmess / trojan / shadowsocks（SIP002）/ hysteria2（hy2://），不支持 TUIC / SSR，
  也不支持订阅地址（需要把链接粘贴进来）
- 规则管理为简单表单（每条规则一个域名/IP/端口集合），复杂表达式请直接编辑
