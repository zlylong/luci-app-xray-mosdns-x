#!/usr/bin/env python3
"""Assertions over the configs produced by tests/gen.sh.

usage: tests/check.py <outdir> [--all]

--all (CI): the output of tests/scripts.sh and tests/runtime.sh has to be
there; without it a part that was not run is skipped.
"""
import json
import re
import os
import sys
import time

import yaml

args = [a for a in sys.argv[1:] if not a.startswith("--")]
out = args[0] if args else "/tmp/xm-test"
strict = "--all" in sys.argv[1:]
failed = []


def check(cond, msg):
    if not cond:
        failed.append(msg)


def load(case):
    x = json.load(open(f"{out}/{case}/xray.json"))
    # every rule tagged, one prefix for the set; the rules alone as Xray's
    # API takes them; a name for the rest (what Xray is restarted for)
    rtags = [r.get("ruleTag", "") for r in x["routing"]["rules"]]
    pre = rtags[0].rsplit("_", 1)[0] if rtags else ""
    check(re.fullmatch(r"r[0-9a-f]{8}", pre) is not None and rtags == [f"{pre}_{i}" for i in range(len(rtags))],
          f"{case}: every routing rule tagged by its set and place {rtags[:3]}")
    check(json.load(open(f"{out}/{case}/xray-rules.json")) == {"routing": {"rules": x["routing"]["rules"]}}
          and re.fullmatch(r"[0-9a-f]{8}\n", open(f"{out}/{case}/xray.restart").read()) is not None,
          f"{case}: xray-rules.json has the rules alone, xray.restart names the rest")
    # the checks below compare rules as generated from the configuration
    for r in x["routing"]["rules"]:
        r.pop("ruleTag", None)
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
check(x["log"] == {"loglevel": "warning", "access": "none"}, f"defaults: Xray warnings only, no access log flooding the system log {x['log']}")
check({"type": "field", "ip": ["geoip:cn"], "outboundTag": "direct"} in rules, "chnroute: geoip:cn direct rule missing")
check(x["outbounds"][0]["settings"]["vnext"][0]["address"] == "hk1.example.net", "node hostname must be passed to Xray unresolved")
check(x["outbounds"][1]["settings"]["servers"][0]["password"] == 'p@ss"word', "password with a quote must survive")
main = plugin(m, "main_sequence")["args"]["exec"]
by_if = {e["if"]: e["exec"] for e in main if isinstance(e, dict) and "if" in e}
check(by_if["rule_0"] == ["local_seq", "add_direct", "_return"], "chnroute: direct rule must resolve locally and mark the direct set")
check(by_if["rule_1"][0] == {"if": "query_is_ipv6", "exec": ["_new_empty_response", "_return"]}, "default: proxied names get no AAAA, direct names do")
check(by_if["rule_1"][-3:] == ["remote_seq", "add_proxy", "_return"], "chnroute: proxy rule must resolve remotely and mark the proxy set")
check(by_if["rule_2"] == ["metrics_block", "_new_nxdomain_response", "_return"], "chnroute: block rule must answer NXDOMAIN (and is counted)")
order = [e["if"] for e in main if isinstance(e, dict) and "if" in e]
# the fixture is a pre-0.9.1 config: its mode and ad switch must turn into rule rows after the user's rules
check(plugin(m, "rule_3")["args"]["domain"] == ["provider:geosite:category-ads-all"] and by_if["rule_3"] == ["metrics_block", "_new_nxdomain_response", "_return"], "legacy adblock becomes a block rule")
# the DNS counts (stats.uc): every query first, every blocked one in its branch, read on 127.0.0.1
cmain = plugin(m, "main_sequence")["args"]["exec"]
# the watchdog's health check first: answered, neither logged nor counted (#90)
check(cmain[0] == {"if": "query_is_probe", "exec": ["_new_nxdomain_response", "_return"]}
      and plugin(m, "query_is_probe")["args"] == {"domain": ["full:xray-mosdns-probe.invalid"]},
      f"stats: the watchdog's health check is answered before anything counts or logs it {cmain[:2]}")
check(cmain[1] == "metrics_all" and (plugin(m, "metrics_all") or {}).get("type") == "metrics_collector"
      and (plugin(m, "metrics_block") or {}).get("type") == "metrics_collector" and m.get("api") == {"http": "127.0.0.1:5336"},
      f"stats: every query counted next, the counters on 127.0.0.1:5336 {cmain[:2]} {m.get('api')}")
# the block branches (not the health check's, which nothing counts)
blocks = [e for e in cmain if isinstance(e, dict) and e["if"] != "query_is_probe" and ("_new_nxdomain_response" in e["exec"] or "block_zero" in e["exec"])]
check(len(blocks) >= 2 and all(e["exec"][0] == "metrics_block" for e in blocks), f"stats: every block branch counts first {blocks}")
check(plugin(m, "rule_4")["args"]["domain"] == ["provider:geosite:cn"] and by_if["rule_4"] == ["local_seq", "add_direct", "_return"], "legacy chnroute: mainland domains resolve locally")
check(plugin(m, "rule_5")["args"]["domain"] == ["provider:geosite:geolocation-!cn"] and by_if["rule_5"][-3:] == ["remote_seq", "add_proxy", "_return"], "legacy chnroute: non-mainland domains resolve through the proxy")
check(order == ["query_is_probe", "query_is_lan_name || query_is_ptr", "query_is_node"] + ["rule_%d" % i for i in range(6)], f"chnroute: rule order {order}")
check(main[-1] == "fallback_seq", "mainland IPs direct + default proxy: unclassified names use the ChinaDNS fallback")
check({"type": "field", "domain": ["geosite:cn"], "outboundTag": "direct"} in rules, "geosite:cn rule reaches Xray")
check(order.index("query_is_node") < order.index("rule_0"), "node hostnames must be resolved locally before any rule")
check(plugin(m, "query_is_node")["args"]["domain"] == ["full:hk1.example.net"], "only hostname nodes need the node matcher")
check(plugin(m, "rule_1")["args"]["domain"] == ["provider:geosite:netflix", "full:api.example.com", "keyword:tracker"], "domain syntax conversion")
check(plugin(m, "local_seq")["args"]["exec"] == ["cache", "forward_local"], "cache must sit inside the sequence so nftset runs on hits")
check(plugin(m, "ecs_local") is None and "ECS_IFACES=''" in open(f"{out}/chnroute/runtime.env").read(), "defaults: no ECS, no WAN interfaces watched for it")
check(plugin(m, "forward_remote")["args"]["upstream"] == [{"addr": "tcp://1.1.1.1:53", "socks5": "127.0.0.1:1070", "idle_timeout": 10, "enable_pipeline": True}], "default foreign upstream")
check(m["log"].get("production") is False and "_query_summary" not in plugin(m, "main_sequence")["args"]["exec"] and plugin(m, "query_is_ipv4_only") is None and plugin(m, "min_ttl") is None and plugin(m, "block_zero") is None, "defaults: no query log, no TTL floor, NXDOMAIN blocking")
check("disabled.example" not in json.dumps(m), "disabled rule leaked into mosdns")
check(m["servers"][0]["listeners"][0]["addr"] == ":5335", "redirect mode listens on the wildcard address")
pre = chain(n, "prerouting")
check(pre[0] == 'iifname != { "br-lan" } return', "traffic not entering from the LAN must be left alone")
check(pre.index("ip daddr @direct4_dns return") < pre.index("ip daddr @proxy4_dns goto do_tproxy") < pre.index("ip daddr @ipg4_0 goto do_tproxy") < pre.index("ip daddr @ipg4_1 return"), "DNS sets first, then IP rule groups in rule order")
SHARED = 'comment "learned for a direct and a proxied name"'
check(pre.index(f"ip daddr @direct4_dns ip daddr @proxy4_dns goto do_tproxy {SHARED}") < pre.index("ip daddr @direct4_dns return"),
      "an address in both DNS sets goes to Xray, ahead of the direct set")
