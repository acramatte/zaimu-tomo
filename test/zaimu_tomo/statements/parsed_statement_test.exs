defmodule ZaimuTomo.Statements.ParsedStatementTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias ZaimuTomo.FinancialAccounts.FinancialAccount
  alias ZaimuTomo.Statements.ParsedStatement

  @account %FinancialAccount{currency: "CHF", account_number: "CH93 0076 2011 6238 5295 7"}

  defp page(attrs) do
    Map.merge(
      %{
        account_ref: nil,
        period_start: nil,
        period_end: nil,
        currency: nil,
        opening_balance_cents: nil,
        closing_balance_cents: nil,
        lines: []
      },
      attrs
    )
  end

  defp header_page(attrs \\ %{}) do
    page(
      Map.merge(
        %{
          period_start: ~D[2026-10-01],
          period_end: ~D[2026-10-31],
          currency: "CHF",
          opening_balance_cents: 0,
          closing_balance_cents: 0
        },
        attrs
      )
    )
  end

  defp line(direction, cents, description \\ "Line") do
    %{
      booking_date: ~D[2026-10-05],
      value_date: nil,
      description: description,
      amount_cents: cents,
      direction: direction,
      original_amount_cents: nil,
      original_currency: nil
    }
  end

  describe "parse_page/1" do
    test "types every field of one page of extractor output" do
      raw = %{
        "account_ref" => " CH93 0076 2011 6238 5295 7 ",
        "period_start" => "2026-10-01",
        "period_end" => "2026-10-31",
        "currency" => " chf ",
        "opening_balance_cents" => -12_000,
        "closing_balance_cents" => nil,
        "lines" => [
          %{
            "booking_date" => "2026-10-03",
            "value_date" => "2026-10-04",
            "description" => "SBB CFF FFS",
            "amount_cents" => 4_200,
            "direction" => "debit",
            "original_amount_cents" => 4_500,
            "original_currency" => "eur"
          }
        ]
      }

      assert {:ok,
              %{
                account_ref: "CH93 0076 2011 6238 5295 7",
                period_start: ~D[2026-10-01],
                period_end: ~D[2026-10-31],
                currency: "CHF",
                opening_balance_cents: -12_000,
                closing_balance_cents: nil,
                lines: [
                  %{
                    booking_date: ~D[2026-10-03],
                    value_date: ~D[2026-10-04],
                    description: "SBB CFF FFS",
                    amount_cents: 4_200,
                    direction: :debit,
                    original_amount_cents: 4_500,
                    original_currency: "EUR"
                  }
                ]
              }} = ParsedStatement.parse_page(raw)
    end

    test "names each invalid field and refuses the page" do
      raw = %{
        "period_start" => "1 Oct 2026",
        "lines" => [
          %{
            "booking_date" => "2026-10-03",
            "description" => "ok",
            "amount_cents" => 1,
            "direction" => "debit"
          },
          %{
            "booking_date" => "2026-10-03",
            "description" => " ",
            "amount_cents" => 1.5,
            "direction" => "out"
          }
        ]
      }

      assert {:error, {:validation_failed, errors}} = ParsedStatement.parse_page(raw)

      assert errors == %{
               "period_start" => "is invalid",
               "lines.1.description" => "is invalid",
               "lines.1.amount_cents" => "is invalid",
               "lines.1.direction" => "is invalid"
             }
    end

    test "ignores the amount's sign, drops zero lines, and keeps a foreign amount only with its currency" do
      raw = %{
        "lines" => [
          %{
            "booking_date" => "2026-10-03",
            "description" => "a",
            "amount_cents" => -700,
            "direction" => "debit",
            "original_amount_cents" => 800
          },
          %{
            "booking_date" => "2026-10-04",
            "description" => "b",
            "amount_cents" => 0,
            "direction" => "credit"
          }
        ]
      }

      assert {:ok,
              %{lines: [%{amount_cents: 700, original_amount_cents: nil, original_currency: nil}]}} =
               ParsedStatement.parse_page(raw)
    end

    test "reads a page without lines as an empty list and refuses a non-list" do
      assert {:ok, %{lines: []}} = ParsedStatement.parse_page(%{})

      assert {:error, {:validation_failed, %{"lines" => _}}} =
               ParsedStatement.parse_page(%{"lines" => "none"})
    end
  end

  describe "from_pages/2" do
    test "takes the header from the first page that prints it and the closing balance from the last" do
      pages = [
        header_page(%{
          account_ref: "CH9300762011623852957",
          opening_balance_cents: 10_000,
          closing_balance_cents: 9_000,
          lines: [line(:debit, 1_000, "first")]
        }),
        page(%{
          opening_balance_cents: 9_000,
          closing_balance_cents: 9_500,
          lines: [line(:credit, 500, "second")]
        })
      ]

      assert {:ok,
              %ParsedStatement{
                account_ref: "CH9300762011623852957",
                period_start: ~D[2026-10-01],
                currency: "CHF",
                opening_cents: 10_000,
                closing_cents: 9_500,
                lines: [
                  %{description: "first", amount_cents: -1_000},
                  %{description: "second", amount_cents: 500}
                ]
              }} = ParsedStatement.from_pages(pages, @account)
    end

    test "fails on a header two pages print differently" do
      for {field, a, b} <- [
            {:currency, "CHF", "EUR"},
            {:period_end, ~D[2026-10-31], ~D[2026-11-30]},
            {:account_ref, "CH93 0076 2011 6238 5295 7", "CH56 0483 5012 3456 7800 9"}
          ] do
        pages = [header_page(%{field => a}), page(%{field => b})]
        assert {:error, :inconsistent_header} = ParsedStatement.from_pages(pages, @account)
      end
    end

    test "treats the same reference printed with other spacing as one value" do
      pages = [
        header_page(%{account_ref: "CH93 0076 2011 6238 5295 7"}),
        page(%{account_ref: "ch9300762011623852957"})
      ]

      assert {:ok, %{account_ref: "CH93 0076 2011 6238 5295 7"}} =
               ParsedStatement.from_pages(pages, @account)
    end

    test "fails when a header fact is missing or the period runs backwards" do
      for missing <- [
            :period_start,
            :period_end,
            :currency,
            :opening_balance_cents,
            :closing_balance_cents
          ] do
        assert {:error, :missing_header} =
                 ParsedStatement.from_pages([header_page(%{missing => nil})], @account)
      end

      assert {:error, :inconsistent_header} =
               ParsedStatement.from_pages(
                 [header_page(%{period_start: ~D[2026-11-01]})],
                 @account
               )
    end

    test "checks the currency and the account reference against the account" do
      assert {:error, :currency_mismatch} =
               ParsedStatement.from_pages([header_page(%{currency: "EUR"})], @account)

      assert {:error, :account_mismatch} =
               ParsedStatement.from_pages(
                 [header_page(%{account_ref: "CH56 0483 5012 3456 7800 9"})],
                 @account
               )

      card = %FinancialAccount{currency: "CHF", account_number: "1234"}

      assert {:ok, _} =
               ParsedStatement.from_pages(
                 [header_page(%{account_ref: "XXXX XXXX XXXX 1234"})],
                 card
               )

      assert {:ok, _} =
               ParsedStatement.from_pages(
                 [header_page(%{account_ref: "XXXX 9999"})],
                 %FinancialAccount{currency: "CHF", account_number: nil}
               )
    end

    test "compares account references right-aligned, with mask characters as wildcards" do
      read = fn ref, number ->
        ParsedStatement.from_pages(
          [header_page(%{account_ref: ref})],
          %FinancialAccount{currency: "CHF", account_number: number}
        )
      end

      assert {:error, :account_mismatch} =
               read.("CH56 0483 5012 3456 5295 7", "CH93 0076 2011 6238 5295 7")

      assert {:ok, _} = read.("CH93 XXXX XXXX XXXX 5295 7", "CH93 0076 2011 6238 5295 7")
      assert {:ok, _} = read.("•••• •••• •••• 1234", "1234")
      assert {:ok, _} = read.("**** 1234", "4111 1111 1111 1234")
      assert {:error, :account_mismatch} = read.("XXXX XXXX XXXX 9234", "4111 1111 1111 1234")
      assert {:error, :account_mismatch} = read.("CH93 0076 2011 6238 5295 7", "1234")
      assert {:ok, _} = read.("XXXX XX57", "CH93 0076 2011 6238 5295 7")
    end

    test "fails on a line dated a year away from the period, and keeps one dated weeks before it" do
      dated = fn date -> %{line(:debit, 1_000) | booking_date: date} end

      year_off = [header_page(%{closing_balance_cents: -1_000, lines: [dated.(~D[2027-10-20])]})]
      assert {:error, :line_outside_period} = ParsedStatement.from_pages(year_off, @account)

      value_off = [
        header_page(%{
          closing_balance_cents: -1_000,
          lines: [%{dated.(~D[2026-10-20]) | value_date: ~D[2025-10-20]}]
        })
      ]

      assert {:error, :line_outside_period} = ParsedStatement.from_pages(value_off, @account)

      early = [header_page(%{closing_balance_cents: -1_000, lines: [dated.(~D[2026-08-01])]})]
      assert {:ok, %ParsedStatement{lines: [_line]}} = ParsedStatement.from_pages(early, @account)
    end

    test "accepts a period with no lines only when the balance did not move" do
      assert {:ok, %{lines: []}} = ParsedStatement.from_pages([header_page()], @account)

      assert {:error, :no_lines} =
               ParsedStatement.from_pages([header_page(%{closing_balance_cents: 1})], @account)
    end

    test "keeps a foreign amount with the line's sign" do
      debit = %{line(:debit, 4_200) | original_amount_cents: 4_500, original_currency: "EUR"}

      assert {:ok, %{lines: [%{amount_cents: -4_200, original: {-4_500, "EUR"}}]}} =
               ParsedStatement.from_pages(
                 [header_page(%{closing_balance_cents: -4_200, lines: [debit]})],
                 @account
               )
    end
  end

  defp line_gen do
    gen all(
          direction <- member_of([:debit, :credit]),
          cents <- positive_integer(),
          description <- string(:alphanumeric, min_length: 1)
        ) do
      line(direction, cents, description)
    end
  end

  property "applies each line's sign exactly once, from its direction" do
    check all(lines <- list_of(line_gen(), min_length: 1)) do
      expected =
        Enum.sum_by(
          lines,
          &if(&1.direction == :credit, do: &1.amount_cents, else: -&1.amount_cents)
        )

      pages = [header_page(%{closing_balance_cents: expected, lines: lines})]

      assert {:ok, parsed} = ParsedStatement.from_pages(pages, @account)

      for {input, output} <- Enum.zip(lines, parsed.lines) do
        assert abs(output.amount_cents) == input.amount_cents
        assert output.amount_cents < 0 == (input.direction == :debit)
      end
    end
  end

  property "keeps every line, in page order, then printed order" do
    check all(page_lines <- list_of(list_of(line_gen()), min_length: 1, max_length: 5)) do
      [first | rest] = Enum.map(page_lines, &page(%{lines: &1}))

      total =
        page_lines
        |> List.flatten()
        |> Enum.sum_by(&if(&1.direction == :credit, do: &1.amount_cents, else: -&1.amount_cents))

      pages = [
        Map.merge(first, header_page(%{closing_balance_cents: total, lines: first.lines})) | rest
      ]

      assert {:ok, parsed} = ParsedStatement.from_pages(pages, @account)

      assert Enum.map(parsed.lines, & &1.description) ==
               page_lines |> List.flatten() |> Enum.map(& &1.description)
    end
  end

  # Letters and digits, without X, which is also a mask character.
  defp reference_gen(min_length) do
    [?0..?9, ?A..?W, ?Y..?Z]
    |> Enum.flat_map(&Enum.to_list/1)
    |> member_of()
    |> list_of(min_length: min_length, max_length: 30)
    |> map(&List.to_string/1)
  end

  defp spaced(reference, every),
    do: reference |> String.graphemes() |> Enum.chunk_every(every) |> Enum.join(" ")

  property "a reference matches its account however it is spaced, cased, masked, or cut" do
    check all(
            reference <- reference_gen(8),
            masked <- integer(0..(String.length(reference) - 4)),
            mask <- member_of(["X", "x", "*", "•"]),
            kept <- integer(4..String.length(reference)),
            every <- integer(1..6)
          ) do
      {hidden, shown} = String.split_at(reference, masked)
      printed = spaced(String.duplicate(mask, String.length(hidden)) <> shown, every)

      account = %FinancialAccount{
        currency: "CHF",
        account_number: String.slice(reference, -kept..-1//1)
      }

      assert {:ok, _} =
               ParsedStatement.from_pages(
                 [header_page(%{account_ref: String.downcase(printed)})],
                 account
               )
    end
  end

  property "two full references that differ in any character are an account mismatch" do
    check all(
            reference <- reference_gen(8),
            position <- integer(0..(String.length(reference) - 1)),
            replacement <- reference_gen(1) |> map(&String.first/1),
            replacement != String.at(reference, position)
          ) do
      other =
        reference
        |> String.graphemes()
        |> List.replace_at(position, replacement)
        |> Enum.join()

      account = %FinancialAccount{currency: "CHF", account_number: spaced(reference, 4)}

      assert {:error, :account_mismatch} =
               ParsedStatement.from_pages([header_page(%{account_ref: other})], account)
    end
  end

  property "a header field printed with two values on two pages always fails" do
    check all({a, b} <- {integer(1..28), integer(1..28)}, a != b) do
      pages = [
        header_page(%{period_end: Date.new!(2026, 10, a)}),
        page(%{period_end: Date.new!(2026, 11, b)})
      ]

      assert {:error, :inconsistent_header} = ParsedStatement.from_pages(pages, @account)
    end
  end
end
