defmodule Nexus.Literate do
  @moduledoc """
  Parse a `.work` literate file into ordered blocks. This is the ONE parse the
  viewer (highlighting), the code-graph literate extractor, the weave gate
  (ref resolution), and WIT generation (`do…end` headers) all read — replacing
  the per-consumer regex guessing.

  The format's rule does the heavy lifting: a `do…end` block is the code
  delimiter. So at the top level a file is a sequence of:

    * `:heading`  — a markdown `#`…`######` line
    * `:code`     — a `<kind> [lang] :name … do … end` block (header parsed out)
    * `:decl`     — a flat declaration (`@attr`, `data :x, …`), bracket-balanced
    * `:prose`    — everything else: a markdown paragraph, with inline refs

  Each node carries `:line` (1-based start) and, where it has text, `:refs`
  (the `[[backlinks]]`, `:atoms`, `@types`, `#tags`, and `work://` links found).
  """

  @langs ~w(elixir rust zig python svelte solid js ts c go wit)
  @decl_kw ~w(data task user type deps checks theme show query workbook nexus grant route)

  @ref_re ~r/\[\[[^\]\n]+\]\]|work:\/\/[^\s)]*[a-zA-Z0-9_\/#-]|(?<![\w:]):[a-z]\w*|(?<![\w])@[a-z]\w*|(?<![\w])#[a-z][\w-]*/

  @spec parse(binary) :: [map]
  def parse(src) when is_binary(src) do
    src
    |> String.split("\n")
    |> Enum.with_index(1)
    |> walk([], [])
    |> Enum.reverse()
  end

  @doc """
  Extract the inline reference tokens from a chunk of text, in order. Tokens inside
  `inline code` are syntax examples (e.g. a lesson showing `[[backlink]]`), not real
  references, so they're stripped first.
  """
  def refs(text) when is_binary(text) do
    text
    |> String.replace(~r/`[^`]*`/, "")
    |> then(&Regex.scan(@ref_re, &1))
    |> Enum.map(&hd/1)
  end

  # ── the walk ──────────────────────────────────────────────────────────────
  # state: remaining {line, n} pairs · accumulating prose lines (reversed) · nodes

  defp walk([], prose, nodes), do: flush(prose, nodes)

  defp walk([{line, n} | rest], prose, nodes) do
    cond do
      # A ``` fenced code block is consumed whole — INCLUDING blank lines — so a blank
      # line inside a code listing doesn't split the fence (prose flushes on blanks).
      fence?(line) ->
        {flines, rest2} = take_fence(rest, [])
        text = Enum.join([line | flines], "\n")
        node = %{type: :prose, line: n, text: text, refs: []}
        walk(rest2, [], [node | flush(prose, nodes)])

      blank?(line) ->
        walk(rest, [], flush(prose, nodes))

      h = heading(line, n) ->
        walk(rest, [], [h | flush(prose, nodes)])

      opener?(line) ->
        {body, after_block} = take_block(rest, [])
        walk(after_block, [], [code_node(line, n, body) | flush(prose, nodes)])

      # only START a declaration at a block boundary (prose flushed) — a decl keyword
      # appearing mid-paragraph (a soft-wrapped continuation line) is prose, not a decl.
      decl?(line) and prose == [] ->
        {lines, rest2} = take_decl([{line, n} | rest])
        text = lines |> Enum.map(&elem(&1, 0)) |> Enum.join("\n")
        node = %{type: :decl, line: n, text: text, refs: refs(text)}
        walk(rest2, [], [node | flush(prose, nodes)])

      true ->
        walk(rest, [{line, n} | prose], nodes)
    end
  end

  # ── block recognition ─────────────────────────────────────────────────────

  defp blank?(line), do: String.trim(line) == ""

  # ``` fenced code block: a line that (trimmed) starts a fence. take_fence consumes
  # everything up to and INCLUDING the closing fence line, blanks and all.
  defp fence?(line), do: String.starts_with?(String.trim(line), "```")

  defp take_fence([], acc), do: {Enum.reverse(acc), []}

  defp take_fence([{line, _n} | rest], acc) do
    if String.starts_with?(String.trim(line), "```"),
      do: {Enum.reverse([line | acc]), rest},
      else: take_fence(rest, [line | acc])
  end

  defp heading(line, n) do
    case Regex.run(~r/^(#+)\s+(.*)$/, line) do
      [_, hashes, text] -> %{type: :heading, level: min(byte_size(hashes), 6), text: text, line: n}
      _ -> nil
    end
  end

  # A top-level code block opens with a non-indented line ending in ` do` — BUT only
  # when the line is actually a block HEADER, not prose that happens to end in the
  # English word "do" (e.g. "…what each block may do"). A real header is a bare kind
  # (`deploy do`), a kind with a `:name` (`server :x do`), or a CamelName declaration
  # (`data Order do`). Without this guard a sentence ending in "do" swallows the rest
  # of the page as a phantom block.
  defp opener?(line) do
    Regex.match?(~r/^[^\s#].*\sdo\s*$/, line) and header_shaped?(line)
  end

  defp header_shaped?(line) do
    head = line |> String.replace(~r/\s+do\s*$/, "") |> String.trim()

    head != "" and
      (Regex.match?(~r/^[a-z]\w*$/, head) or
         Regex.match?(~r/(^|\s):[a-z]/, head) or
         Regex.match?(~r/^(data|resource|record|defmodule|type|enum)\s+[A-Z]\w*/, head))
  end

  # A flat declaration starts (non-indented) with `@attr`, or a declaration word
  # FOLLOWED BY declaration-shaped content — not merely any prose line that happens to
  # begin with one of these common words (e.g. "workbook, and a …", "show your work").
  # A real decl's keyword is followed by an atom/string/CamelName/bracket/`:`/`=`, or the
  # line ends in ` do`, or it's the bare keyword. Otherwise it's prose.
  defp decl?(line) do
    Regex.match?(~r/^@[a-z]/, line) or
      (Regex.match?(~r/^(#{Enum.join(@decl_kw, "|")})\b/, line) and decl_shaped?(line))
  end

  defp decl_shaped?(line) do
    rest = line |> String.replace(~r/^\w+/, "") |> String.trim_leading()
    rest == "" or
      Regex.match?(~r/^[:"\[\{A-Z=]/, rest) or
      Regex.match?(~r/^[a-z_]\w*$/, rest) or
      Regex.match?(~r/\sdo\s*$/, line)
  end

  # ── consuming a code block: top-level opener at col 0 closes at `^end` ──────

  defp take_block([], acc), do: {Enum.reverse(acc), []}

  defp take_block([{line, _n} = h | rest], acc) do
    if Regex.match?(~r/^end\b/, line) do
      {Enum.reverse(acc), rest}
    else
      take_block(rest, [h | acc])
    end
  end

  # ── consuming a flat declaration: continue while brackets stay open ─────────

  defp take_decl(lines), do: take_decl(lines, 0, [])

  defp take_decl([], _depth, acc), do: {Enum.reverse(acc), []}

  defp take_decl([{line, _} = h | rest], depth, acc) do
    depth = depth + bracket_delta(line)

    if depth <= 0 do
      {Enum.reverse([h | acc]), rest}
    else
      take_decl(rest, depth, [h | acc])
    end
  end

  defp bracket_delta(line) do
    # ignore markdown/string brackets so prose-y content doesn't extend a decl
    code = line |> String.replace(~r/\[\[[^\]]*\]?\]?/, "") |> String.replace(~r/"[^"]*"/, "")
    opens = code |> String.graphemes() |> Enum.count(&(&1 in ["(", "[", "{"]))
    closes = code |> String.graphemes() |> Enum.count(&(&1 in [")", "]", "}"]))
    opens - closes
  end

  # ── building nodes ─────────────────────────────────────────────────────────

  defp code_node(opener, n, body_pairs) do
    header = Regex.replace(~r/\s+do\s*$/, opener, "")
    body = body_pairs |> Enum.map(&elem(&1, 0)) |> Enum.join("\n")
    full = opener <> "\n" <> body <> "\nend"

    # Prefer the REAL Elixir AST: a `<kind> :name … do … end` block parses to a
    # macro-call tuple, so kind/name/args come from the tree, not a regex. A
    # foreign-language body (Rust/Zig/Python/…) won't parse as Elixir — those fall
    # back to the header and keep an opaque body for the per-language extractor.
    {kind, name, lang, ast} =
      case Code.string_to_quoted(full, emit_warnings: false) do
        {:ok, quoted} -> from_ast(quoted, header)
        {:error, _} -> from_header(header)
      end

    %{
      type: :code,
      kind: kind,
      lang: lang,
      name: name,
      header: header,
      body: body,
      ast: ast,
      line: n,
      refs: refs(header <> "\n" <> body)
    }
  end

  # The Elixir AST of `kind arg, … do … end` — a call tuple. Pull kind + the
  # first atom argument (the unit name); a `lang :name` block names the language.
  defp from_ast({kind, _meta, args} = ast, _header) when is_atom(kind) and is_list(args) do
    name =
      Enum.find_value(args, fn
        a when is_atom(a) -> Atom.to_string(a)
        {inner, _, [a | _]} when is_atom(inner) and is_atom(a) -> Atom.to_string(a)
        _ -> nil
      end)

    # `<placement> <lang> :name` nests the lang as a call: {:rust, _, [:enrich]}
    inner_lang =
      Enum.find_value(args, fn
        {l, _, _} when is_atom(l) -> if Atom.to_string(l) in @langs, do: Atom.to_string(l)
        _ -> nil
      end)

    lang =
      cond do
        Atom.to_string(kind) in @langs -> Atom.to_string(kind)
        inner_lang -> inner_lang
        true -> "elixir"
      end

    {Atom.to_string(kind), name, lang, ast}
  end

  defp from_ast(_other, header), do: from_header(header)

  defp from_header(header) do
    words = String.split(header)
    kind = List.first(words)
    name = with [_, a] <- Regex.run(~r/:([a-z]\w*)/, header), do: a, else: (_ -> nil)
    lang = Enum.find(words, &(&1 in @langs)) || if(kind in @langs, do: kind)
    {kind, name, lang, nil}
  end

  defp flush([], nodes), do: nodes

  defp flush(prose, nodes) do
    {_, first_n} = List.last(prose)
    text = prose |> Enum.reverse() |> Enum.map(&elem(&1, 0)) |> Enum.join("\n")
    [%{type: :prose, line: first_n, text: text, refs: refs(text)} | nodes]
  end
end
