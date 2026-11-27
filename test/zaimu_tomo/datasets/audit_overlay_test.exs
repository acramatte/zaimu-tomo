defmodule ZaimuTomo.Datasets.AuditOverlayTest do
  use ExUnit.Case, async: true

  alias ZaimuTomo.Datasets.AuditOverlay

  @tag :tmp_dir
  test "returns an empty map when path is nil" do
    assert {:ok, %{}} = AuditOverlay.load(nil)
  end

  @tag :tmp_dir
  test "parses valid JSONL overlay entries and ignores blank lines", %{tmp_dir: tmp_dir} do
    path = Path.join(tmp_dir, "audit_overlay.jsonl")

    File.write!(
      path,
      """
      {"document_id": 42, "ocr_faithful": false, "error_tags": ["ocr_misread"], "extracted_faithful": {"amount_to_pay_cents": 10810}}

      {"document_id": 99, "ocr_faithful": true, "quality": "gold_verified"}
      """
    )

    assert {:ok, overlay} = AuditOverlay.load(path)

    assert overlay[42] == %{
             "ocr_faithful" => false,
             "error_tags" => ["ocr_misread"],
             "extracted_faithful" => %{"amount_to_pay_cents" => 10_810},
             "quality" => "gold_audited"
           }

    assert overlay[99] == %{
             "ocr_faithful" => true,
             "error_tags" => [],
             "extracted_faithful" => nil,
             "quality" => "gold_verified"
           }
  end

  @tag :tmp_dir
  test "rejects malformed lines and unknown extracted_faithful keys with line numbers", %{
    tmp_dir: tmp_dir
  } do
    path = Path.join(tmp_dir, "bad.jsonl")

    File.write!(
      path,
      """
      {"document_id": 1, "ocr_faithful": true}
      {"document_id": 2, "extracted_faithful": {"bogus_field": 123}}
      """
    )

    assert {:error, {:invalid_audit_overlay, 2, msg}} = AuditOverlay.load(path)
    assert msg =~ "bogus_field"

    assert {:error, {:audit_overlay_read_failed, _, :enoent}} =
             AuditOverlay.load(Path.join(tmp_dir, "missing.jsonl"))
  end
end
