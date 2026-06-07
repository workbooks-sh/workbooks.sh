-- Experiment 2: race resolution sweep — GATE CRITERION (a).
-- A meaningful A/B race must resolve within 1-2 flights at honest n.
-- Two ads split a test budget 50/50 (the Test Bench). Looks at each of the
-- 5 day boundaries per flight; races may carry over one extra flight
-- (docs/01-game-design.md: bench carry-over). Family alpha 0.05 over 10
-- looks → per-look 0.005 (Bonferroni, z=2.807).
--
-- Sweep: raced metric × effect size × test budget.
--   HOOK races: trials=imps        (the top-funnel, high-n race)
--   CTR  races: trials=imps        (clicks per impression)
--   CVR  races: trials=clicks      (purchases per click — the low-n race)
--
-- Usage: luajit spikes/0a-stats/experiments/exp2_races.lua

local base = arg[0]:match("^(.*)/experiments/[^/]+%.lua$") or "."
package.path = base .. "/../../?.lua;" .. base .. "/../../test/?.lua;" .. base .. "/?.lua;" .. package.path

local Rng = require("sim.rng")
local Funnel = require("sim.funnel")
local Flight = require("sim.flight")
local Sig = require("sim.significance")

local RACES = 400
local ZC = Sig.zcrit(0.005)
local N_MIN = 200 -- per arm, on the race's own trial denominator

local BASE = { hook_ppm = 280000, click_given_stop_ppm = 78571, cvr_ppm = 24000, aov_cents = 4500 }

local function clone(t) local c = {}; for k, v in pairs(t) do c[k] = v end; return c end

-- Each case: B is worse than A on exactly one knob (a clean test).
local CASES = {
  { metric = "HOOK", label = "28% vs 26%  (-2pt)",  knob = "hook_ppm",            b = 260000 },
  { metric = "HOOK", label = "28% vs 24%  (-4pt)",  knob = "hook_ppm",            b = 240000 },
  { metric = "HOOK", label = "28% vs 20%  (-8pt)",  knob = "hook_ppm",            b = 200000 },
  { metric = "CTR",  label = "2.2% vs 1.9% (-15%)", knob = "click_given_stop_ppm", b = 66786 },
  { metric = "CTR",  label = "2.2% vs 1.65%(-25%)", knob = "click_given_stop_ppm", b = 58929 },
  { metric = "CVR",  label = "2.4% vs 1.8% (-25%)", knob = "cvr_ppm",             b = 18000 },
  { metric = "CVR",  label = "2.4% vs 1.2% (-50%)", knob = "cvr_ppm",             b = 12000 },
}

local function counts(ad, metric)
  if metric == "HOOK" then return ad.stops, ad.imps
  elseif metric == "CTR" then return ad.clicks, ad.imps
  else return ad.buys, ad.clicks end
end

print(("exp2: race resolution — bench 50/50 split, looks at day ends, carry-over 1 flight"))
print(("z=%.3f (family alpha 0.05 over 10 looks), n_min=%d/arm on the raced denominator, %d seeded races/case"):format(ZC, N_MIN, RACES))
print("")
print(("%-5s %-20s %-10s | %8s %8s %8s | %9s %7s"):format(
  "race", "effect", "bench $", "fl.1", "fl.1-2", "never", "med. day", "wrong%"))

for _, case in ipairs(CASES) do
  for _, bench_budget in ipairs({ 20000, 40000, 80000 }) do
    local cfg = { days = 5, seconds_per_day = 36, ticks_per_second = 10,
                  budget_cents_per_ad = bench_budget / 2, cpm_cents = 1200 }
    local plan = Flight.plan(cfg)
    local r1, r2, never, wrong = 0, 0, 0, 0
    local days_list = {}

    for s = 1, RACES do
      local truthB = clone(BASE); truthB[case.knob] = case.b
      local adA = Funnel.new_ad(BASE)
      local adB = Funnel.new_ad(truthB)
      local rngA = Rng.substream(s, "exp2A-" .. case.label .. bench_budget)
      local rngB = Rng.substream(s, "exp2B-" .. case.label .. bench_budget)
      local resolved_day, winner = nil, nil

      for flight = 1, 2 do
        Flight.run(plan, { adA, adB }, { rngA, rngB }, function(t, day, is_day_end)
          if not is_day_end then return false end
          local sa, na = counts(adA, case.metric)
          local sb, nb = counts(adB, case.metric)
          local w = Sig.compare(sa, na, sb, nb, ZC, N_MIN)
          if w then
            winner = w
            resolved_day = (flight - 1) * 5 + day
            return true
          end
          return false
        end)
        if winner then break end
      end

      if not winner then never = never + 1
      else
        if winner == "B" then wrong = wrong + 1 end
        days_list[#days_list + 1] = resolved_day
        if resolved_day <= 5 then r1 = r1 + 1 else r2 = r2 + 1 end
      end
    end

    table.sort(days_list)
    local med = #days_list > 0 and days_list[math.ceil(#days_list / 2)] or -1
    print(("%-5s %-20s $%-9.0f | %7.0f%% %7.0f%% %7.0f%% | %9s %6.1f%%"):format(
      case.metric, case.label, bench_budget / 100,
      100 * r1 / RACES, 100 * (r1 + r2) / RACES, 100 * never / RACES,
      med > 0 and tostring(med) or "—", 100 * wrong / RACES))
  end
end

print("")
print("gate (a) read: a race class 'works' when fl.1-2 ≥ ~90% and wrong% ≈ 0.")
print("expected shape: HOOK resolves fast (huge n), CVR needs carry-over or bigger gaps —")
print("that asymmetry is itself the curriculum (top-funnel reads fast, bottom-funnel needs patience).")
