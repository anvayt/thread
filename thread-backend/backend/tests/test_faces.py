"""The real face models, not stand-ins.

The repository ships no photographs of people. To check matching on real
faces, put two different photos of the same person at

    testdata/local/enroll.jpg
    testdata/local/probe.jpg

(the folder is git-ignored). Without them those tests are skipped.
"""

import base64
from pathlib import Path

import pytest

from server import faces
from server.logic import cosine

TESTDATA = Path(__file__).resolve().parent.parent / "testdata"
ENROLL = TESTDATA / "local" / "enroll.jpg"
PROBE = TESTDATA / "local" / "probe.jpg"

needs_photos = pytest.mark.skipif(
    not (ENROLL.exists() and PROBE.exists()),
    reason="add testdata/local/enroll.jpg and probe.jpg to run",
)


def b64(path: Path) -> str:
    return base64.b64encode(path.read_bytes()).decode()


def test_the_models_load_and_find_no_face_in_a_scene_without_one():
    scene = (TESTDATA / "scene.b64").read_text().strip()
    assert faces.embed_face(scene) == []


def test_enrolling_from_a_frame_without_a_face_is_refused(api):
    scene = (TESTDATA / "scene.b64").read_text().strip()
    got = api("enroll", {"name": "Empty Room", "frame_b64": scene})
    assert got["enrolled"] is False
    assert api("roster")["people"] == []


@needs_photos
def test_two_photos_of_one_person_match():
    first, second = faces.embed_face(b64(ENROLL)), faces.embed_face(b64(PROBE))
    assert len(first) == 128 and len(second) == 128
    assert cosine(first, second) >= faces.FACE_THRESHOLD


@needs_photos
def test_a_person_enrolled_from_one_photo_is_recognised_in_another(api, fake):
    enrolled = api("enroll", {"name": "Local Tester", "frame_b64": b64(ENROLL)})
    assert enrolled["enrolled"] is True

    got = api("recognize", {"frame_b64": b64(PROBE)})

    assert got["matched"] is True
    assert got["name"] == "Local Tester"
    photo = api("roster")["people"][0]["photo_b64"]
    assert photo, "the enrolment thumbnail is kept so clients can show a face"


# Boxes are (x, y, width, height), as the detector gives them.


def test_the_face_in_the_middle_is_picked_over_a_bigger_one_at_the_edge():
    # From a real frame, 240x320: a bystander close to the camera at the left
    # edge, and the person being talked to in the middle, further away.
    bystander, speaker = (9, 180, 22, 28), (95, 173, 15, 20)
    assert faces.pick_face([bystander, speaker], 240, 320) == speaker


def test_a_small_face_in_the_background_does_not_win_by_being_central():
    near, far_in_the_middle = (10, 140, 60, 70), (112, 150, 12, 14)
    assert faces.pick_face([near, far_in_the_middle], 240, 320) == near


def test_a_lone_face_is_picked_wherever_it_is():
    assert faces.pick_face([(0, 0, 10, 10)], 240, 320) == (0, 0, 10, 10)
