import hashlib
import importlib.util
from pathlib import Path
import signal
import shlex
import socket
import subprocess
import sys
import time

import httpx
import pytest


ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location("server_cli", ROOT / "backend/cli.py")
cli = importlib.util.module_from_spec(spec)
spec.loader.exec_module(cli)


@pytest.fixture
def setup_backend(tmp_path):
    (tmp_path / "requirements.txt").write_text("fastapi==0.143.3\n")
    return tmp_path


def mock_setup(monkeypatch, backend, fail_install=False):
    calls = []

    def run(command, **kwargs):
        calls.append(command)
        if "venv" in command:
            python = backend / ".venv/bin/python"
            python.parent.mkdir(parents=True)
            python.touch()
        if "pip" in command and fail_install:
            raise subprocess.CalledProcessError(1, command)

    monkeypatch.setattr(cli.subprocess, "run", run)
    return calls


def test_first_setup_reuse_and_changed_requirements(setup_backend, monkeypatch):
    calls = mock_setup(monkeypatch, setup_backend)
    python = cli.ensure_environment(setup_backend)
    assert python == setup_backend / ".venv/bin/python"
    assert sum("venv" in call for call in calls) == 1
    assert sum("pip" in call for call in calls) == 1
    calls.clear()
    cli.ensure_environment(setup_backend)
    assert not any("venv" in call or "pip" in call for call in calls)
    (setup_backend / "requirements.txt").write_text("fastapi==0.143.3\nuvicorn==0.54.0\n")
    cli.ensure_environment(setup_backend)
    assert sum("pip" in call for call in calls) == 1


def test_failed_install_is_not_stamped_and_is_reported(setup_backend, monkeypatch, capsys):
    mock_setup(monkeypatch, setup_backend, fail_install=True)
    monkeypatch.setattr(cli, "BACKEND", setup_backend)
    assert cli.main(["start"]) == 1
    assert not (setup_backend / ".venv/.1dmd-requirements.sha256").exists()
    assert "could not start" in capsys.readouterr().err


def test_old_python_reports_requirement(setup_backend, monkeypatch):
    monkeypatch.setattr(cli.sys, "version_info", (3, 10))
    with pytest.raises(RuntimeError, match="3.11"):
        cli.ensure_environment(setup_backend)


@pytest.mark.parametrize("port", ["0", "65536", "-1", "nope"])
def test_invalid_port(port):
    with pytest.raises(SystemExit) as error:
        cli.parser().parse_args(["start", "--port", port])
    assert error.value.code == 2


def test_options_and_exec(monkeypatch):
    monkeypatch.setattr(cli, "ensure_environment", lambda _: Path("/test/python"))
    calls = []
    monkeypatch.setattr(cli.os, "execv", lambda *args: calls.append(args))
    assert cli.main(["start"]) == 0
    assert calls[-1][1][-6:] == ["--host", "127.0.0.1", "--port", "8000", "--workers", "1"]
    assert cli.main(["start", "--host", "0.0.0.0", "--port", "8123", "--reload"]) == 0
    command = calls[-1][1]
    assert command[command.index("--port") + 1] == "8123"
    assert command[command.index("--host") + 1] == "0.0.0.0"
    assert command[-3:] == ["--reload", "--reload-dir", str(cli.BACKEND)]


def test_phone_hint(monkeypatch):
    assert "--host 0.0.0.0" in cli.phone_hint("127.0.0.1", 8000)
    monkeypatch.setattr(cli, "wifi_address", lambda: "192.168.1.20")
    assert cli.phone_hint("0.0.0.0", 8000).endswith("set Server to: 192.168.1.20:8000")
    assert cli.phone_hint("10.0.0.5", 8123).endswith("set Server to: 10.0.0.5:8123")
    monkeypatch.setattr(cli, "wifi_address", lambda: None)
    assert "Is Wi-Fi on?" in cli.phone_hint("0.0.0.0", 8000)


