#!/usr/bin/env python3
"""Write the [nodeN] sections of control/ssr.cfg from the resolved manifest.

    python3 -m ops.manifest resolve prototype/testbed/manifest.yaml | prototype/testbed/render-cfg.py [ssr.cfg]

The [cluster] section - the round, the clock gate, the grandmaster - is SSR's
own and is kept as it stands; only the node sections are replaced, so the
physical facts (hostname, interface names, namespaces, the control address)
come from the testbed's topology and are never copied by hand.
"""
import re
import sys
from pathlib import Path

import yaml

cfg_path = Path(sys.argv[1] if len(sys.argv) > 1 else Path(__file__).resolve().parents[1] / "control" / "ssr.cfg")
resolved = yaml.safe_load(sys.stdin)
project = resolved["project"]
members = {(m["endpoint"], m["iface"]): m for d in resolved["domains"] for m in d["members"]}

sections = []
for node_id, endpoint in enumerate(project["nodes"]):
    data = members[(endpoint, project["data_iface"])]
    ctl = members[(endpoint, project["ctl_iface"])]
    ip = ctl["ip"].split("/")[0]
    sections.append(
        f"[node{node_id}]\n"
        f"host = {ctl['hostname']:<24}# {endpoint}, rendered from the testbed topology\n"
        f"ctl = {ip}:{project['grpc_port']}\n"
        f"ssr_iface = {data['ifname']:<19}# {data['switch_port']} on the switch\n"
        f"ssr_netns = {data['netns']}\n"
        f"ctl_iface = {ctl['ifname']:<19}# {ctl['switch_port']}\n"
        f"ctl_netns = {ctl['netns']}\n"
    )

text = cfg_path.read_text()
head = re.split(r"(?m)^\[node\d+\]", text, maxsplit=1)[0].rstrip() + "\n\n"
cfg_path.write_text(head + "\n".join(sections))
print(f"{cfg_path}: {len(sections)} node sections rendered")
