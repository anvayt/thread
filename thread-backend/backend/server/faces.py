"""Face perception: detect the nearest face and turn it into a 128-number
signature. Runs entirely on this machine; no frame leaves it."""

import base64
import binascii
import threading
from pathlib import Path

import cv2
import numpy as np

MODELS = Path(__file__).resolve().parent.parent / "models"
DET_PATH = MODELS / "face_detection_yunet_2023mar.onnx"
REC_PATH = MODELS / "face_recognition_sface_2021dec.onnx"

# Wearable frames are shot close-up and often backlit, which sinks the face
# into shadow and hides it from the detector. Equalising the luminance channel
# first recovers the detection; measured on a hard backlit frame, this is the
# difference between needing a 0.15 score threshold and a comfortable 0.5.
DET_SCORE = 0.5

# SFace's published cosine threshold for a same-identity match.
FACE_THRESHOLD = 0.363

# Longest edge for a stored enrolment photo. It is shown at thumbnail size in
# a list, so anything larger is pure payload.
PHOTO_MAX_EDGE = 320

# Model handles are built once and reused. The detector is resized per frame,
# so only one request may use the pair at a time.
_models: dict = {}
_lock = threading.Lock()


def _detector():
    if "det" not in _models:
        _models["det"] = cv2.FaceDetectorYN.create(
            str(DET_PATH), "", (320, 320), DET_SCORE, 0.3, 5000
        )
    return _models["det"]


def _recognizer():
    if "rec" not in _models:
        _models["rec"] = cv2.FaceRecognizerSF.create(str(REC_PATH), "")
    return _models["rec"]


def _decode(jpeg_b64: str):
    """Base64 JPEG -> BGR image, or None for anything that is not an image."""
    try:
        raw = base64.b64decode(jpeg_b64)
    except (binascii.Error, ValueError):
        return None
    if not raw:
        return None
    try:
        return cv2.imdecode(np.frombuffer(raw, dtype=np.uint8), cv2.IMREAD_COLOR)
    except cv2.error:
        return None


def _delight(img):
    """Lift the face out of the backlight before detection: equalise L in LAB
    space, leaving colour untouched so the embedding still sees a natural
    face."""
    lightness, a, b = cv2.split(cv2.cvtColor(img, cv2.COLOR_BGR2LAB))
    equalised = cv2.createCLAHE(clipLimit=3.0, tileGridSize=(8, 8)).apply(lightness)
    return cv2.cvtColor(cv2.merge((equalised, a, b)), cv2.COLOR_LAB2BGR)


def embed_face(jpeg_b64: str) -> list[float]:
    """A 128-d embedding for the largest face in the frame, or [] if none.

    Anything that is not a readable image also yields [] rather than raising:
    callers treat an empty vector as "say nothing", which is the safe answer.
    """
    decoded = _decode(jpeg_b64)
    if decoded is None:
        return []
    img = _delight(decoded)

    with _lock:
        detector = _detector()
        height, width = img.shape[:2]
        detector.setInputSize((int(width), int(height)))
        faces = detector.detect(img)[1]
        if faces is None or len(faces) == 0:
            return []

        # Largest face wins - the wearer is looking at whoever is closest.
        best = max(faces, key=lambda box: float(box[2]) * float(box[3]))

        recognizer = _recognizer()
        feature = recognizer.feature(recognizer.alignCrop(img, best))
    return [float(v) for v in feature.flatten().tolist()]


def thumbnail(jpeg_b64: str) -> str:
    """Shrink a photo to thumbnail size; "" if it cannot be read.

    Enrolment photos are only ever displayed next to a name. Clients are asked
    to downscale before upload, but one full-resolution frame is enough to
    bloat every roster response, so it is enforced here.
    """
    if not jpeg_b64:
        return ""
    try:
        img = _decode(jpeg_b64)
        if img is None:
            return ""
        height, width = img.shape[:2]
        longest = max(height, width)
        if longest > PHOTO_MAX_EDGE:
            scale = PHOTO_MAX_EDGE / longest
            img = cv2.resize(
                img,
                (int(width * scale), int(height * scale)),
                interpolation=cv2.INTER_AREA,
            )
        encoded = cv2.imencode(".jpg", img, [int(cv2.IMWRITE_JPEG_QUALITY), 80])[1]
        return base64.b64encode(encoded.tobytes()).decode()
    except cv2.error:
        # A photo is a nicety; never fail an enrolment over one.
        return ""
