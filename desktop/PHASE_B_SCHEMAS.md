# Workbooks Desktop — Phase B Schema Map

_Phase-B reconcile workflow, 2026-06-08. Canonical naming + native/runtime/local-store placement for every desktop capability. Native = offline Rust shell; local-store = plugin-store JSON; runtime = control-plane (graceful when daemon down)._

# Workbooks Desktop — Phase B Canonical Schema Map

LEAN SHELL TODAY (lib.rs invoke_handler): weave, tangle, validate, lint, outline, read_file, write_file, runtime_url, daemon_status, daemon_up, daemon_down, tabs::{tab_list,tab_open,tab_focus,tab_close,tab_set_dirty}, fs::read_dir. Modules: daemon.rs fs.rs kernel.rs tabs.rs lib.rs. Cargo deps: tauri2(tray-icon) dialog updater process serde serde_json dirs wasmtime27 wasmtime-wasi27. NO plugin-store/keyring/notify/portable_pty/clipboard-manager/uuid/ed25519/base64.

Placement legend: **native** = Rust shell cmd (offline). **local-store** = client-side / plugin-store JSON (offline). **runtime** = control-plane HTTP/WS to optional Elixir tier (graceful-offline).

## lifecycle (daemon + discovery + keychain-probe)
| cap | old | new name | place | signature | now/pending |
|---|---|---|---|---|---|
| daemon liveness (chip/gate) | engine_status + sidecar_status | daemon_status | native | ()->DaemonStatus{state:running\|stopped\|unhealthy\|unknown,url,pid,token} | UPGRADE now (today raw json) |
| provision/boot daemon | engine_install | daemon_install→daemon_up | native | ()->Result | now (alias to daemon_up) |
| teardown daemon | engine_uninstall | daemon_uninstall→daemon_down | native | ()->Result | now (alias to daemon_down) |
| start daemon | daemon_up | daemon_up | native | ()->DaemonStatus | EXISTS; retype now |
| stop daemon | daemon_down | daemon_down | native | ()->DaemonStatus | EXISTS; retype now |
| restart daemon | sidecar_restart (MISSING) | daemon_restart | native | ()->Result<DaemonStatus> | now |
| status mirror+event | sidecar_status + listen('sidecar-state') | daemon_status + event 'daemon-state' | native | snapshot+event:DaemonStatus | now (poll thread ~3s) |
| discover url+token | runtime_url | runtime_url | native | ()->Runtime{url,token,state} | EXISTS; token-wire pending |
| health probe | engineRequest /health | GET /health | runtime | GET->200\|non200 | pending (fold into daemon_status native) |
| engine HTTP transport | engineRequest(sidecar.url) | engineRequest(daemon url+token) | runtime | (path,opts)->Promise<T> | pending (attach Bearer) |
| WS connect lifecycle | ws.init on sidecar.status | ws.init on daemon.status | runtime | socket Bearer token | pending |
| keychain init probe (no prompt) | setup_status | keychain_status | native | ()->KeychainStatus{initialized} | now (MISSING) |
| keychain init (prompt) | setup_initialize_keychain | keychain_init | native | ()->Result | now (MISSING) |
| active selection | active rune | active store | local-store | agentSlug,workdir | now |

