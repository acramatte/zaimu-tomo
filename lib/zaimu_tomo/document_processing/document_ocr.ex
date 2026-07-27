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
    files_completion_path = "/files"

    with {:ok, contents} <- read_file(filepath, :ocr_upload_failed),
         {:ok, base_url, api_key} <- mistral_config(:ocr_upload_failed) do
      multipart_fields = [
        purpose: "ocr",
        file: {contents, filename: Path.basename(filepath)}
      ]

      Req.post(base_url <> files_completion_path,
        form_multipart: multipart_fields,
        headers: [{"Authorization", "Bearer #{api_key}"}]
      )
      |> handle_response(:ocr_upload_failed)
    end
  end

  @spec get_url(String.t()) :: {:ok, map()} | {:error, term()}
  defp get_url(id) do
    files_completion_path = "/files"

    with {:ok, base_url, api_key} <- mistral_config(:ocr_url_failed) do
      Req.get(base_url <> files_completion_path <> "/" <> id <> "/url?expiry=24",
        headers: [{"Authorization", "Bearer #{api_key}"}]
      )
      |> handle_response(:ocr_url_failed)
    end
  end

  defp handle_response({:ok, %Req.Response{status: 200, body: json_body}}, _stage) do
    {:ok, json_body}
  end

  defp handle_response({:ok, %Req.Response{} = response}, stage) do
    # handle non 200 status codes
    {:error, {stage, response.body}}
  end

  defp handle_response({:error, reason}, stage) do
    {:error, {stage, reason}}
  end

  @spec ocr_request(String.t()) :: {:ok, map()} | {:error, term()}
  defp ocr_request(document_url) do
    ocr_path = "/ocr"

    payload = %{
      model: @model,
      document: %{
        type: "document_url",
        document_url: document_url
      }
    }

    with {:ok, base_url, api_key} <- mistral_config(:ocr_request_failed) do
      Req.post(base_url <> ocr_path,
        json: payload,
        headers: [{"Authorization", "Bearer #{api_key}"}]
      )
      |> handle_response(:ocr_request_failed)
    end
  end

  defp mistral_config(stage) do
    config = Application.fetch_env!(:zaimu_tomo, :mistral)
    base_url = Keyword.fetch!(config, :base_url)
    api_key = Keyword.get(config, :api_key)

    if is_binary(api_key) and String.trim(api_key) != "" do
      {:ok, base_url, api_key}
    else
      {:error, {stage, "Missing Mistral API key"}}
    end
  end

  defp read_file(filepath, stage) do
    case File.read(filepath) do
      {:ok, contents} -> {:ok, contents}
      {:error, reason} -> {:error, {stage, reason}}
    end
  end
end
