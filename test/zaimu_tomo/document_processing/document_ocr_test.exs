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
end
