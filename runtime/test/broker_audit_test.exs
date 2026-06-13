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

  test "exec + serve denials are also audited (observability across capability brokers)" do
    BrokerAudit.reset()
    # exec without the commands grant -> denied (recorded via the central deny/2 helper)
    assert {:error, :denied} = Workbooks.ExecBroker.exec("jq", [], "", allow: false)
    # a revoked inbound serve dispatch -> denied (recorded)
    sid = "audit-#{System.unique_integer([:positive])}"
    :ok = Workbooks.Revocation.revoke(sid)
    assert {:error, :revoked} = Workbooks.ServeBroker.dispatch(sid, nil, "req")
    :ok = Workbooks.Revocation.unrevoke(sid)

    assert BrokerAudit.count({:exec, :deny}) >= 1
    assert BrokerAudit.count({:serve, :deny, :revoked}) >= 1
  end

  test "the NEW execution-model + raw-TCP brokers are observable (process + tcp_serve denials queryable)" do
    BrokerAudit.reset()

    # ProcessBroker: a revoked principal's spawn is denied + audited (:process)
    p = "audit-proc-#{System.unique_integer([:positive])}"
    :ok = Workbooks.Revocation.revoke(p)
    assert {:error, :revoked} = Workbooks.ProcessBroker.spawn("nope", [], "", allow: true, principal: p)
    :ok = Workbooks.Revocation.unrevoke(p)

    # TcpServeBroker: start a revoked server; a connection is refused + audited (:tcp_serve)
    sid = "audit-tcps-#{System.unique_integer([:positive])}"
    {:ok, lsock} = Workbooks.TcpServeBroker.start(handler: fn r -> r end, serve_id: sid)
    port = Workbooks.TcpServeBroker.port(lsock)
    :ok = Workbooks.Revocation.revoke(sid)
    {:ok, sock} = :gen_tcp.connect(~c"127.0.0.1", port, [:binary, active: false], 2_000)
    :gen_tcp.send(sock, "x")
    _ = :gen_tcp.recv(sock, 0, 1_000)
    :gen_tcp.close(sock)
    Process.sleep(100)
    Workbooks.TcpServeBroker.stop(lsock)
    :ok = Workbooks.Revocation.unrevoke(sid)

    # both new brokers' denials are in the queryable counters + the forensics ring + total
    assert BrokerAudit.count({:process, :deny, :revoked}) >= 1
    assert BrokerAudit.count({:tcp_serve, :deny, :revoked}) >= 1
    assert BrokerAudit.total_denials() >= 2
    brokers = BrokerAudit.recent(50) |> Enum.map(fn {b, _r, _t, _ts} -> b end)
    assert :process in brokers
    assert :tcp_serve in brokers
  end

  test "forensics ring — recent/1 captures the denial TARGET (what the guest tried to reach)" do
    BrokerAudit.reset()
    assert {:error, :denied} = NetGuard.get("http://169.254.169.254/")
    assert {:error, :denied} = NetGuard.get("http://10.0.0.1/")

    recent = BrokerAudit.recent(10)
    targets = Enum.map(recent, fn {_broker, _reason, t, _ts} -> t end)
    # the ring records WHICH internal targets were attempted — the key incident-response question
    assert "http://169.254.169.254/" in targets
    assert "http://10.0.0.1/" in targets
    # newest-first: the most recent attempt heads the list, tagged broker + reason
    assert [{:net, :ssrf, "http://10.0.0.1/", _ts} | _] = recent
  end

  test "telemetry — denials emit a [:workbooks, :broker, :deny] event external monitors can attach to" do
    ref = make_ref()
    parent = self()

    :telemetry.attach(
      "test-#{inspect(ref)}",
      [:workbooks, :broker, :deny],
      fn _event, measurements, metadata, _ -> send(parent, {:telemetry, measurements, metadata}) end,
      nil
    )

    BrokerAudit.record(:net, :deny, :ssrf, "http://169.254.169.254/")

    assert_receive {:telemetry, %{count: 1},
                    %{broker: :net, reason: :ssrf, target: "http://169.254.169.254/"}},
                   1_000

    :telemetry.detach("test-#{inspect(ref)}")
  end

  test "wb-8w8x: a huge guest-controlled target is TRUNCATED in the forensics ring (memory floor)" do
    BrokerAudit.reset()
    huge = "http://10.0.0.1/" <> String.duplicate("A", 100_000)
    BrokerAudit.record(:net, :deny, :ssrf, huge)

    [{:net, :ssrf, target, _ts} | _] = BrokerAudit.recent(1)
    assert byte_size(target) <= 512
  end
end
