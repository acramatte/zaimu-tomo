defmodule ZaimuTomo.StatementsFixtures do
  @moduledoc false

  import Ecto.Query, only: [where: 2]

  alias ZaimuTomo.Repo
  alias ZaimuTomo.Statements
  alias ZaimuTomo.Statements.{Statement, StatementLine}

  @doc "Uploads a statement file with unique bytes against `account`."
  def statement_fixture(scope, account, bytes \\ nil) do
    path = Path.join(System.tmp_dir!(), "statement-#{System.unique_integer([:positive])}.pdf")
    File.write!(path, bytes || "statement #{System.unique_integer([:positive])}")

    {:ok, statement} = Statements.upload_statement(scope, account.id, path, "statement.pdf")
    File.rm(path)
    statement
  end

  @doc """
  Writes an extraction result directly, as `ExtractJob` would, for tests of
  readers. Lines are `{booking_date, description, signed_cents}` tuples, with
  a fourth `{signed_original_cents, original_currency}` for foreign spend.
  """
  def put_extraction(%Statement{} = statement, header \\ %{}, lines \\ []) do
    header =
      Enum.into(header, %{
        extracted_at: DateTime.utc_now(:second),
        period_start: ~D[2026-10-01],
        period_end: ~D[2026-10-31],
        currency: "EUR",
        opening_balance_cents: 100_000,
        failure_code: nil
      })

    header =
      Map.put_new(
        header,
        :closing_balance_cents,
        header.opening_balance_cents + Enum.sum_by(lines, &elem(&1, 2))
      )

    Repo.delete_all(where(StatementLine, statement_id: ^statement.id))

    Repo.insert_all(
      StatementLine,
      lines
      |> Enum.with_index(1)
      |> Enum.map(fn {line, position} ->
        {date, description, cents, {original_cents, original_currency}} =
          case line do
            {date, description, cents} -> {date, description, cents, {nil, nil}}
            {_date, _description, _cents, {_original_cents, _original_currency}} -> line
          end

        %{
          statement_id: statement.id,
          user_id: statement.user_id,
          position: position,
          booking_date: date,
          description: description,
          amount_cents: cents,
          currency: header.currency,
          original_amount_cents: original_cents,
          original_currency: original_currency
        }
      end)
    )

    statement |> Ecto.Changeset.change(header) |> Repo.update!()
  end
end
