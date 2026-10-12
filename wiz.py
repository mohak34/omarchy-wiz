#!/usr/bin/env python3
"""Talk to a WiZ bulb over its local UDP API and print one JSON object.

The bar widget runs this once per action or refresh, so nothing stays
resident between clicks. Standard library only, so there is nothing to build.

    wiz.py get <mac> [--cached]   print the bulb state
    wiz.py set <mac> <json>       apply setPilot params, then print the new state
    wiz.py discover               list every bulb on the local networks

An empty mac selects the single bulb that accepts unsigned local control
(WiZ app: Settings > Current home > Security > Local communication > All
controls). --cached only tries the last known address, and scans the network
only when nothing is cached yet, so background refreshes stay cheap when the
bulb is out of reach.
"""

import json
import os
import selectors
import socket
import struct
import sys
import time
from pathlib import Path
from typing import Any, TypedDict

PORT = 38899

# Packets to hosts that ARP has not resolved yet count against the socket's
# send buffer, so a sweep is spread over small batches, one socket each. One
# socket for a whole /24 blocks for seconds.
SWEEP_BATCH = 32
SWEEP_WAIT = 1.2


class WizError(Exception):
    pass


class Bulb(TypedDict):
    ip: str
    mac: str
    signed: bool


class State(TypedDict):
    ip: str
    mac: str
    on: bool
    dimming: int
    temp: int
    color: bool
    r: int
    g: int
    b: int
    scene: int
    rssi: int


def main(argv: list[str]) -> int:
    try:
        out: Any = run(argv)
        code = 0
    except (WizError, OSError) as e:
        out = {"error": str(e)}
        code = 1
    print(json.dumps(out))
    return code


def run(argv: list[str]) -> Any:
    match argv:
        case ["discover"]:
            return discover()
        case ["get", mac, *flags] if set(flags) <= {"--cached"}:
            ip, pilot = locate(normalize_mac(mac), scan="--cached" not in flags)
            return to_state(ip, pilot)
        case ["set", mac, raw]:
            try:
                params = json.loads(raw)
            except json.JSONDecodeError as e:
                raise WizError(f"params must be a JSON object: {e}") from e
            if not isinstance(params, dict):
                raise WizError("params must be a JSON object")
            ip, _ = locate(normalize_mac(mac), scan=True)
            reply = call(ip, "setPilot", params)
            if "error" in reply:
                if "hmac" in reply:
                    raise WizError("bulb only accepts verified controls; set Local communication to All controls in the WiZ app")
                raise WizError(f"bulb rejected {raw}: {reply['error'].get('message')}")
            return to_state(ip, get_pilot(ip))
    raise WizError("usage: wiz.py get <mac> [--cached] | set <mac> <json> | discover")


def locate(mac: str, scan: bool) -> tuple[str, dict[str, Any]]:
    """Find the bulb's current IP. DHCP can move the bulb, so a stale cached
    address falls back to a network sweep when scanning is allowed."""
    cached = read_cache()
    if cached and (not mac or mac == cached["mac"]):
        try:
            pilot = get_pilot(cached["ip"])
            if pilot.get("mac") == cached["mac"]:
                return cached["ip"], pilot
        except WizError:
            pass
        if not scan:
            raise WizError(f"bulb at {cached['ip']} did not answer")

    if mac:
        matches = [b for b in discover() if b["mac"] == mac]
        if not matches:
            raise WizError(f"no bulb with MAC {mac} on this network")
    else:
        matches = [b for b in discover() if not b["signed"]]
        if not matches:
            raise WizError("no bulb accepts local control; set Local communication to All controls in the WiZ app")
        if len(matches) > 1:
            raise WizError("several bulbs accept local control; set the bulb MAC in the widget settings")

    ip = matches[0]["ip"]
    pilot = get_pilot(ip)
    write_cache({"ip": ip, "mac": pilot.get("mac", mac), "signed": False})
    return ip, pilot


