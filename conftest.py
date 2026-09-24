"""Shared pytest fixtures.

Lives at the repo root so `import main` and `from cv import ...` resolve the
same way they do when uvicorn starts the worker.
"""

import os
import sys

import cv2
import numpy as np
import pytest

ROOT = os.path.dirname(os.path.abspath(__file__))
if ROOT not in sys.path:
    sys.path.insert(0, ROOT)

ASSETS = os.path.join(ROOT, "test_assets")


def _load(name):
    """Read a fixture image, failing the test clearly if it is missing."""
    path = os.path.join(ASSETS, name)
    frame = cv2.imread(path)
    if frame is None:
        pytest.fail(f"fixture image unreadable: {path}")
    return frame


@pytest.fixture(scope="session")
def phone_image():
    """A photo containing a phone — the positive case for phone detection."""
    return _load("phone_sample.jpg")


@pytest.fixture(scope="session")
def head_down_image():
    """A photo containing a visible face — the positive case for gaze."""
    return _load("woman-with-her-head-down-on-the-table-looking-at-phone.jpg")


@pytest.fixture(scope="session")
def desk_image():
    """A third real photo, used to check the result contract holds generally."""
    return _load("swello-2f_zK0ruzJE-unsplash.jpg")


@pytest.fixture(scope="session")
def blank_frame():
    """A synthetic black frame — the negative case for both detectors.

    All three bundled photos trip the phone detector (the desk photo scores
    ~0.61, plausibly a false positive), so none of them works as a negative
    control. A generated frame is both unambiguous and deterministic.
    """
    return np.zeros((480, 640, 3), dtype=np.uint8)


@pytest.fixture(scope="session")
def jpeg_bytes(phone_image):
    """The phone photo as encoded JPEG bytes, as the client would send it."""
    ok, buffer = cv2.imencode(".jpg", phone_image)
    assert ok, "failed to JPEG-encode the fixture image"
    return buffer.tobytes()


@pytest.fixture(scope="session")
def client():
    """FastAPI test client for the worker's HTTP and WebSocket endpoints."""
    from fastapi.testclient import TestClient

    import main

    return TestClient(main.app)
