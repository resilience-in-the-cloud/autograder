"""Static checks on the rates page (no AWS needed).

These protect the things CloudFront failover depends on: every page the
distribution references must exist, the pages must be well-formed, and
nothing may load from a third-party host (that host would be a new single
point of failure the origin group can't help with).
"""

import re
from html.parser import HTMLParser
from pathlib import Path

import pytest

SITE = Path(__file__).resolve().parent.parent / "site"
VOID = {"meta", "link", "br", "img", "input", "hr", "source", "area", "base", "col", "embed", "wbr"}


class TagBalance(HTMLParser):
    def __init__(self):
        super().__init__()
        self.stack, self.errors, self.urls = [], [], []

    def handle_starttag(self, tag, attrs):
        for name, value in attrs:
            if name in ("src", "href") and value:
                self.urls.append(value)
        if tag not in VOID:
            self.stack.append(tag)

    def handle_endtag(self, tag):
        if tag in VOID:
            return
        if not self.stack or self.stack[-1] != tag:
            self.errors.append(f"unexpected </{tag}> (open: {self.stack[-3:]})")
        else:
            self.stack.pop()


def parse(name):
    p = TagBalance()
    p.feed((SITE / name).read_text(encoding="utf-8"))
    p.close()
    return p


@pytest.mark.parametrize("name", ["index.html", "404.html", "error.html"])
def test_pages_referenced_by_cloudfront_exist(name):
    # default_root_object = index.html; custom_error_response -> /404.html, /error.html
    assert (SITE / name).is_file(), f"site/{name} is referenced by the CloudFront config"


@pytest.mark.parametrize("name", ["index.html", "404.html", "error.html"])
def test_pages_are_well_formed(name):
    p = parse(name)
    assert not p.errors, p.errors
    assert not p.stack, f"unclosed tags: {p.stack}"


@pytest.mark.parametrize("name", ["index.html", "404.html", "error.html"])
def test_no_third_party_dependencies(name):
    external = [u for u in parse(name).urls if re.match(r"^(https?:)?//", u)]
    assert not external, f"external URLs add a dependency outside our failover: {external}"


def test_rates_page_has_branding_and_rate_tables():
    html = (SITE / "index.html").read_text(encoding="utf-8")
    assert "Niner National Bank" in html
    for table in ("deposit-rates", "cd-rates", "loan-rates"):
        assert f'id="{table}"' in html
    assert re.search(r"\d+\.\d+%", html), "rates page should show at least one rate"


def test_error_page_is_self_contained():
    # The maintenance page is shown when origins are failing, so it must not
    # depend on any other object (stylesheet, images) from those origins.
    p = parse("error.html")
    assert p.urls == [], f"error.html should inline everything, found {p.urls}"


def test_no_origin_marker_in_site_dir():
    # origin.txt is generated per bucket by Terraform; a copy here would clash.
    assert not (SITE / "origin.txt").exists()
