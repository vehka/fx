#!/usr/bin/env python3
"""Send code to a norns over its websocket REPLs and print what comes back.

  test/repl.py --host 10.0.0.138 'print(norns.state.shortname)'      # Lua (matron)
  test/repl.py --host 10.0.0.138 --sc 'FxRack.ready.postln;'          # sclang

Needs websocket-client (pip install websocket-client, in a venv if the
system Python is externally managed). sclang takes one line per message,
ended by ESC; put longer code in a file on the device and send
'"/tmp/x.scd".load;'.
"""
import argparse
import time

import websocket

ap = argparse.ArgumentParser()
ap.add_argument("--host", default="localhost")
ap.add_argument("--sc", action="store_true", help="talk to sclang (port 5556) instead of matron (5555)")
ap.add_argument("--wait", type=float, default=2.0, help="seconds to keep reading output")
ap.add_argument("code", nargs="+")
a = ap.parse_args()

port = 5556 if a.sc else 5555
ws = websocket.create_connection(f"ws://{a.host}:{port}/", subprotocols=["bus.sp.nanomsg.org"], timeout=10)
ws.settimeout(0.2)
for c in a.code:
    ws.send(c.replace("\n", " ") + "\x1b" if a.sc else c + "\n")
end = time.time() + a.wait
while time.time() < end:
    try:
        msg = ws.recv()
        print(msg if isinstance(msg, str) else msg.decode(errors="replace"), end="")
    except websocket.WebSocketTimeoutException:
        pass
ws.close()
