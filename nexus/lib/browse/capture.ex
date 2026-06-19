defmodule Nexus.Browse.Capture do
  @moduledoc """
  A process-scoped **network capture** — the HAR layer. Every brokered fetch in the runtime flows
  through one chokepoint (`Nexus.Dock.fetch/1`); within a `with/1` scope, each fetch is recorded into
  a log: `%{url, type, bytes, ok, ms, at}` (type sniffed from the response bytes, which is truthier
  than a Content-Type header). Outside a scope `record/3` is a cheap no-op, so normal fetches are
  unaffected.

      {result, har} = Nexus.Browse.Capture.with(fn -> Nexus.Browse.render(url) end)
      # har = every resource the render actually fetched (document, stylesheets, scripts…)

  Captures don't nest-merge: an inner scope shadows the outer for the duration. Per-process — the
  render pipeline's host-side sub-resource fetches happen in the calling process, so they're caught.
  """

  @table :nexus_capture
  @key :nx_capture_session

  @doc "Run `fun` capturing every brokered fetch; returns `{fun_result, [entry]}`."
  def with(fun) when is_function(fun, 0) do
    ensure_table()
    sid = make_ref()
    prev = Process.put(@key, sid)

    try do
      result = fun.()
      {result, entries(sid)}
    after
      if prev, do: Process.put(@key, prev), else: Process.delete(@key)
      :ets.match_delete(@table, {{sid, :_}, :_})
    end
  end

  @doc "Is a capture active in this process?"
  def active?, do: Process.get(@key) != nil

  @doc "Record one fetch into the active capture (no-op when none is active). Called by the chokepoint."
  def record(url, body, ms) do
    case Process.get(@key) do
      nil ->
        :ok

      sid ->
        ensure_table()
        body = body || ""
        entry = %{url: url, type: classify(body), bytes: byte_size(body), ok: body != "", ms: ms, at: now()}
        :ets.insert(@table, {{sid, System.unique_integer([:monotonic])}, entry})
        :ok
    end
  end

  @doc "The recorded entries for a session id, in fetch order."
  def entries(sid) do
    ensure_table()

    :ets.match_object(@table, {{sid, :_}, :_})
    |> Enum.sort_by(fn {{_sid, seq}, _} -> seq end)
    |> Enum.map(&elem(&1, 1))
  end

  @doc "Magic-byte content-type sniff — truthier than a header. Public so `Nexus.Browse.Media` reuses it."
  def classify(<<0xFF, 0xD8, 0xFF, _::binary>>), do: "image/jpeg"
  def classify(<<0x89, "PNG\r\n", 0x1A, 0x0A, _::binary>>), do: "image/png"
  def classify(<<"GIF8", _::binary>>), do: "image/gif"
  def classify(<<"RIFF", _::32, "WEBP", _::binary>>), do: "image/webp"
  def classify(<<"<svg", _::binary>>), do: "image/svg+xml"
  def classify(<<"<?xml", _::binary>> = b), do: if(String.contains?(binary_part(b, 0, min(200, byte_size(b))), "<svg"), do: "image/svg+xml", else: "text/xml")
  def classify(<<_::32, "ftyp", _::binary>>), do: "video/mp4"
  def classify(<<0x1A, 0x45, 0xDF, 0xA3, _::binary>>), do: "video/webm"
  def classify(<<"OggS", _::binary>>), do: "audio/ogg"
  def classify(<<"ID3", _::binary>>), do: "audio/mpeg"
  def classify(<<0xFF, f, _::binary>>) when f in [0xFB, 0xF3, 0xF2], do: "audio/mpeg"
  def classify(<<"%PDF", _::binary>>), do: "application/pdf"
  def classify(body) when is_binary(body) do
    head = binary_part(body, 0, min(512, byte_size(body))) |> String.downcase()

    cond do
      String.contains?(head, "<!doctype html") or String.contains?(head, "<html") -> "text/html"
      String.starts_with?(String.trim_leading(head), "{") or String.starts_with?(String.trim_leading(head), "[") -> "application/json"
      printable?(body) -> "text/plain"
      true -> "application/octet-stream"
    end
  end

  def classify(_), do: "application/octet-stream"

  defp printable?(body), do: String.valid?(binary_part(body, 0, min(256, byte_size(body))))

  defp now do
    System.system_time(:millisecond)
  rescue
    _ -> 0
  end

  defp ensure_table do
    case :ets.whereis(@table) do
      :undefined ->
        try do
          :ets.new(@table, [:named_table, :public, :ordered_set])
        rescue
          ArgumentError -> @table
        end

      _ ->
        @table
    end
  end
end
