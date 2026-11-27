defmodule ZaimuTomo.Datasets.LangfuseReaderTest do
  use ExUnit.Case, async: false

  alias ZaimuTomo.Datasets.LangfuseReader

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

  test "returns unconfigured enrichment with a warning when Langfuse credentials are missing" do
    enrichment = LangfuseReader.fetch_enrichment(["trace-1"])
    assert enrichment.configured? == false
    assert enrichment.scores_by_trace == %{}
    assert enrichment.observations_by_trace == %{}
    assert Enum.any?(enrichment.warnings, &String.contains?(&1, "credentials"))
  end

  test "paginates v3 scores with name filter and paginates v2 observations per trace" do
    Req.Test.stub(__MODULE__, fn conn ->
      case {conn.request_path, conn.query_string} do
        {"/api/public/v3/scores", qs} ->
          assert String.contains?(qs, "name=user-extraction-thumbs")

          if String.contains?(qs, "cursor=page-2") do
            Req.Test.json(conn, %{
              "data" => [
                %{
                  "id" => "user-extraction-thumbs-trace-2",
                  "name" => "user-extraction-thumbs",
                  "value" => false,
                  "comment" => "Corrected before posting: amount_to_pay_cents 1 -> 0",
                  "environment" => "default",
                  "timestamp" => "2026-11-20T18:17:17Z",
                  "subject" => %{"kind" => "trace", "id" => "trace-2"}
                },
                %{
                  "id" => "other-score",
                  "name" => "unrelated",
                  "value" => 1,
                  "subject" => %{"kind" => "trace", "id" => "trace-2"}
                }
              ],
              "meta" => %{}
            })
          else
            Req.Test.json(conn, %{
              "data" => [
                %{
                  "id" => "user-extraction-thumbs-trace-1",
                  "name" => "user-extraction-thumbs",
                  "value" => true,
                  "comment" => nil,
                  "environment" => "prod",
                  "timestamp" => "2026-11-20T18:01:55Z",
                  "subject" => %{"kind" => "trace", "id" => "trace-1"}
                }
              ],
              "meta" => %{"cursor" => "page-2"}
            })
          end

        {"/api/public/v2/observations", qs} ->
          cond do
            String.contains?(qs, "traceId=trace-1") and String.contains?(qs, "cursor=obs-p2") ->
              Req.Test.json(conn, %{
                "data" => [
                  %{
                    "name" => "verify-extraction",
                    "providedModelName" => "qwen/qwen3.6-35b-a3b",
                    "promptName" => "verify-extraction",
                    "promptVersion" => 2,
                    "usageDetails" => %{"input" => 980, "output" => 1650, "total" => 2630}
                  }
                ],
                "meta" => %{}
              })

            String.contains?(qs, "traceId=trace-1") ->
              Req.Test.json(conn, %{
                "data" => [
                  %{
                    "name" => "process-invoice",
                    "environment" => "prod",
                    "metadata" => %{"attributes.langfuse.release" => "0.2.1"}
                  },
                  %{
                    "name" => "extract-invoice",
                    "providedModelName" => "ibm-granite/granite-4.2-8b",
                    "promptName" => "extract-invoice",
                    "promptVersion" => 2,
                    "latency" => 3.4,
                    "totalCost" => 0.0012,
                    "usageDetails" => %{"input" => 973, "output" => 2254, "total" => 3227},
                    "metadata" => %{"finish_reason" => "tool_calls"}
                  }
                ],
                "meta" => %{"cursor" => "obs-p2"}
              })

            String.contains?(qs, "traceId=trace-2") ->
              Plug.Conn.send_resp(conn, 500, "temporary error")

            true ->
              Req.Test.json(conn, %{"data" => []})
          end
      end
    end)

    enrichment =
      LangfuseReader.fetch_enrichment(
        ["trace-1", "trace-2", "trace-missing"],
        base_url: "https://langfuse.test",
        public_key: "pk",
        secret_key: "sk",
        req_options: [plug: {Req.Test, __MODULE__}, retry: false]
      )

    assert enrichment.configured? == true
    assert enrichment.scores_by_trace["trace-1"]["value"] == true
    assert enrichment.scores_by_trace["trace-2"]["value"] == false
    assert Map.keys(enrichment.scores_by_trace) |> Enum.sort() == ["trace-1", "trace-2"]

    t1 = enrichment.observations_by_trace["trace-1"]
    assert t1["observation_count"] == 3
    assert t1["app_release"] == "0.2.1"
    assert t1["extraction"]["model"] == "ibm-granite/granite-4.2-8b"
    assert t1["extraction"]["prompt_version"] == 2

    assert t1["extraction"]["usage"] == %{
             "input_tokens" => 973,
             "output_tokens" => 2254,
             "total_tokens" => 3227
           }

    assert t1["verification"]["model"] == "qwen/qwen3.6-35b-a3b"

    assert enrichment.observations_by_trace["trace-missing"]["observation_count"] == 0
    assert Enum.any?(enrichment.warnings, &String.contains?(&1, "trace-2"))
  end
end
