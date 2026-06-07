//! Data types for the wave state machine. Lives here so wave.rs stays < 500 LOC.
use crate::funnel::{Ad, Truth};
use crate::rng::Rng;

// ------------------------------------------------------------------ config

#[derive(Clone)]
pub struct DayMods {
    pub volume_x1000: Vec<i64>,
    pub cpm_x1000: Vec<i64>,
}

#[derive(Clone)]
pub struct FlightCfg {
    pub cpm_cents: i64,
    pub days: i64,
    pub seconds_per_day: i64,
    pub ticks_per_second: i64,
    pub day_mods: Option<DayMods>,
}

#[derive(Clone)]
pub struct Client {
    pub id: String,
    pub multiples: Vec<i64>,
    pub base_target_cents: i64,
    pub spend_floor_cents: i64,
    pub fee_cents: i64,
}

#[derive(Clone)]
pub struct Cfg {
    pub seed: u32,
    pub clients: Vec<Client>,
    pub pips: Option<i64>,
    pub ap_per_day: Option<i64>,
    pub flight_cfg: FlightCfg,
}

// ------------------------------------------------------------------ commands

#[derive(Clone, Default)]
pub struct Command {
    pub kind: String,
    pub at_tick: Option<i64>,
    pub wave: Option<i64>,
    pub truth: Option<Truth>,
    pub budget_cents: Option<i64>,
    pub clean: Option<bool>,
    pub a: Option<usize>,
    pub b: Option<usize>,
    pub metric: Option<String>,
    pub call: Option<usize>,  // 1-based ad index (pin winner prediction)
    pub ad: Option<usize>,
}

impl Command {
    pub fn new(kind: &str) -> Self {
        Command { kind: kind.to_string(), ..Default::default() }
    }
}

// ------------------------------------------------------------------ pins

#[derive(Clone)]
pub struct Pin {
    pub a: usize,
    pub b: usize,
    pub metric: String,
    pub call: usize,     // 1-based ad index (from significance.rs Pin definition)
    pub verdict: Option<String>,
}

// ------------------------------------------------------------------ run state

pub struct Pace {
    pub budget_millicents: i64,
    pub sched_prev: i64,
    pub spend_acc: i64,
    pub spent: i64,
    pub start_tick: i64,
}

pub struct AdSlot {
    pub ad: Ad,
    pub killed: bool,
    pub rng: Rng,
    pub ad_imps: i64,
    pub prev_cum: i64,
    pub pace: Option<Pace>,
}

#[derive(Clone)]
pub struct RunResult {
    pub passed: bool,
    pub revenue_cents: i64,
    pub spend_cents: i64,
    pub recovered_cents: i64,
    pub payout_cents: i64,
    pub field_note_bonus: bool,
    pub pins: Vec<Pin>,
    pub is_boss: bool,
}

pub struct Run {
    pub cfg: Cfg,
    pub seed: u32,
    pub client_i: usize,
    pub wave_in_client: usize,
    pub global_wave: i64,   // i64 to match journal/wave fields
    pub pips: i64,
    pub ap: Option<i64>,
    pub state: String,
    pub journal: Vec<Command>,
    pub builds: Vec<Command>,
    pub pins: Vec<Pin>,
    pub clean_test_count: i64,
    pub ads: Vec<AdSlot>,
    pub tick: i64,
    pub plan_ticks: i64,
    pub ticks_per_day: i64,
    pub pending: Vec<Command>,
    pub last_result: Option<RunResult>,
}

impl Run {
    /// Number of ad slots (1-based indexing used by wasm/game callers).
    pub fn ad_count(&self) -> usize { self.ads.len() }

    /// Ad counters for slot i (1-based). Panics if out of range.
    pub fn ad_counts(&self, i: usize) -> &Ad { &self.ads[i - 1].ad }

    /// Whether slot i (1-based) has been killed.
    pub fn ad_killed(&self, i: usize) -> bool { self.ads[i - 1].killed }
}

// ------------------------------------------------------------------ brief / result

pub struct Brief {
    pub client: String,
    pub wave_in_client: usize,
    pub is_boss: bool,
    pub target_cents: i64,
    pub spend_floor_cents: i64,
    pub fee_cents: i64,
}

// ------------------------------------------------------------------ events

#[derive(Clone)]
pub enum Event {
    Killed { ad: usize, tick: i64 },
    DayEnd { day: i64 },
    Bell { winner: usize, verdict: String, day: i64 },
    Autopsy { passed: bool, state: String },
}
