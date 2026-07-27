defmodule ZaimuTomo.DocumentProcessing.DocumentOCRTest do
  use ZaimuTomo.DataCase
  alias ZaimuTomo.DocumentProcessing.DocumentOCR

  describe "extract_markdown/1" do
    test "successfully extracts markdown from a valid Mistral OCR response" do
      mock_body = %{
        "pages" => [
          %{"index" => 0, "markdown" => "# Invoice\nAmount: 1500"},
          %{"index" => 1, "markdown" => "Page 2 content"}
        ]
      }

      assert {:ok, markdown, raw_map} = DocumentOCR.extract_markdown(mock_body)

      assert markdown == "# Invoice\nAmount: 1500\n\nPage 2 content"
      assert raw_map == mock_body
    end

    test "returns error for malformed API structure" do
      bad_body = %{"something" => "unexpected"}

      assert {:error, :unexpected_api_structure} = DocumentOCR.extract_markdown(bad_body)
    end
  end

  describe "process/1" do
    test "returns a stage-aware error when the Mistral API key is missing" do
      previous_config = Application.fetch_env!(:zaimu_tomo, :mistral)
      temp_path = Path.join(System.tmp_dir!(), "missing-mistral-key-test.pdf")
      File.write!(temp_path, "fake pdf")

      try do
        Application.put_env(
          :zaimu_tomo,
          :mistral,
          Keyword.put(previous_config, :api_key, nil)
        )

        assert {:error, {:ocr_upload_failed, "Missing Mistral API key"}} =
                 DocumentOCR.process(temp_path)
      after
        Application.put_env(:zaimu_tomo, :mistral, previous_config)
        File.rm(temp_path)
      end
    end
  end
end
