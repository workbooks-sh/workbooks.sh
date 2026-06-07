"""Generic sitemap walker + structured-data extractor.

Strategy:
  1. Discover sitemap URLs from /robots.txt (Sitemap: directives), falling
     back to /sitemap.xml, /sitemap_index.xml, /sitemap.xml.gz.
  2. Recursively expand sitemap indexes into URL sets.
  3. Filter likely product URLs by path heuristics.
  4. Fetch each candidate concurrently (bounded), parse with selectolax,
     and extract a Product via two layers, in priority order:
       a. JSON-LD (schema.org Product) — most reliable
       b. Open Graph + product:* meta tags
  5. Emit product + product_image + stats JSONL rows.

Covers most non-Shopify storefronts (WooCommerce, BigCommerce, Squarespace,
Webflow, custom carts) when those expose sitemaps and embed structured data —
which the major SEO platforms all do by default.
"""

from __future__ import annotations

import asyncio
import gzip
import json
import re
import time
import uuid
import xml.etree.ElementTree as ET
from collections.abc import AsyncIterator, Iterable
from dataclasses import dataclass, field
from typing import Any
from urllib.parse import urlparse

import httpx
from selectolax.parser import HTMLParser

from .fingerprint import _normalize_origin  # noqa: PLC2701

_USER_AGENT = "brandnana-crawler/0.1 (+https://brandnana.net)"
_FETCH_TIMEOUT = httpx.Timeout(connect=3.0, read=8.0, write=5.0, pool=5.0)
_DEFAULT_HEADERS = {"user-agent": _USER_AGENT, "accept": "*/*"}

_SITEMAP_NS = {"sm": "http://www.sitemaps.org/schemas/sitemap/0.9"}

_PRODUCT_PATH_RE = re.compile(
    r"/(?:product|products|p|shop|item|items|store)(?:/|$|\?)", re.IGNORECASE
)

_PRICE_NUM_RE = re.compile(r"\d+(?:[.,]\d{1,2})?")


@dataclass(slots=True)
class CrawlStats:
    products: int = 0
    images: int = 0
    urls_considered: int = 0
    urls_fetched: int = 0
    extraction_failures: int = 0
    errors: list[str] = field(default_factory=list)
    started_at: int = 0
    finished_at: int = 0

    def to_dict(self) -> dict[str, Any]:
        return {
            "__type": "stats",
            "products": self.products,
            "images": self.images,
            "urls_considered": self.urls_considered,
            "urls_fetched": self.urls_fetched,
            "extraction_failures": self.extraction_failures,
            "errors": list(self.errors),
            "started_at": self.started_at,
            "finished_at": self.finished_at,
        }


def _now_ms() -> int:
    return int(time.time() * 1000)


def _to_cents(value: Any) -> int | None:
    if value is None:
        return None
    if isinstance(value, (int, float)):
        return round(float(value) * 100)
    s = str(value).strip()
    if not s:
        return None
    m = _PRICE_NUM_RE.search(s)
    if not m:
        return None
    num = m.group(0).replace(",", ".")
    try:
        return round(float(num) * 100)
    except ValueError:
        return None


def _availability_to_int(value: Any) -> int:
    if not value:
        return 1
    s = str(value).lower()
    if "outofstock" in s or "out of stock" in s or "discontinued" in s:
        return 0
    return 1


# ---------------------------------------------------------------------------
# Sitemap discovery + parsing
# ---------------------------------------------------------------------------


async def _discover_sitemaps(client: httpx.AsyncClient, origin: str) -> list[str]:
    candidates: list[str] = []
    try:
        r = await client.get(origin + "/robots.txt")
        if r.status_code == 200:
            for line in r.text.splitlines():
                stripped = line.strip()
                if stripped.lower().startswith("sitemap:"):
                    url = stripped.split(":", 1)[1].strip()
                    if url:
                        candidates.append(url)
    except httpx.HTTPError:
        pass

    if not candidates:
        for path in ("/sitemap.xml", "/sitemap_index.xml", "/sitemap.xml.gz"):
            try:
                r = await client.head(origin + path)
            except httpx.HTTPError:
                continue
            if r.status_code < 400:
                candidates.append(origin + path)
    return candidates


async def _fetch_sitemap_body(client: httpx.AsyncClient, url: str) -> bytes | None:
    try:
        r = await client.get(url)
    except httpx.HTTPError:
        return None
    if r.status_code != 200:
        return None
    body = r.content
    if url.endswith(".gz") or body[:2] == b"\x1f\x8b":
        try:
            body = gzip.decompress(body)
        except (OSError, EOFError):
            return None
    return body


