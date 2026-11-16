#!/usr/bin/env python3
"""Assertions over the configs produced by tests/gen.sh.

usage: tests/check.py <outdir>
"""
import json
import sys

import yaml

out = sys.argv[1] if len(sys.argv) > 1 else "/tmp/xm-test"
failed = []


def check(cond, msg):
    if not cond:
        failed.append(msg)


def load(case):
    x = json.load(open(f"{out}/{case}/xray.json"))
    m = yaml.safe_load(open(f"{out}/{case}/mosdns.yaml"))
    n = open(f"{out}/{case}/nft.rules").read()
    return x, m, n


def refs(node):
    """every plugin tag a sequence body refers to"""
    if isinstance(node, str):
        yield node
    elif isinstance(node, list):
        for item in node:
            yield from refs(item)
    elif isinstance(node, dict):
        for key in ("exec", "else_exec", "primary", "secondary"):
            if key in node:
                yield from refs(node[key])


def matcher_refs(node):
    if isinstance(node, list):
        for item in node:
            yield from matcher_refs(item)
    elif isinstance(node, dict):
        if "if" in node:
            for tok in node["if"].replace("(", " ").replace(")", " ").replace("!", " ").split():
                if tok not in ("&&", "||") and not tok.startswith("["):
                    yield tok
        for key in ("exec", "else_exec", "primary", "secondary"):
            if key in node:
                yield from matcher_refs(node[key])


def check_mosdns_refs(case, m):
    seen = set()
    for p in m["plugins"]:
        if p["type"] == "sequence":
            for r in refs(p["args"]["exec"]):
                check(r.startswith("_") or r in seen, f"{case}: sequence {p['tag']} uses undefined plugin {r}")
            for r in matcher_refs(p["args"]["exec"]):
                check(r in seen, f"{case}: sequence {p['tag']} uses undefined matcher {r}")
        check(p["tag"] not in seen, f"{case}: duplicate plugin tag {p['tag']}")
        seen.add(p["tag"])
    check(m["servers"][0]["exec"] in seen, f"{case}: server exec undefined")


def plugin(m, tag):
    return next((p for p in m["plugins"] if p["tag"] == tag), None)


def chain(n, name):
    body = n.split(f"\tchain {name} {{\n", 1)[1].split("\t}", 1)[0]
    return [line.strip() for line in body.splitlines() if line.strip()]


