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
  @confidences [:named, :amount_only]

  # Legal forms, generic organisation words, country/TLD codes and connectors:
  # they say what kind of company or domain the issuer uses, not which company,
  # and card descriptors usually drop or reuse them.
  @noise ~w(ag sa gmbh sarl ltd inc co kg llc plc bv sas srl spa
            genossenschaft gesellschaft holding group gruppe international
            schweiz suisse svizzera switzerland ch com net org eu uk us
            the and und et of de du la le les des der die das)
  @min_token_length 2

  @doc "All match confidence levels returned by `match/2`."
  @spec confidences() :: [confidence()]
  def confidences, do: @confidences

  @doc """
  The amount keys a statement line can be backed under.

  Statement amounts are from the account holder's side (money out < 0), so the
  keys negate them. A debit has its account amount key and, for foreign card
  spend, its original amount key (which must also be negative). A credit has
  none, because only money out is backed by an invoice.
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
      when is_integer(original) and original < 0 and is_binary(currency) ->
        Enum.uniq([{-cents, line.currency}, {-original, currency}])

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
  for the matched lines only. Raises `ArgumentError` if line ids or entry ids
  are not unique.
  """
  @spec match([line_in()], [entry_in()]) :: %{term() => {term(), confidence()}}
  def match(lines, entries) do
    ensure_unique_ids!(lines, "line")
    ensure_unique_ids!(entries, "entry")

    by_key =
      entries
      |> Enum.map(&{&1, significant_words(&1.issuer)})
      |> Enum.group_by(fn {entry, _tokens} -> entry.key end)

    lines
    |> Enum.flat_map(&candidates(&1, description_word_set(&1.description), by_key))
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

  defp ensure_unique_ids!(items, kind) do
    seen =
      Enum.reduce(items, MapSet.new(), fn %{id: id}, acc ->
        if MapSet.member?(acc, id) do
          raise ArgumentError, "duplicate #{kind} id in Matcher.match/2: #{inspect(id)}"
        end

        MapSet.put(acc, id)
      end)

    seen
  end

  defp candidates(%{date: %Date{} = line_date} = line, desc_words, by_key) do
    for key <- Enum.uniq(line.keys),
        {%{date: %Date{} = entry_date} = entry, issuer_words} <- Map.get(by_key, key, []),
        days <- [Date.diff(line_date, entry_date)],
        days in -@before_days..@after_days//1 do
      {rank(issuer_words, desc_words, days), line.id, entry.id}
    end
  end

  defp candidates(_line, _desc_words, _by_key), do: []

  defp rank(issuer_words, desc_words, days) do
    named = if Enum.any?(issuer_words, &MapSet.member?(desc_words, &1)), do: 0, else: 1
    distance = if days >= 0, do: days, else: @early_weight * -days
    {named, distance}
  end

  defp confidence(0), do: :named
  defp confidence(1), do: :amount_only

  @doc """
  Whether the description names the issuer.

  Both sides are compared as words: accents stripped, German/Swiss umlauts and
  `ß` matched against both stripped and ASCII digraph forms (`ä`/`ae`, `ö`/`oe`,
  `ü`/`ue`, `ß`/`ss`), case folded, split on anything that is not a letter or
  digit. An issuer word is significant when it has at least #{@min_token_length}
  characters and is not a legal form, a generic organisation word, a country/TLD
  code or a connector (AG, SA, GmbH, Sàrl, Ltd, Inc, Co, Genossenschaft,
  Schweiz, ch, com, de, la, und, ...). The description names the issuer when it
  contains any significant issuer word as a whole word. One word suffices
  because card descriptors truncate legal names ("Migros Genossenschaft" prints
  as "MIGROS M ZUERICH"), and a rare false positive only reorders candidates
  that already share the amount and the date window. A nil or blank issuer, or
  one with no significant word, is never named.
  """
  @spec named?(String.t() | nil, String.t() | nil) :: boolean()
  def named?(issuer, description) when is_binary(issuer) and is_binary(description) do
    significant = significant_words(issuer)
    description_words = description_word_set(description)
    Enum.any?(significant, &MapSet.member?(description_words, &1))
  end

  def named?(_issuer, _description), do: false

  defp significant_words(issuer) when is_binary(issuer) do
    issuer
    |> words()
    |> Enum.filter(&(String.length(&1) >= @min_token_length and &1 not in @noise))
  end

  defp significant_words(_issuer), do: []

  defp description_word_set(description) when is_binary(description),
    do: description |> words() |> MapSet.new()

  defp description_word_set(_description), do: MapSet.new()

  defp words(text) do
    downcased = text |> :unicode.characters_to_nfc_binary() |> String.downcase()

    stripped = downcased |> String.replace("ß", "ss") |> strip_and_split()
    digraph = downcased |> transliterate_german() |> strip_and_split()

    if stripped == digraph, do: stripped, else: Enum.uniq(stripped ++ digraph)
  end

  defp transliterate_german(text) do
    text
    |> String.replace("ß", "ss")
    |> String.replace("ä", "ae")
    |> String.replace("ö", "oe")
    |> String.replace("ü", "ue")
  end

  defp strip_and_split(text) do
    text
    |> :unicode.characters_to_nfd_binary()
    |> String.replace(~r/\p{Mn}/u, "")
    |> String.split(~r/[^\p{L}\p{N}]+/u, trim: true)
  end
end