## files (fs + tabs + workbook + package) — FULLY NATIVE/OFFLINE
| cap | old | new name | place | signature | now/pending |
|---|---|---|---|---|---|
| recursive tree walk | tree_walk | fs_tree_walk | native | (root)->{root,entries[{path,rel,name,is_dir,depth}],truncated} | now (cap 5000) |
| one-level list | read_dir | fs_dir_read | native | (path)->[{name,path,is_dir}] | RENAME now |
| reveal in Finder | open_in_os | fs_reveal | native | (path)->() | now |
| rename/move | (none) | fs_rename | native | (from,to)->() | now |
| delete recursive | (none) | fs_delete | native | (path)->() | now |
| mkdir -p | (none) | fs_mkdir | native | (path)->() | now |
| create empty file | (none) | fs_create_file | native | (path)->() | now |
| watch start | listen fs-tree-changed (no emitter) | fs_watch_start | native | (root)->() emits {root} | now (notify) |
| watch stop | — | fs_watch_stop | native | (root)->() | now |
| read text | read_file | fs_read_file | native | (path)->string | RENAME now |
| write text | write_file | fs_write_file | native | (path,content)->() | RENAME now (mkdir parent) |
| list tabs | tab_list | tab_list | native | ()->TabsSnapshot{tabs,active} | EXISTS; FIX serde field active |
| open/focus tab | tab_open | tab_open | native | (path)->TabsSnapshot | EXISTS |
| focus tab | tab_focus | tab_focus | native | (id)->TabsSnapshot | EXISTS |
| close tab | tab_close | tab_close | native | (id)->TabsSnapshot | EXISTS |
| set dirty | tab_set_dirty | tab_set_dirty | native | (id,dirty)->() | EXISTS |
| close/focus by path | client resolve | (no cmd) | native | (path)->bool | now (client) |
| persist tabs | (none, TODO) | tabs.json local-store | local-store | TabsSnapshot<->json | now |
| bundle dir->html | workbook_bundle | workbook_bundle | native | (dir,output)->{output,stdout,stderr} | PENDING (kernel bundle export / work shim) |
| unbundle html->dir | workbook_unbundle | workbook_unbundle | native | (htmlPath,outputDir)->{output_dir,files} | PENDING (port workbook.ex regex → flip now) |
| read workbook-spec | Workbook.spec | workbook_spec_read | native | (htmlPath)->{spec\|null} | now |
| portability check | workbook_check_portability | workbook_check_portability | native | (workdir)->{cells,workbook_tier,declared_tier} | PENDING (work check --portability) |
| list packages | package_list | package_list | native | ()->string[] | now |
| active package | package_get_active | package_get_active | native | ()->Package\|null | now |
| load package | package_load | package_load | native | (name)->Package | now |
| create package | package_create | package_create | native | (name,icon?)->Package | now |
| import folder | package_import_folder | package_import_folder | native | (ws,pkg,src,icon?)->Package | now |
| set icon | package_set_icon | package_set_icon | native | (name,icon)->Package | now |
| delete package | package_delete | package_delete | native | (name)->() | now |
| add folder | package_add_folder | package_add_folder | native | (name,path)->Package | now |
| remove folder | package_remove_folder | package_remove_folder | native | (name,path)->Package | now |
| set active | package_set_active | package_set_active | native | (name\|null)->() emits workspace-scope-change | now |
| refresh active | package_refresh_active | package_refresh_active | native | ()->() | now |
| set layout | package_set_layout | package_set_layout | native | (name,'grid'\|'tree')->Package | now |
| set view mode | package_set_view_mode | package_set_view_mode | native | (name,viewMode)->Package | now |
| set subtree | package_set_subtree | package_set_subtree | native | (name,{remote_url,branch}\|null)->Package | now |
| list workbooks | package_workbooks | package_workbooks | native | (name)->[{path,title}] | now |
| discovery url | runtime_url | runtime_url | native | ()->{url,token,state} | EXISTS |

CRITICAL BUG: tabs.rs TabsSnapshot serializes `activeId` but TS reads `snap.active` → snapshot.active always undefined. FIX: rename Rust field to `active` (archive types.ts is contract).

