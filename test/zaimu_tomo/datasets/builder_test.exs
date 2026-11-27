defmodule ZaimuTomo.Datasets.BuilderTest do
  use ZaimuTomo.DataCase, async: false

  alias ZaimuTomo.Datasets.Builder
  alias ZaimuTomo.Datasets.Record
  alias ZaimuTomo.DocumentProcessing.ExtractedContent.ExtractedContent
  alias ZaimuTomo.DocumentProcessing.ExtractedData
  alias ZaimuTomo.Documents.Document
  alias ZaimuTomo.Fingerprint
  alias ZaimuTomo.Repo
  alias ZaimuTomo.Review
  alias ZaimuTomo.Review.ReviewDecision
  alias ZaimuTomo.Storage

  import ZaimuTomo.AccountsFixtures, only: [user_fixture: 0, user_scope_fixture: 1]
  import ZaimuTomo.DocumentsFixtures, only: [document_fixture: 2]
  import ZaimuTomo.ReviewFixtures, only: [extracted_content_fixture: 3]

  setup do
    original_langfuse = Application.get_env(:zaimu_tomo, :langfuse)
    Application.put_env(:zaimu_tomo, :langfuse, enabled: false)

    on_exit(fn ->
      if original_langfuse do
        Application.put_env(:zaimu_tomo, :langfuse, original_langfuse)
      else
        Application.delete_env(:zaimu_tomo, :langfuse)
      end
    end)

    :ok
  end

  @tag :tmp_dir
  test "builds canonical.jsonl, splits.json, and manifest.json from Postgres, Storage, Langfuse, and overlay",
       %{tmp_dir: tmp_dir} do
    user = user_fixture()
    scope = user_scope_fixture(user)

    # 1. Clean approved invoice with S3 object, matching fingerprint, verifier + Jev shadow
    sha1 = Fingerprint.sha256("pdf-bytes-1")
    {:ok, _} = Storage.put_object("documents/doc1.pdf", "pdf-bytes-1")

    doc1 =
      document_fixture(scope, %{
        filename: "swisscom.pdf",
        object_key: "documents/doc1.pdf",
        content_sha256: sha1
      })

    ec1 =
      extracted_content_fixture(doc1, user, %{
        trace_id: "trace-approved",
        raw_llm_response: %{
          "model" => "mistral-ocr-2505",
          "pages" => [%{"markdown" => "Swisscom CHF 108.10"}]
        },
        extracted_data: invoice_data(10_810, "CHF", "Swisscom", "INV-1", "Mobile plan"),
        analysis: %{
          "extraction" => %{
            "currency_hint" => "CHF",
            "ocr_model" => "mistral-ocr-2505",
            "extractor_model" => "ibm-granite/granite-4.2-8b",
            "extractor_backend" => "nousresearch",
            "prompt_version" => 2,
            "source_content_sha256" => sha1
          },
          "verification" => %{
            "reason" => "All fields match.",
            "verifier_model" => "qwen/qwen3.6-35b-a3b",
            "prompt_version" => 2,
            "typesafe_shadow" => %{
              "status" => "verified",
              "model" => "jev-1.14.0",
              "review_threshold" => 0.7,
              "max_error_probability" => 0.12,
              "field_probabilities" => %{"amount_to_pay_cents" => 0.05}
            }
          }
        }
      })

    {:ok, _} = Review.create_initial_decision(ec1)
    {:ok, _} = Review.approve_invoice(ec1.id, user.id)

    # 2. Amended invoice with explicit extraction_feedback: true (personal bookkeeping edit)
    sha2 = Fingerprint.sha256("pdf-bytes-2")
    {:ok, _} = Storage.put_object("documents/doc2.pdf", "pdf-bytes-2")

    doc2 =
      document_fixture(scope, %{
        filename: "zvv.pdf",
        object_key: "documents/doc2.pdf",
        content_sha256: sha2
      })

    ec2 =
      extracted_content_fixture(doc2, user, %{
        trace_id: "trace-personal",
        raw_llm_response: %{"pages" => [%{"markdown" => "ZVV Travelcard CHF 88.00"}]},
        extracted_data: invoice_data(8800, "CHF", "ZVV", "INV-2", "Travelcard purchase")
      })

    {:ok, _} = Review.create_initial_decision(ec2)

    {:ok, _} =
      Review.amend_invoice(
        ec2.id,
        user.id,
        invoice_data(8800, "CHF", "ZVV", "INV-2", "Monthly transit pass"),
        nil,
        extraction_feedback: true
      )

    # 3. Amended invoice with extraction_feedback: false (real extraction error) + file replaced after posting
    sha3_old = Fingerprint.sha256("pdf-bytes-3-old")
    sha3_new = Fingerprint.sha256("pdf-bytes-3-new")
    # Intentionally do NOT put doc3's object in Storage so storage_missing_count == 1.
    doc3 =
      document_fixture(scope, %{
        filename: "namespace.pdf",
        object_key: "documents/doc3-missing.pdf",
        content_sha256: sha3_old
      })

    ec3 =
      extracted_content_fixture(doc3, user, %{
        trace_id: "trace-error",
        raw_llm_response: %{"pages" => [%{"markdown" => "Total amount due: $0.00 USD"}]},
        extracted_data: invoice_data(1, "USD", "Namespace", "INV-3", "Amount due")
      })

    {:ok, _} = Review.create_initial_decision(ec3)

    {:ok, _} =
      Review.amend_invoice(
        ec3.id,
        user.id,
        invoice_data(0, "USD", "Namespace", "INV-3", nil),
        nil,
        extraction_feedback: false
      )

    # Simulate replacing the file via /documents/:id/edit after posting.
    Repo.update_all(from(d in Document, where: d.id == ^doc3.id), set: [content_sha256: sha3_new])

    # 4. Legacy amended invoice (extraction_feedback = nil) resolved via Langfuse v3 score
    sha4 = Fingerprint.sha256("pdf-bytes-4")
    {:ok, _} = Storage.put_object("documents/doc4.pdf", "pdf-bytes-4")

    doc4 =
      document_fixture(scope, %{
        filename: "migros.pdf",
        object_key: "documents/doc4.pdf",
        content_sha256: sha4
      })

    ec4 =
      extracted_content_fixture(doc4, user, %{
        trace_id: "trace-legacy",
        raw_llm_response: %{"pages" => [%{"markdown" => "Migros CHF 112.95"}]},
        extracted_data: invoice_data(11_295, "CHF", "Migros Online SA", "INV-4", "Order payment")
      })

    {:ok, _} = Review.create_initial_decision(ec4)

    {:ok, d4} =
      Review.amend_invoice(
        ec4.id,
        user.id,
        invoice_data(11_295, "CHF", "Migros Online SA", "INV-4", "Groceries")
      )

    # Simulate legacy pre-migration row where extraction_feedback was NULL.
    Repo.update_all(from(rd in ReviewDecision, where: rd.id == ^d4.id),
      set: [extraction_feedback: nil]
    )

    # 5. Rejected invoice
    doc5 = document_fixture(scope, %{filename: "dup.pdf", object_key: "documents/doc5.pdf"})
    {:ok, _} = Storage.put_object("documents/doc5.pdf", "dup")
    ec5 = extracted_content_fixture(doc5, user, %{raw_llm_response: %{"pages" => []}})
    {:ok, _} = Review.create_initial_decision(ec5)
    {:ok, _} = Review.reject_invoice(ec5.id, user.id, "Duplicate", nil, extraction_feedback: true)

    # 6. Pending invoice (should be skipped by default)
    doc6 = document_fixture(scope, %{filename: "pending.pdf", object_key: "documents/doc6.pdf"})
    ec6 = extracted_content_fixture(doc6, user, %{raw_llm_response: %{"pages" => []}})
    {:ok, _} = Review.create_initial_decision(ec6)

    # Audit overlay for doc3
    overlay_path = Path.join(tmp_dir, "audit_overlay.jsonl")

    File.write!(
      overlay_path,
      Jason.encode!(%{
        "document_id" => doc3.id,
        "ocr_faithful" => true,
        "error_tags" => ["zero_amount_schema_bug"]
      }) <> "\n"
    )

    # Stub Langfuse v3 scores + v2 observations
    Req.Test.stub(__MODULE__, fn conn ->
      case conn.request_path do
        "/api/public/v3/scores" ->
          Req.Test.json(conn, %{
            "data" => [
              %{
                "id" => "user-extraction-thumbs-trace-legacy",
                "name" => "user-extraction-thumbs",
                "value" => true,
                "comment" => "Corrected before posting: reason_for_payment",
                "environment" => "default",
                "timestamp" => "2026-11-17T18:21:24Z",
                "subject" => %{"kind" => "trace", "id" => "trace-legacy"}
              }
            ],
            "meta" => %{}
          })

        "/api/public/v2/observations" ->
          if String.contains?(conn.query_string, "traceId=trace-legacy") do
            Req.Test.json(conn, %{
              "data" => [
                %{
                  "name" => "process-invoice",
                  "environment" => "prod",
                  "metadata" => %{"attributes.langfuse.release" => "0.1.0"}
                },
                %{
                  "name" => "extract-invoice",
                  "providedModelName" => "ibm-granite/granite-4.2-8b",
                  "promptName" => "extract-invoice",
                  "promptVersion" => 1,
                  "usageDetails" => %{"input" => 1407, "output" => 1918, "total" => 3325}
                }
              ]
            })
          else
            Req.Test.json(conn, %{"data" => []})
          end
      end
    end)

    out_dir = Path.join(tmp_dir, "out")

    assert {:ok, summary} =
             Builder.build(
               version: "v001",
               output_dir: out_dir,
               upload_s3: true,
               enrich_langfuse: true,
               langfuse_opts: [
                 base_url: "https://langfuse.test",
                 public_key: "pk",
                 secret_key: "sk",
                 req_options: [plug: {Req.Test, __MODULE__}, retry: false]
               ],
               audit_overlay: overlay_path,
               user_id: user.id
             )

    assert summary.record_count == 5
    assert summary.skipped_count == 1
    assert summary.storage_missing_count == 1
    assert summary.file_mismatch_count == 1
    assert summary.s3_prefix == "datasets/v001"
    assert summary.output_dir == Path.join(out_dir, "v001")

    canonical_raw = File.read!(Path.join([out_dir, "v001", "canonical.jsonl"]))
    splits_raw = File.read!(Path.join([out_dir, "v001", "splits.json"]))
    manifest = File.read!(Path.join([out_dir, "v001", "manifest.json"])) |> Jason.decode!()

    assert manifest["sha256"]["canonical.jsonl"] == Fingerprint.sha256(canonical_raw)
    assert manifest["sha256"]["splits.json"] == Fingerprint.sha256(splits_raw)
    assert manifest["label_quality_counts"]["gold_audited"] == 1
    assert manifest["label_quality_counts"]["gold_reviewed"] == 3
    assert manifest["label_quality_counts"]["rejected"] == 1

    # Uploaded to S3 under datasets/v001/
    assert {:ok, ^canonical_raw} = Storage.read_object("datasets/v001/canonical.jsonl")
    assert {:ok, ^splits_raw} = Storage.read_object("datasets/v001/splits.json")
    assert :ok = Storage.head_object("datasets/v001/manifest.json")

    by_id =
      canonical_raw
      |> String.split("\n", trim: true)
      |> Enum.map(&Jason.decode!/1)
      |> Map.new(&{&1["document_id"], &1})

    # Doc 1: clean approved
    r1 = by_id[doc1.id]
    assert r1["document"]["s3_exists"] == true
    assert r1["document"]["file_matches_posted_snapshot"] == true
    assert r1["inputs"]["currency_hint"] == "CHF"
    assert r1["inputs"]["ocr"]["markdown"] == "Swisscom CHF 108.10"
    assert r1["ground_truth"]["extracted_faithful"]["amount_to_pay_cents"] == 10_810
    assert r1["label"]["human_thumbs"] == true
    assert hd(r1["processing_runs"])["extraction"]["model"] == "ibm-granite/granite-4.2-8b"
    assert hd(r1["processing_runs"])["typesafe_shadow"]["max_error_probability"] == 0.12

    # Doc 2: personal enrichment keeps faithful original_data in extracted_faithful
    r2 = by_id[doc2.id]
    assert r2["label"]["human_thumbs"] == true
    assert r2["ground_truth"]["extracted_faithful"]["reason_for_payment"] == "Travelcard purchase"
    assert r2["ground_truth"]["booked_values"]["reason_for_payment"] == "Monthly transit pass"
    assert [diff2] = r2["ground_truth"]["field_diff"]
    assert diff2["kind"] == "personal_enrichment"

    # Doc 3: genuine extraction error uses corrected values + audit overlay + mismatch/missing flags
    r3 = by_id[doc3.id]
    assert r3["document"]["s3_exists"] == false
    assert r3["document"]["file_matches_posted_snapshot"] == false
    assert r3["ground_truth"]["extracted_faithful"]["amount_to_pay_cents"] == 0
    assert r3["label"]["quality"] == "gold_audited"
    assert r3["label"]["ocr_faithful"] == true
    assert r3["label"]["error_tags"] == ["zero_amount_schema_bug"]
    assert r3["grouping"]["challenge_eval"] == true

    # Doc 4: legacy NULL extraction_feedback fell back to Langfuse v3 score (true) + v2 observations
    r4 = by_id[doc4.id]
    assert r4["label"]["human_thumbs"] == true
    assert r4["ground_truth"]["extracted_faithful"]["reason_for_payment"] == "Order payment"
    assert hd(r4["processing_runs"])["app_release"] == "0.1.0"
    assert hd(r4["processing_runs"])["extraction"]["prompt_version"] == 1

    # Doc 5: rejected
    r5 = by_id[doc5.id]
    assert r5["label"]["review_status"] == "rejected"
    assert r5["label"]["human_thumbs"] == true
    assert r5["ground_truth"]["booked_values"] == nil
    assert r5["ground_truth"]["extracted_faithful"] == nil

    assert Builder.format_summary(summary) =~ "Dataset v001 built (5 records, 1 skipped)"
  end

  @tag :tmp_dir
  test "rejects missing or unsafe version names (including dot-only), missing destinations, and silent overwrites",
       %{tmp_dir: tmp_dir} do
    assert {:error, :missing_version} = Builder.build([])
    assert {:error, {:invalid_version, "../bad"}} = Builder.build(version: "../bad")
    assert {:error, {:invalid_version, "."}} = Builder.build(version: ".")
    assert {:error, {:invalid_version, ".."}} = Builder.build(version: "..")
    assert {:error, {:invalid_version, "-v1"}} = Builder.build(version: "-v1")

    assert {:error, :no_output_destination} =
             Builder.build(version: "v001", output_dir: nil, upload_s3: false)

    user = user_fixture()
    out_dir = Path.join(tmp_dir, "overwrite_check")

    assert {:ok, _} = Builder.build(version: "v001", output_dir: out_dir, user_id: user.id)

    assert {:error, {:version_already_exists, "v001"}} =
             Builder.build(version: "v001", output_dir: out_dir, user_id: user.id)

    assert {:ok, summary} =
             Builder.build(
               version: "v001",
               output_dir: out_dir,
               user_id: user.id,
               overwrite: true,
               enrich_langfuse: true
             )

    # Langfuse credentials are not configured, so langfuse_enriched must be false with a warning.
    assert summary.langfuse_enriched == false
    assert Enum.any?(summary.warnings, &String.contains?(&1, "credentials"))
  end

  @tag :tmp_dir
  test "leaves amended reviews with nil extraction_feedback unclassified, sorts NaiveDateTime chronologically, and guards partial overlays on rejected docs",
       %{tmp_dir: tmp_dir} do
    user = user_fixture()
    scope = user_scope_fixture(user)

    # 1. Pre-D38 amended review without Langfuse enrichment -> amended_unclassified, extracted_faithful: nil
    doc = document_fixture(scope, %{filename: "legacy.pdf", object_key: "documents/legacy.pdf"})
    {:ok, _} = Storage.put_object("documents/legacy.pdf", "bytes")

    ec =
      extracted_content_fixture(doc, user, %{
        raw_llm_response: %{"pages" => [%{"markdown" => "Total CHF 42.00"}]},
        extracted_data: invoice_data(4200, "CHF", "Acme", "INV-99", "Order payment")
      })

    {:ok, _} = Review.create_initial_decision(ec)

    {:ok, rd} =
      Review.amend_invoice(
        ec.id,
        user.id,
        invoice_data(4200, "CHF", "Acme", "INV-99", "Groceries")
      )

    Repo.update_all(from(r in ReviewDecision, where: r.id == ^rd.id),
      set: [extraction_feedback: nil]
    )

    out_dir = Path.join(tmp_dir, "legacy_out")

    assert {:ok, summary} =
             Builder.build(
               version: "v001",
               output_dir: out_dir,
               user_id: user.id,
               enrich_langfuse: false
             )

    assert summary.label_quality_counts == %{"amended_unclassified" => 1}

    [rec] =
      Path.join([out_dir, "v001", "canonical.jsonl"])
      |> File.read!()
      |> String.split("\n", trim: true)
      |> Enum.map(&Jason.decode!/1)

    assert rec["ground_truth"]["extracted_faithful"] == nil
    assert rec["ground_truth"]["booked_values"]["reason_for_payment"] == "Groceries"
    assert rec["inputs"]["ocr"]["model"] == nil

    # 2. NaiveDateTime chronological ordering: 2026-02-01 must sort AFTER 2026-01-31 (not by day field).
    jan31 = %ExtractedContent{
      id: 10,
      status: "success",
      inserted_at: ~N[2026-01-31 12:00:00],
      extracted_data: struct(ExtractedData, invoice_data(100, "CHF", "Jan31", "J1", "Jan")),
      raw_llm_response: %{"pages" => [%{"markdown" => "Jan 31"}]},
      review_decision: %ReviewDecision{
        review_status: "approved",
        extraction_feedback: true,
        original_data: struct(ExtractedData, invoice_data(100, "CHF", "Jan31", "J1", "Jan")),
        journal_entry: nil
      }
    }

    feb01 = %ExtractedContent{
      id: 9,
      status: "success",
      inserted_at: ~N[2026-02-01 12:00:00],
      extracted_data: struct(ExtractedData, invoice_data(200, "CHF", "Feb01", "F1", "Feb")),
      raw_llm_response: %{"pages" => [%{"markdown" => "Feb 01"}]},
      review_decision: %ReviewDecision{
        review_status: "approved",
        extraction_feedback: true,
        original_data: struct(ExtractedData, invoice_data(200, "CHF", "Feb01", "F1", "Feb")),
        journal_entry: nil
      }
    }

    synthetic_doc = %Document{
      id: 500,
      filename: "dates.pdf",
      object_key: "documents/dates.pdf",
      extracted_content: [feb01, jan31]
    }

    assert {:ok, ordered} = Record.build(synthetic_doc, %{include_pending: false})
    assert ordered["ground_truth"]["extracted_faithful"]["amount_to_pay_cents"] == 200
    assert Enum.map(ordered["processing_runs"], & &1["extracted_content_id"]) == [10, 9]

    # 3. Partial overlay on a rejected document must NOT turn it into gold_audited with incomplete fields.
    rejected_doc = %Document{
      id: 501,
      filename: "rej.pdf",
      object_key: "documents/rej.pdf",
      extracted_content: [
        %ExtractedContent{
          id: 11,
          status: "success",
          inserted_at: ~N[2026-02-02 12:00:00],
          extracted_data: struct(ExtractedData, invoice_data(100, "CHF", "Acme", "R1", nil)),
          raw_llm_response: %{"pages" => [%{"markdown" => "Rejected"}]},
          review_decision: %ReviewDecision{review_status: "rejected", journal_entry: nil}
        }
      ]
    }

    partial_overlay = %{501 => %{"extracted_faithful" => %{"amount_to_pay_cents" => 100}}}

    assert {:ok, rej_rec} =
             Record.build(rejected_doc, %{include_pending: false, audit_overlay: partial_overlay})

    assert rej_rec["ground_truth"]["extracted_faithful"] == nil
    assert rej_rec["label"]["quality"] == "rejected"
  end

  defp invoice_data(amount_cents, currency, issuer, number, reason) do
    %{
      amount_to_pay_cents: amount_cents,
      currency: currency,
      invoice_date: "2026-11-15",
      invoice_number: number,
      issuer: issuer,
      reason_for_payment: reason
    }
  end
end
