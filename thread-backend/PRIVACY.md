# Thread: privacy notes

Thread listens to conversations and remembers people. This page says plainly
what the server stores, what leaves the machine it runs on, and what it does
not protect against. Each point describes what the code does today.

## 1. Faces are matched on your machine

A face is turned into a signature (128 numbers) by models that run locally.
Matching is a comparison against the people you have enrolled, not a lookup in
any outside face database. No image and no signature is ever sent to a
language model or any other service.

The signature of a frame you are only *recognising* is used once and dropped.
The signature of a person you *enrol* is stored with their record in the
database, and is deleted with them.

## 2. Recognition frames are dropped; the enrolment photo is kept

A frame sent for recognition is used for that one request and never written to
the database, to logs, or to disk. The one exception is deliberate: the frame
you enrol someone from is stored with their record as a small thumbnail (320
pixels on its longest edge) so a face can be shown beside a name. That is a
stored photograph of a person, and `forget` deletes it with them.

The iPhone app separately keeps its own copy of each enrolment photo on the
phone.

## 3. Only people you have added can be recognised

Recognition compares against people already in *your* database. Someone who is
not in it produces no name; the server cannot identify strangers.

Be aware of how people get added, though: when the iPhone app captures a face
it does not recognise, it enrols that face on the spot, under a name from the
conversation if one was said, or as "New contact 01" otherwise. Every capture
of a new face therefore creates a stored record with a photo.

## 4. Text is sent to a language model

Recognising a face is local. Writing about a person may not be. The server
sends text to the language model at `LLM_BASE_URL` when it needs language:

| When | What is sent |
|---|---|
| Filing a conversation (`ingest`) | The full transcript |
| Cleaning a caption (`caption`) | The caption text |
| Writing the spoken line after a match | That person's name, role, organisation, your notes on them, and summaries of recent interactions |
| Building a lookup card | That person's name, organisation, interests, your promises to them, and recent interaction summaries |
| Answering a question (`query`) | The question, and one line per person you know: name, role, organisation, interests, topics, last interaction |

Photos and face signatures are never part of this. If nothing answers at that
address, or NVIDIA's hosted API is chosen without a key, nothing is sent and
those features report an error instead.

Where the text goes depends on that setting:

- **Your own vLLM server** (the default, `http://127.0.0.1:8001/v1`). The text
  goes to a model running on the same machine as the server. If you point
  `LLM_BASE_URL` at a vLLM server elsewhere, it goes to that machine. A rented machine, such as an NVIDIA Brev instance, is
  covered by its provider's terms. Start vLLM with `--host 127.0.0.1` when it
  runs beside the server; otherwise anyone who can reach its port can use it.
- **NVIDIA's hosted API** (`https://integrate.api.nvidia.com/v1`). The text is
  sent to NVIDIA. The trial service is covered by NVIDIA's API Trial Terms of
  Service; read them for what NVIDIA keeps and how it may use what is sent
  before sending real conversations there.

## 5. Transcripts are kept alongside their summaries

Every filed transcript is summarised into name, organisation, interests,
promises and topics, and the cards and answers are built from that summary.

The raw transcript is **also** kept, in plain text, with the interaction it
came from. Anyone who can read the database file can read it word for word, so
treat the database as holding real conversations, not just summaries.

## 6. Forget is one call

`POST /api/forget {"name": "..."}` removes a person together with their photo,
face signature, interactions, transcripts and topics. `POST /api/reset` removes
everyone.

## 7. No login, no encryption — a single-user tool on a trusted network

There is one database and no authentication on any endpoint. By default the
server listens on every network interface so the phone can reach it, which
means **anyone on the same network can read every contact, photo and
transcript, and can delete them**. Run it only on a network you trust, or set
`HOST=127.0.0.1` to make it reachable from this machine alone.

The database file is not encrypted. Separate accounts, login, and encryption at
rest do not exist. They are the first things that would need building before
this is used with real people's conversations.

## 8. Capture starts with you

The phone app captures when you press Meet, the capture button on the
glasses, or double-tap the temple ("Buttons Start Meet", on by default). It
keeps the microphone ready while it is open, but nothing is transcribed before
a capture starts. Note that the app's "Keep going" switch repeats the capture
every few seconds until you turn it off, so with it on, the app keeps
photographing and listening.

Two optional switches in the app, both off by default, change this.
"Include the Moment Before" keeps the last 5 or 10 seconds the iPhone's
microphone heard, in memory only, overwritten as they pass; they are
transcribed only when a capture starts and are never written to disk or sent
otherwise. "Listen Through Glasses" has the glasses send microphone audio to
the phone for as long as their camera stream is open; the phone transcribes it
only during a capture and discards the rest.

## 9. The dashboard loads one file from the internet

`web/index.html` fetches its charting library from the jsDelivr CDN. That
service sees the address of the machine viewing the dashboard. No data from
your database is sent to it. Nothing else is loaded: the dashboard uses the
system's own font.

## 10. No profiling

A card contains what you were told, by the person who told you. Nothing is
inferred about a person's character, nothing is looked up about them
elsewhere, and people are not scored.
