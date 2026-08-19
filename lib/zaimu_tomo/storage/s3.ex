defmodule ZaimuTomo.Storage.S3 do
  @moduledoc false

  @behaviour ZaimuTomo.Storage.Adapter

  @service "s3"

  @impl true
  def put_object(key, body, config) do
    key
    |> request(:put, body, config, content_type: MIME.from_path(key))
    |> put_result(key)
  end

  @impl true
  def get_object(key, destination, config) do
    try do
      key
      |> request(:get, "", config, into: File.stream!(destination, [:write, :binary]))
      |> get_result(destination)
    rescue
      error in File.Error -> {:error, error.reason}
    end
  end

  @impl true
  def delete_object(key, config) do
    key
    |> request(:delete, "", config)
    |> empty_result()
  end

  @impl true
  def head_object(key, config) do
    key
    |> request(:head, "", config)
    |> head_result()
  end

  defp request(key, method, body, config, options \\ []) do
    url = object_url(key, config)
    headers = signed_headers(method, url, body, config, options)
    req_options = Keyword.delete(options, :content_type)

    config
    |> Keyword.get(:req_options, [])
    |> Keyword.merge(method: method, url: url, headers: headers, body: body)
    |> Keyword.merge(req_options)
    |> Req.request()
  end

  defp signed_headers(method, url, body, config, options) do
    headers =
      case Keyword.fetch(options, :content_type) do
        {:ok, content_type} -> [{"content-type", content_type}]
        :error -> []
      end

    :aws_signature.sign_v4(
      Keyword.fetch!(config, :access_key_id),
      Keyword.fetch!(config, :secret_access_key),
      Keyword.fetch!(config, :region),
      @service,
      :calendar.universal_time(),
      method |> Atom.to_string() |> String.upcase(),
      url,
      headers,
      body,
      uri_encode_path: false
    )
  end

  defp put_result({:ok, %Req.Response{status: status}}, key) when status in 200..299,
    do: {:ok, key}

  defp put_result(result, _key), do: error_result(result)

  defp get_result({:ok, %Req.Response{status: status}}, destination) when status in 200..299,
    do: {:ok, destination}

  defp get_result(result, _destination), do: error_result(result)

  defp empty_result({:ok, %Req.Response{status: status}}) when status in 200..299, do: :ok
  defp empty_result(result), do: error_result(result)

  defp head_result({:ok, %Req.Response{status: status}}) when status in 200..299, do: :ok
  defp head_result({:ok, %Req.Response{status: 404}}), do: {:error, :not_found}
  defp head_result(result), do: error_result(result)

  defp error_result({:ok, %Req.Response{status: status}}),
    do: {:error, {:unexpected_status, status}}

  defp error_result({:error, reason}), do: {:error, reason}

  defp object_url(key, config) do
    endpoint = config |> Keyword.fetch!(:endpoint) |> String.trim_trailing("/")
    bucket = config |> Keyword.fetch!(:bucket) |> URI.encode(&URI.char_unreserved?/1)
    encoded_key = URI.encode(key, &(URI.char_unreserved?(&1) or &1 == ?/))

    case Keyword.fetch!(config, :path_style) do
      true -> "#{endpoint}/#{bucket}/#{encoded_key}"
      false -> virtual_hosted_url(endpoint, bucket, encoded_key)
    end
  end

  defp virtual_hosted_url(endpoint, bucket, encoded_key) do
    uri = URI.parse(endpoint)
    virtual_hosted_endpoint = URI.to_string(%{uri | host: "#{bucket}.#{uri.host}", path: nil})
    "#{virtual_hosted_endpoint}/#{encoded_key}"
  end
end
