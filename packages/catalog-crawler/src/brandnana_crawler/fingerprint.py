"""Platform detection for storefront domains.

Runs a fixed set of HEAD/GET probes concurrently against a domain and returns
the most likely e-commerce platform plus a confidence score in [0.0, 1.0].

Budget: ~2 seconds wall-clock. Each probe has a hard 1.5s timeout and they all
run in parallel via anyio task groups, so total time is bounded by the slowest
probe plus a small scheduling overhead.
"""

from __future__ import annotations

import re
import sys
from dataclasses import dataclass, field
from enum import Enum
from typing import Iterable

import anyio
import httpx


class Platform(str, Enum):
    SHOPIFY = "shopify"
    WOOCOMMERCE = "woocommerce"
    BIGCOMMERCE = "bigcommerce"
    SQUARESPACE = "squarespace"
    WEBFLOW = "webflow"
    CUSTOM = "custom"


@dataclass(slots=True)
class Detection:
    platform: Platform
    confidence: float
    evidence: list[str] = field(default_factory=list)

    def to_dict(self) -> dict[str, object]:
        return {
            "platform": self.platform.value,
            "confidence": round(self.confidence, 3),
            "evidence": list(self.evidence),
        }


_PROBE_TIMEOUT = httpx.Timeout(connect=1.0, read=1.5, write=1.5, pool=1.5)
_USER_AGENT = "brandnana-crawler/0.1 (+https://brandnana.net)"
_DEFAULT_HEADERS = {"user-agent": _USER_AGENT, "accept": "*/*"}


def _normalize_origin(domain: str) -> str:
    """Accept 'example.com', 'https://example.com', 'example.com/' — return origin."""
    raw = domain.strip()
    if "://" not in raw:
        raw = "https://" + raw
    return raw.rstrip("/")


@dataclass(slots=True)
class _Signal:
    platform: Platform
    confidence: float
    note: str


async def _probe_root(client: httpx.AsyncClient, origin: str) -> list[_Signal]:
    try:
        r = await client.get(origin + "/", follow_redirects=True)
    except httpx.HTTPError:
        return []
    body = r.text[:200_000].lower()
    headers = {k.lower(): v.lower() for k, v in r.headers.items()}
    signals: list[_Signal] = []

    if "x-shopify-stage" in headers or "shopify" in headers.get("powered-by", ""):
        signals.append(_Signal(Platform.SHOPIFY, 0.9, "root: x-shopify-stage header"))
    if "cdn.shopify.com" in body or 'content="shopify"' in body:
        signals.append(_Signal(Platform.SHOPIFY, 0.85, "root html: cdn.shopify.com / generator meta"))

    if "wordpress" in headers.get("x-powered-by", "") or "/wp-content/" in body:
        signals.append(_Signal(Platform.WOOCOMMERCE, 0.4, "root: wordpress hint (woo requires confirmation)"))
    if "woocommerce" in body:
        signals.append(_Signal(Platform.WOOCOMMERCE, 0.8, "root html: woocommerce string"))

    if "bigcommerce" in headers.get("x-powered-by", "") or "cdn11.bigcommerce.com" in body:
        signals.append(_Signal(Platform.BIGCOMMERCE, 0.85, "root: bigcommerce headers/cdn"))

    if "squarespace" in headers.get("server", "") or "static1.squarespace.com" in body:
        signals.append(_Signal(Platform.SQUARESPACE, 0.9, "root: squarespace server/cdn"))
    if 'content="squarespace' in body:
        signals.append(_Signal(Platform.SQUARESPACE, 0.85, "root html: squarespace generator meta"))

    if "webflow" in headers.get("server", "") or "assets.website-files.com" in body:
        signals.append(_Signal(Platform.WEBFLOW, 0.85, "root: webflow server/assets host"))
    if 'content="webflow"' in body or "data-wf-site" in body:
        signals.append(_Signal(Platform.WEBFLOW, 0.9, "root html: webflow generator/data-wf-site"))

    return signals


async def _probe_shopify_products(client: httpx.AsyncClient, origin: str) -> list[_Signal]:
    try:
        r = await client.get(origin + "/products.json?limit=1")
    except httpx.HTTPError:
        return []
    if r.status_code != 200:
        return []
    ctype = r.headers.get("content-type", "").lower()
    if "json" not in ctype:
        return []
    try:
        data = r.json()
    except ValueError:
        return []
    if isinstance(data, dict) and "products" in data:
        return [_Signal(Platform.SHOPIFY, 0.98, "/products.json returned Shopify shape")]
    return []


