defmodule ZaimuTomo.RuntimeConfigTest do
  use ExUnit.Case, async: false

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
    TYPESAFE_MAX_QUEUE
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
      "TYPESAFE_MAX_CONCURRENCY" => "3",
      "TYPESAFE_MAX_QUEUE" => "50"
    })

    config = read_typesafe_config()

    assert config[:enabled]
    assert config[:base_url] == "https://typesafe.internal"
    assert config[:model] == "jev-pinned"
    assert config[:review_threshold] == 0.85
    assert config[:receive_timeout] == 4_000
    assert config[:total_timeout] == 5_000
    assert config[:max_retries] == 1
    assert config[:max_concurrency] == 3
    assert config[:max_queue] == 50
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
          {"TYPESAFE_MAX_CONCURRENCY", "many", 1},
          {"TYPESAFE_MAX_QUEUE", "0", 1}
        ] do
      System.put_env(name, value)

      assert_raise ArgumentError,
                   "#{name} must be an integer greater than or equal to #{minimum}",
                   &read_typesafe_config/0

      System.delete_env(name)
    end
  end

  defp read_typesafe_config do
    @runtime_path
    |> Config.Reader.read!(env: :dev)
    |> get_in([:zaimu_tomo, :typesafe])
  end
end
