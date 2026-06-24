defmodule Nexus.Washy.Actor do
  @moduledoc """
  **JS↔OTP interop — the persistent guest actor.** This turns a one-shot Washy run into a long-lived,
  supervised BEAM process that participates in the actor model: it has a stable handle (pid), a mailbox,
  a registered `onMessage` callback, and the ability to `spawn` / `send` / `call`. This is the host-side
  mechanism behind the `Beam.*` global a QuickJS guest will call into (see
  `reference/beam/JS-OTP-INTEROP-DESIGN.md` for the full design + the `harness_run.c` changes that wire
  the JS side).

  ## The model
  Each guest is ONE `GenServer` under a `DynamicSupervisor`. The GenServer holds the guest's *durable*
  state between messages — its script and (in the real wiring) its QuickJS module state. A message
  arriving in the BEAM mailbox is delivered to the guest by **re-entering JS**: the guest runs
  run-to-completion for that one message (exactly like a `GenServer.handle_cast`), invoking the JS
  callback that `Beam.onMessage` registered, then yields and waits for the next message. A crash in one
  guest is contained by the BEAM process boundary + the supervisor — it never touches its siblings.

  ## Host primitives (what a `Beam.*` host-import dispatches to)
  - `Beam.self()`   → `beam_self/0`   — the running guest's handle.
  - `Beam.spawn(s)` → `beam_spawn/1`  — start a new supervised guest actor; returns its handle.
  - `Beam.send(p,m)`→ `beam_send/2`   — deliver `m` to actor `p`'s mailbox (cast).
  - `Beam.call(n,a)`→ `beam_call/2`   — invoke a registered Elixir handler synchronously, get the result.
  - `Beam.processInfo/systemInfo`     → `process_info/1` / `system_info/0`.

  ## The JS↔Erlang term bridge
  Messages cross the boundary as Erlang terms via `Nexus.Washy.Actor.Term` (a JSON-equivalent
  STRUCTURAL mapping — number/string/bool/nil/list/map of those, recursively). The prototype carries
  Elixir terms directly; the real JS path serializes a JS value to this same restricted term shape on
  the way out and reconstructs a JS value on the way in. Round-tripping is bit-stable for any value in
  the shared shape (see `Term.normalize/1`).

  ## Driving the guest
  Two execution backends, selected by what the actor is given:
    * `{:fun, fun}`  — an Elixir handler `(message, state) -> {reply, new_state}`. Proves the actor
      mechanism end-to-end with NO JS side (deliverable #2). Also how Elixir-registered handlers run.
    * `{:js, script}` — a JS guest. Until `qjs-run.wasm` is rebuilt with the `Beam` global, this
      executes the guest through the existing Washy seam for an effect (e.g. it can `Beam.send` via a
      host import); the message→callback re-entry is the documented wiring point. See design doc.
  """

  use GenServer
  require Logger

  alias Nexus.Washy.Actor.Term

  @registry Nexus.Washy.Actor.Registry
  @supervisor Nexus.Washy.Actor.Supervisor

  # ── child specs the application supervisor must add (parent wires these — see integration notes) ──
  @doc """
  Supervision children for `application.ex`. The parent adds these to its child list:

      Nexus.Washy.Actor.child_specs() ++ ...

  This starts the name registry + the dynamic supervisor that owns every guest actor (crash-isolated,
  `:one_for_one`, transient — a normal-exit guest is not restarted, a crashed one is per its policy).
  """
  def child_specs do
    [
      {Registry, keys: :unique, name: @registry},
      {DynamicSupervisor, strategy: :one_for_one, name: @supervisor}
    ]
  end

  # ── public host primitives (a Beam.* host import calls these) ────────────────────────────────────

  @doc """
  `Beam.spawn` — start a new supervised guest actor. `spec` is one of:
    * `{:fun, fun}`     — an Elixir `(msg, state) -> {reply, state}` handler (prototype / Elixir actors).
    * `{:js, script}`   — a JS guest script (real wiring; see module doc).
    * a bare function    — shorthand for `{:fun, fun}`.
  Opts: `:name` (register under a name for `Beam.send(name, …)` / `Beam.call`), `:state` (initial state),
  `:restart` (`:temporary` default — crash stays dead; `:transient`/`:permanent` to auto-restart).
  Returns `{:ok, handle}` where the handle is the actor's pid.
  """
  def beam_spawn(spec, opts \\ []) do
    spec = normalize_spec(spec)
    restart = Keyword.get(opts, :restart, :temporary)
    child = %{
      id: make_ref(),
      start: {__MODULE__, :start_link, [spec, opts]},
      restart: restart,
      type: :worker
    }

    case DynamicSupervisor.start_child(@supervisor, child) do
      {:ok, pid} -> {:ok, pid}
      {:error, {:already_started, pid}} -> {:ok, pid}
      err -> err
    end
  end

  @doc "`Beam.self()` — the running guest's handle. Inside an actor it's the actor pid; outside, the caller pid."
  def beam_self, do: Process.get(:washy_actor_self, self())

  @doc """
  `Beam.link(target)` — monitor `target` (pid handle or registered name) from the CALLING actor. When the
  peer dies, the caller receives a system message `%{"__exit" => handle, "reason" => reason}` into its
  handler (Erlang `trap_exit` semantics, surfaced to the guest as an ordinary delivery). Returns `:ok`.

  Implemented as a cast to the caller's own GenServer so the monitor is owned by the long-lived actor
  process (not the transient run context) and survives across messages.
  """
  def beam_link(target) do
    case beam_self() do
      pid when is_pid(pid) -> GenServer.cast(pid, {:beam_link, target}); :ok
      _ -> :error
    end
  end

  @doc """
  `Beam.send(pid, message)` — deliver `message` to actor `target`'s mailbox (asynchronous cast). `target`
  is a pid/handle or a registered name. The message is normalized to the shared term shape so what the
  receiver sees is exactly the JS-bridgeable value. Returns `:ok` (fire-and-forget, like `send/2`).
  """
  def beam_send(target, message) do
    case resolve(target) do
      nil -> {:error, :no_such_actor}
      pid -> GenServer.cast(pid, {:beam_msg, Term.normalize(message), beam_self()}); :ok
    end
  end

  @doc """
  `Beam.call(name, ...args)` — invoke a registered handler (an Elixir handler or another actor) and get
  the reply SYNCHRONOUSLY. `name` resolves through the registry; the args list is normalized across the
  boundary; the reply is normalized back. Times out (`5s` default) into `{:error, :timeout}` rather than
  hanging the caller.
  """
  def beam_call(name, args, timeout \\ 5_000) when is_list(args) do
    case resolve(name) do
      nil ->
        {:error, :no_such_handler}

      pid ->
        try do
          reply = GenServer.call(pid, {:beam_call, Enum.map(args, &Term.normalize/1), beam_self()}, timeout)
          {:ok, Term.normalize(reply)}
        catch
          :exit, {:timeout, _} -> {:error, :timeout}
          :exit, reason -> {:error, reason}
        end
    end
  end

  @doc "`Beam.processInfo()` — introspect a guest actor (reductions/memory/mailbox)."
  def process_info(target \\ nil) do
    pid = if target, do: resolve(target), else: beam_self()

    case pid && Process.info(pid, [:reductions, :memory, :message_queue_len]) do
      nil -> %{}
      info -> Map.new(info)
    end
  end

  @doc "`Beam.systemInfo()` — VM-wide introspection (process count, atom count, run queue)."
  def system_info do
    %{
      process_count: :erlang.system_info(:process_count),
      process_limit: :erlang.system_info(:process_limit),
      atom_count: :erlang.system_info(:atom_count),
      run_queue: :erlang.statistics(:run_queue)
    }
  end

  @doc "List currently-registered actor names (introspection / tests)."
  def registered do
    Registry.select(@registry, [{{:"$1", :_, :_}, [], [:"$1"]}])
  end

  # ── GenServer ─────────────────────────────────────────────────────────────────────────────────

  @doc false
  def start_link(spec, opts) do
    GenServer.start_link(__MODULE__, {spec, opts})
  end

  @impl true
  def init({spec, opts}) do
    case Keyword.get(opts, :name) do
      nil -> :ok
      name -> Registry.register(@registry, name, nil)
    end

    state = %{
      spec: spec,
      user: Keyword.get(opts, :state),
      on_message: nil,
      name: Keyword.get(opts, :name),
      # persistent guest instance (the JS backend's live QuickJS state); nil for fun-actors / unprovisioned JS
      instance: nil,
      # `Beam.link` monitors: monitor-ref => peer handle. On the peer's :DOWN we deliver a system
      # `%{"__exit" => handle, "reason" => ...}` message into the guest — Erlang trap_exit, JS-side.
      monitors: %{}
    }

    # boot the guest once: for a JS guest this is where `Beam.onMessage(cb)` runs and registers the
    # callback; for a fun-actor there's nothing to boot (the handler IS the callback).
    {:ok, boot(state)}
  end

  @impl true
  def terminate(_reason, %{instance: inst}) when inst != nil do
    Nexus.Washy.instance_free(inst)
    :ok
  end

  def terminate(_reason, _state), do: :ok

  @impl true
  def handle_cast({:beam_msg, msg, from}, state) do
    {_reply, state} = deliver(state, msg, from)
    {:noreply, state}
  end

  @impl true
  def handle_call({:beam_call, args, from}, _gen_from, state) do
    {reply, state} = deliver(state, args, from)
    {:reply, reply, state}
  end

  @impl true
  def handle_cast({:beam_link, target}, state) do
    case resolve(target) do
      nil ->
        {:noreply, state}

      pid ->
        ref = Process.monitor(pid)
        {:noreply, %{state | monitors: Map.put(state.monitors, ref, pid_handle(pid))}}
    end
  end

  @impl true
  def handle_info({:DOWN, ref, :process, _pid, reason}, state) do
    case Map.pop(state.monitors, ref) do
      {nil, _} ->
        {:noreply, state}

      {handle, monitors} ->
        # surface the peer's death to the guest as a normal delivery it can pattern-match on
        msg = %{"__exit" => handle, "reason" => inspect(reason)}
        {_reply, state} = deliver(%{state | monitors: monitors}, msg, self())
        {:noreply, state}
    end
  end

  # ── guest execution ─────────────────────────────────────────────────────────────────────────────

  # Boot is a no-op for the prototype backends. For the JS backend it runs the guest's setup ONCE and KEEPS
  # the instance alive: `_start` creates the QuickJS runtime/context, registers the `Beam` global, and evals
  # the script (which calls `Beam.onMessage(cb)` to register the callback) — then RETURNS WITHOUT freeing the
  # runtime (the rebuilt qjs-run.wasm stashes the JSContext* in a static; see JS-PERSISTENCE-DESIGN.md). The
  # captured `%Washy.Instance{}` is the guest's durable QuickJS heap; per-message we re-enter it via
  # `wb_dispatch` so `let count=0` and closures survive across deliveries. Until qjs-run.wasm is rebuilt the
  # module won't export `wb_dispatch`; boot then leaves `instance: nil` and deliver falls back (see below).
  defp boot(%{spec: {:js, script}} = state) do
    prev = Process.get(:washy_actor_self)
    Process.put(:washy_actor_self, self())

    try do
      case qjs_run_mod() do
        nil ->
          state

        mod ->
          # the setup run needs the same per-run guest context any Washy run gets (argv/stdin/vfs/fds), so a
          # Beam.* host import during eval resolves; the script is fed as the program source.
          set_js_ctx(script)

          case Nexus.Washy.instance_start(mod, "_start", [], fuel: 5_000_000_000) do
            {:ok, inst, _out} -> %{state | instance: inst}
            # setup exited/trapped (or the wasm lacks persistent setup) — fall back to per-message re-run path
            _ -> state
          end
      end
    after
      if prev, do: Process.put(:washy_actor_self, prev), else: Process.delete(:washy_actor_self)
      clear_js_ctx()
    end
  end

  defp boot(state), do: state

  # Deliver one message run-to-completion. This is the GenServer-per-guest re-entry: set the process-dict
  # self handle (so a nested Beam.self/Beam.spawn/Beam.send inside the handler resolves correctly), run
  # the guest's handler, restore. Mirrors call_io's process-dict discipline.
  defp deliver(%{spec: {:fun, fun}} = state, msg, from) do
    prev = Process.get(:washy_actor_self)
    Process.put(:washy_actor_self, self())
    Process.put(:washy_actor_from, from)

    try do
      case apply_handler(fun, msg, state.user) do
        {reply, new_user} -> {Term.normalize(reply), %{state | user: new_user}}
        reply -> {Term.normalize(reply), state}
      end
    after
      if prev, do: Process.put(:washy_actor_self, prev), else: Process.delete(:washy_actor_self)
      Process.delete(:washy_actor_from)
    end
  end

  # JS backend: the documented wiring point. Until qjs-run.wasm carries the Beam global, we re-enter the
  # guest through Washy with the message placed where the guest reads it. The MECHANISM (mailbox →
  # re-enter JS → run-to-completion → yield) is identical; only the in-guest callback dispatch awaits the
  # wasm rebuild. We expose the same self handle so a guest's Beam.send host import works today.
  defp deliver(%{spec: {:js, script}} = state, msg, from) do
    prev = Process.get(:washy_actor_self)
    Process.put(:washy_actor_self, self())
    Process.put(:washy_actor_from, from)
    # the delivered message is stashed where the guest's beam_recv host import reads it, so wb_dispatch()
    # pulls it and invokes the onMessage cb. We run the invoke IN THIS (owner) process, so the dict is read
    # directly (no Sandbox Task copy needed for the persistent path).
    Process.put(:washy_beam_inbox, Term.to_json(msg))
    set_js_ctx(script)

    try do
      case state.instance do
        # PERSISTENT PATH: re-enter the live QuickJS instance via the wb_dispatch export — NO script re-run,
        # so the guest's heap (vars/closures registered at boot) persists across messages. Thread the
        # (possibly memory-grown) instance handle forward.
        %Nexus.Washy.Instance{} = inst ->
          case Nexus.Washy.instance_invoke(inst, "wb_dispatch", [], fuel: 5_000_000_000) do
            {:ok, _r, _out, inst2} -> {Term.normalize(msg), %{state | instance: inst2}}
            {:exit, _c, _out, inst2} -> {Term.normalize(msg), %{state | instance: inst2}}
            {:trap, _reason, inst2} -> {Term.normalize(msg), %{state | instance: inst2}}
          end

        # FALLBACK (qjs-run.wasm not yet rebuilt with persistent setup): re-run the whole script per message
        # via the Sandbox. State does NOT persist on this path (documented limitation until the rebuild).
        nil ->
          qjs = qjs_run_wasm()

          if qjs do
            Nexus.Washy.Sandbox.run_command(
              {:interp, qjs, script <> "\n;__beam_dispatch();"},
              "",
              fuel: 5_000_000_000,
              timeout_ms: 30_000
            )
          end

          {Term.normalize(msg), state}
      end
    after
      Process.delete(:washy_beam_inbox)
      clear_js_ctx()
      if prev, do: Process.put(:washy_actor_self, prev), else: Process.delete(:washy_actor_self)
      Process.delete(:washy_actor_from)
    end
  end

  # set / clear the per-run guest context a Washy run needs (argv/stdin/vfs/fds) when we drive the guest
  # IN-PROCESS (instance_start / instance_invoke), not via the Sandbox harness. The script is the program.
  defp set_js_ctx(script) do
    Process.put(:washy_stdin, "")
    Process.put(:washy_argv, ["qjs", "/work/main"])
    Process.put(:washy_vfs, %{"main" => script})
    Process.put(:washy_backend, :map)
    Process.put(:washy_fds, %{})
    Process.put(:washy_nextfd, 4)
  end

  defp clear_js_ctx do
    Enum.each([:washy_stdin, :washy_argv, :washy_vfs, :washy_backend, :washy_fds, :washy_nextfd], &Process.delete/1)
  end

  # the generic QuickJS runner module the JS actor re-enters (decoded); nil if the JS lane isn't provisioned.
  defp qjs_run_mod do
    case qjs_run_wasm() do
      nil -> nil
      bytes -> case Nexus.Washy.decode_cached(bytes), do: ({:ok, m} -> m; _ -> nil)
    end
  end

  # the generic QuickJS runner (qjs-run.wasm) the JS actor re-enters; nil if the JS lane isn't provisioned.
  defp qjs_run_wasm do
    [Path.join([:code.priv_dir(:nexus), "..", "compilers", "js", "qjs-run.wasm"]), "compilers/js/qjs-run.wasm"]
    |> Enum.find(&File.exists?/1)
    |> case do
      nil -> nil
      path -> File.read!(path)
    end
  end

  defp apply_handler(fun, msg, user) when is_function(fun, 2), do: fun.(msg, user)
  defp apply_handler(fun, msg, _user) when is_function(fun, 1), do: fun.(msg)

  # ── helpers ─────────────────────────────────────────────────────────────────────────────────────

  defp normalize_spec(fun) when is_function(fun), do: {:fun, fun}
  defp normalize_spec({:fun, _} = s), do: s
  defp normalize_spec({:js, _} = s), do: s

  # encode a pid as a stable string handle (same scheme as Nexus.Washy.pid_handle, so handles are
  # interchangeable across the host bridge and the actor layer).
  defp pid_handle(pid) when is_pid(pid), do: pid |> :erlang.pid_to_list() |> to_string()
  defp pid_handle(other), do: to_string(other)

  defp resolve(pid) when is_pid(pid), do: if(Process.alive?(pid), do: pid, else: nil)

  defp resolve(name) do
    case Registry.lookup(@registry, name) do
      [{pid, _}] -> pid
      [] -> nil
    end
  end
end
