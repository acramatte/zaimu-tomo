defmodule ZaimuTomo.DocumentProcessing.DocumentOCR do
  @moduledoc """
  Handles the sequential workflow of OCR analysis:
  Upload file to Mistral.ai's blob store -> Get URL for the file -> Analyze the text with OCR.
  See Document AI QnA: https://docs.mistral.ai/capabilities/document_ai/document_qna
  """

  require Logger

  @model "mistral-ocr-latest"

  @doc """
  Executes the OCR process for a local file and returns the extracted markdown.

  If any step fails, the function immediately stops and returns the error.
  """
  @spec process(String.t()) :: {:ok, String.t(), map()} | {:error, term()}
  def process(filepath) do
    result =
      with {:ok, %{"id" => file_id}} <- upload(filepath),
           {:ok, %{"url" => document_url}} <- get_url(file_id),
           {:ok, res_body} <- ocr_request(document_url) do
        extract_markdown(res_body)
      end

    case result do
      {:ok, markdown, raw_map} ->
        Logger.info("✅ OCR Analysis Complete: #{filepath}")
        {:ok, markdown, raw_map}

      {:error, reason} ->
        Logger.error("❌ OCR Analysis Failed for #{filepath}: #{inspect(reason)}")
        {:error, reason}
    end
  end

  def extract_markdown(%{"pages" => pages} = body) when is_list(pages) do
    markdown =
      pages
      |> Enum.map(fn page -> Map.get(page, "markdown", "") end)
      |> Enum.join("\n\n")

    {:ok, markdown, body}
  end

  def extract_markdown(_unexpected_body) do
    {:error, :unexpected_api_structure}
  end

  @spec upload(String.t()) :: {:ok, map()} | {:error, term()}
  defp upload(filepath) do
    config = Application.fetch_env!(:zaimu_tomo, :mistral)
    base_url = Keyword.fetch!(config, :base_url)
    api_key = Keyword.fetch!(config, :api_key)
    files_completion_path = "/files"

    case File.read(filepath) do
      {:ok, contents} ->
        multiplart_fields = [
          purpose: "ocr",
          file: {contents, filename: Path.basename(filepath)}
        ]

        Req.post(base_url <> files_completion_path,
          form_multipart: multiplart_fields,
          headers: [{"Authorization", "Bearer #{api_key}"}]
        )
        |> handle_response()

      {:error, reason} ->
        {:error, reason}
    end
  end

  @spec get_url(String.t()) :: {:ok, map()} | {:error, term()}
  defp get_url(id) do
    config = Application.fetch_env!(:zaimu_tomo, :mistral)
    base_url = Keyword.fetch!(config, :base_url)
    api_key = Keyword.fetch!(config, :api_key)
    files_completion_path = "/files"

    Req.get(base_url <> files_completion_path <> "/" <> id <> "/url?expiry=24",
      headers: [{"Authorization", "Bearer #{api_key}"}]
    )
    |> handle_response()
  end

  defp handle_response({:ok, %Req.Response{status: 200, body: json_body}}) do
    {:ok, json_body}
  end

  defp handle_response({:ok, %Req.Response{} = response}) do
    # handle non 200 status codes
    {:error, response.body}
  end

  defp handle_response({:error, reason}) do
    {:error, reason}
  end

  @spec ocr_request(String.t()) :: {:ok, map()} | {:error, term()}
  defp ocr_request(document_url) do
    config = Application.fetch_env!(:zaimu_tomo, :mistral)
    base_url = Keyword.fetch!(config, :base_url)
    api_key = Keyword.fetch!(config, :api_key)
    ocr_path = "/ocr"

    payload = %{
      model: @model,
      document: %{
        type: "document_url",
        document_url: document_url
      }
    }

    Req.post(base_url <> ocr_path,
      json: payload,
      headers: [{"Authorization", "Bearer #{api_key}"}]
    )
    |> handle_response()
  end
end