## workspaces (flat registry) — local-store, plugin-store workspaces.json {workspaces[],active_id}
| cap | old | new name | place | signature | now/pending |
|---|---|---|---|---|---|
| list (merge disk) | workspaces_list | workspace_list | local-store | ()->Workspace[] | now |
| get active | workspaces_get_active | workspace_get_active | local-store | ()->Workspace\|null | now |
| create | workspaces_create | workspace_create | local-store | (req{name,icon})->Workspace | now |
| set active | workspaces_set_active | workspace_set_active | local-store | (id\|null)->void | now |
| rename | workspaces_rename | workspace_rename | local-store | (req{id,name})->void | now |
| set icon | workspaces_set_icon | workspace_set_icon | local-store | (req{id,icon})->void | now |
| delete | workspaces_delete | workspace_delete | local-store | (id)->void | now |
| add package | workspaces_add_package | workspace_add_package | local-store | (req{workspace_id,package_name})->void | now |
| remove package | workspaces_remove_package | workspace_remove_package | local-store | (req{workspace_id,package_name})->void | now |
| set subtree | workspaces_set_subtree | workspace_set_subtree | local-store | (req{id,subtree\|null})->void | now |
| monorepo firehose | ws.onMonorepoChange(workspaces.org) | runtime ws sync→reconcile | runtime | (path,cb)->unsub | pending |
| raw fs change | listen fs-tree-changed | fs watcher emit | native | {root}->() | pending (notify) |

Workspace{id,name,icon,package_names,created_at:i64ms,subtree?:{remote_url,branch}}. helper mutate(app,id,f). NOTE: workspace registry (flat id/name/icon) is DISTINCT from runtime workspace.ex (workspace.org manifest, DID/PATH members) — reconcile future. Add tauri-plugin-store to Builder.

## ui-local (bookmarks / themes / toasts) — native plugin-store; toasts pure-memory
| cap | old | new name | place | signature | now/pending |
|---|---|---|---|---|---|
| list bookmarks | bookmarks_list | bookmark_list | native | ()->Bookmark[] | now |
| create | bookmarks_create | bookmark_create | native | (req{title,path,command_slot})->Bookmark | now (slot-evict) |
| rename | bookmarks_update | bookmark_rename | native | (req{id,title})->void | now |
| delete | bookmarks_delete | bookmark_delete | native | (id)->void | now |
| set slot | bookmarks_set_slot | bookmark_set_slot | native | (req{id,slot\|null})->void | now (slot-evict) |
| list themes | themes_list | theme_list | native | ()->{active_id,themes[]} | now (seed builtins) |
| set active | themes_set_active | theme_set_active | native | (id\|null)->void | now |
| create | themes_create | theme_create | native | (req{name,description,light_tokens,dark_tokens})->Theme | now |
| update | themes_update | theme_update | native | (req{id,...})->void | now (guard builtin) |
| delete | themes_delete | theme_delete | native | (id)->void | now (guard builtin) |
| apply tokens :root | client | (client-only) | local-store | ()->void | now |
| snapshot tokens | client | (client-only) | local-store | ()->{light,dark} | now |
| push toast | toasts.push | (client-only) | local-store | (init)->number | now |
| update toast | toasts.update | (client-only) | local-store | (id,patch)->void | now |
| dismiss toast | toasts.dismiss | (client-only) | local-store | (id)->void | now |

Bookmark{id,title,path,command_slot:Option<u8>,created_at:i64}. Slot uniqueness 1..9 evict prior holder. Builtins seeded read-only. Drop ws.onMonorepoChange(*.org) watch → direct refresh after mutation.

