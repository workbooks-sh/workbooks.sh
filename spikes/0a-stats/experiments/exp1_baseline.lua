-- Experiment 1: event cadence at REAL rates on the design-doc flight clock.
-- Question: with NO event-density inflation — real hook/CTR/CVR, real CPM —
-- is the 180-second flight lively enough on a phone screen, per budget tier?
-- (domain.md warned "1 purchase per ~3,000 impressions"; the open question is
-- whether realistic per-flight budgets already deliver enough impressions.)
--
-- Usage: luajit spikes/0a-stats/experiments/exp1_baseline.lua

local base = arg[0]:match("^(.*)/experiments/[^/]+%.lua$") or "."
package.path = base .. "/../../?.lua;" .. base .. "/../../test/?.lua;" .. base .. "/?.lua;" .. package.path

local Rng = require("sim.rng")
local Funnel = require("sim.funnel")
local Flight = require("sim.flight")

local TRUTH = { hook_ppm = 280000, click_given_stop_ppm = 78571, cvr_ppm = 24000, aov_cents = 4500 }
local SEEDS = 200
local SCREEN_SECONDS = 5 * 36

print("exp1: event cadence at real rates — 5d x 36s x 10Hz flight (180s on screen), $12 CPM")
print("truth: hook 28% | CTR/imp 2.2% | CVR 2.4% | AOV $45   (mean of " .. SEEDS .. " seeded flights)")
print("")
print(("%-10s %9s %9s %9s %7s | %10s %11s %9s | %8s"):format(
  "budget/ad", "imps", "stops", "clicks", "buys", "stops/sec", "clicks/sec", "secs/buy", "ROAS"))

for _, budget_cents in ipairs({ 5000, 10000, 20000, 40000, 80000, 160000 }) do
  local cfg = { days = 5, seconds_per_day = 36, ticks_per_second = 10,
                budget_cents_per_ad = budget_cents, cpm_cents = 1200 }
  local plan = Flight.plan(cfg)
  local sum = { imps = 0, stops = 0, clicks = 0, buys = 0, revenue = 0, spend = 0 }
  for s = 1, SEEDS do
    local ad = Funnel.new_ad(TRUTH)
    Flight.run(plan, { ad }, { Rng.substream(s, "exp1-" .. budget_cents) })
    sum.imps = sum.imps + ad.imps
    sum.stops = sum.stops + ad.stops
    sum.clicks = sum.clicks + ad.clicks
    sum.buys = sum.buys + ad.buys
    sum.revenue = sum.revenue + ad.revenue_cents
    sum.spend = sum.spend + ad.spend_millicents / 1000
  end
  local n = SEEDS
  local buys_mean = sum.buys / n
  print(("$%-9.0f %9.0f %9.1f %9.1f %7.2f | %10.1f %11.2f %9s | %8.2f"):format(
    budget_cents / 100, sum.imps / n, sum.stops / n, sum.clicks / n, buys_mean,
    sum.stops / n / SCREEN_SECONDS, sum.clicks / n / SCREEN_SECONDS,
    buys_mean > 0 and ("%.1f"):format(SCREEN_SECONDS / buys_mean) or "—",
    sum.revenue / sum.spend))
end

print("")
print("read: stops/sec is the dot-funnel liveliness; secs/buy is the jackpot cadence;")
print("a CONVERT ceremony every ~5-15s feels alive, every ~60s+ feels dead.")
