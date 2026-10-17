defmodule ZaimuTomo.ReviewTest do
  use ZaimuTomo.DataCase, async: false

  alias ZaimuTomo.Review
  alias ZaimuTomo.Accounting
  alias ZaimuTomo.Repo
  alias ZaimuTomo.Review.ReviewDecision
  alias ZaimuTomo.Review.EventLog
  alias ZaimuTomo.Accounting.JournalEntry
  alias ZaimuTomo.Accounting.TaxDeductionClaim
  alias ZaimuTomo.DocumentProcessing.ExtractedData
  alias ZaimuTomo.DocumentProcessing.ExtractedContent.ExtractedContent
  alias ZaimuTomo.Documents.Document
  import ZaimuTomo.AccountsFixtures, only: [user_fixture: 0, user_scope_fixture: 1]

  import ZaimuTomo.DocumentsFixtures, only: [document_fixture: 1, document_fixture: 2]

  import ZaimuTomo.ReviewFixtures,
    only: [
      approved_review_fixture: 2,
      extracted_content_fixture: 2,
      extracted_content_fixture: 3,
      pending_review_fixture: 1
    ]

  setup do
    original_config = Application.get_env(:zaimu_tomo, :langfuse)
    Application.put_env(:zaimu_tomo, :langfuse, enabled: false, environment: "test")

    on_exit(fn ->
      if original_config do
        Application.put_env(:zaimu_tomo, :langfuse, original_config)
      else
        Application.delete_env(:zaimu_tomo, :langfuse)
      end
    end)
  end

  describe "submit_extraction_feedback/4" do
    test "returns an error when the extracted content does not belong to the user" do
      user = user_fixture()
      scope = user_scope_fixture(user)
      document = document_fixture(scope)
      content = extracted_content_fixture(document, user, %{trace_id: "trace-abc"})
      other_user = user_fixture()

      assert {:error, "Extracted content not found or not owned by user"} =
               Review.submit_extraction_feedback(content.id, other_user.id, 0, "wrong amount")
    end

    test "returns an error when no Langfuse trace was recorded for the extraction" do
      user = user_fixture()
      scope = user_scope_fixture(user)
      document = document_fixture(scope)
      content = extracted_content_fixture(document, user)

      assert {:error, "No Langfuse trace recorded for this extraction"} =
               Review.submit_extraction_feedback(content.id, user.id, 1)
    end

    test "records a score on the extraction's Langfuse trace" do
      user = user_fixture()
      scope = user_scope_fixture(user)
      document = document_fixture(scope)
      content = extracted_content_fixture(document, user, %{trace_id: "trace-abc"})
      parent = self()

      Application.put_env(:zaimu_tomo, :langfuse,
        enabled: true,
        environment: "test",
        score_sender: fn payload ->
          send(parent, {:score_payload, payload})
          {:ok, %{status: 200}}
        end
      )

      assert :ok =
               Review.submit_extraction_feedback(content.id, user.id, 0, "amount was wrong")

      assert_received {:score_payload, payload}
      assert payload.traceId == "trace-abc"
      assert payload.value == 0
      assert payload.comment == "amount was wrong"
    end
  end

  describe "pending_review_count/1" do
    test "counts only pending reviews owned by the scope" do
      user = user_fixture()
      scope = user_scope_fixture(user)

      pending_document = document_fixture(scope)
      pending_document |> extracted_content_fixture(user) |> pending_review_fixture()

      approved_document = document_fixture(scope)
      approved_document |> extracted_content_fixture(user) |> approved_review_fixture(user)

      other_user = user_fixture()
      other_scope = user_scope_fixture(other_user)
      other_document = document_fixture(other_scope)
      other_document |> extracted_content_fixture(other_user) |> pending_review_fixture()

      assert Review.pending_review_count(scope) == 1
    end
  end

  describe "reject_invoice/4" do
    test "requires and persists a rejection reason" do
      user = user_fixture()
      scope = user_scope_fixture(user)
      document = document_fixture(scope)
      extracted_content = extracted_content_fixture(document, user)
      {:ok, _} = Review.create_initial_decision(extracted_content)

      assert {:error, changeset} = Review.reject_invoice(extracted_content.id, user.id, "")
      assert %{rejection_reason: ["can't be blank"]} = errors_on(changeset)

      assert {:ok, decision} =
               Review.reject_invoice(extracted_content.id, user.id, "Duplicate invoice")

      assert decision.review_status == "rejected"
      assert decision.rejection_reason == "Duplicate invoice"
    end
  end

  describe "approve_invoice/3 with a duplicate invoice" do
    test "blocks the posting and rolls the review back to pending" do
      user = user_fixture()
      scope = user_scope_fixture(user)

      original = create_approved_invoice(scope, user, "INV-777")

      duplicate = create_pending_invoice(scope, user, "INV-777")

      assert {:error, :duplicate_invoice} =
               Review.approve_invoice(duplicate.extracted_content_id, user.id)

      # The review stays pending and no journal entry was created for it.
      assert pending_review?(duplicate.id)
      refute entry_exists_for?(duplicate.id)

      # The original entry is untouched.
      assert entry_exists_for?(original.id)
    end
  end

  describe "amend_invoice/4 with a duplicate invoice" do
    test "blocks the amended posting and rolls the review back to pending" do
      user = user_fixture()
      scope = user_scope_fixture(user)

      _original = create_approved_invoice(scope, user, "INV-777")

      document = document_fixture(scope)
      extracted_content = extracted_content_fixture(document, user)
      {:ok, _} = Review.create_initial_decision(extracted_content)

      amended_data = %{
        "issuer" => "Acme Corp",
        "invoice_number" => "INV-777",
        "invoice_date" => "2026-06-09",
        "amount_to_pay_cents" => "4200",
        "currency" => "CHF",
        "reason_for_payment" => "Corrected data"
      }

      assert {:error, :duplicate_invoice} =
               Review.amend_invoice(extracted_content.id, user.id, amended_data)

      pending = Repo.get_by!(ReviewDecision, extracted_content_id: extracted_content.id)
      assert pending.review_status == "pending"
      assert pending.decision_data == nil
    end
  end

  describe "exact-file fingerprints at posting" do
    @digest String.duplicate("c", 64)

    @rent %{
      amount_to_pay_cents: 150_000,
      invoice_date: "2026-05-01",
      invoice_number: nil,
      currency: "CHF",
      reason_for_payment: "Rent",
      issuer: "Landlord AG"
    }

    test "approval and amendment copy the source document fingerprint to the entry" do
      user = user_fixture()
      scope = user_scope_fixture(user)

      approved = pending_file_invoice(scope, user, @digest, @rent)
      assert {:ok, decision} = Review.approve_invoice(approved.extracted_content_id, user.id)
      assert {:ok, entry} = Accounting.get_journal_entry_for_decision(decision.id)
      assert entry.source_document_sha256 == @digest
      refute entry.source_file_reuse_confirmed

      other_digest = String.duplicate("d", 64)
      amended = pending_file_invoice(scope, user, other_digest, %{@rent | issuer: "Other"})

      assert {:ok, decision} =
               Review.amend_invoice(amended.extracted_content_id, user.id, %{
                 "issuer" => "Other",
                 "invoice_date" => "2026-06-01",
                 "amount_to_pay_cents" => "1",
                 "currency" => "CHF",
                 "reason_for_payment" => "Amended"
               })

      assert {:ok, entry} = Accounting.get_journal_entry_for_decision(decision.id)
      assert entry.source_document_sha256 == other_digest
    end

    test "an unconfirmed same-file approval rolls back the review, entry, claim, and event" do
      user = user_fixture()
      scope = user_scope_fixture(user)
      _original = posted_file_invoice(scope, user, @digest, @rent)

      # Different extracted facts: only the fingerprint index can reject it.
      duplicate =
        pending_file_invoice(scope, user, @digest, %{
          @rent
          | issuer: "Misread Landlord",
            invoice_number: "OCR-7",
            amount_to_pay_cents: 1
        })

      counts = ledger_counts(user)

      assert {:error, :duplicate_invoice} =
               Review.approve_invoice(duplicate.extracted_content_id, user.id)

      assert pending_review?(duplicate.id)
      refute entry_exists_for?(duplicate.id)
      assert ledger_counts(user) == counts
    end

    test "an unconfirmed same-file amendment rolls back too" do
      user = user_fixture()
      scope = user_scope_fixture(user)
      _original = posted_file_invoice(scope, user, @digest, @rent)
      duplicate = pending_file_invoice(scope, user, @digest, %{@rent | issuer: "Misread"})
      counts = ledger_counts(user)

      assert {:error, :duplicate_invoice} =
               Review.amend_invoice(duplicate.extracted_content_id, user.id, %{
                 "issuer" => "Someone Else",
                 "invoice_date" => "2026-09-01",
                 "amount_to_pay_cents" => "5",
                 "currency" => "CHF",
                 "reason_for_payment" => "Amended"
               })

      pending = Repo.get!(ReviewDecision, duplicate.id)
      assert pending.review_status == "pending"
      assert pending.decision_data == nil
      assert ledger_counts(user) == counts
    end

    test "a confirmed reuse posts with the flag and logs the matched entry" do
      user = user_fixture()
      scope = user_scope_fixture(user)
      original = posted_file_invoice(scope, user, @digest, @rent)

      next_month =
        pending_file_invoice(scope, user, @digest, %{@rent | invoice_date: "2026-06-01"})

      assert {:ok, decision} =
               Review.approve_invoice(next_month.extracted_content_id, user.id, nil,
                 confirm_file_reuse: true
               )

      assert {:ok, entry} = Accounting.get_journal_entry_for_decision(decision.id)
      assert entry.source_document_sha256 == @digest
      assert entry.source_file_reuse_confirmed

      assert [event] =
               Repo.all(
                 from e in EventLog,
                   where: e.event_type == "source_file_reuse_confirmed",
                   where: e.invoice_id == ^to_string(next_month.extracted_content_id)
               )

      assert event.user_id == user.id
      assert event.metadata["journal_entry_id"] == entry.id
      assert event.metadata["matched_journal_entry_id"] == original.journal_entry_id
      assert event.metadata["matched_journal_entry_ids"] == [original.journal_entry_id]

      # A third posting of the same bytes needs its own confirmation.
      third = pending_file_invoice(scope, user, @digest, %{@rent | invoice_date: "2026-07-01"})

      assert {:error, :duplicate_invoice} =
               Review.approve_invoice(third.extracted_content_id, user.id)

      assert {:ok, _} =
               Review.approve_invoice(third.extracted_content_id, user.id, nil,
                 confirm_file_reuse: true
               )
    end

    test "a hard block cannot be confirmed as a reuse" do
      user = user_fixture()
      scope = user_scope_fixture(user)
      _original = posted_file_invoice(scope, user, @digest, @rent)
      same_facts = pending_file_invoice(scope, user, @digest, @rent)
      counts = ledger_counts(user)

      assert %{verdict: :same_file_blocked} =
               Review.duplicate_check(
                 Repo.get!(ReviewDecision, same_facts.id),
                 struct(ExtractedData, @rent)
               )

      assert {:error, :duplicate_invoice} =
               Review.approve_invoice(same_facts.extracted_content_id, user.id, nil,
                 confirm_file_reuse: true
               )

      assert pending_review?(same_facts.id)
      assert ledger_counts(user) == counts
    end

    test "a reuse confirmation without a file match is refused, not applied" do
      user = user_fixture()
      scope = user_scope_fixture(user)
      lone = pending_file_invoice(scope, user, @digest, @rent)

      assert {:error, :file_reuse_not_applicable} =
               Review.approve_invoice(lone.extracted_content_id, user.id, nil,
                 confirm_file_reuse: true
               )

      assert pending_review?(lone.id)
      refute entry_exists_for?(lone.id)
    end

    test "amending the date of a reused slip turns a hard block into a confirmable reuse" do
      user = user_fixture()
      scope = user_scope_fixture(user)
      _original = posted_file_invoice(scope, user, @digest, @rent)
      reused = pending_file_invoice(scope, user, @digest, @rent)

      amended = %{
        "issuer" => "Landlord AG",
        "invoice_date" => "2026-06-01",
        "amount_to_pay_cents" => "150000",
        "currency" => "CHF",
        "reason_for_payment" => "Rent June"
      }

      assert {:ok, decision} =
               Review.amend_invoice(reused.extracted_content_id, user.id, amended, nil,
                 confirm_file_reuse: true
               )

      assert {:ok, %{source_file_reuse_confirmed: true}} =
               Accounting.get_journal_entry_for_decision(decision.id)
    end

    test "a re-extracted posted document is blocked as the same file" do
      user = user_fixture()
      scope = user_scope_fixture(user)
      document = document_fixture(scope, %{content_sha256: @digest})

      first = extracted_content_fixture(document, user, %{extracted_data: @rent})
      {:ok, _} = Review.create_initial_decision(first)
      {:ok, _} = Review.approve_invoice(first.id, user.id)

      again = extracted_content_fixture(document, user, %{extracted_data: @rent})
      {:ok, decision} = Review.create_initial_decision(again)

      assert %{verdict: :same_file_blocked, candidates: [%{reason: :same_file}]} =
               Review.duplicate_check(decision, ReviewDecision.effective_data(decision))

      assert {:error, :duplicate_invoice} = Review.approve_invoice(again.id, user.id)
      assert pending_review?(decision.id)
    end

    test "another user's posting of the same bytes never blocks" do
      user = user_fixture()
      other_user = user_fixture()
      _theirs = posted_file_invoice(user_scope_fixture(other_user), other_user, @digest, @rent)
      mine = pending_file_invoice(user_scope_fixture(user), user, @digest, @rent)

      decision = Repo.get!(ReviewDecision, mine.id)

      assert %{verdict: :none, candidates: []} =
               Review.duplicate_check(decision, ReviewDecision.effective_data(decision))

      assert {:ok, _} = Review.approve_invoice(mine.extracted_content_id, user.id)
    end
  end

  describe "concurrent identical postings" do
    # Runs outside the SQL sandbox so the two approvals use separate
    # connections and real transactions; the rows are deleted afterwards.
    test "commit at most one journal entry for the same file" do
      digest = String.duplicate("e", 64)

      Ecto.Adapters.SQL.Sandbox.unboxed_run(Repo, fn ->
        user = user_fixture()

        try do
          scope = user_scope_fixture(user)
          a = pending_file_invoice(scope, user, digest, %{@rent | issuer: "Reader A"})
          b = pending_file_invoice(scope, user, digest, %{@rent | issuer: "Reader B"})
          parent = self()

          tasks =
            for pending <- [a, b] do
              Task.async(fn ->
                Ecto.Adapters.SQL.Sandbox.unboxed_run(Repo, fn ->
                  send(parent, {:ready, self()})

                  receive do
                    :go -> Review.approve_invoice(pending.extracted_content_id, user.id)
                  end
                end)
              end)
            end

          for _ <- tasks, do: assert_receive({:ready, _pid}, 5_000)
          for task <- tasks, do: send(task.pid, :go)
          results = Task.await_many(tasks, 10_000)

          assert Enum.count(results, &match?({:ok, _}, &1)) == 1
          assert Enum.count(results, &(&1 == {:error, :duplicate_invoice})) == 1

          assert Repo.aggregate(
                   from(je in JournalEntry, where: je.user_id == ^user.id),
                   :count
                 ) == 1
        after
          delete_user_data!(user)
        end
      end)
    end
  end

  defp pending_file_invoice(scope, user, digest, extracted_data) do
    document = document_fixture(scope, %{content_sha256: digest})
    content = extracted_content_fixture(document, user, %{extracted_data: extracted_data})
    {:ok, decision} = Review.create_initial_decision(content)
    %{id: decision.id, extracted_content_id: content.id}
  end

  defp posted_file_invoice(scope, user, digest, extracted_data) do
    pending = pending_file_invoice(scope, user, digest, extracted_data)
    {:ok, decision} = Review.approve_invoice(pending.extracted_content_id, user.id)
    {:ok, entry} = Accounting.get_journal_entry_for_decision(decision.id)
    Map.put(pending, :journal_entry_id, entry.id)
  end

  defp ledger_counts(user) do
    for schema <- [JournalEntry, TaxDeductionClaim, EventLog], into: %{} do
      {schema, Repo.aggregate(from(r in schema, where: r.user_id == ^user.id), :count)}
    end
  end

  defp delete_user_data!(user) do
    for schema <- [
          TaxDeductionClaim,
          EventLog,
          JournalEntry,
          ReviewDecision,
          ExtractedContent,
          Document
        ] do
      Repo.delete_all(from r in schema, where: r.user_id == ^user.id)
    end

    Repo.delete!(user)
  end

  defp create_approved_invoice(scope, user, invoice_number) do
    document = document_fixture(scope)

    extracted_content =
      extracted_content_fixture(document, user, %{
        extracted_data: %{
          amount_to_pay_cents: 4200,
          invoice_date: "2026-06-09",
          invoice_number: invoice_number,
          currency: "CHF",
          reason_for_payment: "Office supplies",
          issuer: "Acme Corp"
        }
      })

    {:ok, _} = Review.create_initial_decision(extracted_content)
    {:ok, decision} = Review.approve_invoice(extracted_content.id, user.id)

    %{
      id: decision.id,
      extracted_content_id: extracted_content.id
    }
  end

  defp create_pending_invoice(scope, user, invoice_number) do
    document = document_fixture(scope)

    extracted_content =
      extracted_content_fixture(document, user, %{
        extracted_data: %{
          amount_to_pay_cents: 4200,
          invoice_date: "2026-06-09",
          invoice_number: invoice_number,
          currency: "CHF",
          reason_for_payment: "Same invoice uploaded twice",
          issuer: "Acme Corp"
        }
      })

    {:ok, decision} = Review.create_initial_decision(extracted_content)

    %{
      id: decision.id,
      extracted_content_id: extracted_content.id
    }
  end

  defp pending_review?(review_decision_id) do
    decision = Repo.get!(ReviewDecision, review_decision_id)
    decision.review_status == "pending"
  end

  defp entry_exists_for?(review_decision_id) do
    match?({:ok, _}, Accounting.get_journal_entry_for_decision(review_decision_id))
  end
end
