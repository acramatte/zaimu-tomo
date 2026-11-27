defmodule ZaimuTomo.Datasets.Mutations do
  @moduledoc """
  Deterministic, production-grounded negative candidate generator for Verifier
  SFT datasets.

  Mutations mirror real invoice extraction failure modes (Swiss VAT subtotal vs
  grand total, zero-amount 1-cent schema drift, due date vs invoice date,
  currency confusion, hallucinated payment reason, and wrong issuer) rather than
  random noise. Callers apply mutations strictly inside each split after
  issuer/fingerprint grouping so no document leaks across splits.
  """

  @hallucinated_reasons [
    "Order delivery",
    "Invoice for products and services",
    "General service fee",
    "Monthly subscription renewal"
  ]

  @fallback_issuers [
    "Sunrise GmbH",
    "Helvetia Services AG",
    "AlpenCom AG",
    "Nordic Retail Ltd"
  ]

  @type mutation :: %{
          mutation: String.t(),
          candidate: map(),
          expected_status: String.t(),
          field_issues: [String.t()],
          reason: String.t()
        }

  @doc """
  Generates up to `count` deterministic, distinct realistic negative candidates
  for `ground_truth` (a serialized faithful extraction map) keyed by
  `document_id` and `seed`.
  """
  @spec generate(map(), pos_integer(), keyword()) :: [mutation()]
  def generate(ground_truth, document_id, opts \\ [])
      when is_map(ground_truth) and is_integer(document_id) do
    count = Keyword.get(opts, :count, 2)
    seed = Keyword.get(opts, :seed, "zaimu-tomo-v1")

    if count <= 0 do
      []
    else
      candidates = available_mutations(ground_truth, document_id, seed)

      candidates
      |> Enum.sort_by(&stable_hash(seed, "#{document_id}:#{&1.mutation}"))
      |> Enum.take(count)
    end
  end

  defp available_mutations(gt, doc_id, seed) do
    [
      mutate_amount(gt),
      mutate_date(gt),
      mutate_currency(gt),
      mutate_reason(gt, doc_id, seed),
      mutate_issuer(gt, doc_id, seed)
    ]
    |> Enum.reject(&is_nil/1)
  end

  defp mutate_amount(%{"amount_to_pay_cents" => 0} = gt) do
    %{
      mutation: "zero_amount_one_cent",
      candidate: Map.put(gt, "amount_to_pay_cents", 1),
      expected_status: "rejected",
      field_issues: ["amount_to_pay_cents"],
      reason: "amount_to_pay_cents is 1, contradicting the zero total in the OCR markdown."
    }
  end

  defp mutate_amount(%{"amount_to_pay_cents" => cents} = gt) when is_integer(cents) do
    subtotal_cents = subtotal_candidate(cents)

    %{
      mutation: "subtotal_instead_of_total",
      candidate: Map.put(gt, "amount_to_pay_cents", subtotal_cents),
      expected_status: "rejected",
      field_issues: ["amount_to_pay_cents"],
      reason:
        "amount_to_pay_cents (#{subtotal_cents}) does not match the grand total (#{cents}) in the OCR markdown."
    }
  end

  defp mutate_amount(_gt), do: nil

  defp subtotal_candidate(cents) when cents > 0 do
    candidate = round(cents / 1.081)

    cond do
      candidate != cents and candidate > 0 -> candidate
      cents > 1 -> cents - 1
      true -> 2
    end
  end

  defp subtotal_candidate(cents) when cents < 0 do
    candidate = round(cents / 1.081)
    if candidate != cents and candidate < 0, do: candidate, else: cents - 100
  end

  defp mutate_date(%{"invoice_date" => date_str} = gt) when is_binary(date_str) do
    case Date.from_iso8601(date_str) do
      {:ok, date} ->
        due_date = date |> Date.add(30) |> Date.to_iso8601()

        %{
          mutation: "due_date_instead_of_invoice_date",
          candidate: Map.put(gt, "invoice_date", due_date),
          expected_status: "rejected",
          field_issues: ["invoice_date"],
          reason:
            "invoice_date (#{due_date}) does not match the invoice date (#{date_str}) in the OCR markdown."
        }

      {:error, _reason} ->
        nil
    end
  end

  defp mutate_date(_gt), do: nil

  defp mutate_currency(%{"currency" => currency} = gt) when is_binary(currency) do
    wrong_currency = swap_currency(currency)

    %{
      mutation: "wrong_currency",
      candidate: Map.put(gt, "currency", wrong_currency),
      expected_status: "rejected",
      field_issues: ["currency"],
      reason:
        "currency (#{wrong_currency}) contradicts the invoice currency (#{currency}) in the OCR markdown."
    }
  end

  defp mutate_currency(_gt), do: nil

  defp swap_currency("CHF"), do: "EUR"
  defp swap_currency("EUR"), do: "CHF"
  defp swap_currency("USD"), do: "CHF"
  defp swap_currency(_other), do: "USD"

  defp mutate_reason(gt, doc_id, seed) do
    current = gt["reason_for_payment"]
    replacement = pick_different(@hallucinated_reasons, current, seed, "#{doc_id}:reason")

    %{
      mutation: "hallucinated_reason_for_payment",
      candidate: Map.put(gt, "reason_for_payment", replacement),
      expected_status: "rejected",
      field_issues: ["reason_for_payment"],
      reason:
        "reason_for_payment (#{inspect(replacement)}) is not grounded in the source OCR markdown."
    }
  end

  defp mutate_issuer(%{"issuer" => issuer} = gt, doc_id, seed) when is_binary(issuer) do
    replacement = pick_different(@fallback_issuers, issuer, seed, "#{doc_id}:issuer")

    %{
      mutation: "hallucinated_issuer",
      candidate: Map.put(gt, "issuer", replacement),
      expected_status: "rejected",
      field_issues: ["issuer"],
      reason: "issuer (#{replacement}) is not supported by the source OCR markdown."
    }
  end

  defp mutate_issuer(_gt, _doc_id, _seed), do: nil

  defp pick_different(options, current, seed, salt) do
    current_norm = if is_binary(current), do: String.downcase(String.trim(current)), else: nil

    options
    |> Enum.reject(&(String.downcase(&1) == current_norm))
    |> Enum.sort_by(&stable_hash(seed, "#{salt}:#{&1}"))
    |> hd()
  end

  defp stable_hash(seed, value) do
    :crypto.hash(:sha256, "#{seed}:#{value}") |> Base.encode16(case: :lower)
  end
end
