defmodule Nexus.GitHub do
  @moduledoc """
  GitHub **App** integration — the seam the nexus uses to act on a customer's repos: mint short-lived
  **installation tokens**, push agent branches, open **pull requests**, and sync **issues**; a webhook
  endpoint feeds repo events (`pull_request`, `push`) onto the reactive bus so a reviewer/merger agent
  hook + the fetch-back can react.

  **Generic mechanism, no-op-safe.** With no GitHub App configured (`configured?/0` false) every call
  returns `{:skip, reason}` — like `Nexus.JJ`, the feature is simply dark until secrets land. THE LINE:
  this is neutral GitHub plumbing any operator can supply their own App for; OUR workflow *policy*
  (who reviews, which branch, what validates) lives in the cloud product + `.work` config, not here.

  Secrets (via `Nexus.Secrets`, injected at deploy — never in source/`.work`):
    * `GITHUB_APP_ID` · `GITHUB_APP_PRIVATE_KEY` (PEM) — the App identity, used to sign the App JWT.
    * `GITHUB_APP_CLIENT_ID` · `GITHUB_APP_CLIENT_SECRET` — the user-authorization (sign-in) flow.
    * `GITHUB_WEBHOOK_SECRET` — HMAC verification of inbound webhooks.

  Auth flow to act on a repo: sign an App JWT (RS256) → resolve the installation id for the owner →
  exchange for a 1-hour installation token → use it for git push + REST calls on the installed repos.
  """
  require Logger

  @api "https://api.github.com"

  @doc "Is a GitHub App configured (App id + private key present)? Gates every repo action."
  def configured? do
    Nexus.Secrets.has?("GITHUB_APP_ID") and Nexus.Secrets.has?("GITHUB_APP_PRIVATE_KEY")
  end

  @doc """
  Sign the short-lived App JWT (RS256, iss = App id, ~9-min exp) used to call the App-level API. JOSE
  signs with the App private key. `{:ok, jwt} | {:skip, reason} | {:error, reason}`.
  """
  def app_jwt do
    with true <- configured?(),
         id when is_binary(id) <- Nexus.Secrets.get("GITHUB_APP_ID"),
         pem when is_binary(pem) <- Nexus.Secrets.get("GITHUB_APP_PRIVATE_KEY") do
      now = System.os_time(:second)
      jwk = JOSE.JWK.from_pem(pem)
      claims = %{"iat" => now - 60, "exp" => now + 540, "iss" => to_string(id)}
      {_, jwt} = JOSE.JWT.sign(jwk, %{"alg" => "RS256"}, claims) |> JOSE.JWS.compact()
      {:ok, jwt}
    else
      false -> {:skip, "github app not configured"}
      _ -> {:error, :bad_app_credentials}
    end
  rescue
    e -> {:error, Exception.message(e)}
  end

  @doc """
  Mint a 1-hour **installation token** for `owner` (the org/user the App is installed on). Resolves the
  installation id, then exchanges the App JWT for a scoped token. `{:ok, token} | {:skip,_} | {:error,_}`.
  """
  def installation_token(owner) do
    with {:ok, jwt} <- app_jwt(),
         {:ok, %{"id" => inst}} <- api_get("/orgs/#{owner}/installation", jwt),
         {:ok, %{"token" => token}} <-
           api(:post, "/app/installations/#{inst}/access_tokens", jwt, %{}) do
      {:ok, token}
    else
      {:skip, r} -> {:skip, r}
      other -> {:error, other}
    end
  end

  @doc """
  Open a pull request `head` → `base` on `owner/repo`. `token` is an installation token. Returns
  `{:ok, %{number, html_url}} | {:error, _}`. The PR body should link the nexus issue/task.
  """
  def open_pr(token, owner, repo, head, base, title, body) do
    case api(:post, "/repos/#{owner}/#{repo}/pulls", token,
           %{title: title, head: head, base: base, body: body}) do
      {:ok, %{"number" => n, "html_url" => url}} -> {:ok, %{number: n, html_url: url}}
      other -> {:error, other}
    end
  end

  @doc "Create a GitHub Issue (the opt-in 'promote a task to GitHub'). `{:ok, %{number, html_url}} | {:error,_}`."
  def create_issue(token, owner, repo, title, body, labels \\ []) do
    case api(:post, "/repos/#{owner}/#{repo}/issues", token, %{title: title, body: body, labels: labels}) do
      {:ok, %{"number" => n, "html_url" => url}} -> {:ok, %{number: n, html_url: url}}
      other -> {:error, other}
    end
  end

  @doc "Update an existing GitHub Issue (e.g. close it when the nexus task resolves)."
  def update_issue(token, owner, repo, number, fields) when is_map(fields) do
    api(:patch, "/repos/#{owner}/#{repo}/issues/#{number}", token, fields)
  end

  @doc """
  Verify an inbound webhook's `X-Hub-Signature-256` against the raw body using `GITHUB_WEBHOOK_SECRET`.
  Constant-time compare. Returns `true | false` (false also when no secret is configured — fail closed).
  """
  def verify_webhook(raw_body, signature_header) when is_binary(raw_body) do
    with secret when is_binary(secret) <- Nexus.Secrets.get("GITHUB_WEBHOOK_SECRET"),
         "sha256=" <> hex <- to_string(signature_header) do
      expected = :crypto.mac(:hmac, :sha256, secret, raw_body) |> Base.encode16(case: :lower)
      Plug.Crypto.secure_compare(expected, hex)
    else
      _ -> false
    end
  end

  # ── HTTP (httpc, like Nexus.Llm — no extra dep) ────────────────────────────────────────────────
  defp api_get(path, bearer), do: api(:get, path, bearer, nil)

  defp api(method, path, bearer, body) do
    url = String.to_charlist(@api <> path)
    headers = [
      {~c"authorization", String.to_charlist("Bearer #{bearer}")},
      {~c"accept", ~c"application/vnd.github+json"},
      {~c"user-agent", ~c"workbooks-nexus"},
      {~c"x-github-api-version", ~c"2022-11-28"}
    ]

    request =
      case method do
        :get -> {url, headers}
        _ -> {url, headers, ~c"application/json", Jason.encode!(body || %{})}
      end

    case :httpc.request(method, request, [{:timeout, 15_000}], body_format: :binary) do
      {:ok, {{_, status, _}, _h, resp}} when status in 200..299 ->
        {:ok, (resp == "" && %{}) || Jason.decode!(resp)}

      {:ok, {{_, status, _}, _h, resp}} ->
        {:error, {:http, status, resp}}

      {:error, reason} ->
        {:error, reason}
    end
  end
end
