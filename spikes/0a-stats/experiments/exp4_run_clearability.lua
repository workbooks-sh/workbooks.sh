-- Experiment 4: Monte-Carlo run clearability — GATE CRITERION (c).
-- "Multiple discovery paths clear a 6-wave run; decision quality dominates noise."
-- Mini run economy: 8 hook cards with hidden per-run true rates (Layer-2 seeded),
-- 2 ads/wave at $400 each, escalating ROAS briefs, 3 trust pips, consecutive-use
-- fatigue. Three policies play the SAME seeded worlds:
--   RANDOM     ignores all data, plays 2 random hooks every wave
--   HEURISTIC  tests in early waves, exploits observed winners, rests fatigued cards
--   ORACLE     knows true rates, rotates its top cards around fatigue
--
-- Usage: luajit spikes/0a-stats/experiments/exp4_run_clearability.lua

local base = arg[0]:match("^(.*)/experiments/[^/]+%.lua$") or "."
package.path = base .. "/../../?.lua;" .. base .. "/../../test/?.lua;" .. base .. "/?.lua;" .. package.path

local Rng = require("sim.rng")
local Funnel = require("sim.funnel")
local Flight = require("sim.flight")

local RUNS = 300
local WAVES = 6
local POOL = 8
local PIPS = 3
local ROAS_LINE = { 1.40, 1.55, 1.65, 1.75, 1.85, 1.90 } -- escalating briefs
local FATIGUE_PER_USE = 0.10 -- relative hook decay per consecutive reuse (caps at 3)
local BASEC = { click_given_stop_ppm = 78571, cvr_ppm = 24000, aov_cents = 4500 }
local CFG = { days = 5, seconds_per_day = 36, ticks_per_second = 10,
              budget_cents_per_ad = 40000, cpm_cents = 1200 }
local plan = Flight.plan(CFG)

-- Build one hidden world: 8 hooks with true rates ~U(18%, 32%) (Layer-2 seed).
local function make_world(seed)
  local rng = Rng.substream(seed, "world")
  local hooks = {}
  for i = 1, POOL do
    hooks[i] = { base_ppm = 180000 + rng:next_u32() % 140001, consec = 0, observed = nil }
  end
  return hooks
end

local function effective_ppm(h)
  local f = math.min(h.consec, 3) * FATIGUE_PER_USE
  return math.floor(h.base_ppm * (1 - f))
end

-- Play one wave: returns combined ROAS and per-pick observed hook rates.
local function play_wave(world, picks, rng_seed, wave)
  local ads, rngs = {}, {}
  for i, idx in ipairs(picks) do
    local h = world[idx]
    ads[i] = Funnel.new_ad({ hook_ppm = effective_ppm(h),
      click_given_stop_ppm = BASEC.click_given_stop_ppm,
      cvr_ppm = BASEC.cvr_ppm, aov_cents = BASEC.aov_cents })
    rngs[i] = Rng.substream(rng_seed, "w" .. wave .. "ad" .. i)
  end
  Flight.run(plan, ads, rngs)
  local rev, spend = 0, 0
  for i, idx in ipairs(picks) do
    rev = rev + ads[i].revenue_cents
    spend = spend + ads[i].spend_millicents / 1000
    world[idx].observed = ads[i].stops / ads[i].imps -- noisy evidence (real n)
  end
  -- fatigue bookkeeping: used cards accrue consecutive use, rested cards recover
  local used = {}
  for _, idx in ipairs(picks) do used[idx] = true end
  for i, h in ipairs(world) do
    if used[i] then h.consec = h.consec + 1 else h.consec = 0 end
  end
  return rev / spend
end

local function top2(world, key)
  local order = {}
  for i = 1, POOL do order[i] = i end
  table.sort(order, function(a, b) return key(world[a]) > key(world[b]) end)
  return order
end

local POLICIES = {
  RANDOM = function(world, wave, rng)
    local a = 1 + rng:next_u32() % POOL
    local b = 1 + rng:next_u32() % POOL
    while b == a do b = 1 + rng:next_u32() % POOL end
    return { a, b }
  end,

  -- Test new cards while exploiting the observed best; rest anything fatigued.
  HEURISTIC = function(world, wave, rng)
    -- candidates: prefer unfatigued cards; rank by observed rate (untested = explore)
    local untested = {}
    for i, h in ipairs(world) do
      if not h.observed and h.consec == 0 then untested[#untested + 1] = i end
    end
    local ranked = top2(world, function(h)
      local v = h.observed or 0.31 -- optimism drives exploration of untested cards
      if h.consec >= 2 then v = v - 0.06 end -- back off visibly tired cards
      return v
    end)
    local first = ranked[1]
    local second = (wave <= 2 and untested[1] and untested[1] ~= first) and untested[1] or ranked[2]
    return { first, second }
  end,

  ORACLE = function(world, wave, rng)
    local ranked = top2(world, function(h) return effective_ppm(h) end)
    return { ranked[1], ranked[2] }
  end,
}

print(("exp4: run clearability — %d seeded worlds × 3 policies, %d waves, %d pips"):format(RUNS, WAVES, PIPS))
print(("briefs (ROAS line): %s | fatigue: -%.0f%%/consecutive use | pool: %d hooks U(18%%,32%%)"):format(
  table.concat(ROAS_LINE, " "), FATIGUE_PER_USE * 100, POOL))
print("")
print(("%-10s %8s %10s %10s %12s"):format("policy", "cleared", "avg waves", "avg pips", "avg ROAS w4-6"))

for _, name in ipairs({ "RANDOM", "HEURISTIC", "ORACLE" }) do
  local cleared, waves_sum, pips_sum, late_roas, late_n = 0, 0, 0, 0, 0
  for s = 1, RUNS do
    local world = make_world(s)
    local prng = Rng.substream(s, "policy" .. name)
    local pips, w = PIPS, 0
    while w < WAVES do
      w = w + 1
      local picks = POLICIES[name](world, w, prng)
      local roas = play_wave(world, picks, s * 100 + w, w)
      if w >= 4 then late_roas = late_roas + roas; late_n = late_n + 1 end
      if roas < ROAS_LINE[w] then
        pips = pips - 1
        if pips <= 0 then break end
      end
    end
    local survived = (w == WAVES) and (pips > 0)
    if survived then cleared = cleared + 1 end
    waves_sum = waves_sum + w
    pips_sum = pips_sum + math.max(pips, 0)
  end
  print(("%-10s %7.0f%% %10.1f %10.1f %12.2f"):format(
    name, 100 * cleared / RUNS, waves_sum / RUNS, pips_sum / RUNS, late_roas / late_n))
end

print("")
print("gate (c) read: decision quality must dominate noise — ORACLE >> RANDOM with")
print("HEURISTIC close to ORACLE (a learnable path exists between them).")
