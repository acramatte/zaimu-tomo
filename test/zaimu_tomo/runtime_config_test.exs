defmodule ZaimuTomo.RuntimeConfigTest do
  use ExUnit.Case, async: false

  alias ZaimuTomo.DocumentProcessing.OCRJob
  alias ZaimuTomo.Statements.ExtractJob
  alias ZaimuTomo.TypeSafeVerification

  @runtime_path Path.expand("../../config/runtime.exs", __DIR__)
  @typesafe_env ~w(
    TYPESAFE_API_KEY
    TYPESAFE_URL
    TYPESAFE_MODEL
    TYPESAFE_REVIEW_THRESHOLD
    TYPESAFE_RECEIVE_TIMEOUT
    TYPESAFE_TOTAL_TIMEOUT
    TYPESAFE_MAX_RETRIES
    TYPESAFE_MAX_CONCURRENCY
    OBAN_DOCUMENTS_CONCURRENCY
    OBAN_STATEMENTS_CONCURRENCY
    LANGFUSE_PUBLIC_KEY
    LANGFUSE_SECRET_KEY
  )

  setup do
    original = Map.new(@typesafe_env, &{&1, System.get_env(&1)})
    Enum.each(@typesafe_env, &System.delete_env/1)
    System.put_env("LANGFUSE_PUBLIC_KEY", "")
    System.put_env("LANGFUSE_SECRET_KEY", "")

    on_exit(fn ->
      Enum.each(original, fn
        {name, nil} -> System.delete_env(name)
        {name, value} -> System.put_env(name, value)
      end)
    end)
  end

  test "keeps TypeSafe disabled for a blank API key and accepts threshold boundaries" do
    System.put_env("TYPESAFE_API_KEY", "")

    for threshold <- ["0", "1"] do
      System.put_env("TYPESAFE_REVIEW_THRESHOLD", threshold)
      config = read_typesafe_config()

      refute config[:enabled]
      assert config[:review_threshold] == String.to_float(threshold <> ".0")
    end
  end

  test "loads TypeSafe endpoint, model, timeout, retry, and concurrency overrides" do
    System.put_env(%{
      "TYPESAFE_API_KEY" => "typesafe-secret",
      "TYPESAFE_URL" => "https://typesafe.internal",
      "TYPESAFE_MODEL" => "jev-pinned",
      "TYPESAFE_REVIEW_THRESHOLD" => "0.85",
      "TYPESAFE_RECEIVE_TIMEOUT" => "4000",
      "TYPESAFE_TOTAL_TIMEOUT" => "5000",
      "TYPESAFE_MAX_RETRIES" => "1",
      "TYPESAFE_MAX_CONCURRENCY" => "3"
    })

    config = read_typesafe_config()

    assert config[:enabled]
    assert config[:base_url] == "https://typesafe.internal"
    assert config[:model] == "jev-pinned"
    assert config[:review_threshold] == 0.85
    assert config[:receive_timeout] == 4_000
    assert config[:total_timeout] == 5_000
    assert config[:max_retries] == 1

    # TYPESAFE_MAX_CONCURRENCY now feeds the Oban :typesafe queue limit.
    oban_queues = read_oban_queues()
    assert oban_queues[:typesafe] == 3
    assert oban_queues[:documents] == 2
  end

  test "sizes the statements queue from OBAN_STATEMENTS_CONCURRENCY, one by default" do
    assert read_oban_queues()[:statements] == 1

    System.put_env("OBAN_STATEMENTS_CONCURRENCY", "3")
    assert read_oban_queues()[:statements] == 3

    System.put_env("OBAN_STATEMENTS_CONCURRENCY", "0")

    assert_raise ArgumentError,
                 "OBAN_STATEMENTS_CONCURRENCY must be an integer greater than or equal to 1",
                 &read_oban_queues/0
  end

  test "rejects malformed review thresholds" do
    System.put_env("TYPESAFE_REVIEW_THRESHOLD", "not-a-probability")

    assert_raise ArgumentError,
                 "TYPESAFE_REVIEW_THRESHOLD must be a number between 0 and 1",
                 &read_typesafe_config/0
  end

  test "rejects malformed timeout, retry, and concurrency values" do
    for {name, value, minimum} <- [
          {"TYPESAFE_TOTAL_TIMEOUT", "0", 1},
          {"TYPESAFE_MAX_RETRIES", "-1", 0},
          {"TYPESAFE_MAX_CONCURRENCY", "many", 1}
        ] do
      System.put_env(name, value)

      assert_raise ArgumentError,
                   "#{name} must be an integer greater than or equal to #{minimum}",
                   &read_typesafe_config/0

      System.delete_env(name)
    end
  end

  test "Oban.Lifeline rescue_after exceeds every Oban worker's timeout" do
    rescue_after_ms = read_lifeline_rescue_after_ms()
    workers = oban_workers()

    assert OCRJob in workers
    assert ExtractJob in workers
    assert TypeSafeVerification.Worker in workers

    for worker <- [OCRJob, ExtractJob] do
      timeout_ms = worker.timeout(%Oban.Job{})
      assert is_integer(timeout_ms) and timeout_ms > 0
      assert rescue_after_ms > timeout_ms
    end

    for worker <- workers do
      assert_timeout_below_lifeline(worker, rescue_after_ms)
    end
  end

  defp assert_timeout_below_lifeline(worker, rescue_after_ms) do
    case worker.timeout(%Oban.Job{}) do
      :infinity ->
        :ok

      timeout_ms when is_integer(timeout_ms) and timeout_ms > 0 ->
        message =
          "Oban.Lifeline rescue_after (#{rescue_after_ms}ms) must exceed " <>
            "#{inspect(worker)}.timeout/1 (#{timeout_ms}ms)"

        assert rescue_after_ms > timeout_ms, message
    end
  end

  defp read_lifeline_rescue_after_ms do
    plugins =
      :zaimu_tomo
      |> Application.fetch_env!(Oban)
      |> Keyword.fetch!(:plugins)

    lifeline_opts =
      Enum.find_value(plugins, fn
        {Oban.Lifeline, opts} -> opts
        Oban.Lifeline -> [rescue_after: :timer.minutes(60)]
        _other -> nil
      end)

    assert is_list(lifeline_opts), "expected Oban.Lifeline plugin to be configured"

    lifeline_opts
    |> Keyword.fetch!(:rescue_after)
    |> Oban.Period.to_milliseconds()
  end

  defp oban_workers do
    {:ok, modules} = :application.get_key(:zaimu_tomo, :modules)
    Enum.filter(modules, &oban_worker?/1)
  end

  defp oban_worker?(module) do
    Code.ensure_loaded?(module) and Oban.Worker in behaviours(module)
  end

  defp behaviours(module) do
    module.module_info(:attributes)
    |> Keyword.get_values(:behaviour)
    |> List.flatten()
  end

  defp read_typesafe_config do
    read_runtime_config()
    |> get_in([:zaimu_tomo, :typesafe])
  end

  defp read_oban_queues do
    read_runtime_config()
    |> get_in([:zaimu_tomo, Oban])
    |> Keyword.fetch!(:queues)
  end

  defp read_runtime_config do
    Config.Reader.read!(@runtime_path, env: :dev)
  end
end
