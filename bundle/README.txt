luci-app-xray-mosdns-x 完整包（x86_64）

路由器不能联网，或下载不到 Xray、mosdns-x、依赖包时用这个包：里面带齐了
安装所需的全部文件。

用法
  把整个压缩包传到路由器（例如 scp 到 /tmp），然后：
    tar -xzf luci-app-xray-mosdns-x-*-full-x86_64.tar.gz -C /tmp
    sh /tmp/luci-app-xray-mosdns-x-*-full-x86_64/install.sh
  解压后约占 60 MB，/tmp 是内存盘，请先确认空间够（df -h /tmp）。
  装完可以删除解压出来的目录和压缩包。

  sh install.sh             装上缺的：插件和依赖、Xray、mosdns-x、geo 数据。
                            已有的 Xray、mosdns-x（须是 mosdns-x）和 geo 数据保留。
  sh install.sh --replace   已有的 Xray、mosdns-x、geo 数据也换成包里的版本
                            （原文件备份在 /root/pw-backup/xray-mosdns-update）。
  sh install.sh --online    允许 apk 同时使用系统软件源（固件版本不同时用）。

  首次安装后插件不启用。升级时配置保留。

内容
  luci-app-xray-mosdns-x-*.apk  插件
  apks/                         插件依赖的系统包及其全部依赖，和一份索引。
                                安装时 apk 只从中取本机缺少的。
  components/                   Xray、mosdns-x 的官方发布文件，geosite.dat、geoip.dat
  VERSIONS                      各组件的版本
  SHA256SUMS                    所有文件的校验和，install.sh 会先核对

适用的固件
  apks/ 里的包取自 VERSIONS 里 FIRMWARE 一行写的固件（官方 ImmortalWrt）。
  其中内核模块 kmod-nft-tproxy 只能配这个固件的内核：固件版本不同、或是自己
  编译的固件时，如果本机还没有这个模块，离线安装会失败并说明原因，不会装一半。
  这时联网后用 --online，或先从自己固件的软件源装好 kmod-nft-tproxy。

来源和许可
  Xray        https://github.com/XTLS/Xray-core          MPL-2.0
  mosdns-x    https://github.com/pmkol/mosdns-x          GPL-3.0
  geo 数据    https://github.com/Loyalsoldier/v2ray-rules-dat   GPL-3.0
  系统包      https://downloads.immortalwrt.org （ImmortalWrt / OpenWrt，各包自带许可）
  以上文件都是上游发布的原样，未作修改；Xray 和 mosdns-x 的压缩包里带有各自的
  许可文件。插件本身为 MIT 许可：https://github.com/zlylong/luci-app-xray-mosdns-x
