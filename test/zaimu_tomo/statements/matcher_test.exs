defmodule ZaimuTomo.Statements.MatcherTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias ZaimuTomo.Statements.Matcher

  @invoice_date ~D[2026-03-01]
  @descriptions ["SBB CFF FFS 1234 Bern", "MIGROS M ZUERICH", "SWISSCOM PAYMENT", "TWINT 0042"]
  @issuers ["SBB", "Migros Genossenschaft", "Swisscom (Schweiz) AG", "Coop", nil]

  defp line(id, days_after_invoice, keys, description \\ "CARD PAYMENT") do
    %{
      id: id,
      date: Date.add(@invoice_date, days_after_invoice),
      keys: keys,
      description: description
    }
  end

  defp entry(id, key, issuer \\ nil, date \\ @invoice_date) do
    %{id: id, date: date, key: key, issuer: issuer}
  end

  describe "match/2 window" do
    test "a line paid 60 days after or 7 days before the invoice matches" do
      key = {4_200, "CHF"}

      assert Matcher.match([line(:late, 60, [key])], [entry(:e, key)]) ==
               %{late: {:e, :amount_only}}

      assert Matcher.match([line(:early, -7, [key])], [entry(:e, key)]) ==
               %{early: {:e, :amount_only}}
    end

    test "a line paid 61 days after or 8 days before the invoice does not match" do
      key = {4_200, "CHF"}

      assert Matcher.match([line(:late, 61, [key]), line(:early, -8, [key])], [entry(:e, key)]) ==
               %{}
    end
  end

  describe "match/2 keys" do
    test "the same cents in another currency do not match" do
      assert Matcher.match([line(:l, 0, [{4_200, "CHF"}])], [entry(:e, {4_200, "EUR"})]) == %{}
    end

    test "a foreign card line matches an entry booked in the original currency" do
      keys =
        Matcher.line_keys(%{
          amount_cents: -9_350,
          currency: "CHF",
          original_amount_cents: -10_000,
          original_currency: "EUR"
        })

      invoice = entry(:e, Matcher.entry_key(%{amount_cents: 10_000, currency: "EUR"}))

      assert Matcher.match([line(:l, 3, keys)], [invoice]) == %{l: {:e, :amount_only}}
    end
  end

  describe "match/2 ranking" do
    test "an entry whose issuer is named beats a closer one that is not" do
      key = {4_200, "CHF"}
      line = line(:l, 30, [key], "SBB CFF FFS 1234 Bern")
      closer = entry(:closer, key, "Migros", Date.add(@invoice_date, 30))
      named = entry(:named, key, "SBB")

      assert Matcher.match([line], [closer, named]) == %{l: {:named, :named}}
    end

    test "among equally named entries the closer date wins" do
      key = {4_200, "CHF"}
      far = entry(:far, key, nil, Date.add(@invoice_date, -10))
      near = entry(:near, key, nil, Date.add(@invoice_date, -2))

      assert Matcher.match([line(:l, 0, [key])], [far, near]) == %{l: {:near, :amount_only}}
    end

    test "a line before its invoice counts three times the distance of one after" do
      key = {4_200, "CHF"}
      line = line(:l, 0, [key])
      paid_after = entry(:paid_after, key, nil, Date.add(@invoice_date, -5))
      paid_before = entry(:paid_before, key, nil, Date.add(@invoice_date, 2))

      assert Matcher.match([line], [paid_after, paid_before]) ==
               %{l: {:paid_after, :amount_only}}
    end

    test "two identical lines and two identical entries pair one-to-one" do
      key = {4_200, "CHF"}
      lines = [line(1, 5, [key], "SBB"), line(2, 5, [key], "SBB")]
      entries = [entry(:a, key, "SBB"), entry(:b, key, "SBB")]

      result = Matcher.match(lines, entries)

      assert Map.keys(result) |> Enum.sort() == [1, 2]
      assert result |> Map.values() |> Enum.sort() == [{:a, :named}, {:b, :named}]
    end
  end

  describe "line_keys/1 and entry_key/1" do
    test "a debit is keyed by its negated amount, plus the original amount when foreign" do
      assert Matcher.line_keys(%{
               amount_cents: -4_200,
               currency: "CHF",
               original_amount_cents: nil,
               original_currency: nil
             }) == [{4_200, "CHF"}]

      assert Matcher.line_keys(%{
               amount_cents: -9_350,
               currency: "CHF",
               original_amount_cents: -10_000,
               original_currency: "EUR"
             }) == [{9_350, "CHF"}, {10_000, "EUR"}]
    end

    test "a credit produces no keys" do
      assert Matcher.line_keys(%{
               amount_cents: 4_200,
               currency: "CHF",
               original_amount_cents: 4_500,
               original_currency: "EUR"
             }) == []
    end

    test "ignores non-negative original amounts and deduplicates identical keys" do
      assert Matcher.line_keys(%{
               amount_cents: -4_200,
               currency: "CHF",
               original_amount_cents: 4_200,
               original_currency: "EUR"
             }) == [{4_200, "CHF"}]

      assert Matcher.line_keys(%{
               amount_cents: -4_200,
               currency: "CHF",
               original_amount_cents: 0,
               original_currency: "EUR"
             }) == [{4_200, "CHF"}]

      assert Matcher.line_keys(%{
               amount_cents: -4_200,
               currency: "CHF",
               original_amount_cents: -4_200,
               original_currency: "CHF"
             }) == [{4_200, "CHF"}]
    end

    test "an entry is keyed by its amount and currency as booked" do
      assert Matcher.entry_key(%{amount_cents: 4_200, currency: "CHF"}) == {4_200, "CHF"}
    end
  end

  describe "match/2 preconditions" do
    test "raises ArgumentError when line ids are duplicated" do
      key = {4_200, "CHF"}

      assert_raise ArgumentError, ~r/duplicate line id/, fn ->
        Matcher.match([line(:dup, 0, [key]), line(:dup, 1, [key])], [entry(:e, key)])
      end
    end

    test "raises ArgumentError when entry ids are duplicated" do
      key = {4_200, "CHF"}

      assert_raise ArgumentError, ~r/duplicate entry id/, fn ->
        Matcher.match([line(:l, 0, [key])], [entry(:dup, key), entry(:dup, key)])
      end
    end

    test "skips lines or entries with nil dates instead of crashing" do
      key = {4_200, "CHF"}
      undated_line = %{id: :l1, date: nil, keys: [key], description: "ACME"}
      undated_entry = %{id: :e1, date: nil, key: key, issuer: "ACME"}

      assert Matcher.match([undated_line], [entry(:e2, key)]) == %{}
      assert Matcher.match([line(:l2, 0, [key])], [undated_entry]) == %{}
    end
  end

  describe "named?/2" do
    test "an issuer word in the description names it, ignoring case, accents and legal forms" do
      assert Matcher.named?("SBB", "SBB CFF FFS 1234 Bern")
      assert Matcher.named?("Migros Genossenschaft", "MIGROS M ZUERICH")
      assert Matcher.named?("Swisscom (Schweiz) AG", "SWISSCOM PAYMENT")
      assert Matcher.named?("Brülé Sàrl", "BRULE LAUSANNE")
      assert Matcher.named?("Digitec Galaxus AG", "galaxus.ch")
      assert Matcher.named?("BP (Switzerland) AG", "BP STATION 1234 BERN")
    end

    test "matches German and Swiss umlauts and ß against both stripped and digraph forms" do
      assert Matcher.named?("Müller GmbH", "MUELLER ZUERICH")
      assert Matcher.named?("Müller GmbH", "MULLER ZURICH")
      assert Matcher.named?("Mueller GmbH", "MÜLLER ZÜRICH")
      assert Matcher.named?("Bäckerei Huber", "BAECKEREI BERN")
      assert Matcher.named?("Zürich Versicherung", "ZUERICH AG")
      assert Matcher.named?("Bahnhofstraße Apotheke", "BAHNHOFSTRASSE 12")
    end

    test "single letters, TLDs, country codes, and connector words do not name an issuer" do
      refute Matcher.named?("Bäckerei M. Huber", "MIGROS M ZUERICH")
      refute Matcher.named?("Café de la Gare", "BOULANGERIE DE LA PLACE")
      refute Matcher.named?("Spotify CH", "galaxus.ch")
      refute Matcher.named?("Acme Com", "shop.example.com")
    end

    test "a word only matches whole, so a prefix of a longer word does not name the issuer" do
      refute Matcher.named?("Coop", "Cooper Lighting")
    end

    test "legal forms and generic words alone never name an issuer" do
      refute Matcher.named?("Swisscom (Schweiz) AG", "AG SCHWEIZ")
      refute Matcher.named?("Müller & Co AG", "CO AG ZUERICH")
    end

    test "a missing or blank issuer or description is never named" do
      refute Matcher.named?(nil, "SBB CFF FFS")
      refute Matcher.named?("", "SBB CFF FFS")
      refute Matcher.named?("  ", "SBB CFF FFS")
      refute Matcher.named?("SBB", nil)
    end
  end

  describe "match/2 properties" do
    property "no line and no entry appears twice, and only input ids appear" do
      check all({lines, entries} <- books()) do
        result = Matcher.match(lines, entries)
        entry_ids = result |> Map.values() |> Enum.map(&elem(&1, 0))

        assert MapSet.subset?(MapSet.new(Map.keys(result)), MapSet.new(lines, & &1.id))
        assert MapSet.subset?(MapSet.new(entry_ids), MapSet.new(entries, & &1.id))
        assert length(entry_ids) == length(Enum.uniq(entry_ids))
      end
    end

    property "the result does not depend on input order" do
      check all({lines, entries} <- books()) do
        assert Matcher.match(Enum.shuffle(lines), Enum.shuffle(entries)) ==
                 Matcher.match(lines, entries)
      end
    end

    property "every pair shares a key, sits in the window, and reports whether it is named" do
      check all({lines, entries} <- books()) do
        lines_by_id = Map.new(lines, &{&1.id, &1})
        entries_by_id = Map.new(entries, &{&1.id, &1})

        for {line_id, {entry_id, confidence}} <- Matcher.match(lines, entries) do
          line = lines_by_id[line_id]
          entry = entries_by_id[entry_id]

          assert eligible?(line, entry)

          assert confidence ==
                   if(Matcher.named?(entry.issuer, line.description),
                     do: :named,
                     else: :amount_only
                   )
        end
      end
    end

    property "an unmatched line has no eligible entry left unmatched" do
      check all({lines, entries} <- books()) do
        result = Matcher.match(lines, entries)
        taken = result |> Map.values() |> MapSet.new(&elem(&1, 0))
        free_lines = Enum.reject(lines, &Map.has_key?(result, &1.id))
        free_entries = Enum.reject(entries, &MapSet.member?(taken, &1.id))

        for line <- free_lines, entry <- free_entries do
          refute eligible?(line, entry)
        end
      end
    end

    property "a lone line and entry with a shared key inside the window always match" do
      check all(
              key <- key(),
              days <- integer(-7..60),
              description <- member_of(@descriptions),
              issuer <- member_of(@issuers)
            ) do
        lone_line = line(:l, days, [key], description)
        lone_entry = entry(:e, key, issuer)

        assert %{l: {:e, _confidence}} = Matcher.match([lone_line], [lone_entry])
      end
    end

    property "closing over amount groups matches any subset identically to a global run" do
      check all(
              {lines, entries} <- books(),
              take_count <- integer(0..length(lines))
            ) do
        subset = Enum.take(lines, take_count)
        global = Matcher.match(lines, entries)

        initial_keys = subset |> Enum.flat_map(& &1.keys) |> MapSet.new()
        closed_keys = close_keys(lines, initial_keys)

        closed_lines =
          Enum.filter(lines, fn l -> Enum.any?(l.keys, &MapSet.member?(closed_keys, &1)) end)

        closed_entries = Enum.filter(entries, &MapSet.member?(closed_keys, &1.key))
        local = Matcher.match(closed_lines, closed_entries)

        for l <- subset do
          assert Map.get(local, l.id) == Map.get(global, l.id)
        end
      end
    end
  end

  defp close_keys(lines, keys) do
    grown =
      lines
      |> Enum.filter(fn l -> Enum.any?(l.keys, &MapSet.member?(keys, &1)) end)
      |> Enum.flat_map(& &1.keys)
      |> MapSet.new()
      |> MapSet.union(keys)

    if MapSet.equal?(grown, keys), do: keys, else: close_keys(lines, grown)
  end

  defp eligible?(line, entry) do
    days = Date.diff(line.date, entry.date)
    entry.key in line.keys and days >= -7 and days <= 60
  end

  # Few amounts, currencies and a narrow date range so keys collide and dates
  # land on both sides of the window edges.
  defp key, do: tuple({member_of([1_000, 2_500, 9_900]), member_of(["CHF", "EUR"])})

  defp statement_date, do: map(integer(-80..80), &Date.add(@invoice_date, &1))

  defp books do
    lines =
      list_of(
        tuple({statement_date(), list_of(key(), max_length: 2), member_of(@descriptions)}),
        max_length: 12
      )

    entries = list_of(tuple({statement_date(), key(), member_of(@issuers)}), max_length: 12)

    map(tuple({lines, entries}), fn {lines, entries} ->
      {
        for(
          {{date, keys, description}, i} <- Enum.with_index(lines),
          do: %{id: i, date: date, keys: keys, description: description}
        ),
        for(
          {{date, key, issuer}, i} <- Enum.with_index(entries),
          do: %{id: {:entry, i}, date: date, key: key, issuer: issuer}
        )
      }
    end)
  end
end