## agents-boards
| cap | old | new name | place | signature | now/pending |
|---|---|---|---|---|---|
| agent catalog | GET /api/agents?workdir | GET /api/agents | runtime | (workdir?)->{agents[]} | pending (route absent) |
| get agent settings | agent_settings_get | agent_settings_get | native | ()->AgentSettings{default_model,default_agent_slug} | now (MISSING) |
| set agent settings | agent_settings_set | agent_settings_set | native | (req)->AgentSettings | now (best-effort push) |
| start agent session | POST /api/run (wrong shape) | POST /api/agent/run | runtime | ({agent_slug,prompt,workdir?,skills?})->{session_id} | pending (shape mismatch) |
| cancel session | channel push 'cancel' | channel session:<id> 'cancel' | runtime | (session_id)->void | pending (no handler) |
| stream telemetry | channel session:<id> | channel session:<id> | runtime | join->BridgeEvent | pending (no Phoenix layer) |
| list sessions ledger | GET /api/sessions | GET /api/sessions | runtime | ({active?})->{sessions[]} | pending (route absent) |
| org-ql query | POST /api/oql/query | POST /api/oql/query | runtime | (path,sexpr)->{headlines} | pending |
| board views | GET /api/oql/board-views | GET /api/oql/board-views | runtime | (path)->BoardView[] | pending |
| patch headline | PATCH /api/oql/headline/:id | PATCH /api/oql/headline/:id | runtime | (id,{path,op,...})->void | pending |
| run workflow DAG | (none in bridge) | POST /api/workflow | runtime | (org,input?)->runs | pending (exists,unused; boards=workflows reconcile) |
| per-agent session log | localStorage | agent_session_log | local-store | record/updateStatus/forAgent/clearAgent | now |
| selected agent | localStorage | agent_selection | local-store | select/selected | now |
| live catalog refresh | ws.onMonorepoChange(agents) | fs watch→agents_list | runtime | watch(glob) | pending |

BIGGEST BREAK: /api/run shape ({system,task,max_steps,model}) ≠ bridge ({agent_slug,prompt,workdir,skills}→{session_id}). Channel gap: bridge uses Phoenix channels, runtime only has raw WebSock /api/run/:id/stream. Sessions collision: Workbooks.Sessions = workbook-INSTANCE VFS resume, NOT agent ledger.

## chat-voice
| cap | old | new name | place | signature | now/pending |
|---|---|---|---|---|---|
| reveal provider key | connections_reveal_api_key | connections_reveal_api_key | native | (service)->Promise<string> | now (keychain) |
| system prompt | GET /api/agents/:slug/system_prompt | GET /api/agents/:slug/system_prompt | runtime | (slug,workdir?,skills?)->{system_prompt} | pending |
| live bash exec | POST /api/agents/:slug/exec | POST /api/agents/:slug/exec | runtime | ({command})->{output?,error?} | pending |
| gemini live WS | new WebSocket(google) | (renderer-direct) | runtime | bidi BidiGenerateContent | pending (no cmd; renderer) |
| local STT | Moonshine | (renderer-direct) | local-store | start/stop/toggle | now (onnx wasm) |
| webview media enable | media.rs (NOT restored) | webview_enable_media (boot) | native | boot-time WKWebView media cfg | now (re-add; blocks mic) |
| start chat run | POST /api/run | POST /api/run | runtime | ({agent_slug,prompt,...})->{session_id} | pending |
| stream telemetry | channel session:<id> | WS /socket session:<id> | runtime | events | pending |
| poll status | GET /api/run/:id | GET /api/run/:id | runtime | (id)->{status,...} | pending |
| cancel | channel 'cancel' | WS session:<id> 'cancel' | runtime | (session_id)->ok | pending |
| inject text live | ws.send(realtimeInput) | (renderer-direct) | runtime | (text)->void | pending |
| chime/playback | AudioContext | (renderer-direct) | local-store | internal | now |

NATIVE-now decoupled from wb-hhc: connections_reveal_api_key, STT, webview_enable_media. Live voice/STT mic BOTH depend on webview media re-add.

