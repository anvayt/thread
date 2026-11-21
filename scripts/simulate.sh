#!/bin/sh
# Runs Thread in the iOS Simulator with Meta's simulated glasses, so the app
# can be tried by hand with no hardware.
#
#     scripts/simulate.sh
#
# Needs a Mac with Xcode and an iOS Simulator runtime, and uv for the backend.
# It finds or creates the simulator device, boots it and opens its window,
# builds and installs the Debug app, allows what the app needs, starts a
# backend on port 8000 if none is answering, and starts the app with the
# simulated glasses. Run it again at any time; each step is skipped or redone
# as needed. README.md says what to do once the app is on screen.
#
# The device is named "Thread Test". Another name can be given:
#
#     THREAD_SIM_NAME="My test phone" scripts/simulate.sh
#
# Everything it generates goes in build/mock, which git ignores.
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
BACKEND="$ROOT/thread-backend/backend"
GEN="$ROOT/build/mock"
PHOTO="$HERE/simulated/face.jpg"
CLIP="$GEN/clip.mov"
NAME="${THREAD_SIM_NAME:-Thread Test}"
BUNDLE=com.threadglasses.app
PORT=8000
URL="http://127.0.0.1:$PORT"

step() { printf '\n%s\n' "$*"; }
note() { printf '    %s\n' "$*"; }
die() { printf '\nStopped: %s\n' "$*" >&2; exit 1; }

command -v xcodebuild >/dev/null 2>&1 || die "xcodebuild was not found. Install Xcode."
xcrun simctl help >/dev/null 2>&1 ||
    die "xcrun simctl does not run. Open Xcode once, or select it with: sudo xcode-select -s /Applications/Xcode.app"
mkdir -p "$GEN"

# ------------------------------------------------------------- 1. the device

# Prints the UDID of the available simulator device with exactly this name.
find_device() {
    xcrun simctl list devices available | awk -v want="$1" '
        {
            line = $0
            sub(/^ +/, "", line)
            # "Name (UDID) (State)". A UDID is 36 characters.
            if (match(line, / \([0-9A-F-]+\) \(/) && RLENGTH == 41 &&
                substr(line, 1, RSTART - 1) == want) {
                print substr(line, RSTART + 2, 36)
                exit
            }
        }'
}

# Creates the device on the newest installed iOS runtime, as an iPhone 17 if
# this Xcode has one and otherwise as its newest iPhone.
create_device() {
    runtime="$(xcrun simctl list runtimes available | awk '/^iOS /{print $2, $NF}' |
        sort -t. -k1,1n -k2,2n -k3,3n | tail -1 | awk '{print $2}')"
    [ -n "$runtime" ] ||
        die "No iOS Simulator runtime is installed. Add one in Xcode, under Settings, Components."
    types="com.apple.CoreSimulator.SimDeviceType.iPhone-17
$(xcrun simctl list devicetypes | sed -n 's/^iPhone.*(\(com\.apple\.CoreSimulator\.SimDeviceType\.[^)]*\))$/\1/p' | tail -r)"
    for type in $types; do
        if udid="$(xcrun simctl create "$NAME" "$type" "$runtime" 2>/dev/null)"; then
            note "Created \"$NAME\" (${type##*.}, ${runtime##*.})."
            UDID="$udid"
            return 0
        fi
    done
    die "Could not create a simulator device on $runtime."
}

step "1/6  Simulator device"
UDID="$(find_device "$NAME")"
if [ -n "$UDID" ]; then
    note "Found \"$NAME\"."
else
    note "There is no device named \"$NAME\" yet."
    create_device
fi
note "Its identifier is $UDID."

# ------------------------------------------------------ 2. boot and a window

step "2/6  Booting it and opening its window"
xcrun simctl bootstatus "$UDID" -b >/dev/null 2>&1 || die "The simulator did not boot."
note "Booted."
DEVELOPER="$(xcode-select -p)"
if [ -d "$DEVELOPER/Applications/Simulator.app" ]; then
    # Xcode 26 and earlier.
    open -a "$DEVELOPER/Applications/Simulator.app" --args -CurrentDeviceUDID "$UDID" &&
        WINDOW="Simulator"
else
    # Xcode 27 replaced the Simulator app with Device Hub.
    { open "devices://device/open?id=$UDID" 2>/dev/null || open -b com.apple.dt.Devices 2>/dev/null; } &&
        WINDOW="Device Hub"
