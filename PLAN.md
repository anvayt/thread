# Plan and status

Status as of 21 November 2026. Checked boxes are finished; unchecked boxes are still open.

## 1. Backend — done

- [x] Python service (FastAPI, SQLite, an OpenAI-compatible client for NVIDIA Nemotron, OpenCV face matching) in `thread-backend/backend/server/`
- [x] Tests in `thread-backend/backend/tests/`: 82 pass, 2 are skipped until local face photos are added
- [x] API shape: `POST /api/<name>`, answering `{"ok": true, "data": {...}}` or `{"ok": false, "error": "..."}`
- [x] The iOS app, the dashboard and `demo.sh` all use that API
- [x] Landing page is one static HTML page with no build step
- [x] `README.md`, `PRIVACY.md` and `OVERVIEW.md` describe what the code actually does
- [x] Browsers always re-check the dashboard instead of showing a saved copy
- [x] The app defaults to a backend at `http://localhost:8000`

## 2. Name and identity — done

- [x] Product name Thread in page titles and on-screen text
- [x] Xcode project, target and scheme: `Thread.xcodeproj`
- [x] Bundle ID `com.threadglasses.app`, URL scheme `threadglasses://`, `Thread.entitlements`
- [x] Backend folder: `thread-backend/`
- [x] The look-up-a-person feature is named "lookup" everywhere: `/api/lookup`, `LookupCard`, "Looking up…"
- [x] Wordmark and icon, as SVG and PNG, in `thread-backend/assets/`, specified in `BRAND.md`
- [x] No signing team is stored in the project

## 3. Glasses without a display — done, run on real glasses

The app is written for Meta Ray-Ban Display glasses, but it also has to work with Meta glasses that have no screen.

- [x] Connect to Meta glasses without a display (for example Ray-Ban Meta Wayfarer) as well as display models
- [x] Skip the lens step on those glasses and say so in the Glasses and Meet screens, rather than reporting failed sends
- [x] README, overview and the in-app guide (How Thread Works) cover both kinds of glasses
- [x] The app compiles with the change
- [x] Meta SDK upgraded from 0.8.0 to 1.1.0; it needs glasses software V130 or later and Meta AI app V292 or later
- [x] The camera keeps streaming over Bluetooth Classic, the only connection a free Apple Account can use for it (see the note in `project.yml`)
- [x] Try it on real glasses: photo from the glasses camera, and the spoken line through the glasses speakers

### Listening through the glasses — done, run on real glasses

- [x] Switch in Glasses (Listen Through Glasses), off by default: also transcribe what the glasses' microphones hear, and use whichever transcript has more words
- [x] If the glasses refuse or end a stream that carries audio, or it never starts, the camera carries on without it and Glasses says why. Checked with the simulated glasses, which do not send audio
- [ ] On real glasses, check that Glasses → Diagnostics reports audio arriving ("Last capture: … s of audio from the glasses"). It may not over Bluetooth Classic; a public report of it working used Wi-Fi, which needs a paid Apple Developer account
- [ ] On real glasses, check the spoken line still plays with the switch on. One developer reported that sound to the glasses stops while a stream carries audio

### Starting from the glasses — done, run on real glasses

- [x] Switch in Glasses (Buttons Start Meet), on by default: the capture button or a double tap on the temple starts Meet, and another press ends its listening. Uses the SDK's Inputs capability. Checked with the simulated glasses, including after a pause and a resume
- [x] A single tap on the temple is no longer treated as Meet; it pauses the glasses, as Meta intends
- [x] Meet pressed on the phone while the glasses are paused resumes them for that capture, instead of falling back to the iPhone camera. Checked with the simulated glasses
- [x] The phone is kept awake while that switch is on and the glasses are connected
- [x] Listening ends only on a press by default (Done, the capture button or a double tap), never on quiet; the old stop-after-quiet behaviour is an option in Meet's More menu
- [x] Cards are spoken in the most natural English voice on the phone, and the voice can be chosen and previewed in Glasses › Voice
- [x] Your Name (Glasses › You) goes with every conversation, and the backend never files the wearer as the contact; known names are given to both recognisers as hints
- [x] Include the Moment Before (Glasses › Listening, off by default): the last 5 or 10 s of the phone's microphone, kept in memory only, go in front of the next Meet
- [x] Found why the glasses' microphone audio transcribed to nothing: only one on-device recogniser runs at a time, so the phone's stopped the glasses' 0.09 s in. The kept copy is transcribed once the turn ends (8.4 s in 0.4 s, 11 words on real glasses)
- [x] The backend's language tasks use NVIDIA Nemotron (merged from its own branch), run on a real vLLM server
- [ ] Rebuild each conversation as you/them from both microphones with Nemotron, and file each person's part under them
- [x] On real Ray-Ban Meta (Gen 2) glasses: registration through Developer Mode, a session once the glasses are worn, a photo from the glasses camera, on-device speech recognition on the phone, a new face added, and the capture button starting and ending Meet
- [x] A session the glasses end is shown as not connected, instead of staying "connected"
- [ ] On real glasses, check the capture button and a double tap start Meet (Glasses → Diagnostics then shows which one, and "started Meet"), and whether a press of the capture button also takes the glasses' own photo
- [ ] Make it work with the phone locked. That needs the camera stream's background video format (`hvc1`) and a check that photos still arrive with it

## 4. What has been checked, and what has not