def test_is_private():
    for address in ["10.0.0.5", "172.16.0.1", "172.31.255.1", "192.168.19.131"]:
        assert cli.is_private(address)
    for address in ["127.0.0.1", "0.0.0.0", "172.32.0.1", "8.8.8.8", "fd00::1", "", "1.2.3"]:
        assert not cli.is_private(address)


def test_start_prints_phone_hint(monkeypatch, capsys):
    monkeypatch.setattr(cli, "ensure_environment", lambda _: Path("/test/python"))
    monkeypatch.setattr(cli.os, "execv", lambda *args: None)
    monkeypatch.setattr(cli, "wifi_address", lambda: "192.168.1.20")
    assert cli.main(["start", "--host", "0.0.0.0"]) == 0
    out = capsys.readouterr().out
    assert out.splitlines()[0].endswith("set Server to: 192.168.1.20:8000")
    assert "0.0.0.0" not in out


@pytest.mark.parametrize("args", [["--help"], ["start", "--help"]])
def test_help_from_arbitrary_directory_without_setup(tmp_path, args):
    # Copy just the stdlib launcher and CLI: no environment or requirements present.
    repo = tmp_path / "repository with spaces"
    (repo / "backend").mkdir(parents=True)
    launcher = repo / "1dmd"
    launcher.write_bytes((ROOT / "1dmd").read_bytes())
    launcher.chmod(0o755)
    (repo / "backend/cli.py").write_bytes((ROOT / "backend/cli.py").read_bytes())
    result = subprocess.run([str(launcher), *args], cwd=tmp_path, capture_output=True, text=True)
    assert result.returncode == 0
    assert "usage:" in result.stdout
    assert not (repo / "backend/.venv").exists()


def test_start_health_and_sigint_from_arbitrary_directory(tmp_path):
    # Reuse installed test dependencies, keeping bootstrap entirely offline and isolated.
    backend = tmp_path / "backend"
    backend.mkdir()
    (backend / "cli.py").write_bytes((ROOT / "backend/cli.py").read_bytes())
    (backend / "app").symlink_to(ROOT / "backend/app", target_is_directory=True)
    requirements = (ROOT / "backend/requirements.txt").read_bytes()
    (backend / "requirements.txt").write_bytes(requirements)
    environment = backend / ".venv"
    (environment / "bin").mkdir(parents=True)
    python = environment / "bin/python"
    python.write_text("#!/bin/sh\nexec " + shlex.quote(sys.executable) + ' "$@"\n')
    python.chmod(0o755)
    (environment / ".1dmd-requirements.sha256").write_text(hashlib.sha256(requirements).hexdigest())
    launcher = tmp_path / "1dmd"
    launcher.write_bytes((ROOT / "1dmd").read_bytes())
    launcher.chmod(0o755)
    with socket.socket() as sock:
        sock.bind(("127.0.0.1", 0))
        port = sock.getsockname()[1]
    with (tmp_path / "server.log").open("w+") as log:
        process = subprocess.Popen([str(launcher), "start", "--port", str(port)], cwd="/", stdout=log, stderr=log)
        try:
            deadline = time.monotonic() + 10
            with httpx.Client() as client:
                while True:
                    try:
                        response = client.get(f"http://127.0.0.1:{port}/health", timeout=0.5)
                        assert response.json() == {"status": "ok"}
                        break
                    except httpx.TransportError:
                        if process.poll() is not None or time.monotonic() > deadline:
                            log.seek(0)
                            pytest.fail(log.read())
                        time.sleep(0.05)
            process.send_signal(signal.SIGINT)
            # Uvicorn may re-raise SIGINT after its graceful shutdown.
            assert process.wait(timeout=10) in (0, -signal.SIGINT, 128 + signal.SIGINT)
            log.seek(0)
            assert "Application shutdown complete" in log.read()
        finally:
            if process.poll() is None:
                process.terminate()
                process.wait(timeout=10)
