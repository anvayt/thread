#!/usr/bin/env bash
# Command-line helpers for a running server. Rebuild the demo data, enrol a
# face, test a frame - all without the phone.
#
#   ./demo.sh reset                  wipe everything, then add the demo people
#   ./demo.sh roster                 show who and what is stored
#   ./demo.sh enroll <name> <img>    enrol a face from a photo
#   ./demo.sh look <img>             recognise a frame, print the spoken line
#   ./demo.sh caption <text> [lang]  clean/translate speech for the display
#   ./demo.sh hear <transcript>      file a conversation
#   ./demo.sh who <name|last>        lookup card for a person
#   ./demo.sh ask <question>         free-text question over everyone met
#   ./demo.sh forget <name>          delete a person and their history
#
# HOST defaults to this machine; override to reach a server elsewhere:
#   HOST=10.0.0.5 ./demo.sh look frame.jpg

set -euo pipefail
cd "$(dirname "$0")"

HOST="${HOST:-127.0.0.1}"
PORT="${PORT:-8000}"
BASE="http://${HOST}:${PORT}"
PY=".venv/bin/python"

if [[ ! -x "$PY" ]]; then
  echo "No virtualenv yet - run 'uv sync' in $(pwd) first." >&2
  exit 1
fi

# Downscale to 512px on the longest edge and base64 it - same as the iOS app.
b64() {
  "$PY" - "$1" <<'EOF'
import sys, cv2, base64
img = cv2.imread(sys.argv[1])
if img is None:
    sys.exit(f"cannot read image: {sys.argv[1]}")
h, w = img.shape[:2]
s = 512 / max(h, w)
if s < 1:
    img = cv2.resize(img, (int(w * s), int(h * s)), interpolation=cv2.INTER_AREA)
ok, buf = cv2.imencode(".jpg", img, [cv2.IMWRITE_JPEG_QUALITY, 85])
print(base64.b64encode(buf.tobytes()).decode(), end="")
EOF
}

# json key value [key value ...]  ->  a JSON object on stdout
json() {
  "$PY" -c 'import json,sys; a=sys.argv[1:]; print(json.dumps(dict(zip(a[::2], a[1::2]))))' "$@"
}

# call <endpoint>  - POSTs the JSON on stdin, prints the answer.
call() {
  curl -sS -X POST "${BASE}/api/$1" -H 'Content-Type: application/json' -d @- | show
}

# Print the payload, or the error. Photos are elided so output stays readable.
show() {
  "$PY" -c '
import json, sys
raw = sys.stdin.read()
try:
    reply = json.loads(raw)
except ValueError:
    sys.exit(f"not JSON: {raw[:300]}")
if not reply.get("ok"):
    sys.exit("error: " + str(reply.get("error", raw[:300])))
def trim(v):
    if isinstance(v, dict):
        return {k: (f"<{len(x)} chars>" if k == "photo_b64" and x else trim(x)) for k, x in v.items()}
    if isinstance(v, list):
        return [trim(x) for x in v]
    return v
print(json.dumps(trim(reply["data"]), indent=2, ensure_ascii=False))
'
}

case "${1:-}" in
  reset)
    echo "wiping...";  echo '{}' | call reset
    echo "seeding..."; echo '{}' | call seed
    ;;
  roster)
    echo '{}' | call roster
    ;;
  enroll)
    name="${2:?usage: ./demo.sh enroll <name> <image>}"
    img="${3:?usage: ./demo.sh enroll <name> <image>}"
    json name "$name" frame_b64 "$(b64 "$img")" relationship "enrolled on site" | call enroll
    ;;
  look)
    img="${2:?usage: ./demo.sh look <image>}"
    json frame_b64 "$(b64 "$img")" | call recognize
    ;;
  caption)
    txt="${2:?usage: ./demo.sh caption <text> [lang]}"
    json text "$txt" lang "${3:-en}" | call caption
    ;;
  hear)
    txt="${2:?usage: ./demo.sh hear <transcript>}"
    json transcript "$txt" | call ingest
    ;;
  who)
    json name "${2:-last}" | call lookup
    ;;
  ask)
    q="${2:?usage: ./demo.sh ask <question>}"
    json question "$q" | call query
    ;;
  forget)
    name="${2:?usage: ./demo.sh forget <name>}"
    json name "$name" | call forget
    ;;
  *)
    sed -n '2,16p' "$0" | sed 's/^# \{0,1\}//'
    exit 1
    ;;
esac
