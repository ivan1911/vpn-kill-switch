"""Darwin netstat/route fixture. All mutations stay inside KS_TEST."""
import ipaddress
import json
import os
import sys
from pathlib import Path

root = Path(os.environ["KS_TEST"])
store = root / "route-table"
routes = json.loads(store.read_text()) if store.exists() else {}
uplink = (root / "uplink").read_text() if (root / "uplink").exists() else "en0"
if sys.argv[1] == "netstat":
    print("default link#28 UCSg utun4")
    if not (root / "offline").exists():
        print("default 192.168.1.1 UGScIg", uplink)
    print("192.168.1 link#12 UCS", uplink)
    print("203.0.113/24 link#28 UCS utun4")
    for net, (dev, gw) in routes.items():
        print(net, gw, "UGS1", dev)
    sys.exit(0)

operation, kind, target = sys.argv[3:6]
net = ipaddress.ip_network(target)
key = str(net)
if operation == "get" and key in routes:
    dev, gw = routes[key]
    print("destination:", net.network_address)
    print("mask:", net.netmask)
    print("gateway:", gw)
    print("interface:", dev)
    print("flags:", "<UP,HOST,PROTO1>" if kind == "-host" else "<UP,PROTO1>")
elif operation == "add":
    gw, ifp, dev, tag = sys.argv[6:]
    assert (ifp, tag) == ("-ifp", "-proto1")
    assert dev.endswith(":")
    dev = dev[:-1]
    if key in routes or (root / "route-conflict").exists():
        sys.exit(1)
    assert key not in {"192.168.1.0/24", "203.0.113.0/24", "0.0.0.0/0"}
    routes[key] = dev, gw
    store.write_text(json.dumps(routes))
elif operation == "delete" and key in routes:
    assert sys.argv[6] == routes[key][1]
    del routes[key]
    store.write_text(json.dumps(routes))
else:
    sys.exit(1)
