defmodule ZaimuTomo.Storage.VerificationTest do
  use ZaimuTomo.DataCase, async: false

  import ZaimuTomo.AccountsFixtures
  import ZaimuTomo.DocumentsFixtures
  import ZaimuTomo.FinancialAccountsFixtures
  import ZaimuTomo.StatementsFixtures

  alias ZaimuTomo.Storage
  alias ZaimuTomo.Storage.Memory
  alias ZaimuTomo.Storage.Verification

  setup do
    Memory.reset()
    on_exit(&Memory.reset/0)

    %{scope: user_scope_fixture()}
  end

  test "reports present and missing document objects", %{scope: scope} do
    present_key = "documents/present.pdf"
    missing_key = "documents/missing.pdf"

    document_fixture(scope, %{filename: "present.pdf", object_key: present_key})
    document_fixture(scope, %{filename: "missing.pdf", object_key: missing_key})
    assert {:ok, ^present_key} = Storage.put_object(present_key, "stored bytes")

    assert {:error, summary} = Verification.verify()
    assert summary.present == 1
    assert summary.missing == [missing_key]
    assert summary.failures == []
    assert Verification.format_summary(summary) =~ "Missing object: #{missing_key}"
  end

  test "succeeds when every document object exists", %{scope: scope} do
    object_key = "documents/verified.pdf"
    document_fixture(scope, %{filename: "verified.pdf", object_key: object_key})
    assert {:ok, ^object_key} = Storage.put_object(object_key, "stored bytes")

    assert {:ok, %{present: 1, missing: [], failures: []}} = Verification.verify()
  end

  test "verifies statement objects alongside document objects", %{scope: scope} do
    document_key = "documents/verified.pdf"
    document_fixture(scope, %{filename: "verified.pdf", object_key: document_key})
    assert {:ok, ^document_key} = Storage.put_object(document_key, "stored bytes")

    account = financial_account_fixture(scope)
    statement = statement_fixture(scope, account)

    assert {:ok, %{present: 2, missing: [], failures: []}} = Verification.verify()

    assert :ok = Storage.delete_object(statement.object_key)

    assert {:error, summary} = Verification.verify()
    assert summary.present == 1
    assert summary.missing == [statement.object_key]
    assert summary.failures == []
    assert Verification.format_summary(summary) =~ "Missing object: #{statement.object_key}"
  end
end