async def _probe_wp_json(client: httpx.AsyncClient, origin: str) -> list[_Signal]:
    try:
        r = await client.get(origin + "/wp-json/")
    except httpx.HTTPError:
        return []
    if r.status_code != 200 or "json" not in r.headers.get("content-type", "").lower():
        return []
    try:
        data = r.json()
    except ValueError:
        return []
    if not isinstance(data, dict):
        return []
    namespaces = data.get("namespaces") or []
    if isinstance(namespaces, list) and any("wc/" in str(n) for n in namespaces):
        return [_Signal(Platform.WOOCOMMERCE, 0.98, "/wp-json/ lists wc/* namespace")]
    return [_Signal(Platform.WOOCOMMERCE, 0.5, "/wp-json/ present but no wc/* namespace")]


async def _probe_bigcommerce_storefront(client: httpx.AsyncClient, origin: str) -> list[_Signal]:
    try:
        r = await client.get(origin + "/api/storefront/products?limit=1")
    except httpx.HTTPError:
        return []
    if r.status_code != 200 or "json" not in r.headers.get("content-type", "").lower():
        return []
    return [_Signal(Platform.BIGCOMMERCE, 0.95, "/api/storefront/products returned 200 JSON")]


_SQUARESPACE_RE = re.compile(r"squarespace\.com", re.I)
_WEBFLOW_RE = re.compile(r"webflow\.com|website-files\.com", re.I)


async def _probe_robots(client: httpx.AsyncClient, origin: str) -> list[_Signal]:
    try:
        r = await client.get(origin + "/robots.txt")
    except httpx.HTTPError:
        return []
    if r.status_code != 200:
        return []
    body = r.text[:50_000]
    signals: list[_Signal] = []
    if _SQUARESPACE_RE.search(body):
        signals.append(_Signal(Platform.SQUARESPACE, 0.8, "robots.txt references squarespace.com"))
    if _WEBFLOW_RE.search(body):
        signals.append(_Signal(Platform.WEBFLOW, 0.8, "robots.txt references webflow/website-files"))
    return signals


_PROBES = (
    _probe_root,
    _probe_shopify_products,
    _probe_wp_json,
    _probe_bigcommerce_storefront,
    _probe_robots,
)


async def detect_async(domain: str) -> Detection:
    origin = _normalize_origin(domain)
    collected: list[_Signal] = []

    async with httpx.AsyncClient(
        timeout=_PROBE_TIMEOUT,
        headers=_DEFAULT_HEADERS,
        follow_redirects=False,
        http2=False,
    ) as client:

        async def _run(probe):
            try:
                with anyio.fail_after(1.8):
                    collected.extend(await probe(client, origin))
            except TimeoutError:
                pass

        async with anyio.create_task_group() as tg:
            for probe in _PROBES:
                tg.start_soon(_run, probe)

    return _score(collected)


def _score(signals: Iterable[_Signal]) -> Detection:
    """Pick the platform with the highest single-signal confidence; carry the evidence."""
    best: dict[Platform, float] = {}
    evidence_by_platform: dict[Platform, list[str]] = {}
    for s in signals:
        evidence_by_platform.setdefault(s.platform, []).append(s.note)
        if s.confidence > best.get(s.platform, 0.0):
            best[s.platform] = s.confidence

    if not best:
        return Detection(Platform.CUSTOM, 0.0, [])

    platform, confidence = max(best.items(), key=lambda kv: kv[1])
    return Detection(platform, confidence, evidence_by_platform[platform])


def detect(domain: str) -> Detection:
    """Synchronous wrapper for callers that aren't already in an event loop."""
    return anyio.run(detect_async, domain)


def _cli() -> int:
    import json

    if len(sys.argv) != 2:
        print("usage: python -m brandnana_crawler.fingerprint <domain>", file=sys.stderr)
        return 2
    result = detect(sys.argv[1])
    print(json.dumps(result.to_dict(), indent=2))
    return 0


if __name__ == "__main__":
    sys.exit(_cli())
