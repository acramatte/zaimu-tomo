defmodule ZaimuTomo.FingerprintTest do
  use ExUnit.Case, async: true

  alias ZaimuTomo.Fingerprint

  doctest ZaimuTomo.Fingerprint

  # Published SHA-256 test vector (FIPS 180-2) and its one-byte neighbour.
  @abc_sha256 "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
  @abd_sha256 "a52d159f262b2c6ddb724a61840befc36eb30c88877a4030b65cbe86298449c9"

  test "sha256/1 encodes the exact bytes as 64 lowercase hex characters" do
    assert Fingerprint.sha256("abc") == @abc_sha256
    assert Fingerprint.sha256(["a", ["b"], "c"]) == @abc_sha256
    assert Fingerprint.sha256("abd") == @abd_sha256
    assert Fingerprint.sha256(<<0xFF, 0x00>>) =~ Fingerprint.format()
  end
end
