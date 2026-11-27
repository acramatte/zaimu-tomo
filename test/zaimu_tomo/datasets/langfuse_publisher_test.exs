defmodule ZaimuTomo.Datasets.LangfusePublisherTest do
  use ExUnit.Case, async: false

  alias ZaimuTomo.Datasets.LangfusePublisher
  alias ZaimuTomo.Storage

  setup do
    original = Application.get_env(:zaimu_tomo, :langfuse)
    Application.put_env(:zaimu_tomo, :langfuse, enabled: false)

    on_exit(fn ->
      if original do
        Application.put_env(:zaimu_tomo, :langfuse, original)
      else
        Application.delete_env(:zaimu_tomo, :langfuse)
      end
    end)

    :ok
  end

  @tag :tmp_dir
  test "publishes extraction and verification eval items with deterministic IDs and no private fields",
       %{tmp_dir: tmp_dir} do
    eval_path = Path.join(tmp_dir, "challenge.jsonl")

    eval_row = %{
      "document_id" => 94,
      "trace_id" => "trace-94",
      "split" => "validation",
      "challenge_eval" => true,
      "currency_hint" => "CHF",
      "ocr_markdown" => "Total amount due: $0.00 USD",
      "content_sha256" => "secret-digest-should-not-leak",
      "review_notes" => "private user comment",
      "ground_truth" => %{"amount_to_pay_cents" => 0, "currency" => "USD"},
      "candidate_extraction" => %{"amount_to_pay_cents" => 1, "currency" => "USD"},
      "expected_verdict" => "rejected",
      "expected_field_issues" => ["amount_to_pay_cents"],
      "label_quality" => "gold_audited",
      "human_thumbs" => false,
      "ocr_faithful" => true,
      "error_tags" => ["zero_amount_schema_bug"]
    }

    File.write!(eval_path, Jason.encode!(eval_row) <> "\n")

    test_pid = self()

    Req.Test.stub(__MODULE__, fn conn ->
      {:ok, raw, conn} = Plug.Conn.read_body(conn)
      send(test_pid, {:langfuse_post, conn.request_path, Jason.decode!(raw)})
      Req.Test.json(conn, %{"ok" => true})
    end)

    langfuse_opts = [
      base_url: "https://langfuse.test",
      public_key: "pk",
      secret_key: "sk",
      req_options: [plug: {Req.Test, __MODULE__}, retry: false]
    ]

    # Extraction dataset
    assert {:ok, ext_summary} =
             LangfusePublisher.publish(
               input: eval_path,
               dataset: "invoice-extraction-v001",
               task: "extraction",
               langfuse_opts: langfuse_opts
             )

    assert ext_summary.published == 1
    assert ext_summary.skipped == 0

    assert_receive {:langfuse_post, "/api/public/v2/datasets",
                    %{"name" => "invoice-extraction-v001"}}

    assert_receive {:langfuse_post, "/api/public/dataset-items", ext_item}
    assert ext_item["id"] == "invoice-extraction-v001-doc-94"
    assert ext_item["sourceTraceId"] == "trace-94"
    assert ext_item["input"]["currency_hint"] == "CHF"
    assert ext_item["expectedOutput"] == %{"amount_to_pay_cents" => 0, "currency" => "USD"}
    refute Map.has_key?(ext_item["metadata"], "content_sha256")
    refute Map.has_key?(ext_item["metadata"], "review_notes")

    # Verification dataset
    assert {:ok, verif_summary} =
             LangfusePublisher.publish(
               input: eval_path,
               dataset: "invoice-verification-v001",
               task: "verification",
               langfuse_opts: langfuse_opts
             )

    assert verif_summary.published == 1
    assert_receive {:langfuse_post, "/api/public/v2/datasets", _}
    assert_receive {:langfuse_post, "/api/public/dataset-items", verif_item}
    assert verif_item["id"] == "invoice-verification-v001-doc-94"
    assert verif_item["input"]["extracted"] == %{"amount_to_pay_cents" => 1, "currency" => "USD"}

    assert verif_item["expectedOutput"] == %{
             "status" => "rejected",
             "field_issues" => "amount_to_pay_cents"
           }

    # Dry run makes no HTTP requests
    assert {:ok, dry_summary} =
             LangfusePublisher.publish(
               input: eval_path,
               dataset: "invoice-extraction-v001",
               dry_run: true
             )

    assert dry_summary.dry_run == true
    assert dry_summary.published == 0
    assert dry_summary.total == 1
    refute_receive {:langfuse_post, _, _}

    assert LangfusePublisher.format_summary(dry_summary) =~ "(dry run)"
  end

  @tag :tmp_dir
  test "validates required args, task names, and Langfuse configuration", %{tmp_dir: tmp_dir} do
    path = Path.join(tmp_dir, "empty.jsonl")
    File.write!(path, "")

    assert {:error, :missing_input} = LangfusePublisher.publish(dataset: "ds")
    assert {:error, :missing_dataset} = LangfusePublisher.publish(input: path)

    assert {:error, {:invalid_task, "other"}} =
             LangfusePublisher.publish(input: path, dataset: "ds", task: "other")

    assert {:error, :langfuse_not_configured} =
             LangfusePublisher.publish(input: path, dataset: "ds")
  end

  test "publishes directly from an S3 key" do
    key = "datasets/v099/exports/eval/challenge.jsonl"

    row = %{
      "document_id" => 101,
      "currency_hint" => "CHF",
      "ocr_markdown" => "Invoice markdown",
      "ground_truth" => %{"amount_to_pay_cents" => 1200}
    }

    assert {:ok, _} = Storage.put_object(key, Jason.encode!(row) <> "\n")

    assert {:ok, summary} =
             LangfusePublisher.publish(s3_key: key, dataset: "ds-s3", dry_run: true)

    assert summary.total == 1
    assert summary.skipped == 0
  end
end