# ------------------------------------------------------------------ chnroute
x, m, n = load("chnroute")
check_mosdns_refs("chnroute", m)
rules = x["routing"]["rules"]
check(rules[-1] == {"type": "field", "network": "tcp,udp", "outboundTag": "hk1.node"}, "chnroute: default must be the main node")
check({"type": "field", "ip": ["geoip:cn"], "outboundTag": "direct"} in rules, "chnroute: geoip:cn direct rule missing")
check(x["outbounds"][0]["settings"]["vnext"][0]["address"] == "hk1.example.net", "node hostname must be passed to Xray unresolved")
check(x["outbounds"][1]["settings"]["servers"][0]["password"] == 'p@ss"word', "password with a quote must survive")
main = plugin(m, "main_sequence")["args"]["exec"]
by_if = {e["if"]: e["exec"] for e in main if isinstance(e, dict) and "if" in e}
check(by_if["rule_0"] == ["local_seq", "add_direct", "_return"], "chnroute: direct rule must resolve locally and mark the direct set")
check(by_if["rule_1"][0] == {"if": "query_is_aaaa", "exec": ["_new_empty_response", "_return"]}, "default: proxied names get no AAAA, direct names do")
check(by_if["rule_1"][-3:] == ["remote_seq", "add_proxy", "_return"], "chnroute: proxy rule must resolve remotely and mark the proxy set")
check(by_if["rule_2"] == ["_new_nxdomain_response", "_return"], "chnroute: block rule must answer NXDOMAIN")
order = [e["if"] for e in main if isinstance(e, dict) and "if" in e]
# the fixture is a pre-0.9.1 config: its mode and ad switch must turn into rule rows after the user's rules
check(plugin(m, "rule_3")["args"]["domain"] == ["provider:geosite:category-ads-all"] and by_if["rule_3"] == ["_new_nxdomain_response", "_return"], "legacy adblock becomes a block rule")
check(plugin(m, "rule_4")["args"]["domain"] == ["provider:geosite:cn"] and by_if["rule_4"] == ["local_seq", "add_direct", "_return"], "legacy chnroute: mainland domains resolve locally")
check(plugin(m, "rule_5")["args"]["domain"] == ["provider:geosite:geolocation-!cn"] and by_if["rule_5"][-3:] == ["remote_seq", "add_proxy", "_return"], "legacy chnroute: non-mainland domains resolve through the proxy")
check(order == ["query_is_lan_name || query_is_ptr", "query_is_node"] + ["rule_%d" % i for i in range(6)], f"chnroute: rule order {order}")
check(main[-1] == "fallback_seq", "mainland IPs direct + default proxy: unclassified names use the ChinaDNS fallback")
check({"type": "field", "domain": ["geosite:cn"], "outboundTag": "direct"} in rules, "geosite:cn rule reaches Xray")
check(order.index("query_is_node") < order.index("rule_0"), "node hostnames must be resolved locally before any rule")
check(plugin(m, "query_is_node")["args"]["domain"] == ["full:hk1.example.net"], "only hostname nodes need the node matcher")
check(plugin(m, "rule_1")["args"]["domain"] == ["provider:geosite:netflix", "full:api.example.com", "keyword:tracker"], "domain syntax conversion")
check(plugin(m, "local_seq")["args"]["exec"] == ["cache", "forward_local"], "cache must sit inside the sequence so nftset runs on hits")
check("disabled.example" not in json.dumps(m), "disabled rule leaked into mosdns")
check(m["servers"][0]["listeners"][0]["addr"] == ":5335", "redirect mode listens on the wildcard address")
pre = chain(n, "prerouting")
check(pre[0] == 'iifname != { "br-lan" } return', "traffic not entering from the LAN must be left alone")
check(pre.index("ip daddr @direct4_dns return") < pre.index("ip daddr @proxy4_dns goto do_tproxy") < pre.index("ip daddr @ipg4_0 goto do_tproxy") < pre.index("ip daddr @ipg4_1 return"), "DNS sets first, then IP rule groups in rule order")
check(pre[-1] == "goto do_tproxy", "chnroute: default is proxy")
check("meta nfproto ipv6 return" in pre, "IPv6 must not be proxied when disabled")
check("not-an-ip" not in n, "invalid bypass entry leaked into nft")
check("add element inet xray-mosdns ipg4_0 { 192.0.2.0/24 }" in n, "first IP rule (proxy) is group 0")
check("geoip:telegram" not in n, "geoip tags cannot go into nft")
g1 = n.split("add element inet xray-mosdns ipg4_1 {", 1)[1].split("}")[0]
check("198.18.0.0/15" in g1 and "114.114.0.0/16" in g1, "consecutive direct IP rules (literal + geoip:cn) share group 1")
check("8.8.8.0/24" not in n and "1.0.16.0/20" not in n, "only the CN entry is extracted from geoip.dat")
check("add element inet xray-mosdns ipg4_2" not in n, "unused group slots stay empty")
check("198.51.100.20" in n.split("add element inet xray-mosdns bypass4 {", 1)[1].split("}")[0], "literal node address must be bypassed")
# with the DNS watchdog (default) the redirect rule is not part of nft.rules: the watchdog installs it
RULE = 'iifname { "br-lan" } meta l4proto { tcp, udp } th dport 53 counter redirect to :5335'
check(chain(n, "dns_redirect") == [] and "flush chain inet xray-mosdns dns_redirect" not in n, "watchdog owns the redirect chain: nft.rules neither fills nor flushes it")
check(chain(n, "output") == [] and chain(n, "out_mark") == [] and "sockopt" not in json.dumps(x["outbounds"][-2]) and "so_mark" not in json.dumps(m), "router traffic off (default): no output rules, no socket marks")
check(not any('iifname "lo"' in r for r in chain(n, "prerouting")), "router traffic off: nothing is accepted from lo")
check(not any(p["tag"] in ("adblock", "adallow") for p in m["data_providers"]) and plugin(m, "query_is_ad_exception") is None, "no subscription: no blocklist providers")
FLUSH = "flush chain inet xray-mosdns dns_redirect\nflush chain inet xray-mosdns dns_redirect_out\n"
on = open(f"{out}/chnroute/nft-dns-on.rules").read()
check(on == FLUSH + "add rule inet xray-mosdns dns_redirect " + RULE + "\n", "watchdog 'on' rules")
check(open(f"{out}/chnroute/nft-dns-off.rules").read() == FLUSH, "watchdog 'off' rules")
check('th dport 53 return comment "handled by dns_redirect"' in n, "port 53 stays out of the tproxy path either way")

