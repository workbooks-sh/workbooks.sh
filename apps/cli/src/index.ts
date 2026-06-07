#!/usr/bin/env node
import { Command } from "commander";
import { registerAds } from "./commands/ads.js";
import { registerAnalysisCheck } from "./commands/analysis-check.js";
import { registerAuditTrace } from "./commands/audit-trace.js";
import { registerAuth } from "./commands/auth.js";
import { registerBook } from "./commands/book.js";
import { registerBrand } from "./commands/brand.js";
import { registerBrief } from "./commands/brief.js";
import { registerCatalog } from "./commands/catalog.js";
import { registerCreative } from "./commands/creative.js";
import { registerDesign } from "./commands/design.js";
import { registerHarvestAll } from "./commands/harvest-all.js";
import { registerInit } from "./commands/init.js";
import { registerLogin } from "./commands/login.js";
import { registerMcp } from "./commands/mcp.js";
import { registerLogo } from "./commands/logo.js";
import { registerResolve } from "./commands/resolve.js";
import { registerSocial } from "./commands/social.js";
import { registerSubstrate } from "./commands/substrate.js";
import { registerSubstrateCheck } from "./commands/substrate-check.js";
import { registerSubstrateSlice } from "./commands/substrate-slice.js";
import { registerSubstratePublish } from "./commands/substrate-publish.js";
import { registerSkill } from "./commands/skill.js";
import { registerUsage } from "./commands/usage.js";
import { registerSimulate } from "./commands/simulate.js";
import { registerAdmin } from "./commands/admin.js";
import { bindOutputProgram } from "./output.js";
import pkg from "../package.json" with { type: "json" };

const program = new Command();
program
  .name("brandnana")
  .description("Ad and brand intelligence substrate for agents")
  .version(pkg.version)
  .addHelpText(
    "after",
    `\nExamples:\n  brandnana auth login\n  brandnana book publish nike deck.html      # publish an AUTHORED design-system deck\n  brandnana book render-slides nike          # visual-review gate\n  brandnana book query nike '(tagged brand)'\n  brandnana mcp                   # MCP stdio server for Claude/Codex/Cursor\n`,
  )
  .option("--json", "Emit machine-readable JSON output instead of human text")
  .option("--quiet", "Suppress non-error output");

bindOutputProgram(program);

registerInit(program);
registerLogin(program);
registerMcp(program);
registerAuth(program);
registerAuditTrace(program);
registerAds(program);
registerBook(program);
registerBrand(program);
registerBrief(program);
registerCatalog(program);
registerCreative(program);
registerDesign(program);
// `harvest-all <domain>` — deterministic orchestration of the full harvest sweep
// (resolve → identity → company → catalog → social → ads → creative → substrate
// build/check/publish) with an exit-code contract. Phase-A keystone of wb-qy3g:
// the brand-scout agent stops hand-running the happy path and only handles the
// exception when this script writes raw/escalate.json + exits non-zero.
registerHarvestAll(program);
registerLogo(program);
registerResolve(program);
registerSkill(program);
registerSocial(program);
// `substrate build` — deterministic RENDER builder. Registers the `substrate`
// group + `build` subcommand. Must run BEFORE registerSubstrateCheck so the two
// share one group (check reuses an existing `substrate` group when present).
registerSubstrate(program);
// `substrate check` — fidelity validator. registerSubstrateCheck reuses an
// existing `substrate` group if the builder's registerSubstrate ran first,
// otherwise it creates the group. Keep this AFTER any future
// registerSubstrate(program) call so `build` + `check` share one group.
registerSubstrateCheck(program);
// `substrate publish` — deterministic durable push. Runs `check` then pushes the
// archived workdir to gitwork S3-backed storage so the substrate survives a
// machine cycle. Placed AFTER registerSubstrateCheck so it reuses the same
// `substrate` group (build + check + publish under one group).
registerSubstratePublish(program);
// `substrate slice` — DETERMINISTIC pre-read. Digests the built substrate into
// analysis/reports/*.org (no LLM, no spawn) — the deterministic-first replacement
// for the strategist's old 5-child grep fan-out (wb-pyfx). Reuses the `substrate`
// group; placed AFTER the others so build + check + publish + slice share it.
registerSubstrateSlice(program);
// `analysis check` — Stage-2 grounding gate. Validates analysis/*.org against the
// Stage-1 substrate: every :insight: has a :GROUNDS: citing real :point: ids.
// Standalone group (its own `analysis` command); fails loud on ungrounded /
// fabricated insights so the strategist cannot finish on hand-waved strategy.
registerAnalysisCheck(program);
registerUsage(program);
registerSimulate(program);
registerAdmin(program);

program.parseAsync(process.argv);
