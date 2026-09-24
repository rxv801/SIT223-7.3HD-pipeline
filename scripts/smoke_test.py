"""Smoke test a deployed worker: health endpoint, then a real frame over /ws.

Proves the deployment actually works rather than merely that a port is open —
a process can bind 8766 and still be unable to load a model or decode a frame.

    python scripts/smoke_test.py <base-url> <image>
"""

import asyncio
import json
import sys
import urllib.request

import websockets


def check_health(base_url: str) -> None:
    with urllib.request.urlopen(f"{base_url}/", timeout=10) as response:
        if response.status != 200:
            raise SystemExit(f"health check returned HTTP {response.status}")
        payload = json.load(response)

    if payload.get("status") != "ok":
        raise SystemExit(f"health check returned {payload!r}")
    print(f"    health: {payload}")


async def check_detection(ws_url: str, image_path: str) -> None:
    with open(image_path, "rb") as handle:
        frame = handle.read()

    async with websockets.connect(ws_url, open_timeout=15) as socket:
        await socket.send(frame)
        phone = json.loads(await asyncio.wait_for(socket.recv(), timeout=30))
        gaze = json.loads(await asyncio.wait_for(socket.recv(), timeout=30))

    # Order is part of the protocol: main.py sends phone first, then gaze.
    if phone.get("type") != "phone" or gaze.get("type") != "gaze":
        raise SystemExit(f"unexpected events: {phone!r} {gaze!r}")

    # The fixture is a photo of a phone, so a deployment that loaded its models
    # correctly must detect one. A deployment missing yolox_s.onnx would still
    # answer, just always with "none" — which is the failure this catches.
    if phone.get("status") != "detected":
        raise SystemExit(f"expected a phone detection, got {phone!r}")

    print(f"    phone: {phone['status']} ({phone['confidence']:.3f})")
    print(f"    gaze:  {gaze['status']} ({gaze['confidence']:.3f})")


def main() -> None:
    base_url, image_path = sys.argv[1], sys.argv[2]
    ws_url = base_url.replace("http://", "ws://", 1) + "/ws"

    check_health(base_url)
    asyncio.run(check_detection(ws_url, image_path))
    print("    smoke test passed")


if __name__ == "__main__":
    main()