# ------------------------------------------------------------------ gfw
x, m, n = load("gfw")
check_mosdns_refs("gfw", m)
rules = x["routing"]["rules"]
check(rules[-1]["outboundTag"] == "direct", "gfw: everything not listed must be direct")
check(rules[-2] == {"type": "field", "domain": ["geosite:gfw"], "outboundTag": "hk1.node"}, "gfw: listed domains go to the main node")
check({"type": "field", "port": "22,3389", "outboundTag": "direct"} in rules, "list-valued port rule must become one Xray port string")
check({"type": "field", "domain": ["geosite:openai", "domain:example.org"], "outboundTag": "hk1.node"} in rules, "list-valued domain rule")
check(plugin(m, "rule_0")["args"]["domain"] == ["provider:geosite:openai", "domain:example.org"], "list-valued domain rule reaches mosdns")
check(x["inbounds"][0]["listen"] == "::", "ipv6: tproxy inbound must listen dual-stack")
check(x["inbounds"][0]["settings"] == {"network": "tcp,udp", "followRedirect": True}, "tproxy inbound: both protocols, original destination")
check(x["routing"]["domainStrategy"] == "AsIs" and "dns" not in x, "routing never resolves names itself: AsIs, no built-in DNS section")
main = plugin(m, "main_sequence")["args"]["exec"]
check(plugin(m, "rule_1")["args"]["domain"] == ["provider:geosite:gfw"], "legacy gfw mode becomes a rule row")
check(main[-4] == {"if": "rule_1", "exec": ["remote_seq", "add_proxy", "_return"]}, "gfw: listed domains resolve remotely and are marked")
check(main[-2:] == ["local_seq", "_return"], "gfw: other names resolve locally")
no_aaaa = {"if": "query_is_aaaa", "exec": ["_new_empty_response", "_return"]}
check(main[-3] == no_aaaa, "gfw: direct AAAA filter on -> unclassified (direct) names get no AAAA")
check(no_aaaa not in main[-4]["exec"], "gfw: proxy AAAA filter off -> proxied names keep AAAA")
check("category-ads-all" not in json.dumps(m), "adblock off must not emit an ad rule")
check(plugin(m, "add_proxy")["args"].get("set_name6") == "proxy6_dns", "ipv6: nftset must also fill the v6 set")
check(plugin(m, "query_is_node") is None, "an IP-literal node needs no node matcher")
pre = chain(n, "prerouting")
check(pre[-1] == "return", "gfw: kernel default is direct")
check(not any("@ipg" in r for r in pre), "gfw: no IP rule groups are needed")
check("ip6 daddr @proxy6_dns goto do_tproxy" in pre and "meta nfproto ipv6 return" not in pre, "ipv6 rules present")
check("2001:db8:1::5" in n.split("add element inet xray-mosdns bypass6 {", 1)[1].split("}")[0], "v6 node address must be bypassed")
check(len(chain(n, "do_tproxy")) == 3, "ipv6 tproxy rule present")
check('"br-guest"' in pre[0], "lan_devices from the config are honoured")

