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
      name: Keyword.get(opts, :name)
    }

    # boot the guest once: for a JS guest this is where `Beam.onMessage(cb)` runs and registers the
    # callback; for a fun-actor there's nothing to boot (the handler IS the callback).
    {:ok, boot(state)}
  end

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

  # ── guest execution ─────────────────────────────────────────────────────────────────────────────

  # Boot is a no-op for the prototype backends; the JS backend's onMessage registration happens here
  # in the real wiring (run the script once with :washy_actor_self set; the Beam.onMessage host import
  # stashes the callback id into the actor state). Documented in the design doc.
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
    # the delivered message is stashed where the guest's __beam_recv host import reads it (carried into
    # the run Task via Sandbox @ctx_keys), so __beam_dispatch() pulls it and invokes the onMessage cb.
    Process.put(:washy_beam_inbox, Term.to_json(msg))

    try do
      qjs = qjs_run_wasm()

      if qjs do
        # re-enter the guest: run its script (which registers Beam.onMessage), then dispatch this message.
        # run-to-completion = the call returns; the GenServer then blocks for the next message. (QuickJS
        # state isn't persisted between messages yet — persistent guest data lives in the Actor `user`.)
        Nexus.Washy.Sandbox.run_command(
          {:interp, qjs, script <> "\n;__beam_dispatch();"},
          "",
          fuel: 5_000_000_000,
          timeout_ms: 30_000
        )
      end

      {Term.normalize(msg), state}
    after
      Process.delete(:washy_beam_inbox)
      if prev, do: Process.put(:washy_actor_self, prev), else: Process.delete(:washy_actor_self)
      Process.delete(:washy_actor_from)
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

  defp resolve(pid) when is_pid(pid), do: if(Process.alive?(pid), do: pid, else: nil)

  defp resolve(name) do
    case Registry.lookup(@registry, name) do
      [{pid, _}] -> pid
      [] -> nil
    end
  end
end
