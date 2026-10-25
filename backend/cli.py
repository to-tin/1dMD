"""Repository CLI. Bootstrap uses only the Python standard library."""

from __future__ import annotations

import argparse
import hashlib
import os
from pathlib import Path
import socket
import subprocess
import sys


BACKEND = Path(__file__).resolve().parent


def port_number(value: str) -> int:
    try:
        port = int(value)
    except ValueError:
        raise argparse.ArgumentTypeError("port must be an integer") from None
    if not 1 <= port <= 65535:
        raise argparse.ArgumentTypeError("port must be between 1 and 65535")
    return port


def parser() -> argparse.ArgumentParser:
    result = argparse.ArgumentParser(prog="1dmd", description="Run the local 1DMD audio server.")
    commands = result.add_subparsers(dest="command", required=True)
    start = commands.add_parser("start", help="Set up Python dependencies and start the server")
    start.add_argument("--host", default="127.0.0.1", help="Bind address (default: 127.0.0.1)")
    start.add_argument("--port", type=port_number, default=8000, help="Port (default: 8000)")
    start.add_argument("--reload", action="store_true", help="Reload after code edits; clears jobs")
    return result


def ensure_environment(backend: Path) -> Path:
    if sys.version_info < (3, 11):
        raise RuntimeError("Python 3.11 or newer is required. Install it and put python3 on PATH.")
    environment = backend / ".venv"
    python = environment / "bin" / "python"
    if not python.exists():
        print("Creating backend/.venv…", flush=True)
        subprocess.run([sys.executable, "-m", "venv", str(environment)], check=True)

    subprocess.run(
        [str(python), "-c", "import sys; assert sys.version_info >= (3, 11), 'Python 3.11+ required'"],
        check=True,
    )
    requirements = backend / "requirements.txt"
    fingerprint = hashlib.sha256(requirements.read_bytes()).hexdigest()
    stamp = environment / ".1dmd-requirements.sha256"
    if not stamp.exists() or stamp.read_text().strip() != fingerprint:
        print("Installing server dependencies…", flush=True)
        subprocess.run([str(python), "-m", "pip", "install", "-r", str(requirements)], check=True)
        # Only mark a successful installation; a failed setup is retried next start.
        stamp.write_text(fingerprint + "\n")
    return python


def server_command(python: Path, backend: Path, args: argparse.Namespace) -> list[str]:
    command = [
        str(python), "-m", "uvicorn", "app.main:app", "--app-dir", str(backend),
        "--host", args.host, "--port", str(args.port), "--workers", "1",
    ]
    if args.reload:
        command += ["--reload", "--reload-dir", str(backend)]
    return command


def wifi_address() -> str | None:
    """This Mac's address on the local network, or None. Sends nothing: a UDP connect only
    asks the OS which interface it would route through."""
    try:
        with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as probe:
            probe.connect(("192.0.2.1", 9))  # TEST-NET-1: never answers
            address = probe.getsockname()[0]
    except OSError:
        return None
    return None if address.startswith(("127.", "0.")) else address


def phone_hint(host: str, port: int) -> str:
    """What to type in the app's Server field on a real iPhone."""
    if host in ("127.0.0.1", "localhost", "::1"):
        return ("Only this Mac (and the simulator) can reach it. For a real iPhone, run: "
                f"./1dmd start --host 0.0.0.0")
    address = wifi_address() if host in ("0.0.0.0", "::") else host
    if not address:
        return "Couldn't find this Mac's Wi-Fi address. Is Wi-Fi on?"
    return f"On your iPhone (same Wi-Fi), set Server to: {address}:{port}"


def main(argv: list[str] | None = None) -> int:
    args = parser().parse_args(argv)
    try:
        python = ensure_environment(BACKEND)
        host = f"[{args.host}]" if ":" in args.host else args.host
        print(f"Starting 1DMD at http://{host}:{args.port} (Ctrl-C to stop)", flush=True)
        print(f"API docs: http://{host}:{args.port}/docs", flush=True)
        print(phone_hint(args.host, args.port), flush=True)
        if args.reload:
            print("Reload is enabled. Every restart clears existing jobs.", flush=True)
        # Replace the launcher so signals and exit status belong to Uvicorn directly.
        os.execv(str(python), server_command(python, BACKEND, args))
    except KeyboardInterrupt:
        return 130
    except (OSError, RuntimeError, subprocess.CalledProcessError) as error:
        print(f"1dmd: could not start the server: {error}", file=sys.stderr)
        print("Check Python 3.11+, filesystem access, and pip's output above, then run ./1dmd start again.",
              file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
