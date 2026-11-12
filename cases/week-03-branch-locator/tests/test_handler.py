"""Unit tests for the branch locator. No AWS, no boto3, no moto needed:
DynamoDB is replaced by a small in-memory fake, and boto3/botocore are
replaced by stub modules when we test how the client is configured."""

import json
import os
import sys
import types
from decimal import Decimal

import pytest

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "app"))
import handler  # noqa: E402

BRANCHES = [
    {"branch_id": "clt-uptown", "name": "Uptown Main", "lat": Decimal("35.2271"), "atm": True},
    {"branch_id": "clt-noda", "name": "NoDa", "lat": Decimal("35.2465"), "atm": True},
]


class FakeTable:
    """Just enough of boto3's Table resource for the handler."""

    def __init__(self, items, fail=False):
        self.items = {i["branch_id"]: i for i in items}
        self.fail = fail
        self.calls = 0

    def _maybe_fail(self):
        self.calls += 1
        if self.fail:
            raise TimeoutError("Read timeout on endpoint URL (fake)")

    def scan(self, **kwargs):
        self._maybe_fail()
        return {"Items": list(self.items.values())}

    def get_item(self, Key):
        self._maybe_fail()
        item = self.items.get(Key["branch_id"])
        return {"Item": item} if item else {}


@pytest.fixture(autouse=True)
def fresh_state(monkeypatch):
    monkeypatch.setenv("ADDED_LATENCY_MS", "0")
    monkeypatch.setenv("TABLE_NAME", "nnb-branches-test-directory")
    for k in ("DDB_CONNECT_TIMEOUT", "DDB_READ_TIMEOUT", "DDB_MAX_ATTEMPTS"):
        monkeypatch.delenv(k, raising=False)
    monkeypatch.setattr(handler, "_last_good_list", None, raising=False)
    monkeypatch.setattr(handler, "_table", None)


@pytest.fixture
def table(monkeypatch):
    t = FakeTable(BRANCHES)
    monkeypatch.setattr(handler, "_table", t)
    return t


def call(route, params=None):
    return handler.lambda_handler({"routeKey": route, "pathParameters": params}, None)


# --- happy path -------------------------------------------------------------

def test_health_does_not_touch_dynamodb(table):
    r = call("GET /health")
    assert r["statusCode"] == 200
    assert json.loads(r["body"])["status"] == "ok"
    assert table.calls == 0


def test_list_branches(table):
    r = call("GET /branches")
    body = json.loads(r["body"])
    assert r["statusCode"] == 200
    assert body["count"] == 2
    assert body["branches"][0]["branch_id"] == "clt-noda"  # sorted
    assert body["branches"][1]["lat"] == pytest.approx(35.2271)  # Decimal -> float


def test_get_branch(table):
    r = call("GET /branches/{branch_id}", {"branch_id": "clt-uptown"})
    assert r["statusCode"] == 200
    assert json.loads(r["body"])["name"] == "Uptown Main"


def test_unknown_branch_is_404(table):
    r = call("GET /branches/{branch_id}", {"branch_id": "clt-nowhere"})
    assert r["statusCode"] == 404


def test_unknown_route_is_404(table):
    assert call("GET /admin")["statusCode"] == 404


# --- timeouts, retries, degradation -----------------------------------------

def test_client_config_has_timeouts_and_bounded_retries():
    cfg = handler.client_config_kwargs()
    assert 0 < cfg["connect_timeout"] <= 2
    assert 0 < cfg["read_timeout"] <= 2
    assert cfg["retries"] == {"mode": "standard", "max_attempts": 2}


def test_client_config_respects_env(monkeypatch):
    monkeypatch.setenv("DDB_READ_TIMEOUT", "0.25")
    monkeypatch.setenv("DDB_MAX_ATTEMPTS", "3")
    cfg = handler.client_config_kwargs()
    assert cfg["read_timeout"] == 0.25
    assert cfg["retries"]["max_attempts"] == 3


def test_get_table_passes_config_to_boto3(monkeypatch):
    """get_table() must build the client with botocore Config(timeouts, retries)."""
    captured = {}

    class FakeConfig:
        def __init__(self, **kwargs):
            captured["config_kwargs"] = kwargs

    class FakeResource:
        def Table(self, name):
            captured["table"] = name
            return FakeTable([])

    def fake_resource(service, **kwargs):
        captured["service"] = service
        captured["resource_kwargs"] = kwargs
        return FakeResource()

    boto3 = types.ModuleType("boto3")
    boto3.resource = fake_resource
    botocore = types.ModuleType("botocore")
    botocore_config = types.ModuleType("botocore.config")
    botocore_config.Config = FakeConfig
    monkeypatch.setitem(sys.modules, "boto3", boto3)
    monkeypatch.setitem(sys.modules, "botocore", botocore)
    monkeypatch.setitem(sys.modules, "botocore.config", botocore_config)

    handler.get_table()

    assert captured["service"] == "dynamodb"
    assert isinstance(captured["resource_kwargs"].get("config"), FakeConfig)
    assert captured["config_kwargs"]["retries"] == {"mode": "standard", "max_attempts": 2}
    assert captured["config_kwargs"]["connect_timeout"] <= 2
    assert captured["config_kwargs"]["read_timeout"] <= 2
    assert captured["table"] == "nnb-branches-test-directory"


def test_backend_failure_returns_fast_503_not_crash(monkeypatch):
    monkeypatch.setattr(handler, "_table", FakeTable(BRANCHES, fail=True))
    r = call("GET /branches/{branch_id}", {"branch_id": "clt-uptown"})
    assert r["statusCode"] == 503
    assert r["headers"]["Retry-After"]


def test_list_serves_stale_copy_when_backend_fails(monkeypatch, table):
    assert call("GET /branches")["statusCode"] == 200  # warms the last-good cache
    table.fail = True
    r = call("GET /branches")
    body = json.loads(r["body"])
    assert r["statusCode"] == 200
    assert body["stale"] is True
    assert r["headers"]["X-NNB-Degraded"] == "stale-cache"


def test_list_without_cache_and_backend_down_is_503(monkeypatch):
    monkeypatch.setattr(handler, "_table", FakeTable(BRANCHES, fail=True))
    assert call("GET /branches")["statusCode"] == 503


def test_app_does_not_add_its_own_retry_loop(monkeypatch):
    """botocore already retries; retrying again in the app multiplies load (3 x 3 = 9)."""
    t = FakeTable(BRANCHES, fail=True)
    monkeypatch.setattr(handler, "_table", t)
    call("GET /branches/{branch_id}", {"branch_id": "clt-uptown"})
    assert t.calls == 1


def test_latency_injection_sleeps(monkeypatch):
    monkeypatch.setenv("ADDED_LATENCY_MS", "250")
    slept = []
    handler.maybe_inject_latency(sleep=slept.append)
    assert slept == [0.25]