def _parse_sitemap_xml(body: bytes) -> tuple[list[str], list[str]]:
    """Returns (sub_sitemap_urls, page_urls)."""
    try:
        root = ET.fromstring(body)
    except ET.ParseError:
        return [], []
    tag = root.tag.split("}", 1)[-1]
    if tag == "sitemapindex":
        locs = [
            (loc.text or "").strip()
            for loc in root.findall(".//sm:sitemap/sm:loc", _SITEMAP_NS)
        ]
        return [u for u in locs if u], []
    if tag == "urlset":
        locs = [
            (loc.text or "").strip()
            for loc in root.findall(".//sm:url/sm:loc", _SITEMAP_NS)
        ]
        return [], [u for u in locs if u]
    return [], []


async def _expand_sitemaps(
    client: httpx.AsyncClient, sitemap_urls: list[str], max_urls: int
) -> list[str]:
    seen: set[str] = set()
    queue: list[str] = list(sitemap_urls)
    urls: list[str] = []

    while queue and len(urls) < max_urls:
        next_url = queue.pop(0)
        if next_url in seen:
            continue
        seen.add(next_url)
        body = await _fetch_sitemap_body(client, next_url)
        if not body:
            continue
        sub, pages = _parse_sitemap_xml(body)
        queue.extend(sub)
        for u in pages:
            urls.append(u)
            if len(urls) >= max_urls:
                break
    return urls


def _filter_product_urls(urls: Iterable[str], origin: str) -> list[str]:
    origin_host = urlparse(origin).netloc
    out: list[str] = []
    for u in urls:
        parsed = urlparse(u)
        if parsed.netloc and parsed.netloc != origin_host:
            continue
        if _PRODUCT_PATH_RE.search(parsed.path):
            out.append(u)
    return out


# ---------------------------------------------------------------------------
# Structured-data extraction
# ---------------------------------------------------------------------------


def _iter_jsonld_blocks(tree: HTMLParser) -> Iterable[Any]:
    for script in tree.css('script[type="application/ld+json"]'):
        text = (script.text(deep=True, separator="") or "").strip()
        if not text:
            continue
        try:
            data = json.loads(text)
        except json.JSONDecodeError:
            continue
        yield data


def _walk_jsonld_products(node: Any) -> Iterable[dict[str, Any]]:
    if isinstance(node, list):
        for item in node:
            yield from _walk_jsonld_products(item)
        return
    if not isinstance(node, dict):
        return
    graph = node.get("@graph")
    if isinstance(graph, list):
        yield from _walk_jsonld_products(graph)
    typ = node.get("@type")
    types: list[str] = []
    if isinstance(typ, str):
        types = [typ]
    elif isinstance(typ, list):
        types = [str(t) for t in typ if isinstance(t, str)]
    if any(t.lower() == "product" for t in types):
        yield node


def _extract_offers_price(offers: Any) -> tuple[int | None, str | None, int]:
    """Returns (price_cents, currency, available_int) from a schema.org offers field."""
    if isinstance(offers, list):
        candidates = offers
    elif isinstance(offers, dict):
        candidates = [offers]
    else:
        return None, None, 1
    price_cents: int | None = None
    currency: str | None = None
    available = 1
    for offer in candidates:
        if not isinstance(offer, dict):
            continue
        cents = _to_cents(offer.get("price") or offer.get("lowPrice"))
        if cents is not None and (price_cents is None or cents < price_cents):
            price_cents = cents
        if currency is None:
            cur = offer.get("priceCurrency")
            if isinstance(cur, str):
                currency = cur
        if available == 1:
            available = _availability_to_int(offer.get("availability"))
    return price_cents, currency, available


def _extract_jsonld_product(tree: HTMLParser) -> dict[str, Any] | None:
    for block in _iter_jsonld_blocks(tree):
        for product in _walk_jsonld_products(block):
            name = product.get("name")
            if not isinstance(name, str) or not name.strip():
                continue
            price_cents, currency, available = _extract_offers_price(product.get("offers"))
            images: list[str] = []
            raw_image = product.get("image")
            if isinstance(raw_image, str):
                images = [raw_image]
            elif isinstance(raw_image, list):
                for item in raw_image:
                    if isinstance(item, str):
                        images.append(item)
                    elif isinstance(item, dict) and isinstance(item.get("url"), str):
                        images.append(item["url"])
            return {
                "source": "jsonld",
                "title": name.strip(),
                "description": product.get("description")
                if isinstance(product.get("description"), str)
                else None,
                "price_cents": price_cents,
                "currency": currency,
                "available": available,
                "external_id": product.get("sku") or product.get("productID"),
                "images": images,
            }
    return None


