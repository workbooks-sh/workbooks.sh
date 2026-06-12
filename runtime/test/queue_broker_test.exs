defmodule Workbooks.QueueBrokerTest do
  use ExUnit.Case, async: false
  alias Workbooks.QueueBroker

  test "publish/poll is FIFO; empty topic returns :empty" do
    t = "t-#{System.unique_integer([:positive])}"
    assert :empty = QueueBroker.poll(t, "jobs")
    assert :ok = QueueBroker.publish(t, "jobs", "a")
    assert :ok = QueueBroker.publish(t, "jobs", "b")
    assert {:ok, "a"} = QueueBroker.poll(t, "jobs")
    assert {:ok, "b"} = QueueBroker.poll(t, "jobs")
    assert :empty = QueueBroker.poll(t, "jobs")
  end

  test "TENANT ISOLATION — a tenant cannot poll another tenant's topic" do
    a = "a-#{System.unique_integer([:positive])}"
    b = "b-#{System.unique_integer([:positive])}"
    assert :ok = QueueBroker.publish(a, "jobs", "for-a")
    # b's same-named topic is a different queue
    assert :empty = QueueBroker.poll(b, "jobs")
    assert {:ok, "for-a"} = QueueBroker.poll(a, "jobs")
  end

  test "DEPTH cap (DoS floor) — publish past the cap is rejected" do
    t = "t-#{System.unique_integer([:positive])}"
    assert :ok = QueueBroker.publish(t, "j", "1", max_depth: 2)
    assert :ok = QueueBroker.publish(t, "j", "2", max_depth: 2)
    assert {:error, :queue_full} = QueueBroker.publish(t, "j", "3", max_depth: 2)
    # draining one frees a slot
    assert {:ok, "1"} = QueueBroker.poll(t, "j")
    assert :ok = QueueBroker.publish(t, "j", "3", max_depth: 2)
  end

  test "topics within a tenant are independent" do
    t = "t-#{System.unique_integer([:positive])}"
    assert :ok = QueueBroker.publish(t, "topicA", "a")
    assert :ok = QueueBroker.publish(t, "topicB", "b")
    assert {:ok, "b"} = QueueBroker.poll(t, "topicB")
    assert {:ok, "a"} = QueueBroker.poll(t, "topicA")
  end

  test "REVOCATION — a revoked tenant cannot publish or poll" do
    t = "t-#{System.unique_integer([:positive])}"
    assert :ok = QueueBroker.publish(t, "j", "x")
    assert :ok = Workbooks.Revocation.revoke(t)
    assert {:error, :revoked} = QueueBroker.publish(t, "j", "y")
    assert {:error, :revoked} = QueueBroker.poll(t, "j")
    assert :ok = Workbooks.Revocation.unrevoke(t)
    assert {:ok, "x"} = QueueBroker.poll(t, "j")
  end
end