check(x["inbounds"][0]["tag"] == "tproxy-in" and x["inbounds"][0]["sniffing"] == {"enabled": True, "destOverride": ["http", "tls", "quic"], "routeOnly": True},
      "Xray sniffs the name that decides such flows, and still connects to the address")
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
check(plugin(m, "ecs_local") is None and "ecs_local" not in json.dumps(m),
      "ECS from the router's own address: none found (no network in the tests), so none, and no reference to it")
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
# the internal SOCKS inbound must reach the proxy even though this config's default is direct
socks_rule = {"type": "field", "inboundTag": ["socks-in"], "outboundTag": "hk1.node"}
check(socks_rule in rules and rules.index(socks_rule) < rules.index({"type": "field", "port": "22,3389", "outboundTag": "direct"}), "gfw: mosdns' foreign upstream goes through the proxy, ahead of every rule")
check(plugin(m, "query_is_ipv6")["args"] == {"qtype": [28, 65]}, "the IPv6 filter covers AAAA and HTTPS (type 65) queries")
main = plugin(m, "main_sequence")["args"]["exec"]
check(plugin(m, "rule_1")["args"]["domain"] == ["provider:geosite:gfw"], "legacy gfw mode becomes a rule row")
check(main[-4] == {"if": "rule_1", "exec": ["remote_seq", "add_proxy", "_return"]}, "gfw: listed domains resolve remotely and are marked")
check(main[-2:] == ["local_seq", "_return"], "gfw: other names resolve locally")
no_aaaa = {"if": "query_is_ipv6", "exec": ["_new_empty_response", "_return"]}
check(main[-3] == no_aaaa, "gfw: direct AAAA filter on -> unclassified (direct) names get no AAAA")
check(no_aaaa not in main[-4]["exec"], "gfw: proxy AAAA filter off -> proxied names keep AAAA")
check("category-ads-all" not in json.dumps(m), "adblock off must not emit an ad rule")
check(plugin(m, "add_proxy")["args"].get("set_name6") == "proxy6_dns", "ipv6: nftset must also fill the v6 set")
check(plugin(m, "query_is_node") is None, "an IP-literal node needs no node matcher")
pre = chain(n, "prerouting")
check(pre[-1] == "return", "gfw: kernel default is direct")
check(not any("@ipg" in r for r in pre), "gfw: no IP rule groups are needed")
check("ip6 daddr @proxy6_dns goto do_tproxy" in pre and "meta nfproto ipv6 return" not in pre, "ipv6 rules present")
check(pre.index(f"ip6 daddr @direct6_dns ip6 daddr @proxy6_dns goto do_tproxy {SHARED}") < pre.index("ip6 daddr @direct6_dns return"),
      "ipv6: an address in both DNS sets goes to Xray too")
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
check(bal["failover.group"] == {"tag": "failover.group", "selector": ["a.node", "b.node"], "strategy": {"type": "leastLoad", "settings": {"expected": 2, "tolerance": 0.3}}, "fallbackTag": "direct"}, "legacy failover becomes an 'ordered' group whose members are all probed; one failed probe makes a member unusable")
check(bal.get("failover.alive") == {"tag": "failover.alive", "selector": ["a.node", "b.node"], "strategy": {"type": "leastLoad", "settings": {"expected": 2}}}
      and "balance.alive" not in bal, "an ordered group also gets a balancer that reports the members Xray still has as alive; a 'fastest' one does not")
check(not [r for r in x["routing"]["rules"] if str(r.get("balancerTag", "")).endswith(".alive")], "no rule routes through an '.alive' balancer")
check(x["burstObservatory"]["subjectSelector"] == ["a.node", "b.node"], "every group member is probed once")
check("RoutingService" in x["api"]["services"], "RoutingService is needed to read and pin balancer choices")
check({"type": "field", "domain": ["geosite:openai"], "balancerTag": "failover.group"} in x["routing"]["rules"], "rule -> failover group")
check(x["routing"]["rules"][-1].get("balancerTag") == "balance.group", "balance: default is the balancer group")
gj = json.load(open(f"{out}/balance/groups.json"))
check([g["name"] for g in gj] == ["balance", "failover"] and gj[1]["members"] == [{"name": "a", "tag": "a.node"}, {"name": "b", "tag": "b.node"}], "groups.json lists the ordered members for the watcher")
check(gj[1].get("alive") == "failover.alive" and gj[0].get("alive") is None, "groups.json names the ordered group's '.alive' balancer for the watcher")
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
check(x["routing"]["balancers"] == [{"tag": "hk.group", "selector": ["a.node", "b.node"], "strategy": {"type": "leastLoad", "settings": {"expected": 2, "tolerance": 0.3}}, "fallbackTag": "block"},
                                    {"tag": "hk.alive", "selector": ["a.node", "b.node"], "strategy": {"type": "leastLoad", "settings": {"expected": 2}}}], "groups: disabled member skipped, unused and empty groups produce no balancer")
check(x["burstObservatory"]["pingConfig"]["destination"] == "https://probe.example/204" and x["burstObservatory"]["pingConfig"]["interval"] == "30s", "groups: probe settings")
check({"type": "field", "domain": ["geosite:netflix"], "outboundTag": "a.node"} in x["routing"]["rules"], "groups: a group without usable members resolves to its fallback")
check({"type": "field", "ip": ["192.0.2.0/24"], "outboundTag": "b.node"} in x["routing"]["rules"], "groups: plain node target")
check(x["routing"]["rules"][-1] == {"type": "field", "network": "tcp,udp", "balancerTag": "hk.group"}, "groups: main target is a group")
check(chain(n, "dns_redirect") == ['iifname { "br-lan" } meta l4proto { tcp, udp } th dport 53 counter redirect to :5335'] and "flush chain inet xray-mosdns dns_redirect" in n, "watchdog off: the redirect rule is static in nft.rules")
# router's own traffic (proxy_router = tcp, watchdog off in this fixture)
oc = chain(n, "output")
check(oc[0] == 'meta mark 0xff return comment "sent by Xray or mosdns"' and oc[1] == "meta l4proto != tcp return", "router: own packets of Xray/mosdns are skipped first, then only TCP is considered")
check("meta l4proto { tcp, udp } th dport 53 return" in oc and oc.index("ct mark & 0x1 == 0x1 goto out_mark") < oc.index("ct state != new return") < oc.index("ip daddr @bypass4 return"), "router: DNS exempt, then per-flow shortcut, then classification")
check(oc.index('ct direction reply return comment "Xray answering a LAN client"') < oc.index("ct mark & 0x1 == 0x1 goto out_mark"),
      "router: replies (Xray answering LAN clients, whose flows prerouting marked) keep their route")
check(oc[-1] == "goto out_mark" and "ip daddr @proxy4_dns goto out_mark" in oc, "router: same classification as the LAN, with a marking verdict")
check(oc.index(f"ip daddr @direct4_dns ip daddr @proxy4_dns goto out_mark {SHARED}") < oc.index("ip daddr @direct4_dns return"),
      "router: an address in both DNS sets is marked for Xray too")
check(chain(n, "out_mark") == ["ct mark set ct mark | 0x1", "meta mark set 0x1"], "router: marking chain")
check(chain(n, "prerouting")[0] == 'iifname "lo" meta mark 0x1 goto do_tproxy comment "router traffic, marked in output"', "router: re-routed packets enter the tproxy path from lo")
check(chain(n, "dns_redirect_out") == ["meta mark != 0xff fib daddr type local meta l4proto { tcp, udp } th dport 53 counter redirect to :5335"], "router: its own lookups go to mosdns, except the ones mosdns sends to dnsmasq")
check(all(o.get("streamSettings", {}).get("sockopt", {}).get("mark") == 255 for o in x["outbounds"] if o["tag"] != "block"), "router: every Xray outbound carries the self mark")
fl = plugin(m, "forward_local")["args"]["upstream"]
check(all(u.get("so_mark") == 255 for u in fl) and plugin(m, "forward_lan")["args"]["upstream"][0].get("so_mark") == 255, "router: mosdns' direct and dnsmasq queries carry the self mark")

