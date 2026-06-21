defmodule Nexus.Time do
  @moduledoc """
  The ONE time vocabulary for the nexus — the temporal counterpart to `Nexus.Literate`.

  Every place that needs "when / how long / how often" parses through here, so there is a single
  home for time (DRY): the `Nexus.Scheduler`, a `hook`'s `trigger`, a `flow` step's `after:`/`wait`,
  a `task`'s `SCHEDULED:`/`DEADLINE:`, and durations like an agent `limit` or a cache TTL.

  ## Forms

    * **duration** — `"15m"`, `"2h"`, `"1d30m"`, `"90s"` → milliseconds. Units: `s m h d w`.
    * **relative trigger** — `every: "15m"` (repeating), `after: "5m"` (one-shot delay).
    * **clock trigger** — `at: "14:00"` (daily at that UTC wall-clock minute).
    * **cron** — `cron: "0 2 * * *"` (5 fields: minute hour day-of-month month day-of-week,
      each `*`, a number, a `a-b` range, an `a,b,c` list, or a `*/n` step).
    * **org timestamp** — `"<2026-06-21 14:00 +1w>"` with an optional time-of-day, an optional
      **span** (`14:00-15:30` → a `duration_s`), and an optional **repeater**
      (`+1w` shift-from-stamp, `.+1d` shift-from-now, `++1m` catch-up-to-future).

  ## Spec

  `spec/1` normalizes any form into one of:

      %{kind: :every,     ms: 900_000}
      %{kind: :after,     ms: 300_000}
      %{kind: :at,        minute: 0, hour: 14}
      %{kind: :cron,      min: set, hour: set, dom: set, mon: set, dow: set}
      %{kind: :timestamp, at: ~U[…], repeat: {:plus, 1, :week} | nil, duration_s: integer | nil}

  `next_fire/2` and `ms_until/3` turn a spec into the next concrete instant (UTC), the single
  primitive `Nexus.Scheduler` arms `Process.send_after` against. Generic mechanism only.
  """

  @units %{"s" => 1_000, "m" => 60_000, "h" => 3_600_000, "d" => 86_400_000, "w" => 604_800_000}
  @rep_units %{"h" => :hour, "d" => :day, "w" => :week, "m" => :month, "y" => :year}

  # ── Durations ─────────────────────────────────────────────────────────────────────────────────

  @doc """
  Parse a duration string into milliseconds. Supports stacked units (`"1d30m"`). Accepts a bare
  integer/float of seconds for convenience. Returns `{:ok, ms}` or `:error`.
  """
  def duration_ms(ms) when is_integer(ms) and ms >= 0, do: {:ok, ms}

  def duration_ms(str) when is_binary(str) do
    parts = Regex.scan(~r/(\d+)\s*([smhdw])/, String.downcase(str))

    cond do
      parts != [] ->
        {:ok, Enum.reduce(parts, 0, fn [_, n, u], acc -> acc + String.to_integer(n) * @units[u] end)}

      Regex.match?(~r/^\d+$/, String.trim(str)) ->
        {:ok, String.to_integer(String.trim(str)) * 1_000}

      true ->
        :error
    end
  end

  def duration_ms(_), do: :error

  @doc "Like `duration_ms/1` but raises on a bad value. Handy at parse sites with known-good input."
  def duration_ms!(v) do
    case duration_ms(v) do
      {:ok, ms} -> ms
      :error -> raise ArgumentError, "bad duration: #{inspect(v)}"
    end
  end

  # ── Spec building ─────────────────────────────────────────────────────────────────────────────

  @doc """
  Normalize a time form into a canonical spec. Accepts a keyword list (`every:`/`after:`/`at:`/
  `cron:`), or a bare string (an org `<…>` timestamp, a `"hh:mm"`, or a duration treated as `after`).
  Returns `{:ok, spec}` or `{:error, reason}`.
  """
  def spec(opts) when is_list(opts) do
    cond do
      v = opts[:every] -> with {:ok, ms} <- duration_ms(v), do: {:ok, %{kind: :every, ms: ms}}
      v = opts[:after] -> with {:ok, ms} <- duration_ms(v), do: {:ok, %{kind: :after, ms: ms}}
      v = opts[:cron] -> parse_cron(v)
      v = opts[:at] -> parse_at(v)
      true -> {:error, :no_time_field}
    end
    |> case do
      :error -> {:error, :bad_duration}
      other -> other
    end
  end

  def spec(str) when is_binary(str) do
    str = String.trim(str)

    cond do
      String.starts_with?(str, "<") -> parse_timestamp(str)
      Regex.match?(~r/^\d{1,2}:\d{2}/, str) -> parse_at(str)
      true -> with {:ok, ms} <- duration_ms(str), do: {:ok, %{kind: :after, ms: ms}}
    end
    |> case do
      :error -> {:error, :unparsable_time}
      other -> other
    end
  end

  # An already-built spec passes through (lets callers arm a precise spec directly).
  def spec(%{kind: k} = s) when k in [:every, :after, :at, :cron, :timestamp], do: {:ok, s}

  def spec(other), do: {:error, {:bad_time, other}}

  # `at: "14:00"` (optionally an org span "14:00-15:30" — we keep the start; the span feeds duration).
  defp parse_at(v) when is_binary(v) do
    case Regex.run(~r/^(\d{1,2}):(\d{2})/, String.trim(v)) do
      [_, h, m] ->
        hour = String.to_integer(h)
        min = String.to_integer(m)
        if hour in 0..23 and min in 0..59, do: {:ok, %{kind: :at, hour: hour, minute: min}}, else: {:error, :bad_clock}

      _ ->
        {:error, :bad_clock}
    end
  end

  # ── Cron (5-field) ────────────────────────────────────────────────────────────────────────────

  @doc "Parse a 5-field cron string into a spec of MapSets, or `{:error, _}`."
  def parse_cron(str) when is_binary(str) do
    case String.split(String.trim(str), ~r/\s+/) do
      [mi, ho, dom, mo, dow] ->
        with {:ok, min} <- cron_field(mi, 0, 59),
             {:ok, hour} <- cron_field(ho, 0, 23),
             {:ok, dom_s} <- cron_field(dom, 1, 31),
             {:ok, mon} <- cron_field(mo, 1, 12),
             {:ok, dow_s} <- cron_field(dow, 0, 6) do
          {:ok, %{kind: :cron, min: min, hour: hour, dom: dom_s, mon: mon, dow: dow_s}}
        end

      _ ->
        {:error, :cron_needs_5_fields}
    end
  end

  defp cron_field("*", lo, hi), do: {:ok, MapSet.new(lo..hi)}

  defp cron_field(field, lo, hi) do
    field
    |> String.split(",")
    |> Enum.reduce_while({:ok, MapSet.new()}, fn part, {:ok, acc} ->
      case cron_part(part, lo, hi) do
        {:ok, set} -> {:cont, {:ok, MapSet.union(acc, set)}}
        err -> {:halt, err}
      end
    end)
  end

  defp cron_part(part, lo, hi) do
    # groups: start (`*` or n), optional range-end, optional `/step`
    # Erlang drops TRAILING unmatched optional groups, so pad to 3 before destructuring.
    case Regex.run(~r/^(\*|\d+)(?:-(\d+))?(?:\/(\d+))?$/, part, capture: :all_but_first) do
      nil ->
        {:error, {:bad_cron_field, part}}

      groups ->
        [start, range_end, step_s] = groups ++ List.duplicate("", 3 - length(groups))
        step = if step_s == "", do: 1, else: max(String.to_integer(step_s), 1)

        {a, b} =
          cond do
            start == "*" -> {lo, hi}
            range_end != "" -> {String.to_integer(start), String.to_integer(range_end)}
            step_s != "" -> {String.to_integer(start), hi}
            true -> n = String.to_integer(start); {n, n}
          end

        if a in lo..hi and b in lo..hi and a <= b,
          do: {:ok, MapSet.new(Enum.take_every(a..b, step))},
          else: {:error, {:cron_range, part}}
    end
  end

  # ── Org timestamps ────────────────────────────────────────────────────────────────────────────

  @doc """
  Parse an org-style `<YYYY-MM-DD[ Dow][ hh:mm[-hh:mm]][ repeater]>` timestamp. The day-name is
  ignored, the span (`hh:mm-hh:mm`) becomes `duration_s`, the repeater becomes `{:plus, n, unit}`.
  """
  def parse_timestamp(str) when is_binary(str) do
    inner = str |> String.trim() |> String.trim_leading("<") |> String.trim_trailing(">") |> String.trim()

    with [_, y, mo, d] <- Regex.run(~r/^(\d{4})-(\d{2})-(\d{2})/, inner),
         {:ok, date} <- Date.new(String.to_integer(y), String.to_integer(mo), String.to_integer(d)) do
      {hh, mm, dur} = parse_time_span(inner)
      {:ok, dt} = DateTime.new(date, Time.new!(hh, mm, 0), "Etc/UTC")
      {:ok, %{kind: :timestamp, at: dt, repeat: parse_repeater(inner), duration_s: dur}}
    else
      _ -> {:error, :bad_timestamp}
    end
  end

  defp parse_time_span(inner) do
    case Regex.run(~r/(\d{1,2}):(\d{2})(?:-(\d{1,2}):(\d{2}))?/, inner) do
      [_, h, m] ->
        {String.to_integer(h), String.to_integer(m), nil}

      [_, h, m, h2, m2] ->
        start = String.to_integer(h) * 3600 + String.to_integer(m) * 60
        stop = String.to_integer(h2) * 3600 + String.to_integer(m2) * 60
        {String.to_integer(h), String.to_integer(m), max(stop - start, 0)}

      _ ->
        {0, 0, nil}
    end
  end

  # repeaters: `+1w` (from stamp), `.+1d` (from now), `++1m` (catch up). We keep the unit + n; the
  # `++`/`.+` nuance only changes the anchor, handled in advance/2.
  defp parse_repeater(inner) do
    case Regex.run(~r/(\+{1,2}|\.\+)(\d+)([hdwmy])/, inner) do
      [_, mark, n, u] -> {repeat_mode(mark), String.to_integer(n), @rep_units[u]}
      _ -> nil
    end
  end

  defp repeat_mode("++"), do: :catchup
  defp repeat_mode(".+"), do: :from_now
  defp repeat_mode(_), do: :plus

  # ── next_fire / ms_until ──────────────────────────────────────────────────────────────────────

  @doc """
  The next instant (UTC `DateTime`) this spec should fire at, strictly AFTER `from`. Returns
  `{:ok, dt}` or `:none` (a one-shot already in the past / an exhausted timestamp).
  """
  def next_fire(spec, from \\ nil)

  def next_fire(%{kind: :every, ms: ms}, from), do: {:ok, DateTime.add(now(from), ms, :millisecond)}
  def next_fire(%{kind: :after, ms: ms}, from), do: {:ok, DateTime.add(now(from), ms, :millisecond)}

  def next_fire(%{kind: :at, hour: h, minute: m}, from) do
    from = now(from)
    today = %{from | hour: h, minute: m, second: 0, microsecond: {0, 0}}
    if DateTime.compare(today, from) == :gt, do: {:ok, today}, else: {:ok, DateTime.add(today, 86_400, :second)}
  end

  def next_fire(%{kind: :cron} = spec, from) do
    from = now(from) |> Map.merge(%{second: 0, microsecond: {0, 0}}) |> DateTime.add(60, :second)
    cron_search(spec, from, 0)
  end

  def next_fire(%{kind: :timestamp, at: at} = spec, from) do
    from = now(from)

    cond do
      DateTime.compare(at, from) == :gt -> {:ok, at}
      spec.repeat == nil -> :none
      true -> advance(at, spec.repeat, from)
    end
  end

  def next_fire(_, _), do: :none

  @doc """
  Milliseconds from `from` until the next fire, never negative; `:none` if there is no next fire.
  This is what `Nexus.Scheduler` hands to `Process.send_after`.
  """
  def ms_until(spec, from \\ nil) do
    base = now(from)

    case next_fire(spec, base) do
      {:ok, dt} -> max(DateTime.diff(dt, base, :millisecond), 0)
      :none -> :none
    end
  end

  @doc "Does this spec repeat (re-arm after firing) or is it one-shot?"
  def repeating?(%{kind: :every}), do: true
  def repeating?(%{kind: :at}), do: true
  def repeating?(%{kind: :cron}), do: true
  def repeating?(%{kind: :timestamp, repeat: r}), do: r != nil
  def repeating?(_), do: false

  # ── helpers ───────────────────────────────────────────────────────────────────────────────────

  defp now(nil), do: DateTime.utc_now()
  defp now(%DateTime{} = dt), do: dt

  # Minute-by-minute scan for the next cron-matching instant. Bounded so a never-matching field set
  # (e.g. Feb 30) can't loop forever — ~366 days of minutes.
  defp cron_search(_spec, _dt, n) when n > 535_000, do: :none

  defp cron_search(spec, dt, n) do
    if cron_match?(spec, dt), do: {:ok, dt}, else: cron_search(spec, DateTime.add(dt, 60, :second), n + 1)
  end

  defp cron_match?(spec, dt) do
    dow = Date.day_of_week(DateTime.to_date(dt))
    # cron dow: 0=Sunday..6=Saturday; Date.day_of_week: 1=Monday..7=Sunday
    cron_dow = rem(dow, 7)

    MapSet.member?(spec.min, dt.minute) and MapSet.member?(spec.hour, dt.hour) and
      MapSet.member?(spec.dom, dt.day) and MapSet.member?(spec.mon, dt.month) and
      MapSet.member?(spec.dow, cron_dow)
  end

  # Advance a timestamp by its repeater until strictly after `from`. `:from_now` anchors on `from`.
  defp advance(at, {mode, n, unit}, from) do
    base = if mode == :from_now, do: from, else: at
    do_advance(base, n, unit, from)
  end

  defp do_advance(dt, n, unit, from) do
    next = shift(dt, n, unit)
    if DateTime.compare(next, from) == :gt, do: {:ok, next}, else: do_advance(next, n, unit, from)
  end

  defp shift(dt, n, :hour), do: DateTime.add(dt, n * 3600, :second)
  defp shift(dt, n, :day), do: DateTime.add(dt, n * 86_400, :second)
  defp shift(dt, n, :week), do: DateTime.add(dt, n * 604_800, :second)
  defp shift(dt, n, :month), do: add_months(dt, n)
  defp shift(dt, n, :year), do: add_months(dt, n * 12)

  defp add_months(dt, n) do
    m0 = dt.year * 12 + (dt.month - 1) + n
    year = div(m0, 12)
    month = rem(m0, 12) + 1
    day = min(dt.day, Date.days_in_month(Date.new!(year, month, 1)))
    %{dt | year: year, month: month, day: day}
  end
end