- [x] Backend tests: 82 passed, 2 skipped
- [x] iOS app compiles for the simulator and for a device as `Thread.xcodeproj`
- [x] The app, the dashboard and `demo.sh` only call endpoints the backend defines
- [x] Dashboard and landing page open in a browser and load only local data
- [x] Face matching works on sample images
- [ ] Anything that uses the language model against a real Nemotron endpoint (needs NVIDIA's hosted API key or a vLLM server; see below). The tests check the requests against a stand-in server.
- [x] The app runs in the iOS Simulator with Meta's simulated glasses: connecting, a photo from the "glasses", a new face and a known face against the backend (with a scripted stand-in for the language model), and starting Meet from a tap
- [x] One command, `scripts/simulate.sh`, runs the app in a Simulator window with the simulated glasses, and the Glasses tab has controls for them: tap the temple, press and hold, put on, take off, fold, unfold. Checked by working the on-screen controls: connecting, Meet with a photo from the "glasses", Meet started by a tap, and a session ended by folding
- [ ] Listening. In the Simulator the app opens the Mac's microphone, but Apple's speech recognition does not start there (its speech model is not in the Simulator, and the app now says so), so Meet has still not heard anything anywhere. That needs an iPhone. Typed text stands in for it
- [ ] The spoken line. It is played in the Simulator, through the Mac, and nobody has yet confirmed hearing it
- [ ] The app on a real phone
- [x] Pairing with real glasses

## 5. Still to do

- [ ] Add an NVIDIA API key (from https://build.nvidia.com): copy `thread-backend/backend/.env.example` to `.env` in the same folder and set `LLM_BASE_URL=https://integrate.api.nvidia.com/v1` and `LLM_API_KEY`; or run your own vLLM server (see `thread-backend/README.md`)
- [ ] Choose a signing team in Xcode (Thread target → Signing & Capabilities → Team). A free Apple Account works as a Personal Team; the app then has to be rebuilt onto the phone every 7 days.
- [x] The bundle ID is `com.threadglasses.app`; plainer IDs such as `com.callback.app` were already registered by someone else
- [ ] Update the glasses software to V130 or later and the Meta AI app to V292 or later (Meta AI app → Devices → gear → General → About → Version)
- [ ] Register the app with the Meta AI app
- [ ] Run the app on a phone, enter the server's "From a phone" address in Glasses → Backend, and try it with the glasses
- [ ] Check the name "Thread" against the App Store and trademarks before using it publicly (a US App Store search on 21 November 2026 returned 14 apps with Thread in the name, none named just "Thread"; trademarks have not been checked)
- [ ] Optional: add two face photos as `thread-backend/backend/testdata/local/enroll.jpg` and `probe.jpg` to turn on the 2 skipped tests

## 6. Optional cleanup — done

- [x] Colour and font names in the Swift code start with `app` (`Color.appAccent`, `Font.appBody`)
- [x] The style used by every screen is named `screenChrome()` instead of `lookupScreen()`
- [x] How Thread Works describes a capture the way the code runs it: the microphone opens first and the turn stops on silence (3 to 45 seconds)
- [x] The app's unused client method for `/api/caption` is removed; the backend endpoint stays, and live captions on the lens are not built
- [x] The backend README's list of error codes includes 404 and 405
- [x] The app has an icon set, `Sources/Assets.xcassets`, drawn from `thread-backend/assets/thread-icon-ios.svg`
- [x] The project is under git

## 7. Look

The app, the dashboard and the landing page all read as generated. `PRODUCT.md` records who they are for and what they should look like instead.

- [x] The iPhone app uses the system's own look: lists, system controls, colours and type, in light and dark. The only branding is the name, in the system font, and the app icon. Checked in the Simulator
- [x] The iPhone app is rebuilt for iOS 26 and Liquid Glass, and the minimum is now iOS 26. Four tabs: Meet, People, Glasses and Search, which opens its field in the tab bar. Manual's two tools moved into Meet's More menu as Photo Only and Listen Only; Connect became Glasses, set like the AirPods page in Settings, with Backend and Diagnostics a level down; the guide became How Thread Works inside Glasses. Meet's button floats in glass with Speak and Keep Going beside it, listening shows a level meter and a clock, and a result is set like a contact. People is an A to Z list like Contacts, with swipe and touch-and-hold actions, and a person's page has Rename and Share in glass. A welcome sheet comes before the permission prompts. A running Meet shows above the tab bar on the other tabs (iOS 26.1). Buttons, menus, switches and titles are in title case. Checked in the Simulator in light and dark, with the simulated glasses: welcome, every tab, a person's page, Backend, How Thread Works, Listen Only, a Meet pass that added a face and one that recognised it, a pass with no photo, Keep Going from another tab, Photo Only, and a question in Search
- [ ] Check the new screens on a phone
- [x] The web dashboard is laid out like an Apple app with a canvas (Maps, Freeform): the graph fills the window, and the sidebar, the toolbar buttons, the ask field and the sheets float over it in glass. A person opens as a second page of the sidebar. System font and colours, light and dark. Checked in a browser at desktop width in both appearances
- [x] On a phone the dashboard is laid out like Find My: the graph fills the screen and the people are a sheet at the bottom that is pulled up to three heights. Choosing a person opens them in the sheet and centres them on the graph. The ask field moves to the top. The wide layout is unchanged. Checked in a browser at phone size with simulated touches, not on a phone
- [x] The landing page is set like an Apple product page: the system font, the line you hear as the first picture, the app's Meet screen redrawn as three phone screens, the map drawn as the dashboard draws it, and privacy as a grouped list. Light and dark. No fonts loaded and no script. Checked in one browser at desktop and phone width
