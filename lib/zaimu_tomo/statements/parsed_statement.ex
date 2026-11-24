defmodule ZaimuTomo.Statements.ParsedStatement do
  @moduledoc """
  One statement as read from its pages. Pure: no database, no HTTP.

  `parse_page/1` is the boundary for one page of extractor output. It turns
  the model's JSON map into typed values or refuses it. `from_pages/2` merges
  the pages of one statement in page order and checks them against the
  financial account; the result is trusted afterwards.

  The extractor returns a positive amount and a `direction` per line, and the
  sign is applied once, in `from_pages/2`, from the account holder's side:
  a debit (money out) is negative, a credit is positive.
  """

  alias ZaimuTomo.Currency
  alias ZaimuTomo.FinancialAccounts.FinancialAccount

  @enforce_keys [
    :account_ref,
    :period_start,
    :period_end,
    :currency,
    :opening_cents,
    :closing_cents,
    :lines
  ]
  defstruct @enforce_keys

  @type line :: %{
          booking_date: Date.t(),
          value_date: Date.t() | nil,
          description: String.t(),
          amount_cents: integer(),
          original: {integer(), String.t()} | nil
        }

  @type t :: %__MODULE__{
          account_ref: String.t() | nil,
          period_start: Date.t(),
          period_end: Date.t(),
          currency: String.t(),
          opening_cents: integer(),
          closing_cents: integer(),
          lines: [line()]
        }

  @type page_line :: %{
          booking_date: Date.t(),
          value_date: Date.t() | nil,
          description: String.t(),
          amount_cents: pos_integer(),
          direction: :debit | :credit,
          original_amount_cents: pos_integer() | nil,
          original_currency: String.t() | nil
        }

  defmodule Page do
    @moduledoc """
    One validated page of extractor output, produced by `ParsedStatement.parse_page/1`.
    """

    @enforce_keys [
      :account_ref,
      :period_start,
      :period_end,
      :currency,
      :opening_balance_cents,
      :closing_balance_cents,
      :lines
    ]
    defstruct @enforce_keys

    @opaque t :: %__MODULE__{
              account_ref: String.t() | nil,
              period_start: Date.t() | nil,
              period_end: Date.t() | nil,
              currency: String.t() | nil,
              opening_balance_cents: integer() | nil,
              closing_balance_cents: integer() | nil,
              lines: [ZaimuTomo.Statements.ParsedStatement.page_line()]
            }
  end

  @type page :: Page.t()

  @type failure ::
          :missing_header
          | :inconsistent_header
          | :currency_mismatch
          | :account_mismatch
          | :no_lines
          | :line_outside_period

  @header_fields [
    account_ref: :text,
    period_start: :date,
    period_end: :date,
    currency: :currency,
    opening_balance_cents: :integer,
    closing_balance_cents: :integer
  ]

  @line_fields [
    booking_date: {:required, :date},
    value_date: :date,
    description: {:required, :text},
    amount_cents: {:required, :amount},
    direction: {:required, :direction},
    original_amount_cents: :amount,
    original_currency: :currency
  ]

  @matched_header [:account_ref, :period_start, :period_end, :currency]
  @masks ["X", "*", "•", "·", "●"]

  @doc """
  Parses one page of extractor output (a JSON map with string keys).

  Header fields are optional on every page. A line needs a booking date, a
  description, an amount, and a direction. The amount's sign is ignored,
  because `direction` carries it, and a zero line is dropped. A foreign
  amount is kept only with its currency.
  """
  @spec parse_page(map()) :: {:ok, page()} | {:error, {:validation_failed, map()}}
  def parse_page(%{} = raw) do
    {header, header_errors} = parse_fields(raw, @header_fields, "")
    {lines, line_errors} = parse_lines(Map.get(raw, "lines"))

    case Map.merge(header_errors, line_errors) do
      errors when errors == %{} -> {:ok, struct!(Page, Map.put(header, :lines, lines))}
      errors -> {:error, {:validation_failed, errors}}
    end
  end

  def parse_page(_raw), do: {:error, {:validation_failed, %{"page" => "is not an object"}}}

  @doc "Returns the `{period_start, period_end}` printed on a parsed page, or `nil`."
  @spec page_period(page()) :: {Date.t(), Date.t()} | nil
  def page_period(%Page{period_start: %Date{} = first, period_end: %Date{} = last}),
    do: {first, last}

  def page_period(%Page{}), do: nil

  @doc """
  Merges the pages of one statement, in page order, and checks them against
  the account.

  The period and currency are taken from the first page that prints them,
  and account references across pages must refer to the same account
  (keeping the most informative one); two pages that disagree fail with
  `:inconsistent_header`. The opening balance is the first one printed and
  the closing balance the last one, because pages in between often print
  carried-forward subtotals. A line dated more than two months outside the
  period fails with `:line_outside_period`.
  """
  @spec from_pages([page()], FinancialAccount.t()) :: {:ok, t()} | {:error, failure()}
  def from_pages(pages, %FinancialAccount{} = account) when is_list(pages) do
    ensure_parsed_pages!(pages)

    with {:ok, header} <- merge_header(pages),
         :ok <- check_account(header, account),
         lines = pages |> Enum.flat_map(& &1.lines) |> Enum.map(&signed_line/1),
         :ok <- check_dates(header, lines) do
      build(header, lines)
    end
  end

  defp ensure_parsed_pages!(pages) do
    unless Enum.all?(pages, &match?(%Page{}, &1)) do
      raise ArgumentError, "expected ParsedStatement.Page structs from parse_page/1"
    end
  end

  # A page often prints dates without a year, and a wrong year guess still
  # balances. Card statements list purchases made weeks before the period
  # opened, so a line may sit up to two months outside it; a year off cannot.
  defp check_dates(%{period_start: first, period_end: last}, lines) do
    earliest = Date.shift(first, month: -2)
    latest = Date.shift(last, month: 2)

    in_range? = fn
      nil -> true
      date -> not Date.before?(date, earliest) and not Date.after?(date, latest)
    end

    if Enum.all?(lines, &(in_range?.(&1.booking_date) and in_range?.(&1.value_date))),
      do: :ok,
      else: {:error, :line_outside_period}
  end

  defp build(%{opening: opening, closing: closing}, []) when opening != closing,
    do: {:error, :no_lines}

  defp build(header, lines) do
    {:ok,
     %__MODULE__{
       account_ref: header.account_ref,
       period_start: header.period_start,
       period_end: header.period_end,
       currency: header.currency,
       opening_cents: header.opening,
       closing_cents: header.closing,
       lines: lines
     }}
  end

  defp merge_header(pages) do
    with {:ok, matched} <- matched_header(pages) do
      header =
        Map.merge(matched, %{
          opening: pages |> Enum.map(& &1.opening_balance_cents) |> first_present(),
          closing:
            pages |> Enum.map(& &1.closing_balance_cents) |> Enum.reverse() |> first_present()
        })

      cond do
        Enum.any?(
          [:period_start, :period_end, :currency, :opening, :closing],
          &is_nil(header[&1])
        ) ->
          {:error, :missing_header}

        Date.after?(header.period_start, header.period_end) ->
          {:error, :inconsistent_header}

        true ->
          {:ok, header}
      end
    end
  end

  defp matched_header(pages) do
    Enum.reduce_while(@matched_header, {:ok, %{}}, fn field, {:ok, acc} ->
      case match_field(pages, field) do
        {:ok, value} -> {:cont, {:ok, Map.put(acc, field, value)}}
        {:error, _} = error -> {:halt, error}
      end
    end)
  end

  defp match_field(pages, :account_ref) do
    pages
    |> Enum.map(& &1.account_ref)
    |> Enum.reject(&is_nil/1)
    |> merge_account_refs()
  end

  defp match_field(pages, field) do
    values =
      pages
      |> Enum.map(&Map.fetch!(&1, field))
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq_by(&comparable/1)

    case values do
      [] -> {:ok, nil}
      [value] -> {:ok, value}
      _conflict -> {:error, :inconsistent_header}
    end
  end

  defp merge_account_refs([]), do: {:ok, nil}

  defp merge_account_refs(refs) do
    if all_same_account?(refs) do
      {:ok, Enum.max_by(refs, &ref_score/1)}
    else
      {:error, :inconsistent_header}
    end
  end

  defp all_same_account?([_single]), do: true

  defp all_same_account?([head | rest]) do
    Enum.all?(rest, &same_account?(head, &1)) and all_same_account?(rest)
  end

  defp ref_score(ref) do
    chars = reference_chars(ref)
    {length(chars), Enum.count(chars, &(&1 not in @masks))}
  end

  defp first_present(values), do: Enum.find(values, &(not is_nil(&1)))

  defp check_account(%{currency: currency}, %FinancialAccount{currency: account_currency})
       when currency != account_currency,
       do: {:error, :currency_mismatch}

  defp check_account(%{account_ref: ref}, %FinancialAccount{account_number: number}) do
    if same_account?(ref, number), do: :ok, else: {:error, :account_mismatch}
  end

  # A card statement prints a masked number and an account may hold only the
  # last digits, so the references are compared right-aligned over the shorter
  # one, and a mask character on either side matches anything. Fewer than four
  # characters that can be compared prove nothing either way.
  defp same_account?(ref, number) when is_binary(ref) and is_binary(number) do
    compared =
      ref
      |> reference_chars()
      |> Enum.zip(reference_chars(number))
      |> Enum.reject(fn {a, b} -> a in @masks or b in @masks end)

    length(compared) < 4 or Enum.all?(compared, fn {a, b} -> a == b end)
  end

  defp same_account?(_ref, _number), do: true

  # Uppercased letters, digits, and mask characters, last character first.
  defp reference_chars(reference) do
    reference
    |> String.upcase()
    |> String.graphemes()
    |> Enum.filter(&(&1 =~ ~r/\A[A-Z0-9]\z/ or &1 in @masks))
    |> Enum.reverse()
  end

  defp comparable(value) when is_binary(value),
    do: value |> String.replace(~r/\s+/, "") |> String.upcase()

  defp comparable(value), do: value

  defp signed_line(line) do
    sign = if line.direction == :debit, do: -1, else: 1

    original =
      if line.original_amount_cents,
        do: {sign * line.original_amount_cents, line.original_currency}

    %{
      booking_date: line.booking_date,
      value_date: line.value_date,
      description: line.description,
      amount_cents: sign * line.amount_cents,
      original: original
    }
  end

  defp parse_lines(nil), do: {[], %{}}

  defp parse_lines(lines) when is_list(lines) do
    {parsed, errors} =
      lines
      |> Enum.with_index()
      |> Enum.reduce({[], %{}}, fn {raw, index}, {parsed, errors} ->
        case parse_line(raw, "lines.#{index}.") do
          {:ok, nil} -> {parsed, errors}
          {:ok, line} -> {[line | parsed], errors}
          {:error, line_errors} -> {parsed, Map.merge(errors, line_errors)}
        end
      end)

    {Enum.reverse(parsed), errors}
  end

  defp parse_lines(_lines), do: {[], %{"lines" => "is not a list"}}

  defp parse_line(%{} = raw, prefix) do
    case parse_fields(raw, @line_fields, prefix) do
      {%{amount_cents: 0}, errors} when errors == %{} -> {:ok, nil}
      {line, errors} when errors == %{} -> {:ok, keep_original_pair(line)}
      {_line, errors} -> {:error, errors}
    end
  end

  defp parse_line(_raw, prefix),
    do: {:error, %{String.trim_trailing(prefix, ".") => "is invalid"}}

  defp keep_original_pair(%{original_amount_cents: amount, original_currency: currency} = line)
       when amount in [nil, 0] or is_nil(currency),
       do: %{line | original_amount_cents: nil, original_currency: nil}

  defp keep_original_pair(line), do: line

  defp parse_fields(raw, specs, prefix) do
    Enum.reduce(specs, {%{}, %{}}, fn {key, spec}, {parsed, errors} ->
      case parse_field(Map.get(raw, Atom.to_string(key)), spec) do
        {:ok, value} -> {Map.put(parsed, key, value), errors}
        :error -> {parsed, Map.put(errors, prefix <> Atom.to_string(key), "is invalid")}
      end
    end)
  end

  defp parse_field(value, {:required, type}) do
    case parse_field(value, type) do
      {:ok, nil} -> :error
      result -> result
    end
  end

  defp parse_field(nil, _type), do: {:ok, nil}

  defp parse_field(value, :text) when is_binary(value) do
    case String.trim(value) do
      "" -> {:ok, nil}
      text -> {:ok, text}
    end
  end

  defp parse_field(value, :date) when is_binary(value) do
    case Date.from_iso8601(String.trim(value)) do
      {:ok, date} -> {:ok, date}
      {:error, _reason} -> :error
    end
  end

  defp parse_field(value, :currency) when is_binary(value) do
    case Currency.normalize(value) do
      "" -> {:ok, nil}
      code -> if code =~ ~r/\A[A-Z]{3}\z/, do: {:ok, code}, else: :error
    end
  end

  defp parse_field(value, :integer) when is_integer(value), do: {:ok, value}
  defp parse_field(value, :amount) when is_integer(value), do: {:ok, abs(value)}
  defp parse_field("debit", :direction), do: {:ok, :debit}
  defp parse_field("credit", :direction), do: {:ok, :credit}
  defp parse_field(_value, _type), do: :error
end
