"""Entrypoint: `python -m brandnana_crawler.main --domain <domain>`.

Detects platform, dispatches to the right adapter, emits Product /
ProductImage / stats rows as JSONL on stdout. Stderr is reserved for
progress logs.
"""

from __future__ import annotations

import argparse
import asyncio
import json
import sys
import uuid
from collections.abc import AsyncIterator
from typing import Any

from .fingerprint import Platform, detect_async
from .shopify import crawl as shopify_crawl
from .sitemap import crawl as sitemap_crawl


async def _dispatch(
    domain: str, strategy: str, brand_id: str
) -> AsyncIterator[dict[str, Any]]:
    chosen: Platform
    if strategy == "auto":
        detection = await detect_async(domain)
        print(
            f"fingerprint: {detection.platform.value} ({detection.confidence:.2f})",
            file=sys.stderr,
        )
        chosen = detection.platform
    elif strategy == "shopify":
        chosen = Platform.SHOPIFY
    elif strategy == "sitemap":
        chosen = Platform.CUSTOM
    else:
        chosen = Platform.CUSTOM

    if chosen is Platform.SHOPIFY and strategy != "sitemap":
        async for row in shopify_crawl(domain, brand_id=brand_id):
            yield row
        return

    async for row in sitemap_crawl(
        domain, brand_id=brand_id, platform_label=chosen.value
    ):
        yield row


async def _stream(domain: str, strategy: str, brand_id: str) -> int:
    write = sys.stdout.write
    async for row in _dispatch(domain, strategy, brand_id):
        write(json.dumps(row, separators=(",", ":"), default=str))
        write("\n")
        sys.stdout.flush()
    return 0


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--domain", required=True)
    parser.add_argument(
        "--strategy",
        default="auto",
        choices=["auto", "shopify", "sitemap", "generic"],
    )
    parser.add_argument(
        "--brand-id",
        default=None,
        help="UUID for the brand row these products belong to (auto-generated if omitted)",
    )
    args = parser.parse_args()
    brand_id = args.brand_id or str(uuid.uuid4())
    return asyncio.run(_stream(args.domain, args.strategy, brand_id))


if __name__ == "__main__":
    sys.exit(main())
