import json
import os
import sys

import pytest

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "app"))
import handler  # noqa: E402


def call(qs=None):
    return handler.lambda_handler({"queryStringParameters": qs}, None)


@pytest.fixture(autouse=True)
def healthy(monkeypatch):
    monkeypatch.setenv("FAILURE_RATE", "0")
    monkeypatch.setenv("ADDED_LATENCY_MS", "0")


def test_health_check_without_account():
    r = call()
    assert r["statusCode"] == 200
    assert json.loads(r["body"])["status"] == "ok"


def test_known_account_returns_balance():
    r = call({"account_id": "1001"})
    body = json.loads(r["body"])
    assert r["statusCode"] == 200
    assert body["balance"] == 2512.75
    assert body["currency"] == "USD"


def test_unknown_account_is_404_not_error():
    r = call({"account_id": "9999"})
    assert r["statusCode"] == 404


def test_full_failure_rate_raises(monkeypatch):
    monkeypatch.setenv("FAILURE_RATE", "1")
    with pytest.raises(handler.InjectedFailure):
        call({"account_id": "1001"})


def test_latency_injection_sleeps(monkeypatch):
    monkeypatch.setenv("ADDED_LATENCY_MS", "250")
    slept = []
    handler.maybe_inject_failure(rng=lambda: 1.0, sleep=slept.append)
    assert slept == [0.25]


def test_responses_are_not_cached():
    r = call({"account_id": "1002"})
    assert r["headers"]["Cache-Control"] == "no-store"
