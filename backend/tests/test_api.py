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
def client():
    with TestClient(create_app()) as client:
        yield client


def test_health(client):
    response = client.get("/health")
    assert response.status_code == 200
    assert response.json() == {"status": "ok"}


@pytest.mark.parametrize("transcript", ["A conversation about Dune.", "", 'Line one\n"Hello" — 你好 🎬'])
def test_submit_and_poll(client, tmp_path, transcript, monkeypatch):
    mock_path = Path(__file__).resolve().parents[1] / "app/mock_data/mock_response_body.json"
    expected_result = json.loads(mock_path.read_text(encoding="utf-8"))
    monkeypatch.chdir(tmp_path)
    response = client.post("/jobs", json={"transcript": transcript})
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


def test_unknown_job(client):
    assert client.get("/jobs/unknown").status_code == 404


@pytest.mark.parametrize("payload", [{}, {"transcript": None}, {"transcript": 123},
                                       {"transcript": True}, {"transcript": []},
                                       {"transcript": {}}, "raw text", []])
def test_rejected_transcripts(client, payload):
    calls = []
    client.app.state.processor = lambda payload: calls.append(payload)
    assert client.post("/jobs", json=payload).status_code == 422
    assert calls == []


def test_missing_or_non_json_body(client):
    assert client.post("/jobs").status_code == 422
    assert client.post("/jobs", content="not JSON", headers={"Content-Type": "application/json"}).status_code == 422
    assert client.post("/jobs", files={"audio": ("clip.wav", b"audio")}).status_code == 422


def test_processor_receives_transcript_object(client):
    received = []
    transcript = '  Speaker: "Hello"\n你好 🎬  '

    def inspect(payload):
        received.append(payload.model_dump())
        return {"processed": payload.transcript}

    client.app.state.processor = inspect
    accepted = client.post("/jobs", json={"transcript": transcript}).json()
    assert client.get(accepted["status_url"]).json()["result"] == {"processed": transcript}
    assert received == [{"transcript": transcript}]


def test_processing_failure(client, caplog):
    def fail(payload):
        raise RuntimeError("test processor exploded")

    client.app.state.processor = fail
    accepted = client.post("/jobs", json={"transcript": "hello"}).json()
    job = client.get(accepted["status_url"]).json()
    assert job["status"] == "failed"
    assert job["result"] is None
    assert job["error"] == "Transcript processing failed."
    assert "test processor exploded" in caplog.text


@pytest.mark.parametrize(
    "result", [{"invalid": object()}, {"invalid": float("nan")}, ["not an object"]]
)
def test_invalid_processor_result_fails(client, result):
    client.app.state.processor = lambda payload: result
    accepted = client.post("/jobs", json={"transcript": "hello"}).json()
    assert client.get(accepted["status_url"]).json()["status"] == "failed"


def test_job_records_are_isolated_between_app_instances(client):
    accepted = client.post("/jobs", json={"transcript": "hello"}).json()
    with TestClient(create_app()) as restarted:
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


def test_concurrent_jobs_return_202_before_processing_finishes():
    started = {key: Event() for key in ("first", "second")}
    release = {key: Event() for key in started}

    def controlled_processor(request):
        payload = request.transcript
        started[payload].set()
        assert release[payload].wait(timeout=10), "Test did not release processor"
        return {"transcript": payload}

    app = create_app(processor=controlled_processor)
    with running_server(app) as base_url, httpx.Client(
        base_url=base_url, timeout=5
    ) as client:
        try:
            accepted = []
            for payload in started:
                response = client.post("/jobs", json={"transcript": payload})
                assert response.status_code == 202
                accepted.append(response.json())
                assert started[payload].wait(timeout=3)
            assert accepted[0]["job_id"] != accepted[1]["job_id"]
            for job in accepted:
                assert client.get(job["status_url"]).json() == {
                    "job_id": job["job_id"],
                    "status": "processing",
                    "result": None,
                    "error": None,
                }
            release["second"].set()
            second = wait_for_completion(client, accepted[1]["status_url"])
            assert second["result"] == {"transcript": "second"}
            assert (
                client.get(accepted[0]["status_url"]).json()["status"] == "processing"
            )
            release["first"].set()
            first = wait_for_completion(client, accepted[0]["status_url"])
            assert first["result"] == {"transcript": "first"}
        finally:
            for event in release.values():
                event.set()
