"""Shopify fast-path: walks /products.json pagination.

Shopify exposes a public, paginated JSON feed of every product on a store at
`/products.json?page=N&limit=250`. Page 1 starts at 1; an empty `products`
array signals the end. Storefront currency lives at `/meta.json`.

This adapter emits one row per product and one row per image, both as flat
dicts ready to be JSONL-streamed to the API. The API normalises rows into
the consumer's local SQLite (see `packages/schema/migrations/0001_init.sql`).
"""

from __future__ import annotations

import re
import time
import uuid
from collections.abc import AsyncIterator
from dataclasses import dataclass, field
from typing import Any

import httpx

from .fingerprint import _normalize_origin  # noqa: PLC2701  (intentional reuse)

_PAGE_SIZE = 250
_PAGE_TIMEOUT = httpx.Timeout(connect=3.0, read=8.0, write=5.0, pool=5.0)
_USER_AGENT = "brandnana-crawler/0.1 (+https://brandnana.net)"
_DEFAULT_HEADERS = {"user-agent": _USER_AGENT, "accept": "application/json"}

_HTML_TAG_RE = re.compile(r"<[^>]+>")
_WHITESPACE_RE = re.compile(r"\s+")


@dataclass(slots=True)
class CrawlStats:
    products: int = 0
    images: int = 0
    pages_fetched: int = 0
    errors: list[str] = field(default_factory=list)
    started_at: int = 0
    finished_at: int = 0

    def to_dict(self) -> dict[str, Any]:
        return {
            "__type": "stats",
            "products": self.products,
            "images": self.images,
            "pages_fetched": self.pages_fetched,
            "errors": list(self.errors),
            "started_at": self.started_at,
            "finished_at": self.finished_at,
        }


def _strip_html(html: str | None) -> str | None:
    if not html:
        return None
    text = _HTML_TAG_RE.sub(" ", html)
    text = _WHITESPACE_RE.sub(" ", text).strip()
    return text or None


def _to_cents(price_str: str | None) -> int | None:
    """Shopify variant prices are strings like '19.99'. Convert to integer cents."""
    if price_str is None or price_str == "":
        return None
    try:
        return round(float(price_str) * 100)
    except (TypeError, ValueError):
        return None


def _now_ms() -> int:
    return int(time.time() * 1000)


async def _fetch_currency(client: httpx.AsyncClient, origin: str) -> str | None:
    try:
        r = await client.get(origin + "/meta.json")
    except httpx.HTTPError:
        return None
    if r.status_code != 200:
        return None
    try:
        data = r.json()
    except ValueError:
        return None
    currency = data.get("currency") if isinstance(data, dict) else None
    return currency if isinstance(currency, str) else None


async def _fetch_page(
    client: httpx.AsyncClient, origin: str, page: int
) -> list[dict[str, Any]]:
    r = await client.get(
        origin + "/products.json",
        params={"page": str(page), "limit": str(_PAGE_SIZE)},
    )
    if r.status_code == 404:
        return []
    r.raise_for_status()
    try:
        data = r.json()
    except ValueError as e:
        raise httpx.HTTPError(f"page {page}: invalid JSON ({e})") from e
    products = data.get("products") if isinstance(data, dict) else None
    if not isinstance(products, list):
        return []
    return products


def _row_for_product(
    raw: dict[str, Any], *, origin: str, brand_id: str, currency: str | None, now: int
) -> dict[str, Any]:
    handle = raw.get("handle") or ""
    variants = raw.get("variants") if isinstance(raw.get("variants"), list) else []

    price_cents: int | None = None
    available = False
    for v in variants:
        if not isinstance(v, dict):
            continue
        v_price = _to_cents(v.get("price"))
        if v_price is not None and (price_cents is None or v_price < price_cents):
            price_cents = v_price
        if v.get("available"):
            available = True

    return {
        "__type": "product",
        "id": str(uuid.uuid4()),
        "brand_id": brand_id,
        "external_id": str(raw["id"]) if raw.get("id") is not None else None,
        "url": f"{origin}/products/{handle}" if handle else origin,
        "title": raw.get("title") or "",
        "description": _strip_html(raw.get("body_html")),
        "price_cents": price_cents,
        "currency": currency,
        "available": 1 if available else 0,
        "platform": "shopify",
        "raw_json": raw,
        "first_seen_at": now,
        "last_seen_at": now,
    }


def _rows_for_images(raw: dict[str, Any], *, product_id: str) -> list[dict[str, Any]]:
    images = raw.get("images") if isinstance(raw.get("images"), list) else []
    rows: list[dict[str, Any]] = []
    for img in images:
        if not isinstance(img, dict):
            continue
        src = img.get("src")
        if not isinstance(src, str) or not src:
            continue
        rows.append(
            {
                "__type": "product_image",
                "id": str(uuid.uuid4()),
                "product_id": product_id,
                "url": src,
                "alt": img.get("alt"),
                "width": img.get("width"),
                "height": img.get("height"),
                "position": img.get("position") or 0,
            }
        )
    return rows


async def crawl(
    domain: str,
    *,
    brand_id: str,
    max_pages: int = 200,
) -> AsyncIterator[dict[str, Any]]:
    """Yield product + product_image rows for every product on a Shopify store.

    The final yielded row is a `__type: stats` summary. Caller is responsible
    for JSON-serialising each row (raw_json on product rows is a nested dict).
    """
    origin = _normalize_origin(domain)
    stats = CrawlStats(started_at=_now_ms())
    truncated = True

    async with httpx.AsyncClient(
        timeout=_PAGE_TIMEOUT,
        headers=_DEFAULT_HEADERS,
        follow_redirects=True,
        http2=False,
    ) as client:
        currency = await _fetch_currency(client, origin)

        for page in range(1, max_pages + 1):
            try:
                products = await _fetch_page(client, origin, page)
            except httpx.HTTPError as e:
                stats.errors.append(f"page {page}: {e}")
                truncated = False
                break

            stats.pages_fetched += 1
            if not products:
                truncated = False
                break

            for raw in products:
                if not isinstance(raw, dict):
                    continue
                now = _now_ms()
                product_row = _row_for_product(
                    raw, origin=origin, brand_id=brand_id, currency=currency, now=now
                )
                yield product_row
                stats.products += 1

                for img_row in _rows_for_images(raw, product_id=product_row["id"]):
                    yield img_row
                    stats.images += 1

            if len(products) < _PAGE_SIZE:
                truncated = False
                break

    if truncated:
        stats.errors.append(f"hit max_pages={max_pages}; catalog may be truncated")
    stats.finished_at = _now_ms()
    yield stats.to_dict()
