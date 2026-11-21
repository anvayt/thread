# Thread (iOS + Meta glasses)

Smart glasses that remember the people you meet. This repo holds the iOS companion app that drives **Meta glasses**, and the backend it talks to. It is written for Meta Ray-Ban Display, which has a screen in the lens, and also connects to Meta glasses without a display, such as Ray-Ban Meta: those take the photo and speak the card, and the card itself appears in the app.

## What it does

- Takes one photo when you tap **Meet** (from the glasses, or the iPhone camera when they aren't connected) and transcribes what the other person says, on the phone
- Recognizes a face you have met before and shows their card on the lens (on glasses that have a display), in your ear and in the app: name, role, what they are working on, and what you left open
- Adds a face it doesn't know on the spot, named from the conversation
- Answers typed questions like "who was raising a seed round?" from Search
- Lets you page through a card's talking points with a Neural Band pinch (Meta Ray-Ban Display only)

The backend stores your network as people, conversations and follow-ups; this app is the eyes, ears and display. [OVERVIEW.md](OVERVIEW.md) describes the app in detail.

## The app

The app is built from the system's own parts, with Liquid Glass on the controls that float over content, and follows light and dark appearance.

- **Meet**: the Meet button floats at the bottom, with Speak and Keep Going on either side. While it listens, what is heard and a level meter show above it; then the person appears the way Contacts shows a contact, with what to say next. Photo Only, Listen Only and how long a pause ends a turn are in the More menu. A pass that is running while another tab is open shows above the tab bar, with Done.
- **People**: everyone you have met, A to Z, with anyone still waiting for a name at the top. Swipe to forget someone, or touch and hold to rename them. A person's page has their photo, what to ask about, what you owe them and when you met.
- **Glasses**: connect the glasses, the experimental switches, the camera, permissions, the backend address, diagnostics and How Thread Works.
- **Search**: find people by name or company as you type, or ask the whole network a question in plain words.

The first launch shows a welcome screen before iOS asks for the microphone and speech recognition.

## Stack

- App: Swift · SwiftUI (iOS 26 or later, Liquid Glass) · Meta Wearables Device Access Toolkit 1.1 · XcodeGen
- Backend: Python · FastAPI · SQLite · OpenCV · NVIDIA Nemotron (OpenAI-compatible API)

## Run the backend

The backend runs on your own computer. It needs [uv](https://docs.astral.sh/uv/) and NVIDIA Nemotron for its language tasks: either NVIDIA's hosted API, with a key from [build.nvidia.com](https://build.nvidia.com), or your own vLLM server on an NVIDIA GPU (for example an NVIDIA Brev instance). [thread-backend/README.md](thread-backend/README.md) has both.

```bash
cd thread-backend/backend
uv sync
cp .env.example .env        # then set LLM_BASE_URL and LLM_API_KEY in .env
uv run python -m server
```

It prints the address to enter in the app. See [thread-backend/README.md](thread-backend/README.md) for the rest.

## Build the app

```bash
brew install xcodegen
xcodegen generate
open Thread.xcodeproj
```

In Xcode, choose your own team under the target's Signing & Capabilities before building to a phone. The app needs iOS 26 or later.

Then, in the app's **Glasses** tab, open **Backend**, enter the backend address and tap **Test Connection**. The default, `http://localhost:8000`, only reaches the backend from the iOS Simulator; an iPhone needs the "From a phone" address the server prints, with both on the same Wi-Fi.

Using the glasses requires Meta glasses paired through the Meta AI app with Developer Mode enabled, running glasses software V130 or later with Meta AI app V292 or later. To hear the spoken line through glasses that have no display, they must also be the iPhone's Bluetooth audio output. Support for glasses without a display compiles but has not been tried on real hardware. Neither has starting Meet from the glasses: with **Buttons Start Meet** on in the Glasses tab (the default), a press of the capture button or a double tap on the temple starts Meet, and another press stops it listening. Nor has the experimental switch Listen Through Glasses, off by default, which also transcribes what the glasses' microphones hear. Without glasses the whole flow runs on the iPhone camera and speaker.

## Run with simulated glasses

To try the app on a Mac, with no phone and no glasses:

```bash
scripts/simulate.sh
```

It needs Xcode with an iOS Simulator runtime, and [uv](https://docs.astral.sh/uv/). It says what it is doing at each step:

1. Finds the simulator device named "Thread Test", or creates it.
2. Boots it and opens its window.
3. Builds the Debug app and installs it.
4. Allows the microphone and the camera for the app.
5. Starts a backend on port 8000 if none is answering there. When a language model is available (`LLM_BASE_URL` or `LLM_API_KEY` set in the environment or in `thread-backend/backend/.env`, or a vLLM server answering at the default address) it is the real one. Otherwise it is a stand-in that matches faces for real and answers the language tasks from fixed rules.
6. Starts the app with Meta's simulated Ray-Ban Meta glasses in place of real ones.

### What you will see

The simulated phone in a window, with Thread open on Meet. Xcode 27 shows it in an app called Device Hub; earlier versions call it Simulator. The first time, Thread shows its welcome screen; tap **Continue**, and when iOS asks whether Thread may use speech recognition, choose Allow.

- Open **Glasses** and tap **Connect**. The line under the name changes to Connected.
- Open **Meet** and tap **Meet**. The photo comes from the simulated glasses, whose camera sees a public-domain portrait. On an empty database the face is added as a new contact. After that it is recognised.
- The result says where its photo came from, under the card: "photo from the glasses camera".

### The simulated glasses' controls

In a run started this way, and only then, the Glasses tab has a **Simulated Glasses** section. Its buttons are what a hand would do to a real pair.

| Control | What it does |
| --- | --- |
| State | Says whether the glasses are worn, not worn or folded |
| Press the Capture Button | Starts Meet, or stops it listening, while Buttons Start Meet is on |
| Double-Tap the Temple | The same as the capture button |
| Tap the Temple | Pauses the glasses. A second tap resumes them |
| Press and Hold the Temple | Ends the session. Tap Connect to start again |
| Take Off, Put On | Glasses that are taken off keep a session they already have, but cannot start one |
| Fold, Unfold | Folding ends the session. Unfold them and put them on before connecting again |

The four button and temple controls do nothing without a session, so they are greyed out until the glasses are connected.

### What it cannot do

- The simulated glasses send no microphone audio. With Listen Through Glasses on, the app waits for it, gives up, and carries on with the camera alone.
- Meet cannot hear. The simulated phone opens this Mac's microphone, but Apple's speech recognition does not start in the Simulator: its speech model is a download the Simulator does not have, and turning on Dictation there does not change that. Every Meet says so ("Speech recognition doesn't run in the Simulator"). On an iPhone the model is there. To give Meet words, type them first: open Meet's More menu (the … button), choose **Listen Only**, tap the keyboard button, type what was said and tap Use. The next Meet uses that text.
- There is no iPhone camera in the Simulator. With Always Use iPhone Camera on, Meet gets no photo.
- The simulated glasses have no display, so nothing is sent to a lens.

While Thread is open in the Simulator it holds this Mac's microphone open, as it does a phone's.

### Stopping it

The script prints the two commands when it finishes: `xcrun simctl shutdown` with the device's identifier, and `lsof -ti tcp:8000 | xargs kill` for a backend it started. What the app logs is in `build/mock/app.log`. The files the script uses are described in [scripts/simulated/README.md](scripts/simulated/README.md).