# ------------------------------------------------------------------ balance
x, m, n = load("balance")
check_mosdns_refs("balance", m)
# the fixture is a pre-0.9.2 config: one global balancer + a primary/standby pair
tags = [o["tag"] for o in x["outbounds"]]
check(tags == ["a.node", "b.node", "c.node", "direct", "block"], f"balance: outbound tags {tags}")
bal = {b["tag"]: b for b in x["routing"]["balancers"]}
check(bal["balance.group"] == {"tag": "balance.group", "selector": ["a.node", "b.node"], "strategy": {"type": "leastLoad"}, "fallbackTag": "c.node"}, "legacy balancer becomes a 'fastest' group of the enabled nodes")
check(bal["failover.group"] == {"tag": "failover.group", "selector": ["a.node", "b.node"], "strategy": {"type": "leastLoad", "settings": {"expected": 2}}, "fallbackTag": "direct"}, "legacy failover becomes an 'ordered' group whose members are all probed")
check(x["burstObservatory"]["subjectSelector"] == ["a.node", "b.node"], "every group member is probed once")
check("RoutingService" in x["api"]["services"], "RoutingService is needed to read and pin balancer choices")
check({"type": "field", "domain": ["geosite:openai"], "balancerTag": "failover.group"} in x["routing"]["rules"], "rule -> failover group")
check(x["routing"]["rules"][-1].get("balancerTag") == "balance.group", "balance: default is the balancer group")
gj = json.load(open(f"{out}/balance/groups.json"))
check([g["name"] for g in gj] == ["balance", "failover"] and gj[1]["members"] == [{"name": "a", "tag": "a.node"}, {"name": "b", "tag": "b.node"}], "groups.json lists the ordered members for the watcher")
check(plugin(m, "add_proxy") is None, "kernel split off: no nftset plugins")
bmain = plugin(m, "main_sequence")["args"]["exec"]
check(bmain[-2:] == ["remote_seq", "_return"], "default proxy without a mainland rule: unclassified names resolve through the proxy")
check(plugin(m, "forward_lan") is None, "no redirect: nothing is forwarded to dnsmasq")
check([l["addr"] for l in m["servers"][0]["listeners"]] == ["127.0.0.1:5335", "127.0.0.1:5335", "[::1]:5335", "[::1]:5335"], "no redirect: loopback listeners")
pre = chain(n, "prerouting")
check(not any("_dns" in r for r in pre) and pre[-1] == "goto do_tproxy", "kernel split off: everything goes to Xray")
check(chain(n, "dns_redirect") == [] and "flush chain inet xray-mosdns dns_redirect" in n, "no redirect rule when disabled, and the chain is cleared")
check(not any("dport 53" in r for r in pre), "port 53 is not exempted when the redirect is off")