def discover() -> list[Bulb]:
    """Ask every host on the local IPv4 networks for its state. Routers often
    drop broadcasts, so each host is asked directly."""
    msg = json.dumps({"method": "getPilot", "params": {}}).encode()
    hosts = local_hosts()
    sel = selectors.DefaultSelector()
    socks: list[socket.socket] = []
    for start in range(0, len(hosts), SWEEP_BATCH):
        sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        sock.setblocking(False)
        for host in hosts[start : start + SWEEP_BATCH]:
            try:
                sock.sendto(msg, (host, PORT))
            except OSError:
                pass
        sel.register(sock, selectors.EVENT_READ)
        socks.append(sock)

    found: dict[str, Bulb] = {}
    deadline = time.monotonic() + SWEEP_WAIT
    while (left := deadline - time.monotonic()) > 0:
        for key, _ in sel.select(left):
            sock = key.fileobj
            assert isinstance(sock, socket.socket)
            try:
                data, (ip, _) = sock.recvfrom(2048)
                reply = json.loads(data)
            except (OSError, ValueError):
                continue
            mac = reply.get("result", {}).get("mac") if isinstance(reply, dict) else None
            if mac:
                found[ip] = {"ip": ip, "mac": mac, "signed": "hmac" in reply}
    for sock in socks:
        sock.close()
    return list(found.values())


def local_hosts() -> list[str]:
    """Host addresses of every directly connected IPv4 network between a /22
    and a /30, read from the kernel routing table."""
    hosts: list[str] = []
    for line in Path("/proc/net/route").read_text().splitlines()[1:]:
        fields = line.split()
        iface, dest, gateway, mask = fields[0], fields[1], fields[2], fields[7]
        if iface == "lo" or int(gateway, 16) != 0 or int(dest, 16) == 0:
            continue
        net = struct.unpack(">I", struct.pack("<I", int(dest, 16)))[0]
        prefix = int(mask, 16).bit_count()
        if not 22 <= prefix <= 30:
            continue
        for i in range(1, (1 << (32 - prefix)) - 1):
            hosts.append(socket.inet_ntoa(struct.pack(">I", net + i)))
    return hosts


def get_pilot(ip: str) -> dict[str, Any]:
    reply = call(ip, "getPilot", {})
    if "error" in reply:
        raise WizError(f"getPilot: {reply['error'].get('message')}")
    return reply.get("result", {})


def call(ip: str, method: str, params: dict[str, Any]) -> dict[str, Any]:
    """Send one request and wait for the reply, retrying because UDP on Wi-Fi
    drops packets."""
    msg = json.dumps({"method": method, "params": params}).encode()
    with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as sock:
        sock.settimeout(0.4)
        for _ in range(3):
            sock.sendto(msg, (ip, PORT))
            try:
                while True:
                    data, (sender, _) = sock.recvfrom(2048)
                    if sender == ip:
                        reply = json.loads(data)
                        if isinstance(reply, dict):
                            return reply
            except (TimeoutError, ValueError):
                continue
    raise WizError(f"bulb at {ip} did not answer")


def to_state(ip: str, p: dict[str, Any]) -> State:
    color = all(k in p for k in ("r", "g", "b"))
    return {
        "ip": ip,
        "mac": p.get("mac", ""),
        "on": bool(p.get("state")),
        "dimming": p.get("dimming", 0),
        "temp": p.get("temp", 0),
        "color": color,
        "r": p.get("r", 0),
        "g": p.get("g", 0),
        "b": p.get("b", 0),
        "scene": p.get("sceneId", 0),
        "rssi": p.get("rssi", 0),
    }


def cache_path() -> Path:
    base = os.environ.get("XDG_CACHE_HOME") or Path.home() / ".cache"
    return Path(base) / "omarchy-wiz" / "bulb.json"


def read_cache() -> Bulb | None:
    try:
        data = json.loads(cache_path().read_text())
    except (OSError, ValueError):
        return None
    if isinstance(data, dict) and data.get("ip") and data.get("mac"):
        return {"ip": data["ip"], "mac": data["mac"], "signed": False}
    return None


def write_cache(bulb: Bulb) -> None:
    path = cache_path()
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(bulb))


def normalize_mac(mac: str) -> str:
    """Accept aa:bb:cc:dd:ee:ff or aabbccddeeff, the form bulbs report."""
    return mac.strip().lower().replace(":", "").replace("-", "")


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
