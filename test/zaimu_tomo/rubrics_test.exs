defmodule ZaimuTomo.RubricsTest do
  use ExUnit.Case, async: true

  alias ZaimuTomo.Rubrics
  alias ZaimuTomo.Rubrics.Yaml

  @repo_root Path.expand("../..", __DIR__)
  @rubrics_dir Path.join(@repo_root, ".rubrics")

  test "all repo .rubrics/*.yaml files validate cleanly" do
    assert {:ok, count} = Rubrics.validate_dir(@rubrics_dir, @repo_root)
    assert count >= 4
  end

  test "parses folded strings, inline lists, numbers, and negatives from YAML" do
    raw = File.read!(Path.join(@rubrics_dir, "datasets.yaml"))
    parsed = Yaml.parse(raw)

    assert parsed["name"] == "datasets"
    assert "lib/zaimu_tomo/datasets/**" in parsed["paths"]
    assert length(parsed["criteria"]) == 5
    assert length(parsed["penalties"]) == 3
    assert Enum.all?(parsed["criteria"], &(is_float(&1["weight"]) and &1["inspect"] == ["diff"]))
    assert Enum.all?(parsed["penalties"], &(is_float(&1["penalty"]) and &1["penalty"] < 0))
    assert Rubrics.validate(parsed, "datasets.yaml") == []
  end

  test "matches path globs and normalizes weights across merged rubrics" do
    repo_rubrics = Rubrics.load_dir(@rubrics_dir)

    ds_merged =
      Rubrics.select_and_merge(repo_rubrics, [
        "lib/zaimu_tomo/datasets/exporters.ex",
        "docs/operations.md"
      ])

    assert ds_merged.matched_rubrics == ["datasets", "global", "ops_and_release"]

    weight_sum = Enum.reduce(ds_merged.criteria, 0.0, &(&1["normalized_weight"] + &2))
    assert_in_delta weight_sum, 1.0, 0.001

    ai_merged =
      Rubrics.select_and_merge(repo_rubrics, [
        "lib/zaimu_tomo/document_processing/ocr_worker.ex"
      ])

    assert ai_merged.matched_rubrics == ["ai_pipeline", "global"]
  end

  test "extracts optional pre-code task rubric from fenced PR body block" do
    pr_body = """
    ## Summary
    Adds credit note support.

    ```yaml rubric
    name: credit_notes
    criteria:
      - id: credit_note_sign
        weight: 0.5
        inspect: [diff, raw_logs]
        check: Keeps negative amounts intact end to end.
    ```
    """

    extracted = Rubrics.extract_from_pr_body(pr_body)
    assert extracted["name"] == "credit_notes"
    assert Rubrics.validate(extracted, "pr_body") == []
    assert hd(extracted["criteria"])["id"] == "credit_note_sign"
  end

  test "scores deterministically, excludes not_applicable from denominator, and applies penalties" do
    merged = %{
      matched_rubrics: ["datasets"],
      criteria: [
        %{"id" => "c1", "rubric" => "datasets", "weight" => 0.5},
        %{"id" => "c2", "rubric" => "datasets", "weight" => 0.5},
        %{"id" => "c3", "rubric" => "datasets", "weight" => 0.5}
      ],
      penalties: [
        %{"id" => "slop_train_in_eval", "rubric" => "datasets", "penalty" => -0.30}
      ]
    }

    critic_json = %{
      "summary" => "Found eval leakage.",
      "scores" => [
        %{"id" => "c1", "score" => 1.0, "status" => "pass", "evidence" => "exporters.ex:10"},
        %{"id" => "c2", "score" => 0.5, "status" => "partial", "evidence" => "exporters.ex:154"},
        %{"id" => "c3", "score" => 1.0, "status" => "not_applicable", "evidence" => "untouched"},
        %{"id" => "hallucinated_id", "score" => 0.0, "status" => "fail", "evidence" => "nope"}
      ],
      "penalties_triggered" => [
        %{"id" => "slop_train_in_eval", "evidence" => "exporters.ex:154 includes train split"},
        %{"id" => "unknown_penalty", "evidence" => "ignored"}
      ]
    }

    result = Rubrics.score_critic_response(merged, critic_json)
    assert_in_delta result.base_score, 0.75, 0.0001
    assert_in_delta result.penalty_total, -0.30, 0.0001
    assert_in_delta result.final_score, 0.45, 0.0001
    assert length(result.penalties_triggered) == 1

    md = Rubrics.render_markdown(result, "test-model")
    assert md =~ Rubrics.comment_marker()
    assert md =~ "45/100"
    assert md =~ "slop_train_in_eval"
  end

  test "calls OpenAI-compatible critic endpoint over Req and decodes JSON" do
    Req.Test.stub(__MODULE__, fn conn ->
      Req.Test.json(conn, %{
        "choices" => [
          %{
            "message" => %{
              "content" =>
                Jason.encode!(%{
                  "summary" => "Looks clean.",
                  "scores" => [
                    %{
                      "id" => "c1",
                      "score" => 1.0,
                      "status" => "pass",
                      "evidence" => "ok"
                    }
                  ],
                  "penalties_triggered" => []
                })
            }
          }
        ]
      })
    end)

    assert {:ok, decoded} =
             Rubrics.call_critic(
               [
                 api_key: "test-key",
                 base_url: "https://critic.test/v1",
                 model: "critic-1",
                 req_options: [plug: {Req.Test, __MODULE__}, retry: false]
               ],
               [%{"role" => "user", "content" => "diff"}]
             )

    assert decoded["summary"] == "Looks clean."
  end
end