## network
| cap | old | new name | place | signature | now/pending |
|---|---|---|---|---|---|
| load identity | network_identity_load | identity_load | native | ()->IdentityView\|null | now |
| mint did:key | network_identity_generate | identity_generate | native | (handle?,workosUserId?)->IdentityView | now (ed25519) |
| set handle | network_identity_set_handle | identity_set_handle | native | (handle)->IdentityView | now |
| set workos | network_identity_set_workos | identity_set_workos | native | (workosUserId\|null)->IdentityView | now |
| package workspace | network_workspace_package | workspace_package | native | (workspaceName)->path | now (local tangle+sign) |
| publish share | network_publisher_publish | POST /v1/network/shares | runtime | (PublishArgs)->PublishResult | pending (broker) |
| workos sign-in | network_workos_sign_in | workos_sign_in | native | (brokerUrl)->StoredSession | now (loopback+PKCE) |
| load session | network_workos_load_session | workos_load_session | native | ()->StoredSession\|null | now |
| clear session | network_workos_clear_session | workos_clear_session | native | ()->void | now |
| workgate install | network_workgate_install | workgate_install | native | (args)->result | PENDING (fetch-by-rid needs broker) |
| workbook fork | network_workbook_fork | workbook_fork | native | (args)->result | PENDING (non-local source needs broker) |
| network mode flag | client setNetworkMode | local-store networkMode | local-store | (demo\|live)->void | now |
| broker url | client setBrokerUrl | local-store brokerUrl | local-store | (url)->void / ()->string | now |
| broker identity | GET /v1/network/identity | GET /v1/network/identity | runtime | ()->BrokerIdentity\|null | pending |
| resolve handle | GET /v1/network/resolve/:h | GET /v1/network/resolve/:handle | runtime | (handle)->BrokerIdentity\|null | pending |
| resolve did | GET /v1/network/resolve-did/:did | same | runtime | (did)->BrokerIdentity\|null | pending |
| seeds | GET /v1/network/seeds | same | runtime | ()->SeedsResponse | pending |
| inbox | GET /v1/network/inbox | same | runtime | ({since?})->InboxResponse | pending |
| share accept/decline | POST /v1/network/shares/:id/:action | same | runtime | (id,action)->ShareSettlement | pending |
| fork upstream status | GET forks/upstream-status | fork_upstream_status | native | ()->ForkUpstreamStatusResponse | PENDING (local base native; upstream head needs broker) |
| friends list | GET /v1/network/friends | same | runtime | ({status?})->FriendsResponse | pending |
| friend request | POST /v1/network/friends | same | runtime | (handle)->{outcome,handle} | pending |
| friend accept/decline | POST .../friends/:h/:action | same | runtime | (handle,action)->FriendView | pending |
| block | POST .../friends/:h/block | same | runtime | (handle)->FriendView | pending |
| unfriend | DELETE .../friends/:h | same | runtime | (handle)->void | pending |
| groups list | GET /v1/network/groups | same | runtime | ()->GroupsResponse | pending |
| group detail | GET .../groups/:id | same | runtime | (id)->GroupDetailView | pending |
| group create | POST .../groups | same | runtime | ({name,visibility?})->GroupDetailView | pending |
| group update | PATCH .../groups/:id | same | runtime | (id,{...})->GroupView | pending |
| group delete | DELETE .../groups/:id | same | runtime | (id)->void | pending |
| group add member | POST .../groups/:id/members | same | runtime | (id,handle,role?)->member | pending |
| group remove member | DELETE .../members/:h | same | runtime | (id,handle)->void | pending |
| subs list | GET /v1/network/subscriptions | same | runtime | ()->SubscriptionsResponse | pending |
| subscribe | POST .../subscriptions | same | runtime | (rid)->SubscriptionView | pending |
| unsubscribe | DELETE .../subscriptions/:rid | same | runtime | (rid)->void | pending |
| sub ack | POST .../subscriptions/:rid/ack | same | runtime | (rid,head)->SubscriptionView | pending |
| connections list | connections_list | connections_list | native | ()->ConnectionRedacted[] | now (keychain) |
| connections create | connections_create | connections_create | native | (ConnectionCreate)->ConnectionRedacted | now |
| connections delete | connections_delete | connections_delete | native | (id)->void | now |
| composio accounts | GET /api/integrations/composio/connections | same | runtime | ()->{connections[]} | pending |
| connections.changed | ws.onMonorepoChange(connections.org) | runtime ws event | runtime | (cb)->unsub | pending |