# blocklist subscriptions
prov = {p["tag"]: p for p in m["data_providers"]}
check(prov.get("adblock") == {"tag": "adblock", "file": "/tmp/xm-adlists/xray-mosdns/block.txt", "auto_reload": True} and prov.get("adallow", {}).get("file") == "/tmp/xm-adlists/xray-mosdns/allow.txt", "adlist: merged files are data providers with auto reload, in our own subdirectory of a directory set in the options")
gmain = plugin(m, "main_sequence")["args"]["exec"]
adrow = [e for e in gmain if isinstance(e, dict) and "query_is_ad_exception" in e.get("if", "")]
check(len(adrow) == 1 and adrow[0]["exec"] == ["metrics_block", "block_zero", "_return"] and adrow[0]["if"].endswith("&& (! query_is_ad_exception)"), "adlist: blocked (0.0.0.0 mode) unless one of the lists' own exceptions matches")
# DNS options set in this fixture
check(plugin(m, "block_zero")["args"] == {"ipv4": ["0.0.0.0"], "ipv6": ["::"]}, "block mode zero")
check(plugin(m, "min_ttl")["args"] == {"minimal_ttl": 120} and plugin(m, "local_seq")["args"]["exec"] == ["cache", "forward_local", "min_ttl"] and plugin(m, "remote_seq")["args"]["exec"] == ["cache", "forward_remote", "min_ttl"] and plugin(m, "fallback_seq")["args"]["exec"][-1] == "min_ttl", "TTL floor sits behind the forwarder in every cached sequence")
ups = plugin(m, "forward_remote")["args"]["upstream"]
check([u["addr"] for u in ups] == ["tcp://8.8.8.8:53", "https://1.1.1.1/dns-query", "tls://dns.google"] and all(u["socks5"] == "127.0.0.1:1070" for u in ups), "several foreign upstreams, all through the proxy, junk dropped")
check("bootstrap" in ups[2] and "bootstrap" not in ups[1] and ups[0].get("enable_pipeline") is True and "enable_pipeline" not in ups[1], "host-name upstream gets a bootstrap resolver; pipelining only for plain TCP")
# two bootstrap resolvers (junk dropped) go round the host-name upstreams, domestic first
boots = [(u["addr"], u.get("bootstrap")) for u in fl + ups]
check(boots == [("https://dns.alidns.com/dns-query", "119.29.29.29"), ("tls://dot.pub", "223.5.5.5"), ("tls://223.5.5.5", None),
                ("tcp://8.8.8.8:53", None), ("https://1.1.1.1/dns-query", None), ("tls://dns.google", "119.29.29.29")],
      f"bootstrap resolvers: one per host-name upstream, in turn; none for an address {boots}")
# IPv4-only names: AAAA/HTTPS answered empty right after the static entries, before
# any other branch; bare names mean the name and its subdomains, junk dropped
check(plugin(m, "query_is_ipv4_only") == {"tag": "query_is_ipv4_only", "type": "query_matcher",
                                          "args": {"domain": ["domain:hs.example.com", "full:exact.example.org", "keyword:home"]}}
      and gmain[gmain.index("hosts") + 1] == {"if": "query_is_ipv4_only && query_is_ipv6", "exec": ["_new_empty_response", "_return"]},
      f"dns.ipv4_only: a matcher and an empty answer for AAAA/HTTPS, behind hosts: {gmain[:5]}")
# the preset summary node first: it wraps everything behind it, so every query is logged
check(m["log"]["production"] is True and gmain[0].get("if") == "query_is_probe" and gmain[1] == "_query_summary"
      and gmain.count("_query_summary") == 1 and gmain[2] == "metrics_all",
      "query log: JSON log lines, the preset summary node first in the main sequence after the health check (then the counter)")
# mosdns-x v26.05.25 panics while loading any plugin of type query_summary
check(not [p for p in m["plugins"] if p["type"] == "query_summary"] and not any(f'"log_{k}"' in json.dumps(m) for k in ("lan", "block", "direct", "proxy", "fallback")), "query log: no query_summary plugins (they crash mosdns-x), no references to them")
check({"type": "field", "inboundTag": ["socks-in"], "balancerTag": "hk.group"} in x["routing"]["rules"], "internal SOCKS inbound follows the main target (a group here)")
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

# ------------------------------------------------------------------ nosniff: chnroute with sniffing off
x, m, n = load("nosniff")
pre = chain(n, "prerouting")
check("sniffing" not in x["inbounds"][0], "nosniff: Xray does not sniff")
check(x["log"] == {"loglevel": "info"}, f"log_level info: with Xray's access log {x['log']}")
check(not any("@direct4_dns ip daddr @proxy4_dns" in r for r in pre) and pre.index("ip daddr @direct4_dns return") < pre.index("ip daddr @proxy4_dns goto do_tproxy"),
      "nosniff: Xray could not decide by name, so the direct set keeps precedence")
# ECS with addresses given by hand (this fixture): one of each family, the rest dropped
check(plugin(m, "ecs_local") == {"tag": "ecs_local", "type": "ecs", "args": {"mask4": 24, "mask6": 48, "ipv4": "203.0.113.7", "ipv6": "2001:db8::7"}},
      f"ECS: the addresses given by hand, one IPv4 and one IPv6 (junk and a second IPv4 dropped) {plugin(m, 'ecs_local')}")
ptags = [p["tag"] for p in m["plugins"]]
check(plugin(m, "local_seq")["args"]["exec"][:3] == ["cache", "ecs_local", "forward_local"] and ptags.index("ecs_local") < ptags.index("local_seq"),
      "ECS: behind the cache (which keys on the client's own query), in front of the domestic upstreams")
fbx = plugin(m, "fallback_seq")["args"]["exec"][1]
check(fbx["primary"][:2] == ["ecs_local", "forward_local"] and "ecs_local" not in json.dumps(fbx["secondary"])
      and "ecs_local" not in plugin(m, "remote_seq")["args"]["exec"],
      "ECS: the domestic side of the fallback carries it, the proxied side never does")
check("ECS_IFACES=''" in open(f"{out}/nosniff/runtime.env").read(), "ECS given by hand: no WAN interface watched for it")

# ------------------------------------------------------------------ blocklist conversion
block = open(f"{out}/adlist/block.txt").read().split()
allow = open(f"{out}/adlist/allow.txt").read().split()
check(block == ["domain:ads.example.com", "domain:tracker.example.net", "full:exact.example.org", "full:hosts.example.com",
                "full:other.example.com", "full:v6hosts.example.com", "full:plain.example.org", "full:plain2.example.org",
                "domain:noanchor.example.com", "domain:rw-nx.example.com", "domain:rw-refused.example.com",
                "domain:rw-zero.example.com", "domain:rw-adguard.example.com", "domain:rw-imp.example.com"],
      f"adlist: block rules, $dnsrewrite blocks (an error, a null address, AdGuard's block host) among them {block}")
check(allow == ["domain:good.example.com", "domain:good2.example.com"], f"adlist: exceptions {allow}")
check(json.load(open(f"{out}/adlist/stats.json")) == {"rules": 14, "allow": 2, "skipped": 9},
      "adlist: counts (wildcard, regex, other modifiers, a $dnsrewrite that answers with a record or a name, localhost and junk are skipped)")

