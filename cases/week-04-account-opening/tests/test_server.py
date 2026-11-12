import json
import os
import sys

import pytest

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "app"))
import server  # noqa: E402


@pytest.fixture(autouse=True)
def off_ec2(monkeypatch, tmp_path):
    # Pretend we're on an EC2 instance in us-east-1b without touching the network.
    server._metadata_cache.clear()
    server._metadata_cache.update({"placement/availability-zone": "us-east-1b",
                                   "instance-id": "i-0abc123"})
    monkeypatch.setenv("NNB_FAIL_FLAG", str(tmp_path / "FAIL_HEALTH"))
    yield tmp_path


def test_form_page_is_served():
    status, ctype, body = server.route("GET", "/")
    assert status == 200
    assert ctype.startswith("text/html")
    assert "Niner National Bank" in body
    assert 'action="/apply"' in body


def test_health_reports_az_and_ok():
    status, ctype, body = server.route("GET", "/health")
    data = json.loads(body)
    assert status == 200
    assert ctype == "application/json"
    assert data["status"] == "ok"
    assert data["az"] == "us-east-1b"
    assert data["instance_id"] == "i-0abc123"


def test_health_fails_when_flag_file_exists(off_ec2):
    (off_ec2 / "FAIL_HEALTH").write_text("chaos")
    status, _, body = server.route("GET", "/health")
    assert status == 503
    assert json.loads(body)["status"] == "failing"


def test_health_recovers_when_flag_removed(off_ec2):
    flag = off_ec2 / "FAIL_HEALTH"
    flag.write_text("chaos")
    assert server.route("GET", "/health")[0] == 503
    flag.unlink()
    assert server.route("GET", "/health")[0] == 200


def test_valid_application_is_accepted():
    body = b"full_name=Ada+Lovelace&email=ada%40example.com&product=savings&deposit=100"
    status, _, html = server.route("POST", "/apply", body)
    assert status == 200
    assert "NNB-" in html


@pytest.mark.parametrize("body", [
    b"full_name=&email=ada%40example.com&product=savings&deposit=100",
    b"full_name=Ada&email=not-an-email&product=savings&deposit=100",
    b"full_name=Ada&email=ada%40example.com&product=crypto&deposit=100",
    b"full_name=Ada&email=ada%40example.com&product=savings&deposit=5",
])
def test_invalid_application_is_400(body):
    assert server.route("POST", "/apply", body)[0] == 400


def test_user_input_is_escaped():
    body = b"full_name=%3Cscript%3E&email=a%40b.co&product=checking&deposit=30"
    _, _, html = server.route("POST", "/apply", body)
    assert "<script>" not in html


def test_unknown_path_is_404():
    assert server.route("GET", "/nope")[0] == 404


def test_imds_failure_degrades_to_unknown():
    server._metadata_cache.clear()

    def broken_opener(*_a, **_k):
        raise OSError("no IMDS here")

    assert server.instance_metadata("placement/availability-zone", opener=broken_opener) == "unknown"
