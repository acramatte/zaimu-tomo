defmodule ZaimuTomo.DocumentProcessing.DocumentOCR do
  @moduledoc """
  Handles the sequential workflow of OCR analysis:
  Upload file to Mistral.ai's blob store -> Get URL for the file -> Analyze the text with OCR.
  See Document AI QnA: https://docs.mistral.ai/capabilities/document_ai/document_qna
  """

  alias ZaimuTomo.DocumentProcessing.ExtractedData
  require Logger

  @model "mistral-small-latest"

  @doc """
  Executes the full OCR process for a local file and return the extracted data.

  If any step fails, the function immediately stops and returns the error.

  ## Examples
      iex> DocumentOCR.process("../path/to/my_file.pdf")
      {:ok, %{extracted_data: "..."}}
  """
  @spec process(String.t()) :: {:ok, ExtractedData.t()} | {:error, term()}
  def process(filepath) do
    with {:ok, %{"id" => file_id}} <- upload(filepath),
         {:ok, %{"url" => document_url}} <- get_url(file_id),
         {:ok, res_body} <- chat_completions(document_url),
         {:ok, result} <- extract_data(res_body) do
      Logger.info("✅ OCR Analysis Complete #{filepath}")

      {:ok, result}
    end
  end

  # body is the full JSON map from Mistral
  defp extract_data(body) do
    with %{"choices" => [%{"message" => %{"content" => raw_string}} | _]} <- body,
         {:ok, decoded_map} <- Jason.decode(raw_string),
         {:ok, extracted_data} <-
           decoded_map
           |> ExtractedData.changeset()
           |> Ecto.Changeset.apply_action(:parse) do
      {:ok, extracted_data}
    else
      # 'body' doesn't have the expected Mistral structure
      %{} ->
        {:error, :unexpected_api_structure}

      {:error, %Jason.DecodeError{}} ->
        {:error, :invalid_json_from_llm}

      {:error, %Ecto.Changeset{} = cs} ->
        {:error, {:validation_failed, changeset_errors_to_string(cs)}}

      # Safety net: ensures we never return a raw string
      other ->
        {:error, {:internal_processing_error, other}}
    end
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

  @spec chat_completions(String.t()) :: {:ok, map()} | {:error, term()}
  def chat_completions(document_url) do
    config = Application.fetch_env!(:zaimu_tomo, :mistral)
    base_url = Keyword.fetch!(config, :base_url)
    api_key = Keyword.fetch!(config, :api_key)
    chat_completion_path = "/chat/completions"

    payload = %{
      messages: [
        %{
          role: "user",
          content: [
            %{
              type: "text",
              text:
                "the content received by the user is an invoice. Extract the total amount to pay and the description"
            },
            %{
              type: "document_url",
              document_url: document_url
            }
          ]
        }
      ],
      response_format: %{
        type: "json_schema",
        json_schema: %{
          "schema" => %{
            "title" => "Invoice",
            "type" => "object",
            "properties" => %{
              "amount_to_pay_cents" => %{
                "title" => "Amount to Pay (in cents)",
                "type" => "integer",
                "minimum" => 0
              },
              "invoice_date" => %{
                "title" => "Invoice Date",
                "type" => "string"
              },
              "invoice_number" => %{
                "title" => "Invoice Number",
                "type" => "string"
              },
              "currency" => %{
                "title" => "Currency",
                "type" => "string"
              },
              "reason_for_payment" => %{
                "title" => "Reason for Payment",
                "type" => "string"
              },
              "issuer" => %{
                "title" => "Issuer",
                "description" => "Company or person issuing the invoice",
                "type" => "string"
              }
            },
            "required" => [
              "amount_to_pay_cents",
              "invoice_date",
              "currency",
              "reason_for_payment",
              "issuer"
            ],
            "additionalProperties" => false
          },
          "name" => "invoice",
          "strict" => true
        }
      },
      model: @model
    }

    Req.post(base_url <> chat_completion_path,
      json: payload,
      headers: [{"Authorization", "Bearer #{api_key}"}]
    )
    |> handle_response()
  end

  defp changeset_errors_to_string(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {msg, opts} ->
      Regex.replace(~r"%\{(\w+)\}", msg, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
  end
end