# ------------------------------------------------------------------ blocklists that change places (tests/runtime.sh)
swp = f"{out}/runtime/adlist-swap.txt"
if os.path.exists(swp):
    sw = {}
    for line in open(swp).read().splitlines():
        k, _, v = line.partition(" ")
        sw[k] = v
    def swj(k):
        try:
            return json.loads(sw.get(k, ""))
        except ValueError:
            return {}
    def secmap(v):  # "name list a=.. b=..; ..." -> {list: (a, b)}
        res = {}
        for part in filter(None, (p.strip() for p in v.split(";"))):
            f = part.split()
            res[f[1]] = (f[2], f[3])
        return res
    check(swj("swap-update1").get("ok") is True and sw.get("swap-merged1") == "a=1 b=1 lines=3"
          and secmap(sw.get("swap-secs1", "")) == {"swap-a.txt": ("a=1", "b=0"), "swap-b.txt": ("a=0", "b=1")},
          f"adlist swap: two anonymous lists, each with its own data {sw.get('swap-secs1')}")
    check(secmap(sw.get("swap-secs2", "")) == {"swap-b.txt": ("a=1", "b=0"), "swap-a.txt": ("a=0", "b=1")}
          and swj("swap-status2").get("lists") == {},
          f"adlist swap: after changing places each name holds the other's data, and its state is not shown for it {sw.get('swap-status2')}")
    st2b = swj("swap-status2b").get("lists") or {}
    check(sw.get("swap-ensure2", "") == "" and sw.get("swap-kept2") == "yes 0"
          and secmap(sw.get("swap-secs2b", "")) == {"swap-b.txt": ("a=0", "b=1"), "swap-a.txt": ("a=1", "b=0")}
          and sorted((e.get("url", "").rsplit("/", 1)[-1], e.get("rules")) for e in st2b.values()) == [("swap-a.txt", 1), ("swap-b.txt", 2)]
          and swj("swap-status2b").get("running") is False and swj("swap-status2b").get("progress") is None,
          f"adlist swap: at start the data goes to its list's new name by its address, nothing fetched, the merged list in use stays "
          f"{sw.get('swap-ensure2')!r} {sw.get('swap-secs2b')} {st2b}")
    st3 = swj("swap-status3").get("lists") or {}
    check(swj("swap-update3").get("ok") is True and sw.get("swap-merged3") == "a=1 b=1 lines=3"
          and secmap(sw.get("swap-secs3", "")) == {"swap-b.txt": ("a=0", "b=1"), "swap-a.txt": ("a=1", "b=0")}
          and sorted((e.get("url", "").rsplit("/", 1)[-1], e.get("rules")) for e in st3.values()) == [("swap-a.txt", 1), ("swap-b.txt", 2)],
          f"adlist swap: the next update gives each its own data, nothing twice in the merged list {sw.get('swap-secs3')} {st3}")
    check(swj("swap-legacy-status").get("lists") == {} and swj("swap-legacy-ensure").get("running") is True
          and sw.get("swap-legacy-kept") == "yes a=1 b=1 lines=3",
          f"adlist swap: state without addresses (older versions) counts as another address: fetched again, the list in use stays "
          f"{sw.get('swap-legacy-status')} {sw.get('swap-legacy-kept')}")
    # #84: a failed update throws nothing away
    fu = swj("swap-fail-update")
    check(fu.get("ok") is False and fu.get("failed") == 2 and sw.get("swap-fail-kept") == "yes files-same",
          f"adlist #84: downloads fail with state from older versions: both lists keep their data, the lists in use are as they were {fu} {sw.get('swap-fail-kept')}")
    fst = swj("swap-fail-status").get("lists") or {}
    check(len(fst) == 2 and all(e.get("error") == "download failed" and str(e.get("tried", "")).startswith("https://lists.test/swap-")
                                and not e.get("url") for e in fst.values()),
          f"adlist #84: the status shows the failure for each list's address, not a success {fst}")
    check(swj("swap-update6").get("ok") is True and sw.get("swap-merged6") == "a=1 b=1 lines=3",
          f"adlist #84: the next update that gets them gives each its own data {sw.get('swap-merged6')}")
    ru = swj("swap-rename-update")
    check(ru.get("ok") is False and "the lists in use stay as they are" in str(ru.get("error")) and sw.get("swap-rename-kept") == "yes yes 0",
          f"adlist #84: a list's files cannot be replaced: its old data and the lists in use stay, nothing left behind {ru} {sw.get('swap-rename-kept')}")
    ra = [e for e in (swj("swap-rename-status").get("lists") or {}).values() if str(e.get("url", "")).endswith("swap-a.txt")]
    check(len(ra) == 1 and "not a file" in str(ra[0].get("error")),
          f"adlist #84: ... and its status says so instead of a success {ra}")
    check(swj("swap-update8").get("ok") is True and sw.get("swap-merged8") == "1",
          f"adlist #84: once replaceable the new data goes in {swj('swap-update8')} {sw.get('swap-merged8')}")
    check(sw.get("swap-cut-back") == "yes allow 0 yes",
          f"adlist #91: data an update left aside (cut short) goes back at start, the lists in use as they were {sw.get('swap-cut-back')}")
    check(swj("swap-cut-update").get("failed") == 2 and sw.get("swap-cut-kept") == "yes 0 yes",
          f"adlist #91: ... and an update that then fails keeps it, nothing left aside {swj('swap-cut-update')} {sw.get('swap-cut-kept')}")
    own = {"swap-b.txt": ("a=0", "b=1"), "swap-a.txt": ("a=1", "b=0")}
    before = secmap(sw.get("shift-secs-before", ""))
    sst = swj("shift-status").get("lists") or {}
    check(swj("shift-update0").get("ok") is True and before != own and len(before) == 2
          and sw.get("shift-ensure", "") == "" and secmap(sw.get("shift-secs", "")) == own and sw.get("shift-kept") == "yes 0"
          and sorted((e.get("url", "").rsplit("/", 1)[-1], e.get("rules")) for e in sst.values()) == [("swap-a.txt", 2), ("swap-b.txt", 2)],
          f"adlist: a section added before the lists renames them all; at start each list's data follows it, nothing fetched "
          f"{sw.get('shift-secs-before')} -> {sw.get('shift-secs')} {sw.get('shift-ensure')!r} {sst}")
    su = swj("shift-update")
    check(su.get("failed") == 2 and su.get("total") == 4 and secmap(sw.get("shift-secs2", "")) == own
          and sw.get("shift-kept2") == "yes progress=gone",
          f"adlist: ... and an update whose downloads fail finds each list with its own data; no progress file left {su} {sw.get('shift-secs2')} {sw.get('shift-kept2')}")
    check(sw.get("cron-line", "").startswith("0 5 * * * ucode ") and sw.get("cron-line", "").endswith("# xray-mosdns-adlist"),
          f"adlist: the daily update runs on the hour {sw.get('cron-line')}")
else:
    print("adlist swap: no output from tests/runtime.sh, skipped")
    check(not strict, "adlist swap: no output from tests/runtime.sh")

# ------------------------------------------------------------------ helper scripts (tests/scripts.sh)
sd = f"{out}/scripts"
if not os.path.isdir(sd):
    print("scripts: no output from tests/scripts.sh, skipped")
    check(not strict, "scripts: no output from tests/scripts.sh")