# ------------------------------------------------------------------ groups
x, m, n = load("groups")
check_mosdns_refs("groups", m)
tags = [o["tag"] for o in x["outbounds"]]
check(tags == ["a.node", "b.node", "direct", "block"], f"groups: a disabled node gets no outbound ({tags})")
check(x["routing"]["balancers"] == [{"tag": "hk.group", "selector": ["a.node", "b.node"], "strategy": {"type": "leastLoad", "settings": {"expected": 2}}, "fallbackTag": "block"}], "groups: disabled member skipped, unused and empty groups produce no balancer")
check(x["burstObservatory"]["pingConfig"]["destination"] == "https://probe.example/204" and x["burstObservatory"]["pingConfig"]["interval"] == "30s", "groups: probe settings")
check({"type": "field", "domain": ["geosite:netflix"], "outboundTag": "a.node"} in x["routing"]["rules"], "groups: a group without usable members resolves to its fallback")
check({"type": "field", "ip": ["192.0.2.0/24"], "outboundTag": "b.node"} in x["routing"]["rules"], "groups: plain node target")
check(x["routing"]["rules"][-1] == {"type": "field", "network": "tcp,udp", "balancerTag": "hk.group"}, "groups: main target is a group")
check(chain(n, "dns_redirect") == ['iifname { "br-lan" } meta l4proto { tcp, udp } th dport 53 counter redirect to :5335'] and "flush chain inet xray-mosdns dns_redirect" in n, "watchdog off: the redirect rule is static in nft.rules")
# router's own traffic (proxy_router = tcp, watchdog off in this fixture)
oc = chain(n, "output")
check(oc[0] == 'meta mark 0xff return comment "sent by Xray or mosdns"' and oc[1] == "meta l4proto != tcp return", "router: own packets of Xray/mosdns are skipped first, then only TCP is considered")
check("meta l4proto { tcp, udp } th dport 53 return" in oc and oc.index("ct mark & 0x1 == 0x1 goto out_mark") < oc.index("ct state != new return") < oc.index("ip daddr @bypass4 return"), "router: DNS exempt, then per-flow shortcut, then classification")
check(oc[-1] == "goto out_mark" and "ip daddr @proxy4_dns goto out_mark" in oc, "router: same classification as the LAN, with a marking verdict")
check(chain(n, "out_mark") == ["ct mark set ct mark | 0x1", "meta mark set 0x1"], "router: marking chain")
check(chain(n, "prerouting")[0] == 'iifname "lo" meta mark 0x1 goto do_tproxy comment "router traffic, marked in output"', "router: re-routed packets enter the tproxy path from lo")
check(chain(n, "dns_redirect_out") == ["meta mark != 0xff fib daddr type local meta l4proto { tcp, udp } th dport 53 counter redirect to :5335"], "router: its own lookups go to mosdns, except the ones mosdns sends to dnsmasq")
check(all(o.get("streamSettings", {}).get("sockopt", {}).get("mark") == 255 for o in x["outbounds"] if o["tag"] != "block"), "router: every Xray outbound carries the self mark")
fl = plugin(m, "forward_local")["args"]["upstream"]
check(all(u.get("so_mark") == 255 for u in fl) and plugin(m, "forward_lan")["args"]["upstream"][0].get("so_mark") == 255, "router: mosdns' direct and dnsmasq queries carry the self mark")

# blocklist subscriptions
prov = {p["tag"]: p for p in m["data_providers"]}
check(prov.get("adblock") == {"tag": "adblock", "file": "/tmp/xm-adlists/block.txt", "auto_reload": True} and prov.get("adallow", {}).get("file") == "/tmp/xm-adlists/allow.txt", "adlist: merged files are data providers with auto reload")
gmain = plugin(m, "main_sequence")["args"]["exec"]
adrow = [e for e in gmain if isinstance(e, dict) and "query_is_ad_exception" in e.get("if", "")]
check(len(adrow) == 1 and adrow[0]["exec"] == ["_new_nxdomain_response", "_return"] and adrow[0]["if"].endswith("&& (! query_is_ad_exception)"), "adlist: blocked unless one of the lists' own exceptions matches")
adtag = adrow[0]["if"].split(" ")[0] if adrow else "?"
check(plugin(m, adtag)["args"]["domain"] == ["provider:adblock"] and plugin(m, "query_is_ad_exception")["args"]["domain"] == ["provider:adallow"], "adlist: matchers")
check("adlist:" not in json.dumps(x), "adlist: the pseudo value never reaches Xray")

