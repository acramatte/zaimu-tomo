defmodule ZaimuTomo.Datasets.ExportersTest do
  use ExUnit.Case, async: false

  alias ZaimuTomo.Datasets.Exporters
  alias ZaimuTomo.Fingerprint
  alias ZaimuTomo.Storage

  @tag :tmp_dir
  test "exports extractor_sft, verifier_sft, vlm_sft, eval slices, and uploads to S3", %{
    tmp_dir: tmp_dir
  } do
    version_dir = Path.join(tmp_dir, "v001")
    File.mkdir_p!(version_dir)
    canonical_path = Path.join(version_dir, "canonical.jsonl")

    records = [
      # Train: clean approved invoice, 2 pages
      canonical_record(1, "train",
        page_count: 2,
        ground_truth: gt(10_810, "CHF", "2026-11-01", "Swisscom", "Mobile plan"),
        run_output: gt(10_810, "CHF", "2026-11-01", "Swisscom", "Mobile plan")
      ),
      # Validation: real extraction error (1 -> 0), challenge_eval: true
      canonical_record(2, "validation",
        challenge_eval: true,
        human_thumbs: false,
        review_status: "amended",
        error_tags: ["zero_amount_schema_bug"],
        ground_truth: gt(0, "USD", "2026-10-29", "Namespace", nil),
        run_output: gt(1, "USD", "2026-10-29", "Namespace", "Amount due")
      ),
      # Test: clean approved invoice, file_matches_posted_snapshot: false -> excluded from VLM
      canonical_record(3, "test",
        file_matches: false,
        ground_truth: gt(8800, "CHF", "2026-10-06", "ZVV", "Travelcard purchase"),
        run_output: gt(8800, "CHF", "2026-10-06", "ZVV", "Travelcard purchase")
      ),
      # Train: ocr_faithful: false -> excluded from OCR SFT, kept in eval challenge
      canonical_record(4, "train",
        challenge_eval: true,
        ocr_faithful: false,
        ground_truth: gt(5000, "CHF", "2026-09-01", "Coop", "Groceries"),
        run_output: gt(5000, "CHF", "2026-09-01", "Coop", "Groceries")
      ),
      # Train: rejected -> excluded from all SFT and eval
      canonical_record(5, "train",
        review_status: "rejected",
        ground_truth: nil,
        run_output: gt(500, "USD", "2026-11-07", "Railway", "Hobby plan")
      ),
      # Test: challenge_eval: true -> included in eval/challenge.jsonl (only test split goes there)
      canonical_record(6, "test",
        challenge_eval: true,
        human_thumbs: false,
        review_status: "amended",
        error_tags: ["reason_hallucinated"],
        ground_truth: gt(35_613, "CHF", "2026-08-03", "Galaxus", nil),
        run_output: gt(35_613, "CHF", "2026-08-03", "Galaxus", "Order delivery")
      ),
      # Train: amended without 👍/👎 -> amended_unclassified, excluded from all SFT & eval
      canonical_record(7, "train",
        review_status: "amended",
        quality: "amended_unclassified",
        human_thumbs: nil,
        ground_truth: nil,
        run_output: gt(4200, "CHF", "2026-08-10", "Migros", "Groceries")
      )
    ]

    canonical_raw = Enum.map_join(records, "\n", &Jason.encode!/1) <> "\n"
    File.write!(canonical_path, canonical_raw)

    assert {:ok, summary} =
             Exporters.export(
               input: canonical_path,
               upload_s3: true,
               version: "v001",
               synthetic_negatives: 2,
               seed: "export-seed"
             )

    assert summary.canonical_count == 7
    assert summary.s3_prefix == "datasets/v001/exports"
    out = summary.output_dir

    # Extractor SFT: doc1 in train, doc2 in val, doc3 + doc6 in test
    # (doc4 ocr_faithful=false, doc5 rejected, doc7 amended_unclassified)
    assert summary.counts["extractor_sft/train.jsonl"] == 1
    assert summary.counts["extractor_sft/validation.jsonl"] == 1
    assert summary.counts["extractor_sft/test.jsonl"] == 2

    [ext_train] = read_jsonl(Path.join(out, "extractor_sft/train.jsonl"))
    assert ext_train["meta"]["document_id"] == 1
    assert Enum.at(ext_train["messages"], 1)["content"] =~ "Currency hint: CHF"

    assert Jason.decode!(Enum.at(ext_train["messages"], 2)["content"])["amount_to_pay_cents"] ==
             10_810

    # Verifier SFT:
    # - train (doc1): 1 positive + 2 synthetic = 3 (doc7 excluded)
    # - validation (doc2): 1 positive + 1 real negative + 2 synthetic = 4
    # - test (doc3 + doc6): 2 positives + 1 real negative (doc6) + 0 synthetic = 3
    assert summary.counts["verifier_sft/train.jsonl"] == 3
    assert summary.counts["verifier_sft/validation.jsonl"] == 4
    assert summary.counts["verifier_sft/test.jsonl"] == 3

    verif_val = read_jsonl(Path.join(out, "verifier_sft/validation.jsonl"))

    assert Enum.all?(
             verif_val,
             &(&1["meta"]["document_id"] == 2 and &1["meta"]["split"] == "validation")
           )

    real_neg = Enum.find(verif_val, &(&1["meta"]["example_type"] == "real_negative"))
    assert real_neg != nil
    neg_out = Jason.decode!(Enum.at(real_neg["messages"], 2)["content"])
    assert neg_out["status"] == "rejected"
    assert neg_out["field_issues"] == "amount_to_pay_cents,reason_for_payment"

    # VLM SFT: doc1 + doc4 (train), doc2 (val), doc6 (test); doc3 excluded (file mismatch), doc5/doc7 excluded
    assert summary.counts["vlm_sft/train.jsonl"] == 2
    assert summary.counts["vlm_sft/validation.jsonl"] == 1
    assert summary.counts["vlm_sft/test.jsonl"] == 1

    [vlm_doc1 | _] = read_jsonl(Path.join(out, "vlm_sft/train.jsonl"))
    user_parts = Enum.at(vlm_doc1["messages"], 1)["content"]
    image_parts = Enum.filter(user_parts, &(&1["type"] == "image"))
    assert Enum.map(image_parts, & &1["image"]) == ["images/doc_1_p0.png", "images/doc_1_p1.png"]

    # Eval sets: representative = test split (doc3, doc6);
    # challenge = ONLY test-split challenge records (doc6), never train/val (doc2, doc4)
    assert summary.counts["eval/representative.jsonl"] == 2
    assert summary.counts["eval/challenge.jsonl"] == 1

    eval_rep = read_jsonl(Path.join(out, "eval/representative.jsonl"))
    assert Enum.map(eval_rep, & &1["document_id"]) == [3, 6]
    doc3_eval = Enum.find(eval_rep, &(&1["document_id"] == 3))
    assert doc3_eval["expected_verdict"] == "verified"

    [doc6_eval] = read_jsonl(Path.join(out, "eval/challenge.jsonl"))
    assert doc6_eval["document_id"] == 6
    assert doc6_eval["split"] == "test"
    assert doc6_eval["expected_verdict"] == "rejected"
    assert doc6_eval["expected_field_issues"] == ["reason_for_payment"]

    # Manifest checksum (including input_sha256) + S3 upload parity
    manifest = File.read!(Path.join(out, "export_manifest.json")) |> Jason.decode!()
    assert manifest["input_sha256"] == Fingerprint.sha256(canonical_raw)
    rep_raw = File.read!(Path.join(out, "eval/representative.jsonl"))
    assert manifest["sha256"]["eval/representative.jsonl"] == Fingerprint.sha256(rep_raw)

    assert {:ok, ^rep_raw} =
             Storage.read_object("datasets/v001/exports/eval/representative.jsonl")

    assert :ok = Storage.head_object("datasets/v001/exports/export_manifest.json")

    assert Exporters.format_summary(summary) =~ "Exports built from 7 canonical records"

    # S3 -> S3 export with output_dir: nil (production release flow)
    assert {:ok, _} = Storage.put_object("datasets/v002/canonical.jsonl", canonical_raw)

    assert {:ok, s3_summary} =
             Exporters.export(
               from_s3: true,
               version: "v002",
               output_dir: nil,
               upload_s3: true
             )

    assert s3_summary.output_dir == nil
    assert s3_summary.s3_prefix == "datasets/v002/exports"
    assert s3_summary.counts["eval/challenge.jsonl"] == 1
    assert :ok = Storage.head_object("datasets/v002/exports/export_manifest.json")
  end

  @tag :tmp_dir
  test "validates input path, version format, and explicit version for S3", %{tmp_dir: tmp_dir} do
    path = Path.join(tmp_dir, "canonical.jsonl")
    File.write!(path, "")

    assert {:error, :missing_input} = Exporters.export([])

    assert {:error, {:canonical_read_failed, _, :enoent}} =
             Exporters.export(input: "/no/such/file.jsonl")

    assert {:error, :missing_version} = Exporters.export(input: path, upload_s3: true)
    assert {:error, :missing_version} = Exporters.export(from_s3: true, upload_s3: true)

    assert {:error, {:invalid_version, "."}} =
             Exporters.export(input: path, upload_s3: true, version: ".")

    assert {:error, {:invalid_version, ".."}} =
             Exporters.export(input: path, upload_s3: true, version: "..")
  end

  defp read_jsonl(path) do
    path
    |> File.read!()
    |> String.split("\n", trim: true)
    |> Enum.map(&Jason.decode!/1)
  end

  defp gt(cents, currency, date, issuer, reason) do
    %{
      "amount_to_pay_cents" => cents,
      "currency" => currency,
      "invoice_date" => date,
      "invoice_number" => "INV-1",
      "issuer" => issuer,
      "reason_for_payment" => reason
    }
  end

  defp canonical_record(doc_id, split, opts) do
    review_status = Keyword.get(opts, :review_status, "approved")
    gt_val = Keyword.get(opts, :ground_truth)
    run_output = Keyword.get(opts, :run_output)

    %{
      "dataset_schema_version" => 1,
      "document_type" => "invoice",
      "document_id" => doc_id,
      "document" => %{
        "filename" => "doc_#{doc_id}.pdf",
        "mime_type" => "application/pdf",
        "s3_key" => "documents/doc_#{doc_id}.pdf",
        "s3_exists" => Keyword.get(opts, :s3_exists, true),
        "content_sha256" => Fingerprint.sha256("bytes-#{doc_id}"),
        "file_matches_posted_snapshot" => Keyword.get(opts, :file_matches, true),
        "page_count" => Keyword.get(opts, :page_count, 1)
      },
      "inputs" => %{
        "currency_hint" => "CHF",
        "ocr" => %{
          "provider" => "mistral",
          "model" => "mistral-ocr-latest",
          "markdown" => "Invoice markdown for document #{doc_id}",
          "pages" => [%{"index" => 0, "markdown" => "Invoice markdown for document #{doc_id}"}]
        }
      },
      "ground_truth" => %{
        "extracted_faithful" => gt_val,
        "booked_values" => gt_val,
        "field_diff" => []
      },
      "label" => %{
        "quality" =>
          Keyword.get(
            opts,
            :quality,
            if(review_status == "rejected", do: "rejected", else: "gold_reviewed")
          ),
        "review_status" => review_status,
        "reviewed_at" => "2026-11-20T18:00:00Z",
        "human_thumbs" => Keyword.get(opts, :human_thumbs, true),
        "ocr_faithful" => Keyword.get(opts, :ocr_faithful, true),
        "error_tags" => Keyword.get(opts, :error_tags, [])
      },
      "processing_runs" => [
        %{
          "extracted_content_id" => doc_id * 10,
          "status" => "success",
          "trace_id" => "trace-#{doc_id}",
          "extraction" => %{"output" => run_output},
          "verification" => %{"status" => "verified", "field_issues" => []},
          "typesafe_shadow" => %{"status" => "verified", "max_error_probability" => 0.2}
        }
      ],
      "grouping" => %{
        "issuer_norm" => "issuer-#{doc_id}",
        "split" => split,
        "challenge_eval" => Keyword.get(opts, :challenge_eval, false)
      }
    }
  end
end
