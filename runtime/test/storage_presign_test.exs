defmodule Workbooks.StoragePresignTest do
  @moduledoc """
  SigV4 query-string presigned URLs (`Workbooks.Storage.S3.presign_*`). Signing is
  made DETERMINISTIC by injecting a fixed `:config` + `:now`, so we assert the exact
  canonical signature with NO live network. Credentials/date below are throwaway
  test values (the standard AWS example access key), never real secrets.
  """
  use ExUnit.Case, async: true
  alias Workbooks.Storage.S3

  @cfg %{
    endpoint: "https://acct.r2.cloudflarestorage.com",
    bucket: "blobs",
    key: "AKIAIOSFODNN7EXAMPLE",
    secret: "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY",
    region: "auto"
  }
  @now {"20260614T000000Z", "20260614"}

  defp put(key, opts \\ []), do: S3.presign_put("tenantA", key, Keyword.merge([config: @cfg, now: @now], opts))
  defp get(key, opts \\ []), do: S3.presign_get("tenantA", key, Keyword.merge([config: @cfg, now: @now], opts))

  test "presigned PUT URL carries every required X-Amz-* query param + a signature" do
    {:ok, url} = put("docs/report.pdf", expires_in: 900)

    for p <- ~w(X-Amz-Algorithm=AWS4-HMAC-SHA256 X-Amz-Credential= X-Amz-Date=20260614T000000Z
                X-Amz-Expires=900 X-Amz-SignedHeaders=host X-Amz-Signature=) do
      assert String.contains?(url, p), "missing #{p} in #{url}"
    end
  end

  test "the URL NEVER contains the secret key" do
    {:ok, url} = put("docs/report.pdf")
    refute String.contains?(url, @cfg.secret)
    refute String.contains?(url, "bPxRfiCY")
  end

  test "the object path encodes the <tenant>/blobs/ prefix" do
    {:ok, url} = put("docs/report.pdf")
    assert String.contains?(url, "/blobs/tenantA/blobs/docs/report.pdf")
  end

  test "a ../-style key CANNOT escape the tenant/blobs prefix" do
    {:ok, url} = get("../../etc/passwd")
    # The `..` segments are stripped — the object lands under tenantA/blobs.
    assert String.contains?(url, "/blobs/tenantA/blobs/etc/passwd")
    refute String.contains?(url, "..")
  end

  test "DETERMINISTIC canonical signature — PUT" do
    {:ok, url} = put("docs/report.pdf", expires_in: 900)

    assert url ==
             "https://acct.r2.cloudflarestorage.com/blobs/tenantA/blobs/docs/report.pdf?" <>
               "X-Amz-Algorithm=AWS4-HMAC-SHA256&" <>
               "X-Amz-Credential=AKIAIOSFODNN7EXAMPLE%2F20260614%2Fauto%2Fs3%2Faws4_request&" <>
               "X-Amz-Date=20260614T000000Z&X-Amz-Expires=900&X-Amz-SignedHeaders=host&" <>
               "X-Amz-Signature=0d4401f67e55088b9b8d8fefba4aa27445d78efe9e70bce775606603edf6db85"
  end

  test "DETERMINISTIC canonical signature — GET with a path-escape key (scoped)" do
    {:ok, url} = get("../../etc/passwd", expires_in: 900)

    assert url ==
             "https://acct.r2.cloudflarestorage.com/blobs/tenantA/blobs/etc/passwd?" <>
               "X-Amz-Algorithm=AWS4-HMAC-SHA256&" <>
               "X-Amz-Credential=AKIAIOSFODNN7EXAMPLE%2F20260614%2Fauto%2Fs3%2Faws4_request&" <>
               "X-Amz-Date=20260614T000000Z&X-Amz-Expires=900&X-Amz-SignedHeaders=host&" <>
               "X-Amz-Signature=db7840a1cf4095fb634b4c7e5e20f721dea03145ef897c8f7b9a565b4e493d13"
  end

  test "expiry is honored and clamped" do
    {:ok, url} = put("k", expires_in: 60)
    assert String.contains?(url, "X-Amz-Expires=60")

    # Over the 7-day max is clamped down.
    {:ok, clamped} = put("k", expires_in: 999_999_999)
    assert String.contains?(clamped, "X-Amz-Expires=604800")

    # Bad/zero expiry falls back to the default.
    {:ok, defaulted} = put("k", expires_in: 0)
    assert String.contains?(defaulted, "X-Amz-Expires=900")
  end

  test "missing endpoint or credentials fails cleanly (no URL emitted)" do
    assert {:error, :no_endpoint} = S3.presign_put("t", "k", config: %{@cfg | endpoint: ""}, now: @now)
    assert {:error, :no_credentials} = S3.presign_put("t", "k", config: %{@cfg | key: ""}, now: @now)
    assert {:error, :no_credentials} = S3.presign_put("t", "k", config: %{@cfg | secret: ""}, now: @now)
  end

  # ── ADVERSARIAL REGRESSIONS (fail against pre-fix logic) ──────────────────────

  test "BLOCKER-1: a ../-style TENANT cannot escape into another tenant's prefix (presign)" do
    # Pre-fix: tenant flowed raw into "#{tenant}/blobs/..", so "../victim" yielded
    # "../victim/blobs/.." which R2 normalizes to the victim's prefix WITH a valid
    # signature. Now the tenant must be a single opaque segment.
    assert {:error, :invalid_tenant} = S3.presign_put("../victim", "k", config: @cfg, now: @now)
    assert {:error, :invalid_tenant} = S3.presign_get("../victim", "k", config: @cfg, now: @now)
    assert {:error, :invalid_tenant} = S3.presign_put("a/b", "k", config: @cfg, now: @now)
    assert {:error, :invalid_tenant} = S3.presign_put("", "k", config: @cfg, now: @now)
    assert {:error, :invalid_tenant} = S3.presign_put("   ", "k", config: @cfg, now: @now)
    # A normal tenant still works.
    assert {:ok, _} = S3.presign_put("tenantA", "k", config: @cfg, now: @now)
  end

  test "BLOCKER-1: facade rejects a path-traversal tenant on every op" do
    for op <- [
          fn -> Workbooks.Storage.put("../victim", "k", "x") end,
          fn -> Workbooks.Storage.get("../victim", "k") end,
          fn -> Workbooks.Storage.delete("../victim", "k") end,
          fn -> Workbooks.Storage.presign("../victim", "k", :put, content_length: 1) end,
          fn -> Workbooks.Storage.presign("../victim", "k", :get) end
        ] do
      res = op.()
      assert res in [{:error, :invalid_tenant}, :error], "expected rejection, got #{inspect(res)}"
    end
  end

  test "BLOCKER-5: presign with an empty/dot-only key returns a clean error (no crash)" do
    # Pre-fix: Path.join([]) raised FunctionClauseError for these keys.
    assert {:error, :empty_key} = S3.presign_put("tenantA", "", config: @cfg, now: @now)
    assert {:error, :empty_key} = S3.presign_put("tenantA", "..", config: @cfg, now: @now)
    assert {:error, :empty_key} = S3.presign_get("tenantA", ".", config: @cfg, now: @now)
    assert {:error, :empty_key} = S3.presign_put("tenantA", "/", config: @cfg, now: @now)
  end

  test "BLOCKER-2: metered PUT SIGNS the Content-Length header" do
    # With a content_length the signed-headers list includes content-length so R2
    # rejects an upload of a different size.
    {:ok, url} = S3.presign_put("tenantA", "k", config: @cfg, now: @now, content_length: 42)
    assert String.contains?(url, "X-Amz-SignedHeaders=content-length%3Bhost")
    # Without it, only host is signed (the facade is what refuses an unmetered PUT).
    {:ok, plain} = S3.presign_put("tenantA", "k", config: @cfg, now: @now)
    assert String.contains?(plain, "X-Amz-SignedHeaders=host")
    refute String.contains?(plain, "content-length")
  end

  defp sig(url), do: url |> String.split("X-Amz-Signature=") |> List.last()

  test "BLOCKER-6: a custom-port endpoint keeps the port in the signed host" do
    # Pre-fix: URI.parse(endpoint).host dropped :9000, so the canonical host signed
    # for localhost:9000 was identical to portless localhost -> same signature ->
    # SignatureDoesNotMatch on MinIO. Post-fix the port IS in the signed host, so the
    # two endpoints produce DIFFERENT signatures.
    {:ok, ported} = S3.presign_put("tenantA", "k", config: %{@cfg | endpoint: "http://localhost:9000"}, now: @now)
    {:ok, portless} = S3.presign_put("tenantA", "k", config: %{@cfg | endpoint: "http://localhost"}, now: @now)
    assert sig(ported) != sig(portless), "port must change the signed host -> the signature"
    assert String.starts_with?(ported, "http://localhost:9000/blobs/tenantA/blobs/k?")

    # Default ports (80/443) are NOT appended (host stays bare).
    {:ok, https443} = S3.presign_put("tenantA", "k", config: %{@cfg | endpoint: "https://h.example.com:443"}, now: @now)
    {:ok, https} = S3.presign_put("tenantA", "k", config: %{@cfg | endpoint: "https://h.example.com"}, now: @now)
    assert sig(https443) == sig(https)
  end

  test "facade delegates to S3 for s3/r2 backend and refuses on Local" do
    prev = System.get_env("WB_STORAGE")
    on_exit(fn -> if prev, do: System.put_env("WB_STORAGE", prev), else: System.delete_env("WB_STORAGE") end)

    # Local adapter -> unsupported (local dev uploads via put/3).
    System.put_env("WB_STORAGE", "local")
    assert {:error, :unsupported} = Workbooks.Storage.presign("t", "k", :put)
    assert {:error, :unsupported} = Workbooks.Storage.presign("t", "k", :get)

    # S3/R2 adapter -> delegates (config injected so no network). A metered PUT
    # requires a declared content_length; the facade reserves it before signing, so
    # we isolate the ledger to avoid touching the shared quota db.
    System.put_env("WB_STORAGE", "r2")
    :ok = Workbooks.Storage.Usage.Server.reset_for_test!(Path.join(System.tmp_dir!(), "usage_presign_#{System.unique_integer([:positive])}.db"))
    assert {:ok, url} = Workbooks.Storage.presign("tenantA", "f.bin", :put, config: @cfg, now: @now, content_length: 10)
    assert String.contains?(url, "X-Amz-Signature=")
    assert String.contains?(url, "/blobs/tenantA/blobs/f.bin")
    # The download path (GET) is unaffected by the quota.
    assert {:ok, gurl} = Workbooks.Storage.presign("tenantA", "f.bin", :get, config: @cfg, now: @now)
    assert String.contains?(gurl, "X-Amz-Signature=")
  end
end