else:
    def res(name):
        return json.load(open(f"{sd}/{name}.json"))

    port = int(open(f"{sd}/port").read())
    r = res("lat-target")
    check(r.get("ok") is True and r.get("via") == "tcp" and r.get("target") == f"127.0.0.1:{port}"
          and isinstance(r.get("ms"), (int, float)) and 0 <= r["ms"] < 2000, f"latency --target: {r}")
    r = res("lat-node")
    check(r.get("ok") is True and r.get("section") == "n1" and r.get("type") == "vless" and r.get("via") == "tcp"
          and r.get("target") == f"127.0.0.1:{port}", f"latency of a node: {r}")
    check(res("lat-missing") == {"ok": False, "section": "nosuch", "error": "node not found"}, "latency: unknown node")
    check(res("lat-bad") == {"ok": False, "error": "bad target"}, "latency: target without a port")

    t = res("traffic")
    check(t == {"nodes": [{"tag": "b.node", "uplink": 5000, "downlink": 0, "total": 5000},
                          {"tag": "a.node", "uplink": 100, "downlink": 900, "total": 1000}], "error": None},
          f"traffic: node outbounds only, string and missing values, busiest first: {t}")
    check(res("traffic-bad") == {"nodes": [], "error": "bad_api_output"}, "traffic: output that is not JSON")
    check(res("traffic-down") == {"nodes": [], "error": "xray_not_running"}, "traffic: API unreachable, no xray process")

    u = res("update-versions")
    check(u.get("ok") is True and u.get("xray") == "not installed" and u.get("mosdns") == "not installed" and isinstance(u.get("app"), str), f"update.sh versions: {u}")
    check(res("update-versions-apk").get("app") == "9.9.9-r1" and res("update-versions-opkg").get("app") == "8.8.8-r2",
          f"update.sh versions: this package's version from apk, or from opkg: {res('update-versions-apk').get('app')} {res('update-versions-opkg').get('app')}")
    check(res("cron-weekly").get("message") == "geo 定时更新已启用（每周一 6:00）"
          and open(f"{sd}/cron-weekly.txt").read().splitlines() == ["0 6 * * 1 /usr/libexec/xray-mosdns/update.sh geo-auto >>/tmp/xray-mosdns-geo-update.log 2>&1 # xray-mosdns-geo-auto"]
          and res("cron-weekly-status") == {"ok": True, "enabled": 1, "hour": "6", "day": "1", "marker": ""},
          f"geo schedule: weekly on the configured day and hour: {res('cron-weekly')} {res('cron-weekly-status')}")
    check(res("cron-junk").get("message") == "geo 定时更新已启用（每天 4:00）"
          and open(f"{sd}/cron-junk.txt").read().splitlines() == ["0 4 * * * /usr/libexec/xray-mosdns/update.sh geo-auto >>/tmp/xray-mosdns-geo-update.log 2>&1 # xray-mosdns-geo-auto"],
          f"geo schedule: junk day/hour mean every day at 4, the line replaced: {open(f'{sd}/cron-junk.txt').read()!r}")
    check(res("jstr") == 'quote " backslash \\ tab \t newline \n end', "update.sh jstr: escapes quotes, backslashes and control characters")

    # stats.uc (the DNS counts)
    s2 = res("stats-s2")
    check(s2.get("today") == {"queries": 15, "blocked": 3} and s2.get("since") == "2025-11-21" and s2.get("running") is True,
          f"stats: samples add up the counters' growth for today {s2}")
    s3 = res("stats-s3")
    check(s3.get("today") == {"queries": 37, "blocked": 8}, f"stats: a new mosdns start counts all it has, even more than before {s3}")
    check(res("stats-big").get("today") == {"queries": 37 + 1234567 - 22, "blocked": 10}, f"stats: counters in exponent notation {res('stats-big')}")
    check(json.load(open(f"{sd}/stats/disk.json")).get("days", {}).get("2025-11-21") == [37 + 1234570 - 22, 11],
          "stats: flush keeps the counts on flash (after a last sample)")
    check(res("stats-reboot").get("today") == {"queries": 37 + 1234570 - 22, "blocked": 11},
          f"stats: after a reboot the flash copy carries on {res('stats-reboot')}")
    d2 = res("stats-day2")
    check(d2.get("today") == {"queries": 10, "blocked": 1} and [x["day"] for x in d2.get("days", [])] == ["2025-11-22", "2025-11-21"]
          and d2.get("total", {}).get("queries") == 37 + 1234570 - 22 + 10,
          f"stats: a new day gets its own count, newest first, the total over the days {d2}")
    d31 = res("stats-day31")
    check([x["day"] for x in d31.get("days", [])] == ["2025-12-21", "2025-11-22"] and d31.get("total", {}).get("queries") == 11
          and d31.get("since") == "2025-11-22", f"stats: 30 days kept, older ones dropped, counted since the first one kept {d31}")
    check("running" not in json.load(open(f"{sd}/stats/disk.json")), "stats: only the counts are kept on flash")
    dn = res("stats-down")
    check(dn.get("running") is False and dn.get("total") == d31.get("total"), f"stats: no counters to read: the counts as they were {dn}")

    def txt(name):
        return open(f"{sd}/{name}.txt").read().splitlines()

    # xray-rules.sh: the routing rules into a running Xray
    hot = {}
    hcalls = []
    for line in open(f"{sd}/hot-rules.txt").read().splitlines():
        k, _, v = line.partition(" ")
        if k == "apply-call":
            hcalls.append(v)
        else:
            hot[k] = v
    ta, tb, tc = hot.get("tags-a", "").split(), hot.get("tags-b", "").split(), hot.get("tags-c", "").split()
    check(hot.get("key-a") == hot.get("key-b") and hot.get("key-a") != hot.get("key-c") and len(hot.get("key-a", "")) == 8,
          f"hot rules: a rule more leaves what Xray is restarted for as it was, another node port does not {hot.get('key-a')} {hot.get('key-b')} {hot.get('key-c')}")
    check(len(tb) == len(ta) + 1 and not set(ta) & set(tb) and ta == tc and len(set(tb)) == len(tb),
          f"hot rules: another set of rules has no tag of the first, the same rules have the same tags {ta[:2]} {tb[:2]} {tc[:2]}")
    check(hot.get("apply") == "rc=0 out=" and len(hcalls) == 2
          and hcalls[0].startswith("/geo api adrules --server=127.0.0.1:10099 -t 30 -append ") and hcalls[0].endswith("/hot/b/xray-rules.json")
          and hcalls[1] == " api rmrules --server=127.0.0.1:10099 -t 30 " + " ".join(ta),
          f"hot rules: the new set is added behind the old one, then the old one's tags are removed {hot.get('apply')} {hcalls}")
    check(hot.get("same") == "rc=0 calls=0", f"hot rules: the same rules, nothing to do {hot.get('same')}")
    check(hot.get("addfail", "").startswith("rc=1 calls=1 ") and hot.get("rmfail", "").startswith("rc=1 calls=2 ")
          and hot.get("untagged", "").startswith("rc=1 calls=0 "),
          f"hot rules: a failure says so (the caller restarts Xray), nothing removed when adding failed {hot.get('addfail')} | {hot.get('rmfail')} | {hot.get('untagged')}")

    # logs.uc (the plugin's logs kept for global.log_days)
    check(txt("logs-a") == ['2025-11-20T08:00:00+0800 {"ok":true,"message":"geo already up to date"}', "\tcontinuation of the kept one",
                            '{"level":"info","time":"2025-11-21T09:00:00.000Z","msg":"query summary","qname":"new.example."}']
          and txt("logs-b") == ["no time here", "nor here"] and res("logs-prune").get("days") == 30,
          f"logs: older than 30 days dropped (console, JSON, with an offset, continuation lines with theirs); no times, not cut {txt('logs-a')} {txt('logs-b')}")
    check(txt("logs-c") == ["9"], f"logs: kept under the size limit, the newest lines {txt('logs-c')}")

    def utc(ts):
        return time.strftime("%Y-%m-%d %H:%M:%S", time.gmtime(ts))

    sl = open(f"{sd}/syslog.txt").read().splitlines()
    check(txt("log-xray") == sl[0:2], f"log xray: procd's notes on the instance and the configured binary's output only: {txt('log-xray')}")
    lm = txt("log-mosdns")
    check(lm[0] == "== 系统日志 ==" and lm[1:3] == sl[3:5] and lm[3].startswith("== ") and lm[3].endswith("/scripts/mosdns-x.log =="),
          f"log mosdns: its system log lines first, then the file: {lm[:4]}")
    check(lm[4:] == ["2026-11-21T13:00:00.000+0800\tINFO\tserver started",
                     f"{utc(1763730000)} INFO cache: cache hit rate rate=0.5",
                     f"{utc(1763730002)} WARN: upstream error error=timeout",
                     f"{utc(1763730003)} WARN forward_remote: upstream err addr=tcp://8.8.8.8:53"],
          f"log mosdns: plain lines as they are, JSON lines readable (seconds or mosdns-x's ISO time), query lines left out: {lm[4:]}")
    check(txt("log-app") == sl[5:10], f"log app: the service's tags, its helpers by name, procd's notes on them: {txt('log-app')}")
    check(txt("log-all") == sl[0:2] + sl[3:10], "log: without a source, all three in order, nothing else")
    check(txt("log-legacy") == txt("log-all"), "log: `log.sh <lines>` from older pages still works")
    check(txt("log-tail") == sl[8:10], "log: the line count keeps the newest lines")

    q = res("querylog")
    qe = q.get("entries") or []
    check(q.get("ok") is True and q.get("total") == 3 and [e["name"] for e in qe] == ["slow.example.org", "ads.example.net", "example.com"],
          f"querylog: the preset summary lines, newest first, other lines and nameless ones skipped: {q}")
    check(len(qe) == 3 and qe[0] == {"ts": 1763730005, "client": "192.168.1.2", "name": "slow.example.org", "type": "HTTPS",
                                     "rcode": "NO RESPONSE", "ms": 5000, "error": "context deadline exceeded"}
          and qe[1]["type"] == "AAAA" and qe[1]["rcode"] == "NXDOMAIN" and qe[1]["error"] is None
          and qe[2]["type"] == "A" and qe[2]["rcode"] == "NOERROR",
          f"querylog: types and answer codes readable, no handling kind: {qe}")
    check(len(qe) == 3 and abs(qe[1]["ts"] - 1763730003.25) < 1e-6 and abs(qe[1]["ms"] - 0.5) < 1e-9
          and qe[2]["ts"] == 1763730001 and abs(qe[2]["ms"] - 2.1) < 1e-9,
          f"querylog: mosdns-x's ISO times (UTC or with an offset) and Go durations, as seconds and milliseconds: {qe}")
    q = res("querylog-filter")
    check(q.get("total") == 1 and [e["name"] for e in q.get("entries") or []] == ["ads.example.net"], f"querylog: filter by client address: {q}")
    q = res("querylog-limit")
    check(q.get("total") == 3 and [e["name"] for e in q.get("entries") or []] == ["slow.example.org"], f"querylog: the limit caps the entries, not the count: {q}")

