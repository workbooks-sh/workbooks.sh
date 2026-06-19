defmodule Nexus.Upsell do
  @moduledoc """
  Marketing logic as a capability — an AI-assembled, personalized upsell page.

  This is the canonical "upsell opportunity" method: given an org's account data, an
  LLM running in the nexus assembles an upgrade page from a fixed **catalog** of layouts
  and copy-slotted **blocks**, tailoring the language to the organization. It is the
  dogfood of our own [[upsells]] — the same pattern ships as a `.work` template
  (`templates/marketing/upsell.work`) so users build their own on it.

  **Two hard guarantees:**

    1. **The AI can never invent a number.** It is only ever asked to rewrite prose
       slots (headline, sub, intro, CTA label). Every price / memory / bandwidth /
       limit is filled by US from `Nexus.Pricing` facts — the model isn't asked for
       them, and `sanitize/1` additionally DROPS any returned slot that contains a
       digit, `$`, or a unit token. Structurally, prices are pinned.
    2. **Never blank.** `base/1` assembles a complete, real page from whatever minimal
       data we have (at least the org name + the pinned tier facts). The Groq pass only
       *personalizes* that base; if the model is absent, slow, or off-guardrail, the
       deterministic base is what ships.

  Speed-first: one shot, fast model (Groq via OpenRouter provider routing), low token
  cap — the assembly is meant to feel instant on click.
  """
  alias Nexus.Pricing

  # ── catalog: layouts (ordered block ids) + blocks (pinned fields + copy slots) ─────────────────
  # The LLM may only CHOOSE a layout from this set and fill the listed copy slots; the
  # block's pinned fields (prices, limits, unlock items) come from facts, never the model.
  @layouts %{
    "focused" => [:hero, :unlocks, :cta],
    "compare" => [:hero, :compare, :cta],
    "reassure" => [:hero, :headroom, :unlocks, :cta]
  }

  # copy slots, by block — the ONLY text the model can author.
  @slots %{
    hero: [:headline, :subhead],
    unlocks: [:intro],
    compare: [:intro],
    headroom: [:intro],
    cta: [:label, :sub]
  }

  @fast_model "meta-llama/llama-3.3-70b-instruct"

  @doc """
  Assemble a personalized upsell page model for `org`. `opts`:
    * `:org_name` — display name to personalize with (falls back to the org id)
    * `:fetch`    — unused here (kept for symmetry)
    * `:llm`      — injected `(messages, llm_opts) -> {:ok, %{content}} | {:error, _}` (tests)
    * `:personalize` — set false to skip the AI pass (pure deterministic base)

  Returns `%{org, layout, blocks, personalized, at_ceiling}`.
  """
  def assemble(org, opts \\ []) when is_binary(org) do
    facts = facts(org, opts)
    base = base(facts)

    if Keyword.get(opts, :personalize, true) and facts.next != nil do
      personalize(base, facts, opts)
    else
      base
    end
  end

  @doc "The pinned facts the page is built from — real tier/price data, never model output."
  def facts(org, opts \\ []) do
    name = blank(opts[:org_name]) || org
    nx = nexus(org)
    tier = Pricing.tier((nx && nx[:plan]) || "starter")
    next = Pricing.next_tier(tier.id)
    cap = if nx, do: Nexus.Capacity.report(nx), else: nil

    %{
      org: name,
      tier: %{id: tier.id, name: tier.name},
      next: next && tier_facts(next),
      usage: cap && %{ram: cap.ram, storage: cap.storage, hot: cap.ram.status != "ok" or cap.storage.status != "ok"}
    }
  end

  # ── deterministic base — complete, personalized with minimal data, never blank ─────────────────
  def base(%{next: nil} = f) do
    # Top tier: no checkout — more separation is a new org, not a bigger nexus.
    blocks = [
      block(:hero, %{}, headline: "#{f.org} is on #{f.tier.name}", subhead: "You're on our largest tier. Need a hard wall between teams? That's a new organization, not a second nexus."),
      block(:cta, %{href: "/team"}, label: "Invite your team", sub: "Unlimited seats — never per-user")
    ]

    %{org: f.org, layout: "focused", blocks: index(blocks), personalized: false, at_ceiling: true}
  end

  def base(f) do
    n = f.next
    hot = f.usage && f.usage.hot

    hero =
      if hot,
        do: block(:hero, %{}, headline: "#{f.org}, you're near capacity", subhead: "Scale up to #{n.name} to keep your team moving without limits."),
        else: block(:hero, %{}, headline: "Scale #{f.org} to #{n.name}", subhead: "More memory and bandwidth, the moment you need it.")

    blocks = [
      hero,
      block(:headroom, %{usage: f.usage, next: n}, intro: "Where you stand today:"),
      block(:unlocks, %{items: n.unlocks}, intro: "Moving to #{n.name} unlocks:"),
      block(:compare, %{current: f.tier, next: n}, intro: "#{f.tier.name} → #{n.name}"),
      block(:cta, %{href: "/billing/checkout?plan=#{n.id}"}, label: "Scale to #{n.name}", sub: "#{n.price} · cancel anytime")
    ]

    %{org: f.org, layout: if(hot, do: "reassure", else: "focused"), blocks: index(blocks), personalized: false, at_ceiling: false}
  end

  # ── the Groq pass — pick a layout + rewrite prose slots only ────────────────────────────────────
  defp personalize(base, facts, opts) do
    llm = Keyword.get(opts, :llm, &Nexus.Llm.complete/2)

    msgs = [
      %{role: "system", content: system_prompt()},
      %{role: "user", content: user_prompt(facts)}
    ]

    llm_opts = [
      model: Keyword.get(opts, :model, @fast_model),
      provider: %{order: ["Groq"], allow_fallbacks: true},
      temperature: 0.6,
      max_tokens: 500,
      timeout: 20_000
    ]

    with {:ok, %{content: content}} when is_binary(content) <- llm.(msgs, llm_opts),
         {:ok, %{} = out} <- decode(content) do
      apply_personalization(base, out)
    else
      _ -> base
    end
  end

  # Merge a validated {layout, copy} over the base: swap layout if allowed; overlay
  # sanitized prose onto matching blocks (by type) for the listed copy slots.
  defp apply_personalization(base, out) do
    layout = if is_map_key(@layouts, out["layout"]), do: out["layout"], else: base.layout
    copy = sanitize(out["copy"] || %{})

    blocks =
      Enum.map(base.blocks, fn b ->
        slot_copy = copy[Atom.to_string(b.type)] || %{}
        Map.update!(b, :copy, fn c ->
          Enum.reduce(@slots[b.type] || [], c, fn slot, acc ->
            case slot_copy[Atom.to_string(slot)] do
              t when is_binary(t) -> Map.put(acc, slot, t)
              _ -> acc
            end
          end)
        end)
      end)

    # The chosen layout decides which blocks render + their order.
    order = @layouts[layout]
    blocks = order |> Enum.map(fn t -> Enum.find(blocks, &(&1.type == t)) end) |> Enum.reject(&is_nil/1) |> index()

    %{base | layout: layout, blocks: blocks, personalized: true}
  end

  # GUARDRAIL: keep only string slot values free of any number / currency / unit token.
  # This is what makes "the AI can't make up a price" structural — anything numeric is dropped.
  @forbidden ~r/[\d$£€]|\bGB\b|\bMB\b|\/mo|percent|%/i
  def sanitize(copy) when is_map(copy) do
    Map.new(copy, fn {block, slots} ->
      clean =
        if is_map(slots) do
          slots
          |> Enum.filter(fn {_k, v} -> is_binary(v) and String.length(String.trim(v)) in 1..140 and not Regex.match?(@forbidden, v) end)
          |> Map.new()
        else
          %{}
        end

      {block, clean}
    end)
  end

  def sanitize(_), do: %{}

  defp system_prompt do
    """
    You personalize an upgrade page for Workbooks cloud customers. You rewrite ONLY the
    short text slots you are given so they speak to the specific organization — warm,
    concrete, confident, no hype.

    HARD RULES:
    - NEVER write any number, price, amount, GB/MB, percentage, or "$" — those are filled
      in for you. If you include one, your text is discarded.
    - Keep each slot under ~120 characters.
    - Choose the single best layout from the allowed list for this customer.

    Reply with JSON only: {"layout": "<id>", "copy": {"<block>": {"<slot>": "<text>"}}}.
    Use only the blocks and slots provided. Omit any slot you don't want to change.
    """
  end

  defp user_prompt(f) do
    usage =
      case f.usage do
        %{hot: true} -> "They are NEAR CAPACITY on their current plan."
        %{} -> "They have healthy headroom but are growing."
        _ -> "We have minimal usage data — keep it welcoming and general."
      end

    """
    Organization: #{f.org}
    Current plan: #{f.tier.name}. Recommended next: #{f.next.name}.
    Situation: #{usage}

    Allowed layouts: #{@layouts |> Map.keys() |> Enum.join(", ")}
    Editable blocks + slots:
    - hero: headline, subhead
    - unlocks: intro
    - compare: intro
    - headroom: intro
    - cta: label, sub

    Personalize for "#{f.org}". Remember: no numbers or prices in your text.
    """
  end

  defp decode(content) do
    # Tolerate prose around the JSON (fast models sometimes wrap it) — grab the first {...} object.
    json =
      case Regex.run(~r/\{.*\}/s, content) do
        [m] -> m
        _ -> content
      end

    case Jason.decode(json) do
      {:ok, %{} = m} -> {:ok, m}
      _ -> :error
    end
  end

  # ── helpers ────────────────────────────────────────────────────────────────────────────────────
  defp tier_facts(t) do
    %{
      id: t.id,
      name: t.name,
      price: if(t.price > 0, do: "$#{t.price}/mo", else: "Free"),
      memory: ram(t.ram_mb),
      bandwidth: "#{t.storage_gb} GB",
      domains: t.domains?,
      unlocks: unlocks(t.id)
    }
  end

  defp unlocks("team"), do: ["4× the memory", "10× the bandwidth & storage", "Custom domains", "Priority support"]
  defp unlocks("scale"), do: ["4× more memory again", "10× more bandwidth & storage", "Dedicated capacity"]
  defp unlocks(_), do: ["More memory", "More bandwidth"]

  defp block(type, pinned, copy), do: Map.merge(%{type: type, copy: Map.new(copy)}, pinned)

  # Stable index so the client can key blocks; also the render order.
  defp index(blocks), do: Enum.with_index(blocks, fn b, i -> Map.put(b, :i, i) end)

  defp nexus(org) do
    case Nexus.ControlPlane.list(org, :nexus) do
      [nx | _] -> nx
      _ -> nil
    end
  end

  defp ram(mb) when mb >= 1024, do: "#{div(mb, 1024)} GB"
  defp ram(mb), do: "#{mb} MB"

  defp blank(v) when v in [nil, ""], do: nil
  defp blank(v), do: v
end
