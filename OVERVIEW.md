# Thread: what this repo does

This document describes what the iOS app in this repo actually does, based on a full read of the source. Where the in-app guide (Glasses → How Thread Works) says something different from the code, the code is what is described here, and the differences are listed in [Where the docs and the code disagree](#where-the-docs-and-the-code-disagree).

The app has been run in the iOS Simulator with Meta's simulated glasses (see [Running with simulated glasses](#running-with-simulated-glasses)). It has also been run on an iPhone 16 Pro with real Ray-Ban Meta glasses (Gen 2, no display). The backend it talks to lives in `thread-backend/` and is documented in [its own README](thread-backend/README.md); its endpoints have been exercised with tests and over HTTP.

## In one paragraph

This is an iOS app (SwiftUI, iOS 26+, about 7,000 lines of Swift) that acts as the phone-side companion for Meta glasses: Meta Ray-Ban Display, or Meta glasses without a display such as Ray-Ban Meta. When you tap **Meet**, it grabs one still photo (from the glasses camera, or the iPhone's rear camera as a fallback), transcribes what the other person says using Apple's speech recognition on the phone, and sends the photo and the transcript text to a backend that you run on your own computer. The backend decides whether the face is someone you have met. If it is, the app shows a lookup card (who they are, what to say next) in three places: on the glasses lens (when the glasses have a display), spoken through text-to-speech, and in the app. If it is not, the app enrolls the face on the spot, named from the conversation if a name was said, or as "New contact NN" otherwise.

The app holds no recognition or language logic of its own. Face matching, name and topic extraction, and question answering all happen on the backend.

## Names you will see

The product is called **Thread** in the UI and in the Xcode project, target and bundle ID (`com.threadglasses.app`). The URL scheme is `threadglasses://`.

## The pieces

| Piece | Where it lives | Role |
| --- | --- | --- |
| iPhone app | this repo (`Sources/`) | Captures, transcribes, calls the backend, renders results |
| Meta glasses | via Meta Wearables DAT SDK 1.1.0 | Camera in, and optionally microphone audio in. On Meta Ray-Ban Display only: lens cards out, Neural Band pinch to press lens buttons |
| Backend | `thread-backend/` (Python); the app's default address is `http://localhost:8000` | Face matching, transcript extraction, storage, search |
| Apple speech recognition | `SFSpeechRecognizer` on the phone | Turns microphone audio into text |

The glasses are optional. With none connected, the whole flow runs on the iPhone camera and the phone's speaker.

## What happens at launch

1. `Wearables.configure()` initialises the Meta SDK. A failure is stored and shown in Glasses → Diagnostics rather than swallowed.
2. The app subscribes to the SDK's registration state so the Glasses tab can show it.
3. One shared `AVAudioSession` is activated (`.playAndRecord`, speaker output, Bluetooth allowed) and left active for the life of the app.
4. Speech-recognition and microphone permissions are requested.
5. The audio engine starts and a permanent microphone tap is installed. The engine keeps running from then on, but audio is only passed to the speech recogniser while a capture is in progress.
6. The app opens on the **Meet** tab.

## The Meet loop (the main feature)

Implemented in `MeetEngine` in `Sources/MeetView.swift`. One tap runs the following.

1. **Photo starts in the background.** `GlassesManager.capturePhoto()` returns a frame, which is encoded as JPEG at 0.7 quality.
2. **Early recognition.** As soon as the frame arrives it is posted to `/api/recognize`. If the backend reports a match, the app immediately fetches that person's lookup card (`/api/lookup`), shows it on the lens, speaks the first line, and adds a card in the app. This happens once per person per app launch. The engine remembers that it did so for the pass in flight (`earlyResult`).
3. **Listening runs at the same time.** The microphone turn opens straight away and does not wait for the photo. By default it ends when you press Meet (shown as Done) or the glasses' capture button again (see [How a turn ends](#how-a-turn-ends)).
4. **Decide who it is.** After the turn ends, the app takes one of three branches.

**Branch A: the face matched a known person.**
- The transcript is posted to `/api/ingest` with `speaker` set to the matched name, so the conversation attaches to that person instead of creating a duplicate.
- If the backend reports a job title the app did not already have, the app re-posts the frame to `/api/enroll` with the role and org. (The backend already stores a title itself when the person had none, so this second call is a safeguard.)
- The app fetches the lookup card, then shows it on the lens, speaks it, and adds a result card. Follow-ups are appended to the lens card as "You owe them: …" or "They owe you: …", read from their wording the same way the backend reads it.
- If early recognition already announced this person during this pass, none of that is repeated: the result card it added is replaced, in place, by the finished one (transcript, topics, follow-ups), and nothing is spoken or sent to the lens a second time. The follow-ups are then in the app only, not on the lens.

**Branch A2: the face matched an auto-named placeholder ("New contact 03").**
- The transcript is ingested without a `speaker` first, to give the backend a chance to extract a real name.
- If a real name comes back, the app re-enrolls the same frame under the real name, calls `/api/forget` on the placeholder, and moves the cached photo to the new name. The result is announced as "New contact 03 is really Dana". That is spoken and shown on the lens even when early recognition announced the placeholder, because the name is new; the early result card is still replaced, not added to.
- If no name comes back, the transcript is ingested a second time pinned to the placeholder.

**Branch B: no match (a new face).**
- The transcript is ingested first so the conversation can supply a name.
- The name is the extracted real name if there is one; otherwise the next placeholder, "New contact 01", "02", and so on.
- The same frame is posted to `/api/enroll` under that name. Placeholders are enrolled with relationship "just met".
- If the backend says there was no face in the frame, the app shows guidance ("get a little closer") rather than an error. The transcript has already been ingested by this point.
- Otherwise the lens shows a "new contact" or "face linked" card, the app speaks a confirmation, and a result card is added.

**Branch C: no photo at all** (camera permission denied, or no camera returned a frame).
- The transcript is still ingested. The app says plainly that the face was not captured.

If the backend cannot be reached, the app shows a failure card and puts "Backend unreachable — check Connect." on the lens.

**Keep Going** (auto-repeat, the button to the right of Meet) re-runs this loop with a 4-second pause between passes until switched off.

### How a turn ends

Chosen under **Stop Listening** in Meet's More menu and kept in `UserDefaults` (`stopAfterQuiet`; 0 means on a press). The numbers are in `TurnTiming` in `Sources/DictationManager.swift`, and the loop checks every 0.1 s.

**When I Press Again** (the default). Quiet never ends the turn. It ends when you tap Done (the Meet button while listening) or press the glasses' capture button or double-tap the temple, and in any case after 180 s.

**After 1.5 to 3.0 seconds of quiet.** The turn ends on the first of these:

| Condition | Value |
| --- | --- |
| Quiet after speech was heard, and at least 3 s have passed | the chosen 1.5 to 3.0 s |
| Nobody spoke at all | 9 s |
| Hard ceiling | 45 s |
| Done, or a press on the glasses | immediately |

"Speech" means either the input level exceeds an adaptive gate (the larger of 0.075 or 2.5 times the measured room noise), or new words arrive from the recogniser. After the turn ends the app waits 0.7 s for final words, then freezes the transcript so the text on screen is exactly the text that gets posted.

### Speech recognition details

- Locale is fixed to `en-US`.
- On-device recognition is used when the device supports it. If the on-device task fails before producing anything, the app retries once using Apple's network recogniser.
- Apple drops a recognition task after about a minute, so the app starts a fresh one at 50 s and carries the text across.
- While text-to-speech is talking, microphone buffers are dropped so the app does not transcribe its own voice.
- Cards are spoken with `AVSpeechSynthesizer` in the most natural English voice on the phone (Premium, then Enhanced, then Standard, the phone's own variety of English first) at the default rate, or the voice chosen in Glasses › Voice (`UserDefaults` `speechVoiceIdentifier`). Premium voices are a download in the Settings app.
- Audio input is deliberately pinned to the **phone's built-in microphone**, not the glasses' Bluetooth headset microphone. The code comment explains that taking the headset mic drops the route to 8 kHz and hurts recognition. Meta's documentation adds that the headset mic is tuned to the wearer's own voice and turns other speakers down. Audio output can still route to the glasses speakers.

### Listening through the glasses as well (experimental)

Off by default; the switch is **Listen Through Glasses** in the Glasses tab. It has been run on real glasses.

- With it on, the camera stream is opened with audio (16 kHz mono), which is a separate path from the Bluetooth headset microphone and is not narrowed to the wearer's voice. The glasses must first grant their own microphone permission in the Meta AI app, which the app asks for while connecting.
- `GlassesEar` feeds that audio to a second speech recogniser while the phone's microphone is transcribed as usual. iOS records from one input at a time, so this is the only way to have both.
- New words from the glasses keep a turn open, like new words from the phone.
- When the turn ends, Meet uses the transcript with more words; a tie goes to the phone. The result card says which microphone it came from, and Glasses → Diagnostics reports how much audio the glasses sent on the last capture.
- If the glasses refuse the permission, or end a stream that carried audio, the camera is reopened without audio and the switch's status line says why.
- The camera stream stays open between captures, so with the switch on the glasses keep sending audio to the phone until they are disconnected. The phone discards it outside a turn.

What is not known, because it needs glasses to find out:

- Whether the audio arrives at all over Bluetooth Classic, which is how this app streams (see [Taking a photo](#taking-a-photo)). A public report of it working on Ray-Ban Meta Gen 2 used the Wi-Fi stream.
- Whether the spoken line still plays in the glasses. A developer on the same glasses reported that sound to the glasses stops about a second after a stream with audio starts.
- Whether iOS runs two speech recognisers at once on a given phone.

## The glasses integration

Implemented in `Sources/GlassesManager.swift` (session, camera) and `Sources/LensCards.swift` (display).

### Connecting

Tapping **Connect** in the Glasses tab does the following, reporting each step in the status text (the full text is in Glasses → Diagnostics):

1. Registers the app through the Meta AI app if it is not registered yet. The return trip comes back through the `threadglasses://` URL scheme.
2. Checks and, if needed, requests the glasses camera permission. With "Also listen through the glasses" on, it does the same for the glasses microphone permission; a refusal there only turns that switch's feature off.
3. Inspects each visible device. It stops with a specific message if the glasses need a firmware update (and opens the update screen), the SDK is too old, or the glasses are paired but disconnected.
4. Checks whether any visible glasses have a display. If so it selects only display-capable glasses; if not it accepts any glasses.
5. Waits up to about 12 s for the selected glasses to become the active device.
6. Creates and starts one `DeviceSession`. On glasses with a display it then attaches the display capability, and lens cards are only sent once the display reports `.started`. On glasses without one it skips that step: the Lens panel reads "no display", nothing is sent to the lens, and cards are spoken and shown in the app.

The spoken line is ordinary phone audio. It plays through the glasses speakers when the glasses are the iPhone's Bluetooth audio output, and through the phone speaker otherwise. The no-display path has been run on real glasses.

**Reconnect Glasses** (in Glasses → Diagnostics) tears everything down and repeats this without restarting the app.

After connecting, the app keeps following the session's state. If the glasses stop the session (a long press on the temple, folding them, a lost connection), the app shows them as not connected and asks you to connect again.

### Starting a capture from the glasses

On by default; the switch is **Buttons Start Meet** in the Glasses tab. It uses the SDK's Inputs capability (`MWDATInputs`, `DeviceSession.addInputs`), which Meta offers to apps in development and beta release channels only; an app reached through Developer Mode in the Meta AI app is one. It works with Meta's simulated glasses, and has been run on real ones with the capture button.

- A short press of the capture button, a double tap on the temple (`select` from the touchpad) or the action button, on glasses that have one, runs the same pass as the Meet button. While Meet is listening, the same press ends the turn, as Done does.
- A double press of the capture button arrives as a short press and then a double press (a known issue in Meta's documentation), so a short press waits 0.45 s and the pair counts once. Holding the button counts as a press.
- A single tap on the temple pauses the session and a tap and hold ends it. The glasses keep those two for themselves and the app never receives them, so it treats them as the glasses intend.
- Capabilities in testing do not come back when a paused session resumes (another known issue), so the app adds Inputs again each time the session resumes.
- A refusal is shown under the switch, and the Meet button on the phone keeps working.
- With the switch off, a paused session stays paused until it is tapped again, and Glasses → Diagnostics says so. Pressing Meet on the phone while it is paused resumes it for that capture; if it does not resume within 3 s, the photo comes from the iPhone camera.
- While the switch is on and the glasses are connected, the phone is kept awake. The camera stream uses the raw video format, which the SDK pauses when the app is in the background, so a tap could not take a photo from a locked phone.
- Glasses → Diagnostics shows what the last pause led to.

### Taking a photo

1. If glasses are connected and "Always use the iPhone camera" is off, the app adds (or reuses) a camera on the session and uses its stream: raw codec, medium resolution, 15 fps. The stream runs over Bluetooth Classic, because `Info.plist` declares the `com.meta.ar.wearable` accessory protocol. The SDK's other transport, Wi-Fi, needs the Hotspot Configuration capability, which a free Apple Account cannot sign.
2. It waits up to 6 s for the stream to reach `.streaming`, then requests a JPEG photo and waits up to 8 s for it.
3. If any step fails or times out, it falls back to the iPhone's rear camera (`PhoneCameraFallback`), which keeps its capture session running between shots.

The app records which camera produced each frame and shows it on the result card.

### Lens cards

Each card is a single view that replaces the whole lens screen. Every card includes at least one button, because a Neural Band pinch can only press a button on the most recently sent view.

| Card | When | Content | Buttons | Auto-clears after |
| --- | --- | --- | --- | --- |
| Lookup | Known face | Name, role and org, one or two talking points | more / next, dismiss | 14 s |
| New face | Face just enrolled | Name, "new contact" or "face linked", one line | next, dismiss | 12 s |
| Guidance | No face in frame, no frame, backend error | "Try again" plus a reason | ok | 10 s |
| Note | Listen Only saved something; test card | One line | ok | 8 s |
| Detail page | After pressing more / next | One talking point per page, wraps around | next, dismiss | does not auto-clear |

Text is trimmed to fit: 48 characters for headings, 90 for body lines, 120 for guidance and notes.

The Neural Band cannot start a capture. The loop is started from the phone, left on Keep Going, or started by a tap on the temple when that switch is on.

## How it looks

The app uses the system's own lists, controls, type and colours, and follows the phone's light or dark appearance. Controls that float over content are Liquid Glass: the tab bar, the toolbar buttons, the Meet button and the two switches beside it, the actions under a person's name, and the buttons in sheets. Content itself is never glass. There is no palette or type scale of its own. The only branding is the app icon and the name, Thread, set in the system font. The wordmark artwork in `thread-backend/assets` is not shown on screen. `PRODUCT.md` records who the app is for and the principles the screens follow.

Screens follow the Apple app they resemble: Meet the way Camera sets controls around its shutter and Voice Memos shows a recording, People the way Contacts lists and shows people, Glasses the way Settings shows a pair of AirPods, and Search the way iOS 26 apps search from the tab bar.

## The tabs

| Tab | What it does |
| --- | --- |
| **Meet** | The one-tap loop above. The Meet button floats at the bottom in glass and, while the app is listening, becomes Done, which ends the turn. On its left, Speak turns the spoken card on or off; on its right, Keep Going repeats Meet until it is turned off. Above them: the live transcript, a level meter and the elapsed time while listening, then the latest result set like a contact (photo, name, role and company, what to say next, what is owed, what was heard), and earlier results as a list that opens each one. With nothing to show, the page says how to start, or that the microphone or camera is off, with Open Settings. The More menu holds Photo Only, Listen Only, Stop After Quiet (1.5 to 3 seconds) and Clear Results. |
| **Meet → Photo Only** | A sheet. Recognises the face in one photo and shows a lookup card, or auto-enrolls on a miss using whatever transcript is currently held from Listen Only. |
| **Meet → Listen Only** | A sheet. Press and hold to transcribe, release to stop, then tap Save to post the transcript to `/api/ingest`. A keyboard button lets you type or paste text instead. Shows a receipt of what the backend extracted (person, org, topics, follow-ups). |
| **Map** | The backend's network map (the page it serves at `/`), full screen: everyone you have met, joined by what you talked about. Tapping someone opens their card above the ask field; **Ask about the people you've met** at the bottom posts the question to `/api/query`, where Nemotron answers it as an agent (looking people up, their connections and promises over a few steps), and shows the answer, the people it is about and what it looked at, with those people and the links between them lit on the map. Three questions to try sit under the field while it is empty ("Who's hiring ML interns?", "Who do I owe a follow-up?", "Who should I introduce?"); a tap fills the field and sends it. A person's card has **Draft follow-up**, which shows the message Nemotron writes (`/api/followup`) with Copy and Write again. |
| **People** | Everyone in the graph (`/api/roster`, with duplicate names merged on the phone), A to Z with a section index, with a search field that filters by name, role or company, and anyone named automatically in a Needs a Name section at the top. Swipe a row to forget the person; touch and hold to rename or forget. The + button enrolls a person by hand with a name, role, company and a required photo. When it is empty it offers Add Person and Add Sample People. |
| **People → person** | Their photo or initials, name, and role and company at the top, with Rename, Share and Follow-Up in glass under them, then the backend's markdown card (`/api/person_card`) turned into list sections by a small built-in renderer, with History dates shown as dates. Follow-ups are listed under You Owe Them or They Owe You, by who promised them. Forget This Person is at the bottom. |
| **People → person → Follow-Up** | A sheet titled Draft Follow-Up (`FollowUpSheet`). It posts the name to `/api/followup` and shows "Nemotron is writing…" until the message arrives, then the message with Copy, Share and Write Again, or the error text with Try Again. Thread drafts the message and never sends it. The action is left out for a person with no name yet. |
| **Glasses** | The glasses at the top with Connect or Disconnect. Then, in a debug run with simulated glasses, the Simulated Glasses section described under [Running with simulated glasses](#running-with-simulated-glasses); the display, with a test card on glasses that have one; Buttons Start Meet and the experimental Listen Through Glasses; Always Use iPhone Camera; the microphone, speech recognition and camera permissions; Backend (the address, the password, kept in the Keychain, and a connection test); Diagnostics (Reconnect Glasses, the raw glasses, microphone and audio status, and the glasses' log); How Thread Works; and Show Welcome. |
| **Glasses → How Thread Works** | What the app does, in plain words, for career fairs and conferences, plus **Add Sample People** (`/api/seed`: five made-up recruiters and engineers from a career fair, each with a conversation, topics and a follow-up) and **Delete Everything** (`/api/reset`, which empties the whole backend after a confirmation). |

The first launch shows a welcome sheet. iOS asks for speech recognition and the microphone only after it is closed. Show Welcome in Glasses shows it again.

A Meet pass that is running while another tab is open, or Keep Going while it is on, shows as a bar above the tab bar with the time and Done or Stop (iOS 26.1 and later).

### Rename and forget

The backend has no rename endpoint. The app renames by posting the cached reference photo to `/api/enroll` under the new name and then calling `/api/forget` on the old one. A rename is therefore only possible on the phone that still holds the original photo.

Forget calls `/api/forget` and deletes the cached photo from the phone.

## Backend API as the app uses it

Every call is a JSON `POST` to `<base URL><path>` with no authentication header. The backend answers `{"ok": true, "data": {...}}` and the app reads the payload from `data`. A response with `"ok": false` is treated as an error and its `error` text is shown.

| Endpoint | Sends | Reads back | Called from |
| --- | --- | --- | --- |
| `/api/recognize` | `frame_b64` | `matched`, `name`, `role`, `org`, `spoken`, `score`, `elapsed_ms` | Meet, Photo Only |
| `/api/lookup` | `name` | `found`, `name`, `org`, `headline`, `lines`, `topics`, `followups`, `history` | Meet, Photo Only |
| `/api/ingest` | `transcript`, optional `speaker` | `saved`, `new_person`, `role` or `title`, `org` or `company`, `topics`, `new_topics`, `followups` | Meet, Photo Only, Listen Only |
| `/api/enroll` | `name`, `frame_b64`, `role`, `org`, `relationship`, `notes` | `enrolled`, `name`, `attached_to_existing`, `known_interactions`, `reason` | Meet, Photo Only, People |
| `/api/query` | `question` | `matches` (`name`, `org`, `last`), `reason`, `searched` | Search |
| `/api/roster` | nothing | `people` (`name`, `role`, `org`, `relationship`, `enrolled_face`, `encounters`) | People, Search, Glasses → Backend test |
| `/api/person_card` | `name` | `name`, `md` | Person page |
| `/api/followup` | `name` | `name`, `message` | Person page → Follow-Up |
| `/api/forget` | `name` | nothing | People, person page, rename, placeholder merge |
| `/api/seed`, `/api/reset` | nothing | nothing | How Thread Works, and People when it is empty (seed only) |
| `/api/timeline` | nothing | `events` | defined, never called |

Timeouts are 60 s by default, 90 s for Recognize, lookup and person_card, and 120 s for ingest, query, followup, Enroll, Seed and Reset.

The base URL is editable in Glasses → Backend and stored in `UserDefaults` under `backendBaseURL`. The default, `http://localhost:8000`, reaches a backend on the same machine only from the iOS Simulator; on an iPhone you enter the address the server prints when it starts.

## What is stored on the phone

| What | Where |
| --- | --- |
| The JPEG each person was enrolled or last matched with (used for avatars and for rename) | `Application Support/faces/<name-slug>.jpg` |
| Backend URL | `UserDefaults` `backendBaseURL` |
| "Always use the iPhone camera" toggle | `UserDefaults` `usePhoneCamera` |
| "Also listen through the glasses" toggle | `UserDefaults` `listenThroughGlasses` |
| "Buttons Start Meet" toggle (on unless switched off) | `UserDefaults` `glassesButtonsStartMeet` |
| Placeholder counter and the list of placeholder names | `UserDefaults` `autoEnrollCounter`, `placeholderNames` |

Session result cards and transcripts are held in memory only and are lost when the app quits. Everything else lives on the backend, in one database file (`thread-backend/backend/data/memory.db`).

## What leaves the phone

- **To the backend:** JPEG photos (base64), the full transcript text, names, roles, orgs, and typed questions.
- **To Apple:** microphone audio, only when on-device recognition is unsupported or has failed and the network recogniser is used. The same applies to audio from the glasses when "Also listen through the glasses" is on.
- **To the glasses:** lens card text, and text-to-speech audio when the glasses are the audio output.
- **From the glasses to the phone:** photos, and with "Also listen through the glasses" on, microphone audio for as long as the camera stream is open.
- Raw audio is never sent to the backend.
- **Kept on the phone:** with Include the Moment Before on (Glasses › Listening, off by default), the last 5 or 10 s of the phone's microphone are held in memory between turns, overwritten as they pass, and only transcribed when a Meet starts. A Meet that is not asked for them discards them. They are never written to disk. In a debug build, the glasses' audio from the last turn is kept as `Documents/glasses-last.wav` to diagnose glasses transcription; a release build deletes it straight after the second pass.
- **From the backend to the language model (NVIDIA Nemotron):** transcript text and the stored details of the person being written about, whenever the backend needs language written, which includes the last conversation with a person when a follow-up to them is drafted. With your own vLLM server this stays on that machine; with NVIDIA's hosted API it goes to NVIDIA. Photos and face signatures are not sent. See `thread-backend/PRIVACY.md`.

Things worth knowing before pointing this at real data:

- Backend requests carry no authentication, and App Transport Security is disabled (`NSAllowsArbitraryLoads`), so plain HTTP backends are allowed. Anyone on the same network as the backend can read and delete everything in it.
- **Delete Everything** in Glasses → How Thread Works empties whichever backend is configured.
- Full transcripts are written to the device console log (`print`).

## Where the docs and the code disagree

No differences are known. How Thread Works describes the Meet loop the way the code runs it (the microphone opens first, the photo is taken alongside, and by default the turn ends when you press again), and its privacy section says that the microphone is kept ready while the app is open, nothing is transcribed until a capture starts, and what Include the Moment Before keeps.

Not everything the app shows reaches the lens. The live transcript appears only in the phone app: the backend has a `caption` endpoint for a heads-up display, but the app does not call it. Questions are typed in Search and answered in the app; answers are not spoken or shown on the lens.

## Behaviours that look unintended

These are things the code does that a reader would probably not expect.

- **A new face costs two Recognize calls.** The early call discards a non-match, so the frame is posted again after the turn.
- **"next" on a new-face lens card pages through the previous person's talking points.** The pager state is only set by the lookup card, so it still holds the last looked-up person's lines and name.
- **A placeholder match with no name extracted ingests the transcript twice**, once unpinned and once pinned to the placeholder.

## What is not in the repo

- Tests for the app. (The backend has its own suite; see its README.)

`BRAND.md`, which a comment in `Theme.swift` refers to, is at `thread-backend/assets/BRAND.md`.

Unused code: `BackendAPI.timeline`, `DictationManager.record(seconds:)`, `DictationManager.shutdown`, `GlassesManager.releasePhoneCamera`, and the `capitalizedFirst` string helper.

## Source file map

| File | Lines | Contents |
| --- | --- | --- |
| `Sources/ThreadApp.swift` | 145 | App entry point, launch sequence, the tabs, the welcome sheet, the bar for a running Meet |
| `Sources/MeetView.swift` | 1,404 | `MeetEngine` (the loop and its branches) and the Meet screen, its results and its bar for other tabs |
| `Sources/DictationManager.swift` | 758 | Speech-to-text, turn-end detection, transcript bookkeeping |
| `Sources/GlassesManager.swift` | 833 | Meta SDK registration, session and its pauses (tap to start), camera stream with optional audio, photo capture with phone fallback |
| `Sources/GlassesEar.swift` | 171 | Transcribes audio from the glasses' microphones during a Meet turn |
| `Sources/LensCards.swift` | 331 | `LensCards`: every card sent to the glasses display |
| `Sources/BackendAPI.swift` | 580 | Backend client and response models |
| `Sources/PeopleView.swift` | 788 | People list, person page, the follow-up draft, rename, manual enroll |
| `Sources/MapView.swift` | 173 | Map: the backend's network page in a web view |
| `Sources/CaptureView.swift` | 273 | Photo Only: single-shot capture and auto-enroll |
| `Sources/ListenView.swift` | 229 | Listen Only: press-and-hold transcription and ingest |
| `Sources/GlassesView.swift` | 384 | The glasses, settings and permissions, Backend and Diagnostics |
| `Sources/GuideView.swift` | 199 | The welcome sheet, How Thread Works, sample people and Delete Everything |
| `Sources/AudioSessionController.swift` | 176 | The single shared audio session and route handling |
| `Sources/FaceCache.swift` | 133 | On-phone photo cache and placeholder-name rules |
| `Sources/PhoneCameraFallback.swift` | 89 | iPhone rear-camera capture |
| `Sources/SpeechManager.swift` | 69 | Text-to-speech |
| `Sources/MarkdownText.swift` | 111 | Turns the backend's page about a person into list sections |
| `Sources/Theme.swift` | 213 | The pieces several screens share: person rows and headers, glass header actions, the level meter |
| `Sources/SimulatedGlasses.swift` | 232 | Debug builds only: Meta's simulated glasses, for running the app with no hardware, and their controls in the Glasses tab |
| `Sources/Assets.xcassets` | | The app icon, drawn from `thread-backend/assets/thread-icon-ios.svg` |
| `project.yml` | | XcodeGen spec that generates `Thread.xcodeproj` and `Info.plist` |
| `scripts/simulate.sh` | | Runs the app in the iOS Simulator with the simulated glasses, in one command |
| `scripts/simulated/` | | What that run needs: the portrait the simulated camera sees, the script that makes its video clip, and a backend with fixed rules in place of the language model |

## Build and requirements

```bash
brew install xcodegen
xcodegen generate
open Thread.xcodeproj
```

- iOS 26+, iPhone only, portrait only, Swift 5.9. iOS 26 is needed for Liquid Glass; the bar that shows a running Meet above the tab bar on other tabs needs 26.1 and is left out on 26.0.
- One dependency: `meta-wearables-dat-ios` pinned to exactly 1.1.0 (products `MWDATCore`, `MWDATCamera`, `MWDATDisplay`, and `MWDATMockDevice` for the simulated glasses). That version needs glasses software V130 or later and Meta AI app V292 or later.
- No signing team is set. Choose yours in Xcode (target → Signing & Capabilities) or put its ID in `DEVELOPMENT_TEAM` in `project.yml`.
- `MetaAppID` is `"0"` and `ClientToken` is empty, which only works with Developer Mode enabled on the glasses in the Meta AI app.
- The backend must be running and reachable; see [README.md](README.md).
- To use the glasses: Meta Ray-Ban Display, or Meta glasses without a display (Ray-Ban Meta Gen 1 and Gen 2 are both supported by the SDK), paired through the Meta AI app, Developer Mode on.

### Running with simulated glasses

A debug build launched with `-mockGlasses YES` uses Meta's Mock Device Kit in place of real glasses: registration, permissions, a pair of Ray-Ban Meta glasses, their camera and their touchpad. None of that code is compiled into a release build.

`scripts/simulate.sh` does all of it in one command. It finds or creates the simulator device "Thread Test", boots it and opens its window, builds and installs the Debug app, allows the microphone and the camera, starts a backend on port 8000 if none is answering, and launches the app. The backend is the real one when a language model is available (`LLM_BASE_URL` or `LLM_API_KEY` set, or a vLLM server answering at the default address), and otherwise `scripts/simulated/backend.py`, which is the real server with fixed rules in place of the language model. `README.md` has the steps as a person follows them.

The glasses are then worked in one of two ways, which run the same code:

- **By hand.** The Glasses tab gains a Simulated Glasses section (`SimulatedGlassesSection`): a State row that reads Worn, Not worn or Folded, and the buttons Tap the Temple, Press and Hold the Temple, Take Off or Put On, and Fold or Unfold. The kit cannot be asked what state the glasses are in, so the row shows what they were last told.
- **By a script.** Each line appended to the file named by `-mockCommands` is run once (connect, tap, meet, say and so on). `Sources/SimulatedGlasses.swift` lists the commands and the launch arguments.

What the simulated glasses were seen to do:

| Action | Effect |
| --- | --- |
| A press of the capture button, or a double tap on the temple | With Buttons Start Meet on, Meet starts, and a second press ends its listening. Still works after a pause and a resume |
| A tap on the temple | The session pauses, and a second tap resumes it |
| A press and hold on the temple | The session ends |
| Folding | The session ends. The glasses will not connect again until they are unfolded and put on |
| Taking off | A session that is running carries on and still takes photos. A new one will not start ("Device unavailable") |

Checked through the commands file: connecting, a photo from the "glasses", a new face and a known face against the backend, a pause and a resume, and starting Meet from a tap. Checked again by working the on-screen controls: connecting, Meet with a known face, starting Meet from a tap, a pause and a resume, and a session ended by a press and hold and by folding.

What a simulated run cannot show:

- The simulated glasses do not send microphone audio, so "Also listen through the glasses" cannot be checked this way; with it on, the simulated stream times out and the app falls back to a stream without audio, which is the fallback working.
- Listening. With the Simulator's window open the simulated phone uses the Mac's microphone and speakers, and the app's audio engine starts. Apple's speech recognition does not: the on-device attempt and the retry over the network both fail with the same error from the on-device recogniser (`kLSRErrorDomain` 300, "Failed to initialize recognizer"), because its speech model is a download the Simulator does not have. Meet hears nothing and says that speech recognition doesn't run in the Simulator. Text typed in Meet's More menu → Listen Only is used by the next Meet instead.
- `simctl` can allow the microphone and the camera, but not speech recognition. iOS asks for that the first time the app starts.

The launch argument `-noAudio YES` skips the microphone, its permission prompts and the spoken line. It is for a simulator with no audio hardware, where the app aborts when it opens the microphone. That was seen on a simulator booted with no Simulator app running. `scripts/simulate.sh` opens the window first and only passes the argument if the app stops as it starts.
