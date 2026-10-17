from contextlib import contextmanager
import json
from pathlib import Path
import socket
from threading import Event, Thread
import time

from fastapi.testclient import TestClient
import httpx
import pytest
import uvicorn

from app.main import create_app


@pytest.fixture
def client(tmp_path):
    with TestClient(create_app(upload_dir=tmp_path)) as client:
        yield client


def test_health(client):
    response = client.get("/health")
    assert response.status_code == 200
    assert response.json() == {"status": "ok"}


@pytest.mark.parametrize("extension", ["wav", "MP3", "m4a", "aac", "flac", "ogg", "webm"])
def test_upload_and_poll(client, tmp_path, extension, monkeypatch):
    # Metadata-only validation intentionally does not decode these fixture bytes.
    mock_path = Path(__file__).resolve().parents[1] / "app/mock_data/mock_response_body.json"
    expected_result = json.loads(mock_path.read_text(encoding="utf-8"))
    # Loading the mock must not depend on the server's working directory.
    monkeypatch.chdir(tmp_path)
    filename = f"recording.{extension}"
    response = client.post("/jobs", files={"audio": (filename, b"audio", "audio/mp4")})
    assert response.status_code == 202
    accepted = response.json()
    assert accepted == {
        "job_id": accepted["job_id"],
        "status": "queued",
        "status_url": f'/jobs/{accepted["job_id"]}',
    }
    polled = client.get(accepted["status_url"])
    assert polled.status_code == 200
    assert polled.json() == {
        "job_id": accepted["job_id"],
        "status": "completed",
        "result": expected_result,
        "error": None,
    }
    assert list(tmp_path.iterdir()) == []


def test_unknown_job(client):
    assert client.get("/jobs/unknown").status_code == 404


@pytest.mark.parametrize(
    ("files", "expected"),
    [
        (None, 422),
        ({"file": ("recording.wav", b"audio")}, 422),
        ({"audio": ("recording.wav", b"")}, 400),
        ({"audio": ("recording.txt", b"audio")}, 415),
        ({"audio": ("recording", b"audio")}, 415),
    ],
)
def test_rejected_uploads(client, tmp_path, files, expected):
    assert client.post("/jobs", files=files).status_code == expected
    assert list(tmp_path.iterdir()) == []


def test_size_limit_and_cleanup(tmp_path):
    with TestClient(create_app(max_upload_bytes=8, upload_dir=tmp_path)) as client:
        assert client.post("/jobs", files={"audio": ("clip.wav", b"12345678")}).status_code == 202
        assert client.post("/jobs", files={"audio": ("clip.wav", b"123456789")}).status_code == 413
    assert list(tmp_path.iterdir()) == []


def test_default_size_limit(tmp_path):
    with TestClient(create_app(upload_dir=tmp_path)) as client:
        response = client.post(
            "/jobs", files={"audio": ("large.wav", b"x" * (25 * 1024 * 1024 + 1))},
        )
        assert response.status_code == 413
    assert list(tmp_path.iterdir()) == []


def test_processing_failure(client, tmp_path, caplog):
    def fail(path, metadata):
        assert path.read_bytes() == b"audio"
        raise RuntimeError("test processor exploded")

    client.app.state.processor = fail
    accepted = client.post("/jobs", files={"audio": ("clip.wav", b"audio")}).json()
    job = client.get(accepted["status_url"]).json()
    assert job["status"] == "failed"
    assert job["result"] is None
    assert job["error"] == "Audio processing failed."
    assert "test processor exploded" in caplog.text
    assert list(tmp_path.iterdir()) == []


@pytest.mark.parametrize("result", [{"invalid": object()}, {"invalid": float("nan")}, ["not an object"]])
def test_invalid_processor_result_fails(client, tmp_path, result):
    client.app.state.processor = lambda path, metadata: result
    accepted = client.post("/jobs", files={"audio": ("clip.wav", b"audio")}).json()
    assert client.get(accepted["status_url"]).json()["status"] == "failed"
    assert list(tmp_path.iterdir()) == []


def test_filename_is_never_used_as_storage_path(client, tmp_path):
    paths = []

    def inspect(path, metadata):
        paths.append(path)
        assert path.parent == tmp_path
        assert path.name.startswith("1dmd-audio-")
        assert path.read_bytes() == b"audio"
        return {"placeholder": True}

    client.app.state.processor = inspect
    accepted = client.post(
        "/jobs", files={"audio": ("../../outside.wav", b"audio")},
    ).json()
    assert client.get(accepted["status_url"]).json()["status"] == "completed"
    assert len(paths) == 1
    assert not paths[0].exists()


def test_job_records_are_isolated_between_app_instances(client, tmp_path):
    accepted = client.post("/jobs", files={"audio": ("clip.wav", b"audio")}).json()
    with TestClient(create_app(upload_dir=tmp_path)) as restarted:
        assert restarted.get(accepted["status_url"]).status_code == 404
    assert client.get(accepted["status_url"]).status_code == 200


@contextmanager
def running_server(app):
    """Use real HTTP to observe 202 before background work has finished."""
    with socket.socket() as sock:
        sock.bind(("127.0.0.1", 0))
        server = uvicorn.Server(uvicorn.Config(app, log_level="error"))
        thread = Thread(target=server.run, kwargs={"sockets": [sock]}, daemon=True)
        thread.start()
        try:
            deadline = time.monotonic() + 5
            while not server.started:
                if not thread.is_alive() or time.monotonic() > deadline:
                    pytest.fail("Local test server did not start")
                time.sleep(0.01)
            yield f"http://127.0.0.1:{sock.getsockname()[1]}"
        finally:
            server.should_exit = True
            thread.join(timeout=10)
            assert not thread.is_alive(), "Local test server did not stop"


def wait_for_completion(client, status_url):
    deadline = time.monotonic() + 5
    while time.monotonic() < deadline:
        job = client.get(status_url).json()
        if job["status"] == "completed":
            return job
        time.sleep(0.01)
    pytest.fail("Job did not complete")


def test_concurrent_jobs_return_202_before_processing_finishes(tmp_path):
    started = {key: Event() for key in (b"first", b"second")}
    release = {key: Event() for key in started}

    def controlled_processor(path: Path, metadata):
        payload = path.read_bytes()
        started[payload].set()
        assert release[payload].wait(timeout=10), "Test did not release processor"
        return {"payload": payload.decode(), "size_bytes": metadata.size_bytes}

    app = create_app(processor=controlled_processor, upload_dir=tmp_path)
    with running_server(app) as base_url, httpx.Client(base_url=base_url, timeout=5) as client:
        try:
            accepted = []
            for payload in started:
                response = client.post("/jobs", files={"audio": ("same.wav", payload)})
                assert response.status_code == 202
                accepted.append(response.json())
                assert started[payload].wait(timeout=3)
            assert accepted[0]["job_id"] != accepted[1]["job_id"]
            assert len(list(tmp_path.iterdir())) == 2
            for job in accepted:
                assert client.get(job["status_url"]).json() == {
                    "job_id": job["job_id"], "status": "processing", "result": None, "error": None,
                }
            release[b"second"].set()
            second = wait_for_completion(client, accepted[1]["status_url"])
            assert second["result"] == {"payload": "second", "size_bytes": 6}
            assert client.get(accepted[0]["status_url"]).json()["status"] == "processing"
            release[b"first"].set()
            first = wait_for_completion(client, accepted[0]["status_url"])
            assert first["result"] == {"payload": "first", "size_bytes": 5}
        finally:
            for event in release.values():
                event.set()
    assert list(tmp_path.iterdir()) == []
