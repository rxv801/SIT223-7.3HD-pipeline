"""Integration tests for the worker's HTTP and WebSocket surface.

These exercise main.py through FastAPI's TestClient — real routing, real
framing, real detectors — without binding a port or opening a camera.
"""

import json

import numpy as np
import pytest
from starlette.websockets import WebSocketDisconnect

from main import MAX_FRAME_BYTES, decode_frame


# ---------------------------------------------------------------------------
# Health endpoint — what the Deploy stage polls to decide a rollout succeeded.
# ---------------------------------------------------------------------------


def test_health_check_returns_ok(client):
    response = client.get("/")
    assert response.status_code == 200
    assert response.json() == {"status": "ok", "service": "taskmaster-cv-worker"}


# ---------------------------------------------------------------------------
# Frame decoding
# ---------------------------------------------------------------------------


def test_decode_frame_returns_image_for_valid_jpeg(jpeg_bytes):
    frame = decode_frame(jpeg_bytes)
    assert isinstance(frame, np.ndarray)
    # Decoded as colour, so three channels.
    assert frame.ndim == 3
    assert frame.shape[2] == 3


def test_decode_frame_returns_none_for_garbage():
    # The docstring promises None rather than an exception, because the socket
    # loop relies on staying alive when a client sends something unreadable.
    assert decode_frame(b"this is not an image") is None


# ---------------------------------------------------------------------------
# WebSocket protocol
# ---------------------------------------------------------------------------


def test_websocket_returns_phone_then_gaze_for_one_frame(client, jpeg_bytes):
    with client.websocket_connect("/ws") as websocket:
        websocket.send_bytes(jpeg_bytes)

        phone_event = json.loads(websocket.receive_text())
        gaze_event = json.loads(websocket.receive_text())

    # Order is part of the protocol: main.py sends phone first, then gaze.
    assert phone_event["type"] == "phone"
    assert gaze_event["type"] == "gaze"

    for event in (phone_event, gaze_event):
        assert set(event) == {"type", "status", "confidence", "timestamp"}

    # The fixture is a photo of a phone, so the full round trip should agree
    # with the unit test on the detector.
    assert phone_event["status"] == "detected"


def test_websocket_rejects_oversized_frame(client):
    oversized = b"\x00" * (MAX_FRAME_BYTES + 1)

    with pytest.raises(WebSocketDisconnect) as excinfo:
        with client.websocket_connect("/ws") as websocket:
            websocket.send_bytes(oversized)
            # The server closes with 1009 (message too big) instead of replying,
            # so this read is what surfaces the disconnect.
            websocket.receive_text()

    assert excinfo.value.code == 1009