_OG_KEYS = {
    "og:title": "title",
    "og:description": "description",
    "og:image": "image",
    "og:image:secure_url": "image",
    "product:price:amount": "price",
    "og:price:amount": "price",
    "product:price:currency": "currency",
    "og:price:currency": "currency",
    "product:availability": "availability",
    "og:availability": "availability",
    "product:retailer_item_id": "external_id",
}


def _extract_og_product(tree: HTMLParser) -> dict[str, Any] | None:
    meta: dict[str, list[str]] = {}
    for tag in tree.css("meta"):
        prop = tag.attributes.get("property") or tag.attributes.get("name")
        content = tag.attributes.get("content")
        if not prop or content is None:
            continue
        key = _OG_KEYS.get(prop.lower())
        if key is None:
            continue
        meta.setdefault(key, []).append(content)

    if "title" not in meta:
        return None

    return {
        "source": "opengraph",
        "title": (meta.get("title") or [""])[0].strip(),
        "description": (meta.get("description") or [None])[0],
        "price_cents": _to_cents((meta.get("price") or [None])[0]),
        "currency": (meta.get("currency") or [None])[0],
        "available": _availability_to_int((meta.get("availability") or [None])[0]),
        "external_id": (meta.get("external_id") or [None])[0],
        "images": meta.get("image", []),
    }


def _extract_product(tree: HTMLParser) -> dict[str, Any] | None:
    return _extract_jsonld_product(tree) or _extract_og_product(tree)


# ---------------------------------------------------------------------------
# Crawl orchestration
# ---------------------------------------------------------------------------


async def _fetch_html(client: httpx.AsyncClient, url: str) -> str | None:
    try:
        r = await client.get(url)
    except httpx.HTTPError:
        return None
    if r.status_code != 200:
        return None
    ctype = r.headers.get("content-type", "").lower()
    if "html" not in ctype:
        return None
    return r.text


async def crawl(
    domain: str,
    *,
    brand_id: str,
    platform_label: str = "custom",
    max_urls: int = 500,
    concurrency: int = 8,
) -> AsyncIterator[dict[str, Any]]:
    """Yield product + product_image + stats rows from sitemap-discovered URLs."""
    origin = _normalize_origin(domain)
    stats = CrawlStats(started_at=_now_ms())

    async with httpx.AsyncClient(
        timeout=_FETCH_TIMEOUT,
        headers=_DEFAULT_HEADERS,
        follow_redirects=True,
        http2=False,
    ) as client:
        sitemap_urls = await _discover_sitemaps(client, origin)
        if not sitemap_urls:
            stats.errors.append("no sitemap discovered (robots.txt or /sitemap.xml)")
            stats.finished_at = _now_ms()
            yield stats.to_dict()
            return

        all_urls = await _expand_sitemaps(client, sitemap_urls, max_urls=max_urls * 4)
        product_urls = _filter_product_urls(all_urls, origin)[:max_urls]
        stats.urls_considered = len(product_urls)

        sem = asyncio.Semaphore(concurrency)

        async def fetch_and_extract(url: str) -> tuple[str, dict[str, Any] | None]:
            async with sem:
                html = await _fetch_html(client, url)
            if html is None:
                return url, None
            return url, _extract_product(HTMLParser(html))

        tasks = [asyncio.create_task(fetch_and_extract(u)) for u in product_urls]

        for coro in asyncio.as_completed(tasks):
            url, extracted = await coro
            stats.urls_fetched += 1
            if extracted is None:
                stats.extraction_failures += 1
                continue

            now = _now_ms()
            product_id = str(uuid.uuid4())
            ext_id = extracted.get("external_id")
            yield {
                "__type": "product",
                "id": product_id,
                "brand_id": brand_id,
                "external_id": str(ext_id) if ext_id is not None else None,
                "url": url,
                "title": extracted["title"],
                "description": extracted.get("description"),
                "price_cents": extracted.get("price_cents"),
                "currency": extracted.get("currency"),
                "available": extracted.get("available", 1),
                "platform": platform_label,
                "raw_json": {
                    "source": extracted.get("source"),
                    "images": extracted.get("images", []),
                },
                "first_seen_at": now,
                "last_seen_at": now,
            }
            stats.products += 1

            for i, img_url in enumerate(extracted.get("images") or []):
                if not isinstance(img_url, str) or not img_url:
                    continue
                yield {
                    "__type": "product_image",
                    "id": str(uuid.uuid4()),
                    "product_id": product_id,
                    "url": img_url,
                    "alt": None,
                    "width": None,
                    "height": None,
                    "position": i,
                }
                stats.images += 1

    stats.finished_at = _now_ms()
    yield stats.to_dict()