# per-device routing
tin = {i["tag"]: i for i in x["inbounds"]}
check(tin.get("dev-0", {}).get("port") == 12346 and tin.get("dev-1", {}).get("port") == 12347 and "dev-2" not in tin, "devices: one extra tproxy inbound per distinct proxy target")
check(tin["dev-0"]["streamSettings"] == {"sockopt": {"tproxy": "tproxy"}} and tin["dev-0"]["protocol"] == "tunnel", "devices: inbounds are tproxy inbounds")
r = x["routing"]["rules"]
d0 = {"type": "field", "inboundTag": ["dev-0"], "outboundTag": "b.node"}
d1 = {"type": "field", "inboundTag": ["dev-1"], "balancerTag": "hk.group"}
first_user = r.index({"type": "field", "domain": ["geosite:netflix"], "outboundTag": "a.node"})
check(d0 in r and d1 in r and r.index(d0) < r.index(d1) < first_user, "devices: their rules come before every routing rule")
pre = chain(n, "prerouting")
i_dev = [k for k, line in enumerate(pre) if line.startswith("ether saddr")]
check([pre[k] for k in i_dev] == [
    'ether saddr { aa:bb:cc:00:00:01 } meta l4proto udp goto dev_12346 comment "device %s"' % pre[i_dev[0]].split('device ')[1].rstrip('"'),
    'ether saddr { aa:bb:cc:00:00:02, aa:bb:cc:00:00:03 } return comment "device %s: direct"' % pre[i_dev[1]].split('device ')[1].split(':')[0],
    'ether saddr { aa:bb:cc:00:00:04 } goto dev_12347 comment "device %s"' % pre[i_dev[2]].split('device ')[1].rstrip('"'),
    'ether saddr { aa:bb:cc:00:00:05 } meta l4proto tcp goto dev_12346 comment "device %s"' % pre[i_dev[3]].split('device ')[1].rstrip('"'),
], "devices: MAC rules (lower-cased, invalid and disabled entries dropped, shared inbound reused)")
check(max(i_dev) < next(k for k, line in enumerate(pre) if line.startswith("ct mark")), "devices: matched per packet, before the per-flow shortcut")
check(i_dev[0] > next(k for k, line in enumerate(pre) if "dport 53" in line) if any("dport 53" in line for line in pre) else True, "devices: DNS is exempt first")
dc = chain(n, "dev_12346")
check(dc[:3] == ["fib daddr type != unicast return", "ip daddr @bypass4 return", "ip6 daddr @bypass6 return"] and "tproxy ip to :12346" in dc[3] and dc[4] == "return", "devices: chain keeps the usual exemptions, then its own port")
check("th dport { 12345, 12346, 12347 } drop" in n, "devices: their ports are closed to direct access too")
gj = json.load(open(f"{out}/groups/groups.json"))
check(len(gj) == 1 and gj[0]["name"] == "hk" and gj[0]["remarks"] == "香港" and gj[0]["strategy"] == "ordered" and [mm["name"] for mm in gj[0]["members"]] == ["a", "b"], "groups.json: only the used group, in member order")

# ------------------------------------------------------------------ blocklist conversion
block = open(f"{out}/adlist/block.txt").read().split()
allow = open(f"{out}/adlist/allow.txt").read().split()
check(block == ["domain:ads.example.com", "domain:tracker.example.net", "full:exact.example.org", "full:hosts.example.com",
                "full:other.example.com", "full:v6hosts.example.com", "full:plain.example.org", "full:plain2.example.org",
                "domain:noanchor.example.com"], f"adlist: block rules {block}")
check(allow == ["domain:good.example.com", "domain:good2.example.com"], f"adlist: exceptions {allow}")
check(json.load(open(f"{out}/adlist/stats.json")) == {"rules": 9, "allow": 2, "skipped": 5}, "adlist: counts (wildcard, regex, other modifiers, localhost and junk are skipped)")

if failed:
    print("\n".join("FAIL: " + f for f in failed))
    sys.exit(1)
print("all checks passed")