# ------------------------------------------------------------------ runtime.env (the values in effect)
def runtime_env(case):
    env = {}
    for line in open(f"{out}/{case}/runtime.env").read().splitlines():
        if line and not line.startswith("#"):
            k, v = line.split("=", 1)
            env[k] = v.strip("'")
    return env

rt = runtime_env("chnroute")
check(rt == {"XRAY_BIN": "/usr/bin/xray", "MOSDNS_BIN": "/usr/bin/mosdns", "GEO_DIR": "/usr/share/v2ray",
             "TPROXY_PORT": "12345", "API_PORT": "10085", "SOCKS_PORT": "1070", "DNS_PORT": "5335", "STATS_PORT": "5336", "LOG_DAYS": "30", "DNS_REDIRECT": "1",
             "DNS_WATCH": "manage", "FWMARK": "0x1", "ROUTE_TABLE": "100", "IPV6": "0", "KERNEL_SPLIT": "1",
             "DEFAULT_ACTION": "proxy", "PROBE_INTERVAL": "1m", "PROBE_BACKUP": "0", "MAIN_TARGET": "hk1", "ECS_IFACES": ""},
      f"runtime.env (chnroute): {rt}")
rt = runtime_env("groups")
check(rt.get("DNS_WATCH") == "log-only" and rt.get("MAIN_TARGET") == "hk" and rt.get("PROBE_INTERVAL") == "30s",
      f"runtime.env (groups): static redirect, a group as main target, the group probe interval: {rt}")
rt = runtime_env("gfw")
check(rt.get("IPV6") == "1" and rt.get("DEFAULT_ACTION") == "direct", f"runtime.env (gfw): IPv6 on, direct by default: {rt}")
rt = runtime_env("balance")
check(rt.get("KERNEL_SPLIT") == "0" and rt.get("DNS_REDIRECT") == "0", f"runtime.env (balance): split in Xray, no DNS redirect: {rt}")

# ------------------------------------------------------------------ fw.sh gate, update.sh, postrm (tests/runtime.sh)
rd = f"{out}/runtime"
if not os.path.isdir(rd):
    print("runtime: no output from tests/runtime.sh, skipped")
    check(not strict, "runtime: no output from tests/runtime.sh")
