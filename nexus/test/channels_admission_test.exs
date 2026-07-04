defmodule Nexus.Channels.AdmissionTest do
  use ExUnit.Case, async: false
  alias Nexus.Channels.Admission
  alias Nexus.ControlPlane, as: CP

  # The phone-channel money boundary (wb-h0pey): admit/3 must FAIL CLOSED for an enforced org out of
  # credit / with the modality killed, and stay OPEN for trusted/unconfigured callers so the
  # open-standard runtime never gates.
  @org "org_channels"

  setup do
    CP.reset()
    :ok
  end

  defp cfg(attrs), do: CP.put(@org, :channels, "config", attrs)

  test "trusted caller (nil tenant) is always admitted" do
    assert Admission.admit(nil, :sms) == :ok
  end

  test "an org with no policy is admitted (open standard intact)" do
    assert Admission.admit(@org, :sms) == :ok
  end

  test "enforcement off ⇒ admitted even at zero balance" do
    cfg(%{enforce: false, balance: 0.0})
    assert Admission.admit(@org, :sms) == :ok
  end

  test "enforced + zero balance ⇒ insufficient_credit" do
    cfg(%{enforce: true, balance: 0.0})
    assert Admission.admit(@org, :sms) == {:error, :insufficient_credit}
  end

  test "enforced + positive balance ⇒ admitted" do
    cfg(%{enforce: true, balance: 5.0})
    assert Admission.admit(@org, :sms) == :ok
    assert Admission.admit(@org, :voice) == :ok
  end

  test "a killed modality blocks (the kill switch), the other stays open" do
    cfg(%{enforce: true, balance: 5.0, caps: %{voice: false}})
    assert Admission.admit(@org, :voice) == {:error, :capability_disabled}
    assert Admission.admit(@org, :sms) == :ok
  end

  test "capability check comes before credit (killed modality reports policy, not money)" do
    cfg(%{enforce: true, balance: 0.0, caps: %{sms: false}})
    assert Admission.admit(@org, :sms) == {:error, :capability_disabled}
  end

  test "monthly cap reached ⇒ monthly_cap_exceeded (bill-shock ceiling)" do
    cfg(%{enforce: true, balance: 50.0, spent_mtd: 25.0, monthly_cap: 25.0})
    assert Admission.admit(@org, :sms) == {:error, :monthly_cap_exceeded}
  end

  test "charge/2 debits balance and accrues spent_mtd" do
    cfg(%{enforce: true, balance: 10.0, spent_mtd: 0.0})
    assert Admission.charge(@org, 0.02) == :ok
    {:ok, c} = CP.get(@org, :channels, "config")
    assert c.balance == 9.98
    assert c.spent_mtd == 0.02
  end

  test "charge is a no-op when enforcement is off" do
    cfg(%{enforce: false, balance: 10.0})
    assert Admission.charge(@org, 2.5) == :ok
    {:ok, c} = CP.get(@org, :channels, "config")
    assert c.balance == 10.0
  end

  test "cost/3 prices units by the tenant's fee schedule; unpriced ⇒ 0.0" do
    cfg(%{enforce: true, balance: 10.0, rates: %{sms: 0.01, voice: 0.10}})
    assert Admission.cost(@org, :sms, 3) == 0.03
    assert Admission.cost(@org, :voice, 12.5) == 1.25
    assert Admission.cost(@org, :sms, 0) == 0.0

    CP.reset()
    assert Admission.cost(@org, :sms, 3) == 0.0
  end

  test "reason kind classifies credit vs policy" do
    assert Admission.kind(:insufficient_credit) == :credit
    assert Admission.kind(:monthly_cap_exceeded) == :credit
    assert Admission.kind(:capability_disabled) == :policy
  end

  describe "sms_segments/1 (the SMS billing unit)" do
    test "GSM-7 texts split at 160/153" do
      assert Admission.sms_segments("") == 1
      assert Admission.sms_segments("hello") == 1
      assert Admission.sms_segments(String.duplicate("a", 160)) == 1
      assert Admission.sms_segments(String.duplicate("a", 161)) == 2
      assert Admission.sms_segments(String.duplicate("a", 306)) == 2
      assert Admission.sms_segments(String.duplicate("a", 307)) == 3
    end

    test "UCS-2 texts (emoji / non-Latin) split at 70/67" do
      assert Admission.sms_segments(String.duplicate("🔥", 70)) == 1
      assert Admission.sms_segments(String.duplicate("🔥", 71)) == 2
      assert Admission.sms_segments(String.duplicate("你", 67 * 2)) == 2
    end
  end
end
