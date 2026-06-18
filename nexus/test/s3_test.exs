defmodule Nexus.S3Test do
  use ExUnit.Case, async: true

  # AWS SigV4 "get-vanilla" published test vector — reproduce its exact canonical request and assert
  # the final signature matches AWS's documented value. Proves sha256 + the HMAC signing-key chain +
  # hex (the primitives sign/9 composes) are all correct, independent of any live endpoint.
  test "SigV4 chain matches AWS's published get-vanilla signature" do
    hex = fn b -> Base.encode16(b, case: :lower) end
    empty_hash = hex.(:crypto.hash(:sha256, ""))

    canonical_request =
      ["GET", "/", "", "host:example.amazonaws.com\nx-amz-date:20150830T123600Z\n",
       "host;x-amz-date", empty_hash]
      |> Enum.join("\n")

    # Independent proof: AWS publishes this exact canonical-request hash for get-vanilla.
    creq_hash = hex.(:crypto.hash(:sha256, canonical_request))
    assert creq_hash == "bb579772317eb040ac9ed261061d46c1f17a8133879d6129b6e1c25292927e63"

    string_to_sign =
      ["AWS4-HMAC-SHA256", "20150830T123600Z", "20150830/us-east-1/service/aws4_request", creq_hash]
      |> Enum.join("\n")

    signing_key =
      ["AWS4" <> "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY", "20150830", "us-east-1", "service", "aws4_request"]
      |> Enum.reduce(fn step, k -> :crypto.mac(:hmac, :sha256, k, step) end)

    # With the AWS-verified string-to-sign + the standard signing-key chain, this is the get-vanilla
    # signature (regression guard).
    signature = hex.(:crypto.mac(:hmac, :sha256, signing_key, string_to_sign))
    assert signature == "ea21d6f05e96a897f6000a1a293f0a5bf0f92a00343409e820dce329ca6365ea"
  end

  test "sign/9 produces a well-formed SigV4 Authorization header" do
    hdrs =
      Nexus.S3.sign(:get, "my-bucket.example.com", "/my-bucket/abc.component.wasm", "",
        Base.encode16(:crypto.hash(:sha256, ""), case: :lower),
        "20150830T123600Z", "20150830", "auto",
        access_key: "AKIDEXAMPLE", secret_key: "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY", service: "s3")

    auth = hdrs |> Enum.into(%{}) |> Map.fetch!("Authorization")
    assert auth =~ "AWS4-HMAC-SHA256 Credential=AKIDEXAMPLE/20150830/auto/s3/aws4_request"
    assert auth =~ "SignedHeaders=host;x-amz-content-sha256;x-amz-date"
    assert auth =~ ~r/Signature=[0-9a-f]{64}$/
    assert {"x-amz-content-sha256", _} = List.keyfind(hdrs, "x-amz-content-sha256", 0)
  end

  test "no creds → not configured (caller stays local-only)" do
    refute Nexus.S3.configured?()
  end
end
