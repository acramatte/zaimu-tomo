defmodule ZaimuTomo.DocumentProcessing.ExtractedContentTest do
  use ZaimuTomo.DataCase, async: true

  alias ZaimuTomo.DocumentProcessing.ExtractedContentContext
  alias ZaimuTomo.DocumentProcessing.ExtractedContent.ExtractedContent
  import ZaimuTomo.AccountsFixtures, only: [user_scope_fixture: 0, user_fixture: 0]
  import ZaimuTomo.DocumentsFixtures

  describe "create_extracted_content/1" do
    test "creates extracted content with valid attributes" do
      document = fixture(:document)
      document_id = document.id

      extracted_data_attrs = %{
        amount_to_pay_cents: 1000,
        invoice_date: "2024-01-15",
        invoice_number: "INV-001",
        currency: "USD",
        reason_for_payment: "Test payment",
        issuer: "Test Issuer"
      }
      {:ok, extracted_data} = ZaimuTomo.DocumentProcessing.ExtractedData.changeset(extracted_data_attrs)
      |> Ecto.Changeset.apply_action(:insert)

      attrs = %{
        document_id: document_id,
        user_id: user_fixture().id,
        extracted_data: Map.from_struct(extracted_data),
        status: "success"
      }

      assert {:ok, %ExtractedContent{} = content} = ExtractedContentContext.create_extracted_content(attrs)
      assert content.document_id == document_id
      assert content.status == "success"
    end

    test "rejects invalid status" do
      document = fixture(:document)
      document_id = document.id

      extracted_data_attrs = %{
        amount_to_pay_cents: 1000,
        invoice_date: "2024-01-15",
        invoice_number: "INV-001",
        currency: "USD",
        reason_for_payment: "Test payment",
        issuer: "Test Issuer"
      }
      {:ok, extracted_data} = ZaimuTomo.DocumentProcessing.ExtractedData.changeset(extracted_data_attrs)
      |> Ecto.Changeset.apply_action(:insert)

      attrs = %{
        document_id: document_id,
        user_id: user_fixture().id,
        extracted_data: Map.from_struct(extracted_data),
        status: "invalid_status"
      }

      assert {:error, changeset} = ExtractedContentContext.create_extracted_content(attrs)
      assert changeset.errors[:status] == {"is invalid", [validation: :inclusion, enum: ["success", "failed"]]}
    end

    test "creates extracted content successfully" do
      document = fixture(:document)
      document_id = document.id

      extracted_data_attrs = %{
        amount_to_pay_cents: 1000,
        invoice_date: "2024-01-15",
        invoice_number: "INV-001",
        currency: "USD",
        reason_for_payment: "Test payment",
        issuer: "Test Issuer"
      }
      {:ok, extracted_data} = ZaimuTomo.DocumentProcessing.ExtractedData.changeset(extracted_data_attrs)
      |> Ecto.Changeset.apply_action(:insert)

      attrs = %{
        document_id: document_id,
        user_id: user_fixture().id,
        extracted_data: Map.from_struct(extracted_data),
        status: "success"
      }

      assert {:ok, %ExtractedContent{} = content} = ExtractedContentContext.create_extracted_content(attrs)
      assert content.status == "success"
    end
  end

  describe "get_by_document/1" do
    test "retrieves extracted content for a document" do
      document = fixture(:document)
      document_id = document.id
      content = extracted_content_fixture(document_id)

      results = ExtractedContentContext.get_by_document(document_id)
      assert length(results) == 1
      assert hd(results).id == content.id
    end
  end

  describe "get_latest_by_document/1" do
    test "gets the latest extraction for a document" do
      document = fixture(:document)
      document_id = document.id

      # Create old content with an explicit past timestamp
      old_extracted_data = %{
        amount_to_pay_cents: 1000,
        invoice_date: "2024-01-15",
        invoice_number: "INV-001",
        currency: "USD",
        reason_for_payment: "Old payment",
        issuer: "Old Issuer"
      }
      {:ok, old_data} = ZaimuTomo.DocumentProcessing.ExtractedData.changeset(old_extracted_data)
      |> Ecto.Changeset.apply_action(:insert)

      old_attrs = %{
        document_id: document_id,
        user_id: user_fixture().id,
        extracted_data: Map.from_struct(old_data),
        status: "success"
      }

      # Create new content with current timestamp
      new_extracted_data = %{
        amount_to_pay_cents: 2000,
        invoice_date: "2024-01-16",
        invoice_number: "INV-002",
        currency: "USD",
        reason_for_payment: "New payment",
        issuer: "New Issuer"
      }
      {:ok, new_data} = ZaimuTomo.DocumentProcessing.ExtractedData.changeset(new_extracted_data)
      |> Ecto.Changeset.apply_action(:insert)

      new_attrs = %{
        document_id: document_id,
        user_id: user_fixture().id,
        extracted_data: Map.from_struct(new_data),
        status: "success"
      }

      {:ok, _old_content} = ExtractedContentContext.create_extracted_content(old_attrs)
      :timer.sleep(100)
      {:ok, new_content} = ExtractedContentContext.create_extracted_content(new_attrs)

      latest = ExtractedContentContext.get_latest_by_document(document_id)
      assert latest.id == new_content.id
    end
  end

  describe "list_extracted_content/1" do
    test "lists extracted content with filters" do
      success_document = fixture(:document)
      failed_document = fixture(:document)
      success_content = extracted_content_fixture(success_document.id, %{status: "success"})
      _failed_content = extracted_content_fixture(failed_document.id, %{status: "failed"})

      {results, meta} = ExtractedContentContext.list_extracted_content([status: "success"])
      assert length(results) == 1
      assert hd(results).id == success_content.id
      assert meta[:total_count] >= 1
    end

    test "filters by status" do
      doc1 = fixture(:document)
      doc2 = fixture(:document)
      success_content = extracted_content_fixture(doc1.id, %{status: "success"})
      _failed_content = extracted_content_fixture(doc2.id, %{status: "failed"})

      {results, _meta} = ExtractedContentContext.list_extracted_content([status: "success"])
      assert length(results) == 1
      assert hd(results).id == success_content.id
    end
  end

  defp fixture(:document) do
    scope = user_scope_fixture()
    document_fixture(scope)
  end

  defp extracted_content_fixture(document_id, overrides \\ %{}) do
    extracted_data_attrs = %{
      amount_to_pay_cents: 1000,
      invoice_date: "2024-01-15",
      invoice_number: "INV-001",
      currency: "USD",
      reason_for_payment: "Test payment",
      issuer: "Test Issuer"
    }

    {:ok, extracted_data} = ZaimuTomo.DocumentProcessing.ExtractedData.changeset(extracted_data_attrs)
    |> Ecto.Changeset.apply_action(:insert)

    attrs = %{
      document_id: document_id,
      user_id: user_fixture().id,
      extracted_data: Map.from_struct(extracted_data),
      status: "success",
      analysis: %{"processed_at" => DateTime.utc_now()}
    } |> Map.merge(overrides)

    {:ok, content} = ExtractedContentContext.create_extracted_content(attrs)
    content
  end
end
