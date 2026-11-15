defmodule ZaimuTomo.Statements.Matcher do
  @moduledoc """
  Pairs statement lines with the journal entries that back them.

  Pure: plain maps and `Date` in, a map of pairs out. The caller turns its rows
  into `t:line_in/0` and `t:entry_in/0` with `line_keys/1` and `entry_key/1`.

  ## One-to-one

  One entry backs at most one line and one line is backed by at most one entry.
  `match/2` lists every candidate pair, sorts them by rank, then line id, then
  entry id, and folds over that list taking a pair only when neither its line
  nor its entry is taken yet. The sort is a total order, so the answer does not
  depend on the order of the inputs.

  A pair is a candidate only when the line and the entry share an amount key and
  `-7 <= line.date - entry.date <= 60` days. Rank prefers a pair whose entry
  issuer is named in the line description, then the smaller date distance,
  where a line dated before its invoice counts three times its distance because
  paying before the invoice date is rare.

  ## Amount groups

  The fold decides a pair by looking only at earlier pairs that share its line or
  its entry. Pairs never share a line or an entry across two groups of lines and
  entries that no amount key connects, so each group gets the same answer
  whether it is matched alone or together with everything else. A caller can
  therefore load only the lines and entries reachable through the keys it cares
  about (closing over the second key of foreign-amount lines) and get the
  answer a global run would give.
  """

  @typedoc "Expense-signed cents (money out > 0) and an ISO currency."
  @type key :: {integer(), String.t()}
  @type line_in :: %{id: term(), date: Date.t(), keys: [key()], description: String.t()}
  @type entry_in :: %{id: term(), date: Date.t(), key: key(), issuer: String.t() | nil}
  @type confidence :: :named | :amount_only

  @before_days 7
  @after_days 60
  @early_weight 3

  # Legal forms, generic organisation words and connectors: they say what kind
  # of company the issuer is, not which one, and card descriptors usually drop them.
  @noise ~w(ag sa gmbh sarl ltd inc co kg llc plc bv sas srl spa
            genossenschaft gesellschaft holding group gruppe international
            schweiz suisse svizzera switzerland the and und et of de du la le les
            des der die das)
  @min_token_length 2

  @doc """
  The amount keys a statement line can be backed under.

  Statement amounts are from the account holder's side (money out < 0), so the
  keys negate them. A debit has its account amount key and, for foreign card
  spend, its original amount key. A credit has none, because only money out is
  backed by an invoice.
  """
  @spec line_keys(%{
          amount_cents: integer(),
          currency: String.t(),
          original_amount_cents: integer() | nil,
          original_currency: String.t() | nil
        }) :: [key()]
  def line_keys(%{amount_cents: cents} = line) when cents < 0 do
    case line do
      %{original_amount_cents: original, original_currency: currency}
      when is_integer(original) and is_binary(currency) ->
        [{-cents, line.currency}, {-original, currency}]

      _ ->
        [{-cents, line.currency}]
    end
  end

  def line_keys(%{amount_cents: _}), do: []

  @doc "The amount key of a journal entry, whose amounts are already expense-signed."
  @spec entry_key(%{amount_cents: integer(), currency: String.t()}) :: key()
  def entry_key(%{amount_cents: cents, currency: currency}), do: {cents, currency}

  @doc """
  Pairs lines with entries one-to-one. Returns `%{line_id => {entry_id, confidence}}`
  for the matched lines only. Line ids and entry ids must each be unique.
  """
  @spec match([line_in()], [entry_in()]) :: %{term() => {term(), confidence()}}
  def match(lines, entries) do
    by_key = Enum.group_by(entries, & &1.key)

    lines
    |> Enum.flat_map(&candidates(&1, by_key))
    |> Enum.sort()
    |> Enum.reduce({%{}, MapSet.new()}, fn {{named, _distance}, line_id, entry_id},
                                           {pairs, taken} ->
      if Map.has_key?(pairs, line_id) or MapSet.member?(taken, entry_id) do
        {pairs, taken}
      else
        {Map.put(pairs, line_id, {entry_id, confidence(named)}), MapSet.put(taken, entry_id)}
      end
    end)
    |> elem(0)
  end

  defp candidates(line, by_key) do
    for key <- line.keys,
        entry <- Map.get(by_key, key, []),
        days <- [Date.diff(line.date, entry.date)],
        days in -@before_days..@after_days//1 do
      {rank(line, entry, days), line.id, entry.id}
    end
  end

  defp rank(line, entry, days) do
    named = if named?(entry.issuer, line.description), do: 0, else: 1
    distance = if days >= 0, do: days, else: @early_weight * -days
    {named, distance}
  end

  defp confidence(0), do: :named
  defp confidence(1), do: :amount_only

  @doc """
  Whether the description names the issuer.

  Both sides are compared as words: accents stripped, case folded, split on
  anything that is not a letter or digit. An issuer word is significant when it
  has at least #{@min_token_length} characters and is not a legal form, a
  generic organisation word or a connector (AG, SA, GmbH, Sàrl, Ltd, Inc, Co,
  Genossenschaft, Schweiz, de, la, und, ...). The description names the issuer
  when it contains any significant issuer word as a whole word. One word
  suffices because card descriptors truncate legal names ("Migros
  Genossenschaft" prints as "MIGROS M ZUERICH"), and a rare false positive only
  reorders candidates that already share the amount and the date window. A nil
  or blank issuer, or one with no significant word, is never named.
  """
  @spec named?(String.t() | nil, String.t()) :: boolean()
  def named?(nil, _description), do: false

  def named?(issuer, description) do
    significant =
      issuer
      |> words()
      |> Enum.filter(&(String.length(&1) >= @min_token_length and &1 not in @noise))

    description_words = description |> words() |> MapSet.new()
    Enum.any?(significant, &MapSet.member?(description_words, &1))
  end

  defp words(text) do
    text
    |> :unicode.characters_to_nfd_binary()
    |> String.replace(~r/\p{Mn}/u, "")
    |> String.downcase()
    |> String.split(~r/[^\p{L}\p{N}]+/u, trim: true)
  end
end
