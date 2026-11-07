#!/usr/bin/env python3
"""A fake NanoKVM for screenshots: HTTPS API + video/input WebSockets on one port.

  mock-kvm.py <port> <desktop.png> <workdir>

Streams the desktop picture as an H.264 loop. Unknown routes answer {"code":0,"data":{}} and are logged.
"""
import asyncio, json, ssl, struct, subprocess, sys, os
from aiohttp import web

port, desktop, work = int(sys.argv[1]), sys.argv[2], sys.argv[3]
os.makedirs(work, exist_ok=True)

cert, key, h264 = f"{work}/cert.pem", f"{work}/key.pem", f"{work}/desktop.h264"
if not os.path.exists(cert):
    subprocess.run(["openssl", "req", "-x509", "-newkey", "rsa:2048", "-nodes", "-keyout", key, "-out", cert, "-days", "30",
                    "-subj", "/CN=nanokvm.local"], check=True, capture_output=True)
subprocess.run(["ffmpeg", "-y", "-loglevel", "error", "-loop", "1", "-i", desktop, "-t", "1", "-r", "5", "-vf", "scale=1920:1080",
                "-c:v", "libx264", "-g", "1", "-pix_fmt", "yuv420p", "-profile:v", "high", "-x264-params", "repeat-headers=1:aud=0",
                "-f", "h264", h264], check=True)

# One access unit per frame: each starts at an SPS NAL (4-byte start code before type 7).
raw = open(h264, "rb").read()
starts, i = [], 0
while (j := raw.find(b"\x00\x00\x00\x01", i)) != -1:
    if raw[j + 4] & 0x1F == 7:
        starts.append(j)
    i = j + 4
FRAMES = [raw[a:b] for a, b in zip(starts, starts[1:] + [len(raw)])]

INFO = {
    "ips": [{"name": "eth0", "addr": "192.168.1.42", "version": "IPv4", "type": "Wired"}],
    "mdns": "nanokvm-lab", "image": "v1.0.9", "application": "0.2.2",
    "deviceKey": "0000000000000000", "pn": "NanoKVM-Go+", "arch": "riscv64",
}
ROUTES = {
    "POST /auth/login": {"token": "demo-token"},
    "GET /vm/info": INFO,
    "GET /stream/encoder": {"rate_control": "vbr", "bitrate": 8000, "gop": 30, "fps": 30},
    "GET /network/wifi": {"supported": True, "connected": True, "wifi": {"ssid": "Home-5G", "security": "WPA2"}},
    "GET /vm/edid": {"edid": "Built-in-2560x1440.bin", "width": 1920, "height": 1080},
    "GET /vm/edid/custom": {"edidList": ["Built-in-2560x1440.bin", "Studio-Display-2560x1440.bin"]},
    "GET /hid/pointer-mode": {"mode": "absolute"},
    "GET /vm/hdmi/capture": {"enabled": True},
    "GET /vm/mouse-jiggler": {"enabled": False},
    "GET /storage/image": {"files": ["/data/ubuntu-24.04-live-server.iso", "/data/debian-12.5.0-netinst.iso", "/data/memtest86.iso"]},
    "GET /storage/image/mounted": {"mounted": True, "file": "/data/ubuntu-24.04-live-server.iso", "cdrom": True, "readOnly": True},
    "GET /network/wol/mac": {"macs": ["AA:BB:CC:11:22:33 Homelab server", "AA:BB:CC:44:55:66 Media PC", "AA:BB:CC:77:88:99 Workstation"]},
    "GET /vm/hostname": {"hostname": "nanokvm-lab"},
    "GET /vm/mdns": {"enabled": True},
    "GET /vm/ssh": {"enabled": True},
}

async def api(request):
    path = request.path
    if request.headers.get("Upgrade", "").lower() == "websocket":
        ws = web.WebSocketResponse(max_msg_size=0)
        await ws.prepare(request)
        if "/stream/" in path:
            await ws.send_str(json.dumps({"event": "video-status", "data": "1"}))
            ts = 0
            try:
                while True:
                    for frame in FRAMES:
                        await ws.send_bytes(b"\x01" + struct.pack("<Q", ts) + frame)
                        ts += 200_000
                        await asyncio.sleep(0.2)
            except ConnectionResetError:
                pass
        else:
            async for _ in ws:
                pass
        return ws
    key = f"{request.method} {path.removeprefix('/api')}"
    if key not in ROUTES:
        print("unmocked:", key, flush=True)
    return web.json_response({"code": 0, "msg": "success", "data": ROUTES.get(key, {})})

async def main():
    ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    ctx.load_cert_chain(cert, key)
    app = web.Application()
    app.router.add_route("*", "/{tail:.*}", api)
    runner = web.AppRunner(app)
    await runner.setup()
    await web.TCPSite(runner, "127.0.0.1", port, ssl_context=ctx).start()
    print("mock KVM ready", flush=True)
    await asyncio.Future()

asyncio.run(main())
