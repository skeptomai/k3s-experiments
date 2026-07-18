#!/usr/bin/env python3
"""Control ipc cluster power outlets on the Kasa HS300 at 192.168.88.16.

Usage:
  kasa-outlet.py status
  kasa-outlet.py <on|off> <node|all>

Examples:
  kasa-outlet.py status
  kasa-outlet.py off ipc5
  kasa-outlet.py on all
  kasa-outlet.py off all
"""

import asyncio
import sys
from kasa.iot import IotStrip

STRIP_HOST = "192.168.88.16"

NODE_ALIAS = {
    "ipc4": "Node 4",
    "ipc5": "Node 5",
    "ipc6": "Node 6",
    "ipc7": "Node 7",
    "ipc8": "Node 8",
    "ipc9": "Node 9",
}


async def main():
    args = sys.argv[1:]
    if not args or args[0] in ("-h", "--help"):
        print(__doc__)
        sys.exit(0)

    strip = IotStrip(STRIP_HOST)
    await strip.update()

    if args[0] == "status":
        print(f"{'Node':<8} {'Outlet':<10} {'State'}")
        print("-" * 30)
        for node, alias in NODE_ALIAS.items():
            child = next((c for c in strip.children if c.alias == alias), None)
            if child:
                state = "ON " if child.is_on else "off"
                print(f"{node:<8} {alias:<10} {state}")
        return

    if len(args) < 2 or args[0] not in ("on", "off"):
        print(__doc__)
        sys.exit(1)

    action, target = args[0], args[1]

    if target == "all":
        targets = list(NODE_ALIAS.keys())
    elif target in NODE_ALIAS:
        targets = [target]
    else:
        print(f"Unknown target: {target}. Use a node name (ipc4-ipc9) or 'all'.")
        sys.exit(1)

    for node in targets:
        alias = NODE_ALIAS[node]
        child = next((c for c in strip.children if c.alias == alias), None)
        if not child:
            print(f"  {node}: outlet '{alias}' not found on strip")
            continue
        if action == "on":
            await child.turn_on()
        else:
            await child.turn_off()
        print(f"  {node} ({alias}): {action}")


asyncio.run(main())
