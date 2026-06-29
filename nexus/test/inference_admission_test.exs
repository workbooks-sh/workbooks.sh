defmodule Nexus.Inference.AdmissionTest do
  use ExUnit.Case, async: false
  alias Nexus.ControlPlane, as: CP
  alias Nexus.Inference.Admission

  # The money boundary: admit/3 must FAIL CLOSED for an enforced org out of credit / off-policy, and
  # must stay OPEN for trusted/unconfigured callers so the open-standard runtime never pays.
  @org "org_inf"
  @model "anthropic/claude-opus-4.8"

  setup do
    CP.reset()
    :ok
  end

  defp cfg(attrs), do: CP.put(@org, :inference, "config", attrs)

  test "trusted caller (nil tenant) is always admitted" do
    assert Admission.admit(nil, @model) == :ok
  end

  test "an org with no policy is admitted (open standard intact)" do
    assert Admission.admit(@org, @model) == :ok
  end

  test "enforcement off ⇒ admitted even at zero balance" do
    cfg(%{enforce: false, balance: 0.0})
    assert Admission.admit(@org, @model) == :ok
  end

  test "enforced + zero balance ⇒ insufficient_credit" do
    cfg(%{enforce: true, balance: 0.0})
    assert Admission.admit(@org, @model) == {:error, :insufficient_credit}
  end

  test "enforced + positive balance ⇒ admitted" do
    cfg(%{enforce: true, balance: 5.0})
    assert Admission.admit(@org, @model) == :ok
  end

  test "model not in the allow-list ⇒ model_not_allowed (checked before credit)" do
    cfg(%{enforce: true, balance: 5.0, allow_ids: ["openai/gpt-4o"]})
    assert Admission.admit(@org, @model) == {:error, :model_not_allowed}
  end

  test "empty allow-list means unrestricted" do
    cfg(%{enforce: true, balance: 5.0, allow_ids: []})
    assert Admission.admit(@org, @model) == :ok
  end

  test "a disabled modality capability blocks a generator, text is never capability-gated" do
    cfg(%{enforce: true, balance: 5.0, caps: %{image: false}})
    assert Admission.admit(@org, "@cf/x/flux", modality: :image) == {:error, :capability_disabled}
    assert Admission.admit(@org, @model, modality: :text) == :ok
  end

  test "monthly cap reached ⇒ monthly_cap_exceeded" do
    cfg(%{enforce: true, balance: 50.0, spent_mtd: 100.0, monthly_cap: 100.0})
    assert Admission.admit(@org, @model) == {:error, :monthly_cap_exceeded}
  end

  test "charge/2 debits balance and accrues spent_mtd" do
    cfg(%{enforce: true, balance: 10.0, spent_mtd: 0.0})
    assert Admission.charge(@org, 2.5) == :ok
    {:ok, c} = CP.get(@org, :inference, "config")
    assert c.balance == 7.5
    assert c.spent_mtd == 2.5
  end

  test "charge is a no-op when enforcement is off" do
    cfg(%{enforce: false, balance: 10.0})
    assert Admission.charge(@org, 2.5) == :ok
    {:ok, c} = CP.get(@org, :inference, "config")
    assert c.balance == 10.0
  end

  test "reason kind classifies credit vs policy for the client modal" do
    assert Admission.kind(:insufficient_credit) == :credit
    assert Admission.kind(:monthly_cap_exceeded) == :credit
    assert Admission.kind(:model_not_allowed) == :policy
    assert Admission.kind(:capability_disabled) == :policy
  end
end
