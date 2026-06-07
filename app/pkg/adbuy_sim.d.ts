/* tslint:disable */
/* eslint-disable */

/**
 * Stateful game handle the HTML loop drives. Owns the full engagement plus the
 * per-wave specs/pins the settlement needs (carried across build_ad calls).
 */
export class Dashboard {
    free(): void;
    [Symbol.dispose](): void;
    /**
     * Compose `card_ids` (comma-separated, on the current lane) into a truth and
     * launch it. Legal in BUILD (queues a build) or mid-FLIGHT (joins the week).
     * `clean` flags a clean A/B test. Returns {ok, msg?, state}.
     */
    build_ad(card_ids: string, clean: boolean): string;
    /**
     * Declare ad `idx` (1-based) as the predicted winner. Records once per wave;
     * verdict (CONFIRMED/INCORRECT) is derived from final revenues at autopsy.
     */
    call_it(idx: number): string;
    /**
     * Run the 6-case diagnosis engine on ad `idx` (1-based). Legal only in
     * FLIGHT once the ad has enough imps (≥2000). Returns:
     *   {diagnosable: true, case, chip, sentence}  — a diagnosis verdict
     *   {diagnosable: false}                        — below floor or wrong state
     */
    diagnose_ad(idx: number): string;
    /**
     * Advance the turn one game-day. In BUILD this first starts the flight
     * (needs builds totalling the spend floor). When the flight ends, the wave
     * is settled at the game level (wear/combos/shimmer/ledger/economy) and the
     * run parks at the NEWSSTAND — call `next_wave` to continue. Returns
     * {ok, events, state}.
     */
    end_day(): string;
    /**
     * Current state snapshot as JSON (day, AP, bankroll, revenue, target,
     * ads[], race, trust, plus client/brief context and last_result).
     */
    get_state(): string;
    /**
     * Queue a free KILL on ad `idx` (1-based); consumed at the next tick
     * boundary, recovering the unspent budget. Legal only in FLIGHT.
     */
    kill_ad(idx: number): string;
    /**
     * Build a handle and start a run on `seed` (lands in BUILD, brief acked).
     */
    constructor(seed: number);
    /**
     * Leave the newsstand for the next brief (the Lua skip_shop handshake), then
     * ack the new brief into BUILD. No-op unless parked at the NEWSSTAND.
     */
    next_wave(): string;
    /**
     * Register an A/B PIN prediction before or during the flight.
     * `metric` = "HOOK"/"CTR"/"CVR"; `call` = 1 (predict A wins) or 2 (B wins).
     * Graded at autopsy; verdict lands in last_result.pins[0] via the significance engine.
     */
    pin_ab(metric: string, call: number): string;
    /**
     * (Re)start a run on `seed`; returns the initial state JSON.
     */
    start_run(seed: number): string;
}

/**
 * WRI universal dispatcher: call(name, argsJson) -> JSON string.
 * Commands: "team_pool" {seed,count}, "strategist_propose" {seed,stage,noted_aspects,count,hires}.
 */
export function call(name: string, args_json: string): string;

/**
 * The full color pool as a JSON array of [r,g,b] (the spinner reel).
 */
export function colors_json(): string;

/**
 * Suggested glyph ids for a vertical, JSON array.
 */
export function glyphs_for(vertical: string): string;

/**
 * One themed brand for (seed, vertical): name + logo recipe, as JSON.
 */
export function random_brand(seed: number, vertical: string): string;

/**
 * Roll just a fresh name for the current vertical (the "Roll a name" button).
 */
export function roll_name(seed: number, vertical: string): string;

export type InitInput = RequestInfo | URL | Response | BufferSource | WebAssembly.Module;

export interface InitOutput {
    readonly memory: WebAssembly.Memory;
    readonly __wbg_dashboard_free: (a: number, b: number) => void;
    readonly colors_json: (a: number) => void;
    readonly dashboard_build_ad: (a: number, b: number, c: number, d: number, e: number) => void;
    readonly dashboard_call_it: (a: number, b: number, c: number) => void;
    readonly dashboard_diagnose_ad: (a: number, b: number, c: number) => void;
    readonly dashboard_end_day: (a: number, b: number) => void;
    readonly dashboard_get_state: (a: number, b: number) => void;
    readonly dashboard_kill_ad: (a: number, b: number, c: number) => void;
    readonly dashboard_new: (a: number) => number;
    readonly dashboard_next_wave: (a: number, b: number) => void;
    readonly dashboard_pin_ab: (a: number, b: number, c: number, d: number, e: number) => void;
    readonly dashboard_start_run: (a: number, b: number, c: number) => void;
    readonly glyphs_for: (a: number, b: number, c: number) => void;
    readonly random_brand: (a: number, b: number, c: number, d: number) => void;
    readonly roll_name: (a: number, b: number, c: number, d: number) => void;
    readonly call: (a: number, b: number, c: number, d: number, e: number) => void;
    readonly __wbindgen_add_to_stack_pointer: (a: number) => number;
    readonly __wbindgen_export: (a: number, b: number) => number;
    readonly __wbindgen_export2: (a: number, b: number, c: number, d: number) => number;
    readonly __wbindgen_export3: (a: number, b: number, c: number) => void;
}

export type SyncInitInput = BufferSource | WebAssembly.Module;

/**
 * Instantiates the given `module`, which can either be bytes or
 * a precompiled `WebAssembly.Module`.
 *
 * @param {{ module: SyncInitInput }} module - Passing `SyncInitInput` directly is deprecated.
 *
 * @returns {InitOutput}
 */
export function initSync(module: { module: SyncInitInput } | SyncInitInput): InitOutput;

/**
 * If `module_or_path` is {RequestInfo} or {URL}, makes a request and
 * for everything else, calls `WebAssembly.instantiate` directly.
 *
 * @param {{ module_or_path: InitInput | Promise<InitInput> }} module_or_path - Passing `InitInput` directly is deprecated.
 *
 * @returns {Promise<InitOutput>}
 */
export default function __wbg_init (module_or_path?: { module_or_path: InitInput | Promise<InitInput> } | InitInput | Promise<InitInput>): Promise<InitOutput>;
