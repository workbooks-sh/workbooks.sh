//! `wb` — the Workbooks CLI. One Rust source, native + wasm32-wasip1 targets.
//!
//! Verb taxonomy is canonical per cli/TAXONOMY.md. Two execution classes:
//!   - LOCAL    : kernel ops + assembly + provenance + orchestration, no runtime.
//!   - ENGINE   : thin RCP calls into a running runtime (it owns compilers,
//!                wasmtime, the tenant library).

mod commands; // engine-backed verbs
mod deploy;
mod dev;
mod io;
mod kernel;
mod local;
mod mode;
mod rcp;
mod util;

use anyhow::Result;
use clap::{Parser, Subcommand};

#[derive(Parser)]
#[command(name = "wbx", version, about = "Workbooks CLI — author, build, bundle, run, publish, deploy.")]
struct Cli {
    /// Force agent mode: never prompts, no ANSI (default when stdout is piped)
    #[arg(long, global = true)]
    agent: bool,
    /// Agent mode + a single JSON envelope on stdout ({ok, verb, data|error})
    #[arg(long, global = true)]
    json: bool,
    #[command(subcommand)]
    cmd: Option<Cmd>,
}

#[derive(Subcommand)]
enum Cmd {
    // ── start here (local) ──
    /// Scaffold a new workbook source (workbook.org + data/)
    Init { name: String, #[arg(long, default_value = "minimal")] template: String },
    /// Watch + rebuild + serve a live preview (interactive; in agent contexts use `bundle`)
    Dev { #[arg(default_value = ".")] src: String, #[arg(long)] port: Option<u16> },
    /// Environment + engine health report (always exits 0; agents get JSON via --json)
    Doctor,
    /// Where am I — version, engine, workspace (same as bare `wbx`)
    Status,
    /// Open a workbook (or any file) in the default browser
    Open { file: String },
    /// Replace this binary with the latest release (npm installs: use npm)
    Upgrade,
    /// Shell completions to stdout (bash | zsh | fish | elvish | powershell)
    Completions { shell: clap_complete::Shell },
    // ── source inspection (local, kernel) ──
    /// Org → headline rows (the query surface)
    Query { file: String },
    /// Org → WIT-world-shaped build plan (literate tangle)
    Tangle { file: String },
    /// Diagnostics over a workbook source
    Lint { file: String },

    // ── workbook lifecycle ──
    /// Compile the source's code components → WASM (engine-backed)
    Build { #[arg(default_value = ".")] src: String },
    /// Assemble org (+ data) → one workbook .wbundle (local)
    Bundle { #[arg(default_value = ".")] src: String, #[arg(short, long)] out: Option<String> },
    /// Workbook → source tree (local)
    Unbundle { file: String, dest: Option<String> },
    /// Execute a workbook's workflow DAG on the engine
    Run { file: String, #[arg(trailing_var_arg = true)] input: Vec<String> },
    /// Ship an assembled workbook to a surface (local orchestration)
    Publish { #[command(subcommand)] verb: PublishVerb },

    // ── library (engine-backed) ──
    /// List the tenant's workspaces + members
    Library,
    /// Borrow a library member into a working dir
    Checkout { member: String, dir: String },
    /// Pack + sign a member back into the library
    Checkin { member: String, dir: String },
    /// Archive a workspace to durable storage (--list to enumerate)
    Store {
        #[arg(default_value = "")] slug: String,
        #[arg(long)] list: bool,
        /// Compile components → WASM before storing
        #[arg(long)] build: bool,
    },
    /// Restore from durable storage
    Fetch { key: String, #[arg(default_value = "./")] out: String },
    /// Cross-workbook search (--semantic | --literal | --sql)
    Search {
        query: String,
        #[arg(long)] semantic: bool,
        #[arg(long)] literal: bool,
        #[arg(long)] sql: bool,
    },

    // ── toolkit (agent extensibility; engine-backed) ──
    /// Discover, build, and run toolkits (the agent-extensibility surface)
    Toolkit { #[command(subcommand)] verb: ToolkitVerb },

    // ── runtime ops (engine-backed) ──
    /// Run or plan a workflow DAG
    Workflow { #[command(subcommand)] verb: WorkflowVerb },
    /// Long-horizon agent runs
    Agent { #[command(subcommand)] verb: AgentVerb },
    /// Manage deployed workbooks
    Workbook { #[command(subcommand)] verb: WorkbookVerb },
    /// Run index, or one run's summary
    Telemetry { slug: Option<String> },
    /// Verify a run's signed ledger
    Ledger { slug: String },

    // ── provenance + federation ──
    /// Embed a did:key provenance manifest (local)
    Sign { file: String, #[arg(short, long)] out: Option<String> },
    /// Check an artifact's signature + integrity (local)
    Verify { file: String },
    /// Mirror the tenant repo to a git host (url, or forge name to auto-provision)
    Mirror { target: String },
    /// Federate the tenant repo over Radicle (P2P)
    Federate,

    // ── engine (the runtime itself) ──
    /// Stand up / converge the runtime engine
    Deploy { #[command(subcommand)] verb: deploy::DeployVerb },
    /// Raw RCP escape hatch (status | get <path> | post <path> [body])
    Rt { #[arg(trailing_var_arg = true)] args: Vec<String> },

    // ── config (local) ──
    /// Local variables / secrets (set | get | list | ref)
    Var { #[arg(trailing_var_arg = true)] args: Vec<String> },
}

#[derive(Subcommand)]
enum PublishVerb {
    /// Scaffold ./publish.org
    Init,
    /// Coherence-check publish.org
    Validate,
    /// Ship the assembled workbook to the configured surface
    Apply { #[arg(default_value = "workbook.html")] workbook: String },
}

#[derive(Subcommand)]
enum ToolkitVerb {
    /// List discoverable toolkits (id · status · tagline)
    List,
    /// A toolkit's manifest + skill index (or one skill's recipe)
    Show { id: String, skill: Option<String> },
    /// Search toolkits + skills
    Search { q: Vec<String> },
    /// Check a toolkit's invocation contract (bin present / artifact built)
    Verify { id: String },
    /// Sign a toolkit manifest (did:key provenance; required for third-party)
    Sign { id: String },
    /// Build a toolkit's declared artifact (in-sandbox compile + register)
    Build { id: String, which: Option<String> },
    /// Ship a toolkit directory onto the engine (the deploy-the-toolkit verb)
    Push { id: String, dir: String },
    /// Run a toolkit task recipe (server-side gated: WB_TOOLKIT_EXEC=1)
    Run { id: String, task: String, #[arg(trailing_var_arg = true)] args: Vec<String> },
}

#[derive(Subcommand)]
enum WorkflowVerb {
    /// Execute the workflow DAG
    Run { file: String, #[arg(default_value = "")] input: String },
    /// Show the schedule/plan without executing
    Plan { file: String },
}

#[derive(Subcommand)]
enum AgentVerb {
    /// Start a long-horizon run (returns an id to poll)
    Run {
        task: Vec<String>,
        #[arg(long, default_value = "You are a careful, capable agent.")] system: String,
        #[arg(long)] model: Option<String>,
    },
    /// Poll a run's status + result
    Status { id: String },
}

#[derive(Subcommand)]
enum WorkbookVerb {
    /// List deployed workbooks
    List,
    /// Show a deployed workbook's org source
    Show { id: String },
    /// Deploy an org source under an id
    Deploy { id: String, file: String },
}

fn main() {
    let cli = Cli::parse();
    let m = mode::detect(cli.json, cli.agent);
    let verb = mode::verb_path();
    match run(cli, m == mode::Mode::Human) {
        Ok(out) => {
            mode::render_ok(m, &verb, &out);
            if m == mode::Mode::Human {
                if let Some(h) = mode::next_hint(&verb) {
                    eprintln!("→ next: {h}");
                }
            }
        }
        Err(e) => std::process::exit(mode::render_err(m, &verb, &e)),
    }
}

fn landing(io: &dyn io::Io, human: bool) -> Result<String> {
    let mut out = commands::doctor(io, human)?;
    if human {
        out.push_str(
            "\n\nstart here   wbx init <name> · wbx dev · wbx bundle\n\
             the engine   wbx deploy local · wbx deploy status\n\
             the parts    wbx toolkit list · wbx workbook list\n\
             everything   wbx help",
        );
    }
    Ok(out)
}

fn run(cli: Cli, human: bool) -> Result<String> {
    let io = io::platform();
    let io = io.as_ref();

    // bare `wbx` — the where-am-I landing, not a usage dump
    let Some(cmd) = cli.cmd else {
        return landing(io, human);
    };

    let out = match cmd {
        // start here
        Cmd::Init { name, template } => local::init(&name, &template)?,
        Cmd::Dev { src, port } => dev::dev(&src, port)?,
        Cmd::Doctor => commands::doctor(io, human)?,
        Cmd::Status => landing(io, human)?,
        Cmd::Open { file } => local::open(&file)?,
        Cmd::Upgrade => local::upgrade()?,
        Cmd::Completions { shell } => {
            use clap::CommandFactory;
            let mut buf = Vec::new();
            clap_complete::generate(shell, &mut Cli::command(), "wbx", &mut buf);
            String::from_utf8(buf)?
        }
        // local kernel
        Cmd::Query { file } => kernel::query(io, &file)?,
        Cmd::Tangle { file } => kernel::tangle(io, &file)?,
        Cmd::Lint { file } => kernel::lint(io, &file)?,
        // lifecycle
        Cmd::Build { src } => commands::build(io, &src)?,
        Cmd::Bundle { src, out } => local::bundle(io, &src, out.as_deref())?,
        Cmd::Unbundle { file, dest } => local::unbundle(io, &file, dest.as_deref())?,
        Cmd::Run { file, input } => commands::run(io, &file, &input)?,
        Cmd::Publish { verb } => match verb {
            PublishVerb::Init => local::publish(io, "init", None)?,
            PublishVerb::Validate => local::publish(io, "validate", None)?,
            PublishVerb::Apply { workbook } => local::publish(io, "apply", Some(&workbook))?,
        },
        // library
        Cmd::Library => commands::library(io)?,
        Cmd::Checkout { member, dir } => commands::checkout(io, &member, &dir)?,
        Cmd::Checkin { member, dir } => commands::checkin(io, &member, &dir)?,
        Cmd::Store { slug, list, build } => commands::store(io, &slug, list, build)?,
        Cmd::Fetch { key, out } => commands::fetch(io, &key, &out)?,
        Cmd::Search { query, semantic, literal, sql } => {
            let mode = if semantic { "semantic" } else if literal { "literal" } else if sql { "sql" } else { "hybrid" };
            commands::search(io, &query, mode)?
        }
        // toolkit
        Cmd::Toolkit { verb } => match verb {
            ToolkitVerb::List => commands::toolkit_list(io)?,
            ToolkitVerb::Show { id, skill } => commands::toolkit_show(io, &id, skill.as_deref())?,
            ToolkitVerb::Search { q } => commands::toolkit_search(io, &q.join(" "))?,
            ToolkitVerb::Verify { id } => commands::toolkit_verify(io, &id)?,
            ToolkitVerb::Sign { id } => commands::toolkit_sign(io, &id)?,
            ToolkitVerb::Build { id, which } => commands::toolkit_build(io, &id, which.as_deref())?,
            ToolkitVerb::Push { id, dir } => commands::toolkit_push(io, &id, &dir)?,
            ToolkitVerb::Run { id, task, args } => commands::toolkit_run(io, &id, &task, &args)?,
        },
        // runtime ops
        Cmd::Workflow { verb } => match verb {
            WorkflowVerb::Run { file, input } => commands::workflow(io, false, &file, &input)?,
            WorkflowVerb::Plan { file } => commands::workflow(io, true, &file, "")?,
        },
        Cmd::Agent { verb } => match verb {
            AgentVerb::Run { task, system, model } => commands::agent_run(io, &task.join(" "), &system, model.as_deref())?,
            AgentVerb::Status { id } => commands::agent_status(io, &id)?,
        },
        Cmd::Workbook { verb } => match verb {
            WorkbookVerb::List => commands::workbook_list(io)?,
            WorkbookVerb::Show { id } => commands::workbook_show(io, &id)?,
            WorkbookVerb::Deploy { id, file } => commands::workbook_deploy(io, &id, &file)?,
        },
        Cmd::Telemetry { slug } => commands::telemetry(io, slug.as_deref())?,
        Cmd::Ledger { slug } => commands::ledger(io, &slug)?,
        // provenance + federation
        Cmd::Sign { file, out } => local::sign(io, &file, out.as_deref())?,
        Cmd::Verify { file } => local::verify(io, &file)?,
        Cmd::Mirror { target } => commands::mirror(io, &target)?,
        Cmd::Federate => commands::federate(io)?,
        // engine
        Cmd::Deploy { verb } => deploy::run(io, verb, human)?,
        Cmd::Rt { args } => commands::rt(io, &args)?,
        // config
        Cmd::Var { args } => local::var(io, &args)?,
    };

    Ok(out)
}
