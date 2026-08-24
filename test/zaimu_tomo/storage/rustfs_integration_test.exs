defmodule ZaimuTomo.Storage.RustFSIntegrationTest do
  use ExUnit.Case, async: false

  alias Testcontainers.CommandWaitStrategy
  alias Testcontainers.Container
  alias ZaimuTomo.Storage.S3

  @moduletag :integration

  @rustfs_image "rustfs/rustfs:1.0.0-beta.12@sha256:41fe89380f4120a337790c02af192c3fe7bb55c3edc2e6e9357b487b47c6ab21"
  @access_key_id "zaimu-tomo-integration"
  @secret_access_key "zaimu-tomo-integration-secret"
  @region "eu-central-1"

  setup_all do
    started_testcontainers? = start_testcontainers()

    {:ok, container} =
      @rustfs_image
      |> Container.new()
      |> Container.with_environment("RUSTFS_ACCESS_KEY", @access_key_id)
      |> Container.with_environment("RUSTFS_SECRET_KEY", @secret_access_key)
      |> Container.with_environment("RUSTFS_REGION", @region)
      |> Container.with_environment("RUSTFS_ADDRESS", ":9000")
      |> Container.with_exposed_port(9000)
      |> Container.with_waiting_strategy(
        CommandWaitStrategy.new(
          ["curl", "-fsS", "http://localhost:9000/health/ready"],
          120_000
        )
      )
      |> Testcontainers.start_container()

    on_exit(fn ->
      :ok = Testcontainers.stop_container(container.container_id)

      if started_testcontainers? do
        :ok = GenServer.stop(Testcontainers)
      end
    end)

    endpoint =
      "http://#{Testcontainers.get_host(container)}:#{Testcontainers.get_port(container, 9000)}"

    bucket = "zaimu-tomo-integration-#{System.unique_integer([:positive])}"
    :ok = create_locked_bucket(endpoint, bucket)

    {:ok, storage_config: storage_config(endpoint, bucket)}
  end

  test "performs a signed path-style object lifecycle against RustFS", %{storage_config: config} do
    object_key = "documents/integration.pdf"
    body = <<0, 1, 2, "invoice bytes">>
    destination = Path.join(System.tmp_dir!(), "zaimu-tomo-rustfs-#{Ecto.UUID.generate()}.pdf")

    on_exit(fn -> File.rm(destination) end)

    assert {:error, :not_found} = S3.head_object(object_key, config)
    assert {:ok, ^object_key} = S3.put_object(object_key, body, config)
    assert :ok = S3.head_object(object_key, config)
    assert {:ok, ^destination} = S3.get_object(object_key, destination, config)
    assert File.read!(destination) == body
    assert :ok = S3.delete_object(object_key, config)
    assert {:error, :not_found} = S3.head_object(object_key, config)
  end

  test "rejects a request with an invalid SigV4 credential", %{storage_config: config} do
    invalid_config = Keyword.put(config, :secret_access_key, "not-the-rustfs-secret")

    assert {:error, {:unexpected_status, 403}} =
             S3.head_object("documents/forbidden.pdf", invalid_config)
  end

  defp start_testcontainers do
    case Process.whereis(Testcontainers) do
      nil ->
        {:ok, _pid} = Testcontainers.start()
        true

      _pid ->
        false
    end
  end

  defp create_locked_bucket(endpoint, bucket) do
    url = "#{endpoint}/#{bucket}"
    body = ""

    headers =
      :aws_signature.sign_v4(
        @access_key_id,
        @secret_access_key,
        @region,
        "s3",
        :calendar.universal_time(),
        "PUT",
        url,
        [{"x-amz-bucket-object-lock-enabled", "true"}],
        body,
        uri_encode_path: false
      )

    case Req.request(method: :put, url: url, headers: headers, body: body) do
      {:ok, %Req.Response{status: status}} when status in 200..299 -> :ok
      {:ok, %Req.Response{status: status}} -> {:error, {:unexpected_status, status}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp storage_config(endpoint, bucket) do
    [
      endpoint: endpoint,
      region: @region,
      access_key_id: @access_key_id,
      secret_access_key: @secret_access_key,
      bucket: bucket,
      path_style: true
    ]
  end
end
