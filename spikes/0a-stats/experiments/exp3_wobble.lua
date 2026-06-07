-- Experiment 3: wobble/lead-flip drama vs verdict honesty — GATE CRITERION (b).
-- The tug-of-war meter shows the RAW observed leader continuously; the bell
-- rings only at corrected significance. For the peeking lesson to be FELT:
--   - early leads must flip visibly (drama),
--   - calling the raw leader early must be measurably wrong,
--   - the bell must stay ~always right.
-- $400 bench (the exp2-validated floor), leader sampled every 36 ticks (3.6s).
--
-- Usage: luajit spikes/0a-stats/experiments/exp3_wobble.lua

local base = arg[0]:match("^(.*)/experiments/[^/]+%.lua$") or "."
package.path = base .. "/../../?.lua;" .. base .. "/../../test/?.lua;" .. base .. "/?.lua;" .. package.path

local Rng = require("sim.rng")
local Funnel = require("sim.funnel")
local Flight = require("sim.flight")
local Sig = require("sim.significance")

local RACES = 400
local ZC = Sig.zcrit(0.005)
local BASE = { hook_ppm = 280000, click_given_stop_ppm = 78571, cvr_ppm = 24000, aov_cents = 4500 }
local CASES = {
  { label = "HOOK 28%% vs 26%% (-2pt, subtle)", b_hook = 260000 },
  { label = "HOOK 28%% vs 24%% (-4pt, standard)", b_hook = 240000 },
}
-- checkpoints in ticks (10Hz): 10s, 30s, end of day 1/2/3 (36s days)
local CHECKS = { { 100, "10s" }, { 300, "30s" }, { 360, "day1" }, { 720, "day2" }, { 1080, "day3" } }

local cfg = { days = 5, seconds_per_day = 36, ticks_per_second = 10,
              budget_cents_per_ad = 20000, cpm_cents = 1200 } -- $400 bench, 50/50
local plan = Flight.plan(cfg)

print("exp3: tug-of-war wobble vs bell honesty — $400 bench, truth: A wins")
print(("leader sampled every 3.6s once both arms have ≥300 imps; bell: z=%.3f at day ends, n_min=200"):format(ZC))
print("")
print(("%-32s %7s %11s %11s | %5s %5s %5s %5s %5s | %7s %7s %8s"):format(
  "case", "flips", "P(flip>10s)", "P(flip>d1)", "10s", "30s", "d1", "d2", "d3", "bell%", "wrong%", "med.day"))

for _, case in ipairs(CASES) do
  local truthB = {}
  for k, v in pairs(BASE) do truthB[k] = v end
  truthB.hook_ppm = case.b_hook

  local tot_flips, flip_after_10s, flip_after_d1 = 0, 0, 0
  local wrong_at = {} -- checkpoint label → count of races where raw leader was B
  for _, c in ipairs(CHECKS) do wrong_at[c[2]] = 0 end
  local bell_resolved, bell_wrong, bell_days = 0, 0, {}

  for s = 1, RACES do
    local adA, adB = Funnel.new_ad(BASE), Funnel.new_ad(truthB)
    local rngA = Rng.substream(s, "exp3A" .. case.b_hook)
    local rngB = Rng.substream(s, "exp3B" .. case.b_hook)

    local flips, prev_leader = 0, nil
    local f10, fd1 = false, false
    local belled = nil

    Flight.run(plan, { adA, adB }, { rngA, rngB }, function(t, day, is_day_end)
      if t % 36 == 0 and adA.imps >= 300 and adB.imps >= 300 then
        local ra, rb = adA.stops / adA.imps, adB.stops / adB.imps
        if ra ~= rb then
          local leader = ra > rb and "A" or "B"
          if prev_leader and leader ~= prev_leader then
            flips = flips + 1
            if t > 100 then f10 = true end
            if t > 360 then fd1 = true end
          end
          prev_leader = leader
        end
      end
      for _, c in ipairs(CHECKS) do
        if t == c[1] then
          local ra, rb = adA.stops / adA.imps, adB.stops / adB.imps
          if rb >= ra then wrong_at[c[2]] = wrong_at[c[2]] + 1 end
        end
      end
      if is_day_end and not belled then
        local w = Sig.compare(adA.stops, adA.imps, adB.stops, adB.imps, ZC, 200)
        if w then
          belled = { winner = w, day = day }
        end
      end
      return false -- run full flight; bell recorded, race shown to the end
    end)

    tot_flips = tot_flips + flips
    if f10 then flip_after_10s = flip_after_10s + 1 end
    if fd1 then flip_after_d1 = flip_after_d1 + 1 end
    if belled then
      bell_resolved = bell_resolved + 1
      if belled.winner == "B" then bell_wrong = bell_wrong + 1 end
      bell_days[#bell_days + 1] = belled.day
    end
  end

  table.sort(bell_days)
  local med = #bell_days > 0 and bell_days[math.ceil(#bell_days / 2)] or -1
  print((("%-32s %7.1f %10.0f%% %10.0f%% | %4.0f%% %4.0f%% %4.0f%% %4.0f%% %4.0f%% | %6.0f%% %6.1f%% %8s"):format(
    case.label:gsub("%%%%", "%%"), tot_flips / RACES,
    100 * flip_after_10s / RACES, 100 * flip_after_d1 / RACES,
    100 * wrong_at["10s"] / RACES, 100 * wrong_at["30s"] / RACES,
    100 * wrong_at["day1"] / RACES, 100 * wrong_at["day2"] / RACES, 100 * wrong_at["day3"] / RACES,
    100 * bell_resolved / RACES, bell_resolved > 0 and 100 * bell_wrong / bell_resolved or 0,
    med > 0 and tostring(med) or "—")))
end

print("")
print("gate (b) read: drama = flips + double-digit wrong%% at 10-30s; honesty = bell wrong%% ≈ 0.")
print("'wrong at 10s' is the premature-call cost the CALL IT verb makes a felt lesson.")