else:
    G = 'return comment "xray-mosdns: Xray not listening"'
    REDIR = "udp dport 53 redirect to :5335"
    st = dict(l.split("=", 1) for l in open(f"{rd}/status.txt").read().split())

    def state(name):
        s, cur = {}, None
        for line in open(f"{rd}/{name}.txt").read().splitlines():
            if line.startswith("[gated] "):
                s["gated"] = line[8:]
            elif line.startswith("[error]"):
                s["error"] = line[7:].strip()
            elif line.startswith("["):
                cur = line.strip("[]")
                s[cur] = []
            else:
                s[cur].append(line)
        return s

    a = state("apply")
    check(st["apply"] == "0" and a["prerouting"] == ['iifname != "br-lan" return', "meta l4proto tcp goto do_tproxy"]
          and a["dns_redirect"] == [REDIR] and a["gated"] == "no", f"gate: plain apply {a}")
    g = state("gate")
    check(st["gate"] == "0" and g["prerouting"][0] == G and g["output"][0] == G, f"gate: first in prerouting and output {g}")
    check(g["dns_redirect"] == [] and g["gated"] == "yes" and "TProxy 端口 12345" in g["error"],
          f"gate: LAN DNS handed back to dnsmasq, the overview says why {g}")
    g2 = state("gate-again")
    check(st["gate-again"] == "0" and g2["prerouting"].count(G) == 1 and g2["output"].count(G) == 1, "gate: a second gate adds nothing")
    gm, go = state("gate-msg"), state("gate-other")
    check(st["gate-msg"] == "0" and "TProxy 端口 12345" in gm["error"] and gm["prerouting"].count(G) == 1,
          f"gate: gating again puts a cleared message back {gm}")
    check(st["gate-other"] == "0" and go["error"] == "another problem", f"gate: ... without covering another message {go}")
    ag = state("apply-gated")
    check(st["apply-gated"] == "0" and ag["prerouting"][0] == G and ag["prerouting"].count(G) == 1 and len(ag["prerouting"]) == 3
          and ag["output"][0] == G and ag["dns_redirect"] == [] and ag["gated"] == "yes",
          f"gate: a reload while gated stays gated, DNS stays with dnsmasq {ag}")
    u = state("ungate")
    check(st["ungate"] == "0" and G not in u["prerouting"] and G not in u["output"] and u["dns_redirect"] == [REDIR]
          and u["gated"] == "no" and u["error"] == "", f"ungate: proxy back, a static DNS redirect back, message gone {u}")
    r = state("gate-refused")
    check(st["gate-refused"] == "1" and G not in r["prerouting"] and G not in r["output"] and r["dns_redirect"] == [REDIR]
          and r["gated"] == "no" and r["error"] == "", f"gate: a refused transaction changes nothing and reports no gate {r}")
    check(st["half"] == "1", "gated: half a gate (prerouting only) does not count")
    h = state("half-gate")
    check(st["half-gate"] == "0" and h["prerouting"].count(G) == 1 and h["output"].count(G) == 1 and h["gated"] == "yes",
          f"gate: completes half a gate without doubling it {h}")
    gd = state("gate-dns")
    check(st["gate-dns"] == "0" and gd["dns_redirect"] == [] and gd["prerouting"].count(G) == 1 and gd["output"].count(G) == 1
          and gd["gated"] == "yes", f"gate: a gate in place with the DNS redirect back takes it off, no second gate rule {gd}")
    m = state("ungate-managed")
    check(st["ungate-managed"] == "0" and G not in m["prerouting"] and m["dns_redirect"] == [] and m["gated"] == "no",
          f"ungate: a watched DNS redirect is left to the watchdog {m}")

    fs_ = open(f"{rd}/fw-status.txt").read().splitlines()
    check(fs_ == ["nft: loaded", "proxy: in the path", "set bypass4: 2", "set ipg4_0: 1", "set proxy4_dns: 0",
                  "rule4: present", "route4: present"], f"fw.sh status: the sets of ours there are, with their sizes {fs_}")

    def kv(name):
        # "key value" lines; "out <file> <content>" is keyed by "out <file>"
        d = {}
        for line in open(f"{rd}/{name}.txt").read().splitlines():
            k, _, v = line.partition(" ")
            if k == "out":
                f, _, v = v.partition(" ")
                k = f"out {f}"
            d[k] = v
        return d

    sw = kv("switch-ok")
    check(sw == {"rc": "0", "out a.json": "new-a", "out b.yaml": "new-b", "out c.rules": "new-c", "out .h.env": "new-h",
                 "out .fw-state": "state", "new": "", "prev": "no"},
          f"switch.sh: every new file in place, files only the old set has stay, nothing left over {sw}")
    sf = kv("switch-fail")
    check(sf == {"rc": "1", "out a.json": "old-a", "out b.yaml": "old-b", "out c.rules": "-", "out .h.env": "-",
                 "out .fw-state": "state", "new": ".h.env a.json b.yaml c.rules ", "prev": "no"},
          f"switch.sh: a file that cannot be moved puts the old set back whole, the new one stays to look at {sf}")
    check("b.yaml" in open(f"{rd}/switch-fail.err").read(), "switch.sh: says which file could not be moved")
    sb = kv("switch-broken")
    check(sb.get("rc") == "3" and sb.get("prev") == "yes" and sb.get("prev-files") == "a.json b.yaml "
          and sb.get("out a.json") == "-", f"switch.sh: when the old set cannot be put back whole either, it says so "
          f"(exit 3) and keeps what is left of it in .prev {sb}")
    sbe = open(f"{rd}/switch-broken.err").read().splitlines()
    check(len(sbe) == 2 and "b.yaml" in sbe[0] and ".prev" in sbe[1], f"switch.sh: what failed first, then that the old set is not whole {sbe}")

    gl = json.load(open(f"{rd}/groups-list.json"))
    check(gl.get("ok") and gl["groups"][0]["running"] and gl["groups"][0]["current"] == "b" and gl.get("probe_backup") is True,
          f"groups.uc list: the binary, API port and backup probe in effect, not UCI's {gl}")
    ga = open(f"{rd}/groups-watch-api.log").read().splitlines()
    check(len(ga) >= 4 and ga[0] == "api bi --server=127.0.0.1:20001 hk.group"
          and "api bo --server=127.0.0.1:20001 -b hk.group b.node" in ga
          and "api bi --server=127.0.0.1:20002 hk.group" in ga and "api bo --server=127.0.0.1:20002 -b hk.group b.node" in ga,
          f"groups.uc watch: holds the ordered group, takes a changed port on its next round {ga}")
    gal = open(f"{rd}/groups-alive-api.log").read().splitlines()
    check("api bi --server=127.0.0.1:20002 hk.alive" in gal and "api bo --server=127.0.0.1:20002 -b hk.group a.node" in gal,
          f"groups.uc watch: every member failed a probe lately, one is still alive: held on that one, not dropped to the fallback {gal}")
    gs = [l for l in open(f"{rd}/groups-settle-api.log").read().splitlines() if " bo " in l]
    check(gs == ["api bo --server=127.0.0.1:20002 -b hk.group b.node", "api bo --server=127.0.0.1:20002 -b hk.group a.node"],
          f"groups.uc watch: after a start an ordered group follows list order for a few probe rounds, then is sticky again {gs}")
    sj = json.load(open(f"{rd}/status.json"))
    check(sj.get("effective") == {"default_action": "direct", "kernel_split": 0, "dns_redirect": 0, "dns_port": 5353},
          f"status.sh: the default action, split, DNS redirect and port in effect, not UCI's {sj}")

    ad = {}
    for line in open(f"{rd}/adlist.txt").read().splitlines():
        k, _, v = line.partition(" ")
        ad[k] = v
    def adj(k):
        try:
            return json.loads(ad.get(k, ""))
        except ValueError:
            return {"unparsed": ad.get(k)}
    check(adj("update1").get("ok") is True and adj("update1").get("total") == 2, f"adlist update: {ad.get('update1')}")
    check(ad.get("top1") == "allow.txt block.txt gone1.allow gone1.block l1.allow l1.block mine.allow mine.block state.json xray-mosdns ",
          f"adlist update: writes into xray-mosdns/ and moves nothing at the top, where a configuration still running reads its lists {ad.get('top1')}")
    check(ad.get("sub1") == "allow.txt block.txt l1.allow l1.block state.json ", f"adlist update: the subdirectory {ad.get('sub1')}")
    check(adj("migrate1").get("ok") is True and ad.get("top1m") == "mine.allow mine.block xray-mosdns "
          and ad.get("sub1m") == "allow.txt block.txt gone1.allow gone1.block l1.allow l1.block state.json "
          and adj("migrate1b").get("ok") is True,
          f"adlist migrate: what 0.9.7 kept at the top goes (moved, or dropped where the subdirectory has newer), "
          f"another program's files stay, a second run does nothing {ad.get('top1m')} | {ad.get('sub1m')}")
    check(ad.get("sub2u") == "allow.txt block.txt l1.allow l1.block state.json ",
          f"adlist update: a list no longer subscribed goes from the subdirectory {ad.get('sub2u')}")
    check(adj("update2").get("ok") is True and ad.get("theirs2") == 'yes theirs-allow {"theirs":1}' and ad.get("new2") == "1",
          f"adlist: another program's block.txt / allow.txt / state.json at the top are neither moved nor written {ad}")
    check(ad.get("theirs6") == 'yes { "ok": true, "failed": [ ] } {"theirs":1}',
          f"adlist migrate: leaves another program's files at the top alone {ad.get('theirs6')}")
    check(adj("migrate2").get("failed") == ["l1.allow"] and ad.get("migrate2-err") == "l1.allow" and ad.get("top2") == "l1.allow state.json xray-mosdns "
          and ad.get("sub2") == "block.txt l1.allow l1.block ",
          f"adlist migrate: a file that cannot be moved keeps the state at the top, to be tried again {ad.get('top2')} | {ad.get('sub2')}")
    check(adj("migrate3").get("ok") is True and ad.get("top3") == "xray-mosdns "
          and ad.get("sub3") == "block.txt l1.allow l1.block state.json ",
          f"adlist migrate: the next run moves the rest, state last {ad.get('top3')} | {ad.get('sub3')}")
    u3 = adj("update3")
    check(u3.get("ok") is False and "block.txt" in (u3.get("error") or "") and ad.get("kept3") == "yes",
          f"adlist update: merged lists that cannot be written are an error, the ones in use stay {ad.get('update3')}")
    check(adj("status3").get("error") == u3.get("error") and adj("status3").get("total") == 3,
          f"adlist status: shows why {ad.get('status3')}")
    u4 = adj("update4")
    check(u4.get("ok") is False and "allow.txt" in (u4.get("error") or "") and ad.get("kept4") == "yes 0",
          f"adlist update: an exception list that cannot be replaced leaves the block list as it was too {ad.get('update4')} {ad.get('kept4')}")
    u5 = adj("update5")
    check(u5.get("ok") is False and ".allow.prev is in the way" in (u5.get("error") or "") and ad.get("kept5") == "yes 0",
          f"adlist update: a directory where the copy of a list in use goes stops the update, nothing is replaced, "
          f"no link is put inside it {ad.get('update5')} {ad.get('kept5')}")
    check(adj("update6").get("ok") is True and ad.get("new6") == "1 allow" and adj("status6").get("error") is None,
          f"adlist update: the next good update replaces both and clears the error {ad.get('new6')}")
    check(adj("update7").get("ok") is True and ad.get("new7") == "1 0",
          f"adlist update: without hard links (vfat, exfat) the lists in use are copied, and replaced {ad.get('update7')} {ad.get('new7')}")
    check(adj("update8").get("ok") is True and ad.get("inplace8") == "same 1",
          f"adlist update: the lists mosdns reads are rewritten in place (same file: mosdns watches the one it opened) "
          f"{ad.get('update8')} {ad.get('inplace8')}")
    u9 = adj("update9")
    check(u9.get("ok") is False and "cannot rewrite" in (u9.get("error") or "") and "allow.txt" in (u9.get("error") or "")
          and ad.get("kept9") == "yes yes 0",
          f"adlist update: an exception list cut short while rewritten puts both lists back as they were {ad.get('update9')} {ad.get('kept9')}")
    check(ad.get("ensure1") == "" and ad.get("ensure2") == "" and ad.get("ensure2-made") == "yes",
          f"adlist ensure: nothing missing, nothing done; a merged list missing is made from the lists there are, "
          f"no download {ad.get('ensure1')!r} {ad.get('ensure2')!r} {ad.get('ensure2-made')}")
    check(ad.get("ensure2b") == "" and ad.get("ensure2b-made") == "yes",
          f"adlist ensure: an empty merged list while the lists have data is made again {ad.get('ensure2b-made')}")
    check(adj("ensure3") == {"ok": True, "running": True} and ad.get("ensure3-kept") == "yes",
          f"adlist ensure: a list with no data yet is fetched, and the list in use keeps its rules meanwhile "
          f"{ad.get('ensure3')} {ad.get('ensure3-kept')}")
    check("cannot make the merged lists" in (ad.get("ensure4") or "") and "allow.txt: not a file" in (ad.get("ensure4") or ""),
          f"adlist ensure: a merged list that cannot be made is said on stderr {ad.get('ensure4')!r}")
    check(ad.get("ensure5") == "" and ad.get("ensure5-made") == "yes",
          f"adlist ensure: a merged list cut short (not the lists' size) is made again {ad.get('ensure5-made')}")
    check("cannot make the merged lists" in (ad.get("ensure6") or "") and "cannot rewrite" in (ad.get("ensure6") or ""),
          f"adlist ensure: a merge that fails is said on stderr, not taken for done {ad.get('ensure6')!r}")
    check(adj("ensure3b") == {"ok": True, "running": True} and (ad.get("ensure3b-kept") or "").startswith("yes ")
          and not (ad.get("ensure3b-kept") or "").endswith(" 0"),
          f"adlist ensure: a list's exceptions missing: the exceptions in use stay, the list is fetched "
          f"{ad.get('ensure3b')} {ad.get('ensure3b-kept')}")
    check(ad.get("catalog-tmp-left") == "0", f"adlist: a failed catalogue download leaves no file in /tmp {ad.get('catalog-tmp-left')}")
    cn = adj("catalog-newer")
    check(cn.get("ok") is True and cn.get("filters") == 2,
          f"adlist catalog-sync: a catalogue an update fetched while it waited is newer and is the one used {ad.get('catalog-newer')}")
    cs_ = adj("catalog-slow")
    check(cs_.get("ok") is True and cs_.get("filters") == 2 and ad.get("catalog-slow-cache") == "2",
          f"adlist catalog-sync: a slow download does not put its older catalogue over the newer cache, nor use it "
          f"{ad.get('catalog-slow')} cache {ad.get('catalog-slow-cache')}")
    check(ad.get("ensure8") == "" and ad.get("ensure8-made") == "yes",
          f"adlist ensure: a short holder of the lock (a catalogue sync, a move) is waited for, then the list made "
          f"{ad.get('ensure8')!r} {ad.get('ensure8-made')}")
    check("cannot open /var/run/xray-mosdns-adlist.lock" in (ad.get("ensure7") or ""),
          f"adlist ensure: a lock that cannot be taken at all is said, not taken for an update running {ad.get('ensure7')!r}")
    lk, ul = ad.get("locked", ""), ad.get("unlocked", "")
    check(lk.startswith("2 ") and '"postponed": true' in lk and ad.get("locked-top") == "block.txt state.json xray-mosdns ",
          f"adlist migrate: while an update holds the lock nothing moves, it is left to the next start {lk} | {ad.get('locked-top')}")
    check("an update is already running" in ad.get("locked-update", "") and ad.get("locked-status") == '"running": true',
          f"adlist: a second update refuses, and the status says one runs {ad.get('locked-update')} {ad.get('locked-status')}")
    check(ad.get("locked-ensure") == "" and ad.get("locked-standins") == "allow.txt block.txt  block 0 allow kept",
          f"adlist ensure: with an update running, an empty stand-in for the missing list only {ad.get('locked-standins')}")
    lc = adj("locked-catalog")
    check(lc.get("ok") is False and lc.get("busy") is True and ad.get("locked-catalog-state") == "yes",
          f"adlist catalog-sync: while an update runs it does nothing and says so {ad.get('locked-catalog')}")
    check(adj("unlocked-catalog").get("ok") is True and adj("unlocked-catalog").get("filters") == 1,
          f"adlist catalog-sync: with the lock free it goes on {ad.get('unlocked-catalog')}")
    check(ul.startswith("0 ") and ad.get("unlocked-top") == "xray-mosdns  lock kept" and ad.get("unlocked-status") == '"running": false',
          f"adlist migrate: once the lock is free the move happens; the lock file stays (a new one would be a second lock) "
          f"{ul} | {ad.get('unlocked-top')} {ad.get('unlocked-status')}")

    up = {}
    for line in open(f"{rd}/update.txt").read().splitlines():
        k, _, v = line.partition(" ")
        up[k] = v
    check('"ok":true' in up.get("geo-good", ""), f"update geo: good checksums install {up.get('geo-good')}")
    check("does not match its published checksum" in up.get("geo-bad", "") and up.get("geoip-kept") == "yes",
          "update geo: a wrong checksum installs nothing")
    check("does not match its published checksum" in up.get("xray-bad", "") and up.get("xray-after-bad") == "Xray 1.0.0 (old)",
          "update xray: a wrong .dgst installs nothing")
    check('"ok":true' in up.get("xray-good", "") and up.get("xray-after-good") == "Xray 99.0.0 (new)"
          and up.get("old-still-running") == "yes" and up.get("leftovers") == "0",
          f"update xray: replaces a running binary by rename, nothing left over {up}")
    check("another update is running" in up.get("locked", ""), "update: one at a time")
    check(up.get("backups-geosite") == "3" and up.get("backups-xray") == "3", "update: three backups of each file kept")
    check(up.get("mode-backups") == "drwx------" and up.get("mode-geo") == "-rw-------", "update: backups and downloads are root's")

    ph = open(f"{rd}/postrm-holder.txt").read().strip()
    if ph == "holder skipped (no /proc)":
        print("postrm with a blocklist update running: skipped (no /proc here)")
    else:
        check(ph == "holder stopped lock gone",
              f"postrm: a blocklist update still running (holding the lock), and what it started, are gone before "
              f"its files go, made to stop when they do not when asked {ph}")
    pr = open(f"{rd}/postrm.txt").read()
    upgrade, rest = pr.split("[removal]\n")
    removal, theirs = rest.split("[removal-theirs]\n")
    check("cron-ours 2 cron-other 1" in upgrade and "etc-dir present backups present table present" in upgrade
          and "shared .block.tmp .gone3.raw .l1.raw ANON.allow ANON.block allow.txt block.txt gone3.block l1.allow l1.block mine.allow mine.block mine.txt state.json xray-mosdns "
          in upgrade and "sub .gone2.raw allow.txt block.txt gone2.block l1.block state.json " in upgrade,
          f"postrm: an upgrade leaves everything {upgrade}")
    check("cron-ours 0 cron-other 1" in removal and "etc-dir gone backups gone table gone" in removal
          and removal.strip().endswith("shared mine.allow mine.block mine.txt"),
          f"postrm: removal takes our cron lines, data, backups, our subdirectory whole (a list unsubscribed since the "
          f"last update too) and what 0.9.7 left at the top (named or anonymous subscriptions, and a list only its state names); another program's files stay {removal}")
    check(theirs.strip().endswith("shared allow.txt block.txt l1.block state.json"),
          f"postrm: block.txt / allow.txt / state.json at the top that are not ours stay {theirs}")

if failed:
    print("\n".join("FAIL: " + f for f in failed))
    sys.exit(1)
print("all checks passed")