DROP `network_` prefix (redundant). Secrets in OS keychain; only redacted metadata + pubkey plaintext. ForkWatcher is per-machine LOCAL (misrouted through broker today) → native fork_upstream_status.

## config (keys / env_vars / mcp / plugins / skills / memory)
| cap | old | new name | place | signature | now/pending |
|---|---|---|---|---|---|
| list keys redacted | keys_list | keys_list | native | ()->ApiKeyRedacted[] | now (keychain) |
| known providers | keys_known_providers | keys_known_providers | native | ()->string[] | now |
| create key | keys_create | keys_create | native | (req)->ApiKeyRedacted | now |
| rename key | keys_rename | keys_rename | native | (req{id,name})->void | now |
| delete key | keys_delete | keys_delete | native | (id)->void | now |
| copy key clipboard | keys_copy_to_clipboard | keys_copy_to_clipboard | native | (id)->void | now (clipboard-manager) |
| reveal key | (implied) | keys_reveal | native | (id)->string | now |
| restart daemon for env | sidecar_restart | daemon_restart | native | ()->void | now (shared w/ lifecycle) |
| push secrets no-restart | POST /internal/secrets/refresh | same | runtime | ({vars})->{ok} | pending |
| env vars list | env_vars_list | env_vars_list | native | ()->EnvVarRedacted[] | now |
| env vars create | env_vars_create | env_vars_create | native | (req)->EnvVarRedacted | now |
| env vars update | env_vars_update | env_vars_update | native | (req{id,value})->void | now |
| env vars delete | env_vars_delete | env_vars_delete | native | (id)->void | now |
| env vars copy | env_vars_copy_to_clipboard | env_vars_copy_to_clipboard | native | (id)->void | now |
| env vars bulk import | env_vars_bulk_import | env_vars_bulk_import | native | (req)->{imported,skipped} | now |
| mcp list | mcp_list | mcp_list | native | ()->McpServer[] | now |
| mcp create | mcp_create | mcp_create | native | (req)->McpServer | now |
| mcp update | mcp_update | mcp_update | native | (req)->McpServer | now |
| mcp delete | mcp_delete | mcp_delete | native | (id)->void | now |
| plugins list | plugins_list | plugins_list | native | ()->Plugin[] | now |
| plugins install | plugins_install | plugins_install | native | (req)->Plugin | now (registry only) |
| plugins toggle | plugins_set_enabled | plugins_set_enabled | native | (req{id,enabled})->void | now |
| plugins remove | plugins_remove | plugins_remove | native | (id)->void | now |
| skills list | skills_list | skills_list | local-store | ()->Skill[] | now (config file) |
| skills set scope | skills_set_scope | skills_set_scope | local-store | (req)->void | now |
| skills delete | skills_delete | skills_delete | local-store | (id)->void | now |
| skill catalog @-picker | GET /api/skills | GET /api/skills | runtime | (query)->{skills[]} | pending |
| resolve memory source | workbook_load_as_memory | memory_source_resolve | native | (htmlPath)->{canonical_path} | now |
| list memory sources | ws memory:control list | GET /api/memory/sources | runtime | ()->{workbooks[]} | pending |
| add memory source | ws memory:control add | POST /api/memory/sources | runtime | ({path})->AddWorkbookResult | pending |
| remove memory source | ws memory:control remove | DELETE /api/memory/sources | runtime | ({path})->RemoveWorkbookResult | pending |
| config file watch | ws.onMonorepoChange(*.org) | config_watch_start | native | ()->() emits 'config-changed' | now (notify) |

