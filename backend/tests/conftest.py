import pytest


@pytest.fixture(autouse=True)
def no_api_key(monkeypatch):
    """Tests never call the real Claude API, even when a key is set in the shell."""
    monkeypatch.delenv("ANTHROPIC_API_KEY", raising=False)
