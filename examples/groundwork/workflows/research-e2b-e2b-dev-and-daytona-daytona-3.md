# Research E2B and Daytona Pricing

## TODO Gather E2B Pricing Information

- Ordered: yes
- Use `curl` to download the official E2B pricing page (e.g., https://e2b.dev/pricing) and save it to `scratch/e2b_pricing.html`.
- Verify download succeeded: `test -s scratch/e2b_pricing.html`.
- done-when: `test -s scratch/e2b_pricing.html`

## TODO Gather Daytona Pricing Information

- Ordered: yes
- Use `curl` to download the official Daytona pricing page (e.g., https://daytona.io/pricing) and save it to `scratch/daytona_pricing.html`.
- Verify download succeeded: `test -s scratch/daytona_pricing.html`.
- done-when: `test -s scratch/daytona_pricing.html`

## TODO Extract Pricing Details from E2B Page

- Ordered: yes
- Parse `scratch/e2b_pricing.html` with `grep`/`sed`/`awk` or a small Python script to extract:
  - Charge per sandbox/instance
  - Free tier description
  - Billing granularity (per-second vs per-minute)
  - Resource tier pricing (CPU, RAM)
  - Storage costs
  - Pay-as-you-go vs committed options
- Write structured key-value pairs to `scratch/e2b_pricing.md`.
- done-when: `test -s scratch/e2b_pricing.md`

## TODO Extract Pricing Details from Daytona Page

- Ordered: yes
- Parse `scratch/daytona_pricing.html` similarly to extract the same set of fields as for E2B.
- Write results to `scratch/daytona_pricing.md`.
- done-when: `test -s scratch/daytona_pricing.md`

## TODO Search Recent Articles (2024-2025) for Real-World Costs

- Ordered: yes
- Use `curl` or `wget` to query Google Scholar, Hacker News, Reddit, and dev blogs for "E2B pricing 2024", "Daytona pricing 2025", "E2B sandbox cost", "Daytona instance cost".
- Save the first 5 relevant URLs and brief excerpts (≤2 sentences) to `scratch/articles_summary.md`.
- Ensure each entry includes the URL and a citation date.
- done-when: `test -s scratch/articles_summary.md`

## TODO Consolidate Findings into Report

- Ordered: yes
- Combine `scratch/e2b_pricing.md`, `scratch/daytona_pricing.md`, and `scratch/articles_summary.md` into a single report file `scratch/REPORT.md`.
- Format the report with clear sections:
  - E2B Pricing Overview
  - Daytona Pricing Overview
  - Comparison Table (sandbox cost, free tier, billing granularity, CPU/RAM tiers, storage, payment model)
  - Sources (list of URLs)
- Verify the report exists and is non-empty.
- done-when: `test -s scratch/REPORT.md`
