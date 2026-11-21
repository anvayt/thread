"""Start the server:  uv run python -m server"""

import logging
import os
import socket
from pathlib import Path
from urllib.parse import urlsplit

import uvicorn

from server import llm

ENV_FILE = Path(__file__).resolve().parent.parent / ".env"


def load_env(path: Path = ENV_FILE) -> None:
    """Read KEY=value lines from .env. Variables already set in the shell win."""
    if not path.exists():
        return
    for raw in path.read_text().splitlines():
        line = raw.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, _, value = line.partition("=")
        value = value.strip().strip("\"'")
        if value:
            os.environ.setdefault(key.strip(), value)


def lan_address() -> str:
    """This machine's address on the local network, for the phone to dial."""
    try:
        with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as probe:
            # No packet is sent; this only asks which interface would be used.
            probe.connect(("192.0.2.1", 80))
            return probe.getsockname()[0]
    except OSError:
        return ""


def answers(url: str) -> bool:
    """Whether anything accepts a connection at the URL's host and port."""
    parts = urlsplit(url)
    port = parts.port or (443 if parts.scheme == "https" else 80)
    try:
        with socket.create_connection((parts.hostname or "", port), timeout=1):
            return True
    except OSError:
        return False


def main() -> None:
    load_env()
    logging.basicConfig(level=logging.INFO, format="%(levelname)s  %(message)s")
    host = os.environ.get("HOST") or "0.0.0.0"
    port = int(os.environ.get("PORT") or 8000)

    print(f"\n  Dashboard     http://localhost:{port}")
    if host == "0.0.0.0":
        address = lan_address()
        if address:
            print(f"  From a phone  http://{address}:{port}   (same Wi-Fi)")
    print(f"  Language      {llm.model_name()} at {llm.endpoint()}")
    if not llm.available():
        print(
            "\n  LLM_API_KEY is not set, and NVIDIA's hosted API needs one. Face"
            "\n  matching works; whispers, lookup cards, conversation filing and"
            "\n  questions will report an error. Add the key to .env to enable them."
        )
    elif not answers(llm.endpoint()):
        print(
            f"\n  Nothing answers at {llm.endpoint()} yet. Face matching works;"
            "\n  whispers, lookup cards, conversation filing and questions will"
            "\n  report an error until a model server is running there. To use"
            "\n  another one, set LLM_BASE_URL (and LLM_API_KEY) in .env."
        )
    print()

    uvicorn.run("server.main:app", host=host, port=port, log_level="info")


if __name__ == "__main__":
    main()
