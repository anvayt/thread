"""The Thread backend.

Two inputs, one store. A face is resolved locally with an SFace embedding
(deterministic, works offline). Speech is transcribed on the device and filed
by `ingest`, which extracts who was talking and what about. Both write to the
same person record, so recognising someone later retrieves what was actually
said - not merely that you had met.

A language model is used only where language is the problem: cleaning live
captions, pulling structure out of a transcript, and phrasing the reminder.

Run with:  uv run python -m server
"""
