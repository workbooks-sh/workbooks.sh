defmodule Workbooks.BrokerAuditTest do
  use ExUnit.Case, async: false
  alias Workbooks.{BrokerAudit, NetGuard}

  test "record + stats — counts allow/deny outcomes per broker and per reason" do
    BrokerAudit.reset()
    BrokerAudit.record(:net, :deny, :ssrf)
    BrokerAudit.record(:net, :deny, :ssrf)
    BrokerAudit.record(:tcp, :deny, :rate_limited)
    BrokerAudit.record(:net, :allow)

    s = BrokerAudit.stats()
    assert s[{:net, :deny}] == 2
    assert s[{:net, :deny, :ssrf}] == 2
    assert s[{:tcp, :deny, :rate_limited}] == 1
    assert s[{:net, :allow}] == 1
    # a single number a monitor can alert on
    assert BrokerAudit.total_denials() == 3
  end

  test "NetGuard egress denials are AUDITED — the 'manageable' view of the SSRF floor + allow-list" do
    BrokerAudit.reset()
    # internal target -> SSRF deny (recorded)
    assert {:error, :denied} = NetGuard.get("http://169.254.169.254/")
    # public but not on the per-instance allow-list -> allow-list deny (recorded)
    assert {:error, :denied} = NetGuard.get("http://8.8.8.8/", allow: ["example.com"])

    assert BrokerAudit.count({:net, :deny, :ssrf}) >= 1
    assert BrokerAudit.count({:net, :deny, :allowlist}) >= 1
    assert BrokerAudit.total_denials() >= 2
  end
end
