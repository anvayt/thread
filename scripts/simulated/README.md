# What the simulated glasses run on

`scripts/simulate.sh` uses these. The [main README](../../README.md#run-with-simulated-glasses) says how to run it.

| File | What it is |
| --- | --- |
| `face.jpg` | What the simulated camera sees. |
| `make_clip.swift` | Makes the video clip the simulated camera streams, from `face.jpg`. The clip is written to `build/mock/clip.mov`. |
| `backend.py` | The real backend with fixed rules in place of the language model, for running without one. Its database is `build/mock/test.db`. |
| `detached.py` | Starts the backend so that it keeps running after the script and its terminal are gone. |

## The portrait

`face.jpg` is a public-domain portrait photograph, 960 pixels wide.

To use another face, replace `face.jpg` with a JPEG of one person facing the camera and delete `build/mock/clip.mov`. The next run makes a new clip.