fi
if [ -n "${WINDOW:-}" ]; then
    note "Opened it in $WINDOW. The phone's screen is in that window."
else
    note "Could not open a Simulator window. The app will run where it cannot be seen."
fi

# ------------------------------------------------------ 3. build and install

step "3/6  Building the app and installing it"
note "A first build downloads Meta's SDK and takes a few minutes. Later ones take seconds."
build() {
    xcodebuild -project "$ROOT/Thread.xcodeproj" -scheme Thread -configuration Debug \
        -destination "platform=iOS Simulator,id=$UDID" "$@"
}
if ! build build >"$GEN/xcodebuild.log" 2>&1; then
    grep -E 'error:' "$GEN/xcodebuild.log" | sort -u | head -20
    die "The build failed. The whole log is in $GEN/xcodebuild.log"
fi
APP="$(build -showBuildSettings 2>/dev/null | sed -n 's/^ *BUILT_PRODUCTS_DIR = //p' | head -1)/Thread.app"
[ -d "$APP" ] || die "The build finished, but there is no app at $APP"
xcrun simctl install "$UDID" "$APP" || die "The app could not be installed."
note "Built (Debug) and installed."

# ----------------------------------------------------------- 4. permissions

step "4/6  Allowing the microphone and the camera"
for service in microphone camera; do
    if xcrun simctl privacy "$UDID" grant "$service" "$BUNDLE" >/dev/null 2>&1; then
        note "Allowed: $service."
    else
        note "Could not allow: $service. iOS will ask in the app instead."
    fi
done
note "Speech recognition cannot be allowed from here. iOS asks the first time"
note "the app starts. Choose Allow."

# --------------------------------------------------------------- 5. backend

# True when a Thread backend answers, which is what the app's own
# "Test connection" checks.
backend_answers() {
    curl -s -m 5 -X POST "$URL/api/roster" -H 'Content-Type: application/json' -d '{}' 2>/dev/null |
        grep -q '"ok":[[:space:]]*true'
}

# True when the setting named is given a value here or in the backend's .env
# file.
is_set() {
    [ -n "$(printenv "$1")" ] && return 0
    [ -f "$BACKEND/.env" ] &&
        grep -Eq "^[[:space:]]*$1[[:space:]]*=[[:space:]]*[\"']?[^\"'[:space:]]" "$BACKEND/.env"
}

# The backend's own default for LLM_BASE_URL: a vLLM server on this machine.
MODEL_URL="http://127.0.0.1:8001/v1"

# True when the backend has a language model to use: one is set up with
# LLM_BASE_URL or LLM_API_KEY, or a model server answers at the default.
has_model() {
    is_set LLM_BASE_URL || is_set LLM_API_KEY ||
        curl -s -f -m 3 -o /dev/null "$MODEL_URL/models"
}

# Says which kind of backend is listening, going by how it was started.
running_backend() {
    pid="$(lsof -nP -t -iTCP:"$PORT" -sTCP:LISTEN 2>/dev/null | head -1)"
    case "$(ps -o command= -p "${pid:-0}" 2>/dev/null)" in
    *backend.py*) echo "the scripted stand-in" ;;
    *"-m server"*) echo "the real backend" ;;
    *) echo "started some other way" ;;
    esac
}

step "5/6  Backend on port $PORT"
if backend_answers; then
    note "One is already answering ($(running_backend)), so it is used as it is."
    BACKEND_STARTED=""
elif curl -s -m 3 -o /dev/null "$URL/"; then
    die "Something that is not a Thread backend is answering on port $PORT. Stop it and run this again."
