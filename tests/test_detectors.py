"""Unit tests for the two detectors.

They are pure functions — frame in, protocol-shaped dict out — so they can be
tested directly against the bundled fixture images, with no camera and no
running server.
"""

import time

import pytest

from cv.gaze_detector import detect_gaze
from cv.phone_detector import detect_phone

PHONE_STATUSES = {"none", "detected"}
GAZE_STATUSES = {"focused", "distracted"}


# ---------------------------------------------------------------------------
# The result contract
#
# main.py sends these dicts straight to the client as JSON, so the shape is a
# protocol promise, not an internal detail. Checked across every fixture.
# ---------------------------------------------------------------------------


def _assert_contract(result, expected_type, allowed_statuses):
    assert set(result) == {"type", "status", "confidence", "timestamp"}
    assert result["type"] == expected_type
    assert result["status"] in allowed_statuses
    assert isinstance(result["confidence"], float)
    assert 0.0 <= result["confidence"] <= 1.0
    assert isinstance(result["timestamp"], int)
    # Timestamp is epoch milliseconds, so it must be far larger than epoch
    # seconds for the same moment.
    assert result["timestamp"] > int(time.time())


@pytest.mark.parametrize(
    "fixture_name",
    ["phone_image", "head_down_image", "desk_image", "blank_frame"],
)
def test_phone_result_matches_contract(fixture_name, request):
    frame = request.getfixturevalue(fixture_name)
    _assert_contract(detect_phone(frame), "phone", PHONE_STATUSES)


@pytest.mark.parametrize(
    "fixture_name",
    ["phone_image", "head_down_image", "desk_image", "blank_frame"],
)
def test_gaze_result_matches_contract(fixture_name, request):
    frame = request.getfixturevalue(fixture_name)
    _assert_contract(detect_gaze(frame), "gaze", GAZE_STATUSES)


# ---------------------------------------------------------------------------
# Phone detection behaviour
# ---------------------------------------------------------------------------


def test_phone_detected_in_photo_of_a_phone(phone_image):
    result = detect_phone(phone_image)
    assert result["status"] == "detected"
    # Measured ~0.91 on this fixture. Asserting a floor rather than the exact
    # score keeps the test meaningful without making it brittle against model
    # or preprocessing changes.
    assert result["confidence"] > 0.5


def test_no_phone_in_blank_frame(blank_frame):
    result = detect_phone(blank_frame)
    assert result["status"] == "none"
    assert result["confidence"] == 0.0


# ---------------------------------------------------------------------------
# Gaze detection behaviour
# ---------------------------------------------------------------------------


def test_gaze_reports_face_in_photo_with_a_visible_face(head_down_image):
    result = detect_gaze(head_down_image)
    # detect_gaze returns confidence 1.0 whenever it actually found and
    # measured a face, whichever way that face is turned; 0.0 means no face
    # was in view at all. So confidence is what proves the detector ran.
    assert result["confidence"] == 1.0
    assert result["status"] in GAZE_STATUSES


def test_gaze_reports_no_face_in_blank_frame(blank_frame):
    result = detect_gaze(blank_frame)
    assert result["status"] == "distracted"
    assert result["confidence"] == 0.0
