defmodule AccessPostureTest do
  @moduledoc "wb-9io: access posture parsing, the anti-leak static guard, and the serving decision."
  use ExUnit.Case, async: true

  alias Workbooks.Access
  alias Workbooks.Publish.Config

  describe "parse + static_safe?" do
    test "parses the three postures (and dash/underscore forms)" do
      assert Access.parse(nil) == {:ok, :public}
      assert Access.parse("public") == {:ok, :public}
      assert Access.parse("gated-data") == {:ok, :gated_data}
      assert Access.parse("gated_route") == {:ok, :gated_route}
      assert {:error, _} = Access.parse("sortof")
    end

    test "only public is safe to bake into a public static artifact" do
      assert Access.static_safe?(:public)
      refute Access.static_safe?(:gated_data)
      refute Access.static_safe?(:gated_route)
    end
  end

  describe "enforce — routing coupled to auth" do
    @anon nil
    @user %{user_id: "u-1", tenant_id: "org-a"}
    @dev %{user_id: "dev", tenant_id: "dev"}

    test "public: anyone, anything" do
      assert Access.enforce(:public, :full, @anon) == :allow
    end

    test "gated_data: shell public, data needs a real identity" do
      assert Access.enforce(:gated_data, :shell, @anon) == :allow
      assert Access.enforce(:gated_data, :data, @anon) == {:deny, :auth_required}
      assert Access.enforce(:gated_data, :data, @user) == :allow
      # the anonymous dev fallback does NOT count as authenticated
      assert Access.enforce(:gated_data, :data, @dev) == {:deny, :auth_required}
    end

    test "gated_route: everything (even the shell) needs auth" do
      assert Access.enforce(:gated_route, :shell, @anon) == {:deny, :auth_required}
      assert Access.enforce(:gated_route, :shell, @user) == :allow
    end
  end

  describe "publish anti-leak guard" do
    test "gated workbook is REJECTED on public static hosts" do
      for target <- ~w(cloudflare-pages gh-pages) do
        assert {:error, issues} =
                 Config.validate(%{"PUBLISH_TARGET" => target, "PUBLISH_PROJECT" => "x", "PUBLISH_ACCESS" => "gated-data"})

        assert Enum.any?(issues, &(&1 =~ "cannot publish to #{target}"))
      end
    end

    test "gated workbook is ALLOWED on self-hosted (runtime gates per-request)" do
      assert :ok =
               Config.validate(%{"PUBLISH_TARGET" => "self-hosted", "PUBLISH_URL" => "https://rt", "PUBLISH_ACCESS" => "gated-route"})
    end

    test "public workbook is fine anywhere" do
      assert :ok = Config.validate(%{"PUBLISH_TARGET" => "gh-pages", "PUBLISH_PROJECT" => "o/r", "PUBLISH_ACCESS" => "public"})
      assert :ok = Config.validate(%{"PUBLISH_TARGET" => "gh-pages", "PUBLISH_PROJECT" => "o/r"})
    end

    test "bad posture string is rejected" do
      assert {:error, issues} = Config.validate(%{"PUBLISH_TARGET" => "self-hosted", "PUBLISH_URL" => "u", "PUBLISH_ACCESS" => "kinda"})
      assert Enum.any?(issues, &(&1 =~ "PUBLISH_ACCESS"))
    end
  end
end
