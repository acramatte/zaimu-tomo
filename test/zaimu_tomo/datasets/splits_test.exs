defmodule ZaimuTomo.Datasets.SplitsTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias ZaimuTomo.Datasets.Splits

  describe "normalize_issuer/1" do
    test "trims, lowercases, and collapses whitespace" do
      assert Splits.normalize_issuer("  Digitec   Galaxus  AG \n") == "digitec galaxus ag"
      assert Splits.normalize_issuer("   ") == nil
      assert Splits.normalize_issuer(nil) == nil
    end
  end

  describe "assign/2" do
    test "keeps documents sharing a normalized issuer or content_sha256 in the same split" do
      records = [
        record(1, "digitec galaxus ag", "sha-a"),
        record(2, "digitec galaxus ag", "sha-b"),
        # Different issuer string, but same SHA as doc 2 — transitively linked to docs 1 & 2.
        record(3, "galaxus", "sha-b"),
        record(4, "swisscom", "sha-c"),
        record(5, "coop", "sha-d"),
        record(6, "migros", "sha-e"),
        record(7, "sbb", "sha-f"),
        record(8, "ewz", "sha-g")
      ]

      {assigned, artifact} = Splits.assign(records, seed: "test-seed", version: "v001")

      splits_by_id = Map.new(assigned, &{&1["document_id"], get_in(&1, ["grouping", "split"])})
      assert splits_by_id[1] == splits_by_id[2]
      assert splits_by_id[2] == splits_by_id[3]

      assert artifact["version"] == "v001"
      assert artifact["group_count"] == 6
      assert Enum.sum(Map.values(artifact["split_counts"])) == 8

      # Deterministic across repeated calls with the same seed.
      {assigned_again, artifact_again} =
        Splits.assign(records, seed: "test-seed", version: "v001")

      assert assigned_again == assigned
      assert artifact_again == artifact

      # Adding new invoices for new issuers in v002 never moves existing groups across splits.
      extended =
        records ++
          [
            record(9, "new-issuer-1", "sha-h"),
            record(10, "new-issuer-2", "sha-i"),
            record(11, "new-issuer-3", "sha-j")
          ]

      {assigned_v2, _} = Splits.assign(extended, seed: "test-seed", version: "v002")

      splits_v2 = Map.new(assigned_v2, &{&1["document_id"], get_in(&1, ["grouping", "split"])})

      for id <- 1..8 do
        assert splits_v2[id] == splits_by_id[id]
      end
    end

    property "never splits documents sharing an issuer or file digest across train/val/test" do
      check all(
              specs <-
                StreamData.list_of(
                  {StreamData.member_of(["alpha", "beta", "gamma", "delta", "epsilon", nil]),
                   StreamData.member_of(["sha1", "sha2", "sha3", "sha4", "sha5", nil])},
                  min_length: 1,
                  max_length: 25
                )
            ) do
        records =
          specs
          |> Enum.with_index(1)
          |> Enum.map(fn {{issuer, sha}, id} -> record(id, issuer, sha) end)

        {assigned, artifact} = Splits.assign(records, seed: "prop-seed", version: "v1")

        assert length(assigned) == length(records)
        assert Enum.sum(Map.values(artifact["split_counts"])) == length(records)

        for issuer <- ["alpha", "beta", "gamma", "delta", "epsilon"] do
          splits =
            assigned
            |> Enum.filter(&(get_in(&1, ["grouping", "issuer_norm"]) == issuer))
            |> Enum.map(&get_in(&1, ["grouping", "split"]))
            |> Enum.uniq()

          assert length(splits) <= 1
        end

        for sha <- ["sha1", "sha2", "sha3", "sha4", "sha5"] do
          splits =
            assigned
            |> Enum.filter(&(get_in(&1, ["document", "content_sha256"]) == sha))
            |> Enum.map(&get_in(&1, ["grouping", "split"]))
            |> Enum.uniq()

          assert length(splits) <= 1
        end
      end
    end
  end

  describe "challenge_eval?/1" do
    test "flags amended, thumbs-down, verifier-flagged, Jev-flagged, and tagged records" do
      clean = record(1, "swisscom", "sha-1")
      refute Splits.challenge_eval?(clean)

      assert Splits.challenge_eval?(put_in(clean, ["label", "review_status"], "amended"))
      assert Splits.challenge_eval?(put_in(clean, ["label", "human_thumbs"], false))
      assert Splits.challenge_eval?(put_in(clean, ["label", "ocr_faithful"], false))
      assert Splits.challenge_eval?(put_in(clean, ["label", "error_tags"], ["subtotal_vs_total"]))

      flagged_verifier =
        put_in(clean, ["processing_runs"], [
          %{"verification" => %{"status" => "needs_review"}, "typesafe_shadow" => nil}
        ])

      assert Splits.challenge_eval?(flagged_verifier)

      flagged_jev =
        put_in(clean, ["processing_runs"], [
          %{
            "verification" => %{"status" => "verified"},
            "typesafe_shadow" => %{"status" => "needs_review"}
          }
        ])

      assert Splits.challenge_eval?(flagged_jev)
    end
  end

  defp record(id, issuer_norm, sha) do
    %{
      "document_id" => id,
      "document" => %{"content_sha256" => sha},
      "label" => %{
        "review_status" => "approved",
        "human_thumbs" => true,
        "ocr_faithful" => nil,
        "error_tags" => []
      },
      "processing_runs" => [
        %{
          "verification" => %{"status" => "verified"},
          "typesafe_shadow" => %{"status" => "verified"}
        }
      ],
      "grouping" => %{"issuer_norm" => issuer_norm, "split" => nil, "challenge_eval" => false}
    }
  end
end