keys/env_vars secrets in OS keychain (keyring), index in ~/.oql/desktop/*.json. runtime secret.ex/vars.ex = egress-injection, NOT the offline store.

## terminal — ALL native, ALL now (new terminal.rs, portable_pty)
| cap | old | new name | place | signature | now/pending |
|---|---|---|---|---|---|
| spawn pty | terminal_spawn | terminal_spawn | native | (req{cols,rows,shell?,command?,cwd?})->{session_id} | now |
| write | terminal_write | terminal_write | native | (req{session_id,data b64})->void | now |
| resize | terminal_resize | terminal_resize | native | (req{session_id,cols,rows})->void | now |
| kill | terminal_kill | terminal_kill | native | (sessionId)->void | now |
| EVENT output | listen terminal-output | terminal-output | native | {session_id,data b64} | now |
| EVENT exit | listen terminal-exit | terminal-exit | native | {session_id,exit_code} | now |
| EVENT daemon log | listen sidecar-log | daemon-log | native | {stream,line} | now (new daemon.rs long-lived capture) |

runtime shell.ex = WASM-sandboxed agent pipe shell, NOT this. Native pty is only correct placement. Rename sidecar-log→daemon-log, SIDECAR_SESSION_ID 'sidecar'→'daemon'.

## onboarding — minimal native flow gates splash
| cap | old | new name | place | signature | now/pending |
|---|---|---|---|---|---|
| setup status | setup_status | setup_status | native | ()->{keychain_initialized,has_model_key,first_run_done} | now |
| init keychain | setup_initialize_keychain | setup_initialize_keychain | native | ()->Result | now |
| complete first-run | (none) | setup_complete_first_run | native | ()->Result | now |
| save model key | keys_create | setup_save_model_key | native | (req)->ApiKeyRedacted | now |
| keys_list/known/rename/delete/copy | keys_* | keys_* | native | (see config) | now (shared) |
| push secrets | /internal/secrets/refresh | same | runtime | ({secrets})->{ok} | pending |
| daemon restart | sidecar_restart | daemon_restart | native | ()->void | now (shared) |
| daemon status | sidecar_status | daemon_status | native | (see lifecycle) | now (shared) |
| list wizards | GET /api/wizards | same | runtime | (surface?)->{wizards[]} | pending |
| start wizard | POST /api/wizard/start | same | runtime | (args)->WizardStep | pending |
| answer wizard | POST /api/wizard/:id/answer | POST /api/wizard/:session_id/answer | runtime | (id,answers)->WizardStep | pending |
| setup flags store | implicit | ~/.oql/desktop/setup.json | local-store | SetupStore{first_run_done,keychain_initialized,model_key_set} | now |

RECONCILE: lifecycle uses keychain_status/keychain_init; onboarding chart uses setup_status/setup_initialize_keychain. LOCKED: setup_* owns onboarding-flag surface (setup.json: first_run_done+keychain_initialized+model_key_set), and is the canonical name the UI gates on. keychain_status/keychain_init are NOT added separately — folded into setup_status/setup_initialize_keychain (one keychain probe, one init). Minimal flow: setup_status → setup_initialize_keychain → setup_save_model_key → setup_complete_first_run.

## CRATES TO ADD (src-tauri/Cargo.toml)
tauri-plugin-store, tauri-plugin-clipboard-manager, keyring, notify, portable_pty, uuid, base64, ed25519-dalek, rand(OsRng), walkdir (or std), trash(optional soft-delete), rayon(optional package_workbooks), fs_extra(optional copy).

## Naming conventions

LOCKED naming rules:
- Rust commands: snake_case, clear DOMAIN PREFIX, name-for-what-it-IS-now. camelCase TS bridge args (tauri auto-maps; serde rename_all=camelCase on multi-word args like viewMode/workspaceId).
- DROP legacy prefixes: `engine_*` and `sidecar_*` → `daemon_*` (engine.svelte + sidecar.svelte collapse to ONE DaemonStore). `network_*` → bare domain (identity_*/workos_*/connections_*/workspace_package/workbook_fork). No `engine_`/`sidecar_` cruft unless it maps to real daemon/discovery.
- Domain prefixes: lifecycle=daemon_* + runtime_url + setup_*(keychain folded in); fs=fs_*; tabs=tab_*; workbook=workbook_*; package=package_* (singular); workspace=workspace_* (singular, was plural workspaces_*); ui=bookmark_*/theme_* (singular, were plural); agents=agent_settings_*/agent_session_log/agent_selection; config=keys_*/env_vars_*/mcp_*/plugins_*/skills_*/memory_source_*; terminal=terminal_*; network social=identity_*/workos_*/connections_*; onboarding=setup_*.
- Plural→singular renames: bookmarks_*→bookmark_*, themes_*→theme_*, workspaces_*→workspace_*. Honesty renames: bookmarks_update→bookmark_rename (title-only).
- EVENTS: sidecar-state→daemon-state (emit full DaemonStatus not bare string); sidecar-log→daemon-log; keep fs-tree-changed, terminal-output, terminal-exit, workspace-scope-change, config-changed.
- Runtime REST keeps its paths: /api/* and /v1/network/* unchanged (correct as-is). New agent-run endpoint = POST /api/agent/run (slug-resolving, returns {session_id}) to avoid clobbering legacy POST /api/run shape.
- SERDE FIX: TabsSnapshot field must serialize as `active` (not `activeId`) — archive types.ts is the contract.
- Error codes: rename EngineApiError code 'sidecar_down'→'daemon_down'.
- Secrets NEVER cross IPC: keychain reads stay in Rust; copy-to-clipboard done host-side.

## Runtime-pending

- GET /health — control-plane liveness probe (deploy.ex local_verify already GETs it; fold into native daemon_status)
- engineRequest transport — attach Authorization: Bearer token from runtime_url to every HTTP call
- WS /socket — attach Bearer token param; connect lifecycle on daemon.status transitions
- GET /api/agents?workdir — agent catalog scope-walk (route absent in web.ex)
- POST /api/agent/run — slug-resolving agent run returning {session_id} (fixes /api/run shape mismatch)
- channel session:<id> 'cancel' — cancel handler (agent_session.ex has none)
- channel session:<id> — Phoenix channel telemetry stream (only raw WebSock /api/run/:id/stream exists)
- GET /api/sessions?active — agent session ledger (distinct from workbook-instance Sessions)
- POST /api/oql/query — org-ql sexpr -> {headlines}
- GET /api/oql/board-views — parse kanban-views.org -> BoardView[]
- PATCH /api/oql/headline/:id — mutate org headline by id, broadcast oql:document:<path>
- POST /api/workflow — boards=workflows convergence (exists, unused by bridge)
- GET /api/agents/:slug/system_prompt — rendered system prompt for live voice
- POST /api/agents/:slug/exec — sandbox bash exec from gemini-live tool call
- POST /internal/secrets/refresh — push env map to live daemon without restart
- GET /api/skills?workspace — SKILL.md @-picker catalog
- GET/POST/DELETE /api/memory/sources (WS memory:control) — list/add/remove workbook memory tiers (Workbooks.Vector)
- GET /api/wizards — planning wizard list
- POST /api/wizard/start — start wizard session -> WizardStep
- POST /api/wizard/:session_id/answer — answer batch -> next WizardStep
- GET /v1/network/identity — broker identity record
- GET /v1/network/resolve/:handle — handle -> identity
- GET /v1/network/resolve-did/:did — did -> identity
- GET /v1/network/seeds — p2p bootstrap peers
- GET /v1/network/inbox?since — pending shares feed
- POST /v1/network/shares — publish signed workbook fanout
- POST /v1/network/shares/:id/:action — accept/decline share
- GET/POST/.../v1/network/friends — friends list/request/accept/decline/block/unfriend
- GET/POST/PATCH/DELETE /v1/network/groups(+/members) — group CRUD + membership
- GET/POST/DELETE/ack /v1/network/subscriptions — subscription CRUD + seen-ack
- GET /api/integrations/composio/connections — Composio account list (daemon reads COMPOSIO_API_KEY)
- fork content fetch — workgate_install rid-fetch + workbook_fork non-local source + fork_upstream_status upstream-head (local sign/place is native; only byte-fetch needs broker)
