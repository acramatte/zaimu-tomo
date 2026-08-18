defmodule ZaimuTomoWeb.JournalEntryLiveTest do
  use ZaimuTomoWeb.ConnCase

  import Ecto.Query, warn: false
  import Phoenix.LiveViewTest
  import ZaimuTomo.ReviewFixtures

  alias ZaimuTomo.Accounting
  alias ZaimuTomo.Accounting.JournalEntry
  alias ZaimuTomo.Documents.Document
  alias ZaimuTomo.Repo

  setup :register_and_log_in_user

  describe "Show" do
    test "posts an entry with category and need classification", %{
      conn: conn,
      scope: scope,
      user: user
    } do
      entry = create_entry(scope, user)

      {:ok, live, _html} = live(conn, ~p"/journal_entries/#{entry}")

      assert has_element?(live, "#journal-entry-posting-form")

      live
      |> form("#journal-entry-posting-form", %{
        "posting" => %{
          "category" => "Utilities",
          "need_or_want" => "need",
          "notes" => "Electricity bill"
        }
      })
      |> render_submit()

      updated = Accounting.get_journal_entry(entry.id, user.id) |> elem(1)

      assert updated.category == "Utilities"
      assert updated.need_or_want == "need"
      assert updated.notes == "Electricity bill"
      assert render(live) =~ "Need"
    end

    test "requires need or want before posting", %{conn: conn, scope: scope} do
      entry = create_entry(scope, scope.user)

      {:ok, live, _html} = live(conn, ~p"/journal_entries/#{entry}")

      html =
        live
        |> form("#journal-entry-posting-form", %{
          "posting" => %{
            "category" => "Utilities",
            "need_or_want" => "",
            "notes" => ""
          }
        })
        |> render_submit()

      assert html =~ "can&#39;t be blank"
    end

    test "lists need or want classification on the index", %{conn: conn, scope: scope, user: user} do
      entry = create_entry(scope, user)
      {:ok, _entry} = Accounting.post_entry(entry, user.id, "Subscriptions", "want")

      {:ok, _live, html} = live(conn, ~p"/journal_entries")

      assert html =~ "Subscriptions"
      assert html =~ "Want"
      assert html =~ "EUR 42.00"
      refute html =~ "€42.00"
    end

    test "displays the invoice amount with the journal entry currency", %{
      conn: conn,
      scope: scope,
      user: user
    } do
      entry =
        create_entry(scope, user)
        |> Ecto.Changeset.change(amount_cents: 12_345, currency: "USD")
        |> Repo.update!()

      {:ok, _live, html} = live(conn, ~p"/journal_entries/#{entry}")

      assert html =~ "USD 123.45"
      refute html =~ "€123.45"
    end
  end

  describe "Index" do
    test "orders the feed newest-first by last activity", %{conn: conn, scope: scope, user: user} do
      e1 = create_entry(scope, user)
      e2 = create_entry(scope, user)
      e3 = create_entry(scope, user)

      base = ~U[2026-06-01 00:00:00Z]
      set_timestamps(e1, inserted_at: base, updated_at: ~U[2026-06-01 10:00:00Z])
      set_timestamps(e2, inserted_at: base, updated_at: ~U[2026-06-02 10:00:00Z])
      set_timestamps(e3, inserted_at: base, updated_at: ~U[2026-06-03 10:00:00Z])

      {:ok, _live, html} = live(conn, ~p"/journal_entries")

      ids =
        Regex.scan(~r/id="entries-(\d+)"/, html)
        |> Enum.map(fn [_full, id] -> id end)

      assert ids == [Integer.to_string(e3.id), Integer.to_string(e2.id), Integer.to_string(e1.id)]
    end
  end

  defp create_entry(scope, user) do
    document =
      Repo.insert!(%Document{
        filename: "invoice.pdf",
        filepath: "/tmp/invoice.pdf",
        user_id: scope.user.id
      })

    extracted_content = extracted_content_fixture(document, user)
    decision = approved_review_fixture(extracted_content, user)
    {:ok, entry} = Accounting.create_from_decision(decision)
    entry
  end

  defp set_timestamps(entry, opts) do
    from(je in JournalEntry, where: je.id == ^entry.id)
    |> Repo.update_all(set: opts)
  end
end
