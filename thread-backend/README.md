# Thread backend

**your network, remembered.** A memory for the people you meet: you meet a
dozen people in an hour and forget most of it — names, who they work for, what
you promised to send. Thread listens, remembers, and reminds you.

Speech becomes a record of who said what. A face becomes a lookup into it.

## What is in this folder

| Folder | What it is |
|---|---|
| `backend/` | The server. Python: recognises faces, files conversations, answers questions. |
| `web/` | A live dashboard (one HTML file) served by the server at `/`. |
| `landing/` | A static marketing page. Open `landing/index.html`; there is no build step. |
| `assets/` | Logo images and brand usage notes. |

The iPhone app that talks to this server lives in the parent folder. It is a
thin client: it moves pixels in and text out, and all the logic lives here.

## Running it

Needs [uv](https://docs.astral.sh/uv/) and, for anything that writes language,
NVIDIA Nemotron 3.5 Lightning 30B-A3B behind an OpenAI-compatible API. There
are two ways to have that; [PRIVACY.md](PRIVACY.md) says what leaves the
machine in each.

**Your own vLLM server** (the default). On a machine with an NVIDIA GPU, such
as an NVIDIA Brev instance:

```bash
vllm serve nvidia/NVIDIA-Nemotron-3.5-Lightning-30B-A3B-NVFP4 \
    --served-model-name nvidia/nemotron-3.5-lightning-30b-a3b \
    --enable-auto-tool-choice --tool-call-parser qwen3_coder \
    --host 127.0.0.1 --port 8001
```

vLLM's [serving recipe](https://recipes.vllm.ai/nvidia/NVIDIA-Nemotron-3.5-Lightning-30B-A3B-BF16)
lists the flags that suit each GPU, and the BF16 checkpoint; on one H100 the
NVFP4 checkpoint above is the recipe's choice. Keep the flags above: port 8001
is where the backend looks, `--served-model-name` is the name it asks for, the
two tool-calling flags let Ask work as an agent (below), and `127.0.0.1` keeps
the model private to the machine. Leave out `--reasoning-parser`: the backend
switches the model's thinking off. If vLLM runs on another machine, set
`LLM_BASE_URL` to its address.

**NVIDIA's hosted API**, to try it without a GPU. Create a key at
[build.nvidia.com](https://build.nvidia.com/nvidia/nemotron-3.5-lightning-30b-a3b)
and put these in `backend/.env`:

```
LLM_BASE_URL=https://integrate.api.nvidia.com/v1
LLM_API_KEY=<your key>
```

Then:

```bash
cd backend
uv sync                          # creates .venv and installs dependencies
cp .env.example .env             # then fill in .env if you use the hosted API
uv run python -m server
```

The server prints two addresses when it starts: `http://localhost:8000` for the
dashboard on this machine, and a `http://<this machine's address>:8000` to enter
in the phone app under Glasses → Backend. The second one changes between networks.

Without a language model the server still runs and face matching still works;
the endpoints that need one answer with an error saying so. On start, the server
prints where it sends language and warns if nothing answers there.

Everything is stored in one SQLite file, `backend/data/memory.db`. Delete it to
start over.

### Settings

Set these in `backend/.env` or in the shell.

| Variable | Default | Meaning |
|---|---|---|
| `LLM_BASE_URL` | `http://127.0.0.1:8001/v1` | The OpenAI-compatible API that writes whispers, lookup cards, conversation filing, questions and long captions: a vLLM server, or `https://integrate.api.nvidia.com/v1` for NVIDIA's hosted API. |
| `LLM_API_KEY` | none | The key for NVIDIA's hosted API. A vLLM server started without `--api-key` needs none. |
| `LLM_MODEL` | `nvidia/nemotron-3.5-lightning-30b-a3b` | The model to ask for. With vLLM it must match `--served-model-name`. |
| `HOST` | `0.0.0.0` | `127.0.0.1` keeps the server unreachable from other devices. |
| `PORT` | `8000` | |
| `DB_PATH` | `data/memory.db` | Where the database file lives. |

### Without a phone

With the server running:

```bash
./demo.sh reset                  # wipe, then add three demo people
./demo.sh hear "Hi, I'm Sarah Chen, I run product at Acme, we just closed our Series B."
./demo.sh who Sarah              # lookup card
./demo.sh ask "who did I meet in fintech?"
./demo.sh caption "uh yeah so im sara chen i run product at acme" en
./demo.sh enroll "Sarah Chen" sarah.jpg
./demo.sh look frame.jpg         # recognise + spoken line
./demo.sh roster
./demo.sh forget "Sarah Chen"
```

Or with curl:

```bash
curl -s -X POST http://127.0.0.1:8000/api/ingest \
     -H 'Content-Type: application/json' \
     -d '{"transcript":"Marcus Webb, engineering at Northwind, deep in a Postgres to Kafka migration."}'

curl -s -X POST http://127.0.0.1:8000/api/query \
     -H 'Content-Type: application/json' \
     -d '{"question":"who works on databases?"}'
```

Interactive API documentation is at `/api/docs`.

### Tests

```bash
cd backend
uv run pytest
```

The suite never contacts a language model and needs no key. It ships no
photographs of people; to test matching on real faces, put two photos of the
same person at `backend/testdata/local/enroll.jpg` and `probe.jpg` (that folder
is git-ignored) and the two skipped tests will run.

## The two halves

Most products of this kind pick one input. Thread uses both, and they meet on
the same person record:

```
        speech ──► ingest ──┐
                            ├──► person ──► interactions, topics
        face   ──► enroll ──┘        │
                                     ▼
                            recognize / lookup
```

**Speech answers *what was said*.** A transcript goes to `ingest`, which
extracts who was speaking, what they're into, and what you owe them, then
records an interaction and the topics discussed.

**A face answers *who is this*.** `recognize` turns the frame into a signature
on this machine and compares it with the people you have enrolled.

Because `enroll` finds an existing person before creating one, a face lands on
the *same* record a conversation already created. So recognising someone later
retrieves what you actually discussed, not just that you had met.

## Why identity is not a language-model call

Face identity uses a local embedding (OpenCV's YuNet detector and SFace
recogniser, both in `backend/models/`). It takes tens of milliseconds, gives the
same answer every time, works offline, and sends no image anywhere. A language
model would take over a second, and may simply decline to name a person from a
photo.

So the language model is aimed where language is the real problem: cleaning
captions, pulling structure out of speech, and phrasing the reminder.

## How it is built

| File | Role |
|---|---|
| `server/main.py` | The HTTP endpoints (FastAPI). |
| `server/store.py` | The database: people, interactions, topics, things (SQLite). |
| `server/faces.py` | Face detection, signatures and photo thumbnails (OpenCV). |
| `server/llm.py` | The five language tasks and the shape of each answer, and one agent step with tools (Nemotron, through an OpenAI-compatible API). |
| `server/agent.py` | Ask: Nemotron as an agent with read-only tools over the people you have met. |
| `server/logic.py` | Name matching, similarity, and the lookup-card cache. |
| `server/__main__.py` | Start-up: reads `.env`, prints addresses, runs the server. |

Each person carries two numbers, `closeness` and `recency`, describing your tie
to them. `recognize` multiplies the face similarity by
`1 + 0.15 × closeness + 0.10 × recency`, so a close, recent contact resolves
more readily than a faint one.

Each language task is a function with named inputs and a declared answer shape.
The model must answer by filling in that shape, so a chatty reply can never
reach the display; an answer that does not fit is requested once more and then
reported as an error. The shape goes to the server as a JSON schema, which vLLM
enforces while the answer is written, and is repeated in the instructions for
a server that does not. The model's thinking is switched off for every task:
the answers are short, and someone is waiting for them.

`query`, the Ask field, runs Nemotron as an agent. It gets the question with
an outline of everyone you have met and read-only tools: search everyone, one
person's page, who someone connects to and through what, who talked about a
topic, recent meetings, open promises. It uses them over up to three rounds of three lookups,
then calls `answer` with what to say, who it is about, and the links it points
out ("introduce Sarah to Dana: both talk payments"). **The model reads the
network, it never writes to it**: every name it gives is checked back against
the database, a link between two people is kept only when the database shows
what they share (a topic, an interest, a company, or one introducing the
other), and that, not the model's wording, is what the link says. Anything
else is dropped, so it can report "nobody" instead of inventing a contact. The answer also lists what the agent looked at, and the
map lights up the people and links. A model server without tool calling gets
the question the simple way: the database builds the roster and the model only
picks from it.

Lookup cards are cached per person and rebuilt only when something about that
person changes, so reopening a card does not call the model again.

## Endpoints

All are `POST /api/<name>` with a JSON body.

| Endpoint | Send | Get back |
|---|---|---|
| `recognize` | `frame_b64` | `matched`, `name`, `role`, `org`, `spoken`, `score`, `elapsed_ms` |
| `enroll` | `name`, `frame_b64`, optional `role`, `org`, `relationship`, `notes` | `enrolled`, `name`, `attached_to_existing`, `known_interactions`, or `reason` |
| `ingest` | `transcript`, optional `speaker` | `saved`, `new_person`, `role`, `org`, `topics`, `new_topics`, `followups` |
| `lookup` | `name` (or `"last"`) | `found`, `headline`, `lines`, `topics`, `followups`, `history`, `photo_b64` |
| `person_card` | `name`, optional `refresh` | `name`, `md` (a markdown page), `photo_b64` |
| `query` | `question`, optionally `wearer` (your own name) | `matches` (`name`, `org`, `last`), `reason` (the answer), `searched`; from the agent also `links` (`from`, `to`, `kind`: person or topic, `via`), `steps` (what it looked at) and `agent: true` |
| `caption` | `text`, optional `lang` | `display_text` |
| `roster` | nothing | `people`, `things` |
| `graph`, `timeline` | nothing | the dashboard's views |
| `forget` | `name` | `forgotten` |
| `seed`, `reset` | nothing | demo data in, everything out |
| `glance` | `image_b64` | `whisper` (`text`, `kind`, `confidence`), `matched` |
| `compact_photos` | nothing | re-thumbnails stored photos |

Images are base64-encoded JPEGs.

A successful response is `{"ok": true, "data": {...}}`. A failure is
`{"ok": false, "error": "..."}` with HTTP status 404 (no such endpoint), 405
(not a `POST`), 422 (bad request), 503 (the language model is unavailable) or
500.

## Deliberate behaviour

**No confident match means silence.** Below the threshold, `spoken` is empty and
the client says nothing. A wrong name said with confidence is worse than none.

**A match never depends on the language model.** If the model is unreachable,
`recognize` still names the person and leaves the spoken line empty.

**Names are never guessed.** `ingest` returns `saved: ""` rather than inventing
a name from a voice.

**Pronouns are never inferred.** No pronoun is stored, and every task that
writes about a person is told to use the name or "they".

**Backlit frames are equalised before detection.** Glasses photos are
close-range and often backlit, which drops the face into shadow; lifting the
brightness channel first lets the detector keep a comfortable 0.5 confidence
threshold.

See [PRIVACY.md](PRIVACY.md) for what is stored, what leaves the machine, and
what is missing before this could be used with real people's conversations.