else
    command -v uv >/dev/null 2>&1 ||
        die "uv was not found, and the backend needs it. See https://docs.astral.sh/uv/"
    cd "$BACKEND" || die "There is no backend folder at $BACKEND"
    # detached.py gives the server a session of its own, so it keeps running
    # after this script, and the terminal it was run from, are gone.
    if has_model; then
        BACKEND_STARTED="the real backend. A language model is set up, so language comes from Nemotron"
        PORT="$PORT" uv run python "$HERE/simulated/detached.py" python -m server \
            >"$GEN/backend.log" 2>&1 </dev/null &
    else
        BACKEND_STARTED="the scripted stand-in. No language model was found (LLM_BASE_URL and LLM_API_KEY are not set, and nothing answers at $MODEL_URL), so names, cards and answers come from fixed rules. Faces are matched for real"
        DB_PATH="$GEN/test.db" PORT="$PORT" uv run python "$HERE/simulated/detached.py" \
            python "$HERE/simulated/backend.py" >"$GEN/backend.log" 2>&1 </dev/null &
    fi
    server=$!
    cd "$ROOT" || exit 1
    note "Starting $BACKEND_STARTED."
    note "The first start sets up its Python environment, which can take a minute."
    waited=0
    until backend_answers; do
        kill -0 "$server" 2>/dev/null || {
            tail -15 "$GEN/backend.log"
            die "The backend stopped as it started. Its log is $GEN/backend.log"
        }
        [ "$waited" -lt 180 ] || die "The backend did not answer within 3 minutes. Its log is $GEN/backend.log"
        sleep 1
        waited=$((waited + 1))
    done
    note "It answers at $URL, and its log is $GEN/backend.log"
fi

# ------------------------------------------------------------------ 6. launch

step "6/6  Starting Thread with the simulated glasses"
if [ ! -f "$CLIP" ] || [ "$PHOTO" -nt "$CLIP" ]; then
    note "Making the camera's video clip from the portrait."
    swift "$HERE/simulated/make_clip.swift" "$PHOTO" "$CLIP" >"$GEN/make_clip.log" 2>&1 ||
        die "The clip could not be made. See $GEN/make_clip.log"
fi
: >"$GEN/commands.txt"

# Starts the app, replacing any copy that is running. What the app prints
# goes to app.log, and the system's own chatter to app-errors.log. Extra
# arguments are passed on to the app. NSUnbufferedIO makes each line reach
# the file as it is printed, which is what Xcode does when it runs an app.
launch() {
    : >"$GEN/app.log"
    : >"$GEN/app-errors.log"
    SIMCTL_CHILD_NSUnbufferedIO=YES xcrun simctl launch --terminate-running-process \
        --stdout="$GEN/app.log" --stderr="$GEN/app-errors.log" "$UDID" "$BUNDLE" \
        -mockGlasses YES -mockGlassesPhoto "$PHOTO" -mockGlassesVideo "$CLIP" \
        -mockCommands "$GEN/commands.txt" "$@" >/dev/null ||
        die "The app could not be started."
}

app_running() {
    xcrun simctl spawn "$UDID" launchctl list 2>/dev/null |
        awk -v label="UIKitApplication:$BUNDLE" '
            $1 ~ /^[0-9]+$/ && index($3, label) == 1 { found = 1 }
            END { exit !found }'
}

launch
sleep 6
AUDIO="on"
if ! app_running; then
    # A simulated phone booted with no Simulator app running has been seen to
    # have no audio hardware, and the app then aborts when it opens the
    # microphone. It can still run without sound.
    note "The app stopped as it started, which is what happens when the simulated"
    note "phone has no audio. Starting it again with the microphone and speech off."
    launch -noAudio YES
    sleep 6
    app_running || die "The app does not stay running. See $GEN/app.log"
    AUDIO="off"
fi
note "Running."

cat <<EOF

Thread is running on "$NAME" with simulated Ray-Ban Meta glasses.

    In the app   Open Glasses and tap Connect. Then open Meet and tap Meet.
                 The glasses' own controls are in Glasses, under "Simulated Glasses".
    Sound        $([ "$AUDIO" = on ] && echo "The simulated phone uses this Mac's microphone and speakers, and keeps
                 the microphone open while the app runs." || echo "Off for this run. Meet takes the photo but hears nothing.")
    Words        Meet cannot hear here: Apple's speech recognition does not run in the
                 Simulator. Type what was said instead: Meet's More menu, Listen Only,
                 the keyboard button, Use. The next Meet uses it.
    Backend      $URL (open it in a browser for the dashboard)
    App log      tail -f "$GEN/app.log"

README.md, under "Run with simulated glasses", says what the controls do.

To stop:

    xcrun simctl shutdown $UDID
EOF
if [ -n "${BACKEND_STARTED:-}" ]; then
    echo "    lsof -ti tcp:$PORT | xargs kill        # the backend this script started"
fi
