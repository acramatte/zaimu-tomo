defmodule ZaimuTomo.Storage.VerificationTest do
  use ZaimuTomo.DataCase, async: false

  import ZaimuTomo.AccountsFixtures
  import ZaimuTomo.DocumentsFixtures

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
end
