defmodule ZaimuTomo.Statements.StatementLine do
  @moduledoc """
  One line of a statement as read by the last successful extraction.

  `amount_cents` is signed from the account holder's side, in the statement
  currency: money out is negative. Lines have no public changeset;
  `ZaimuTomo.Statements.ExtractJob` replaces them wholesale.
  """
  use Ecto.Schema

  @type t :: %__MODULE__{}

  schema "statement_lines" do
    field :position, :integer
    field :booking_date, :date
    field :value_date, :date
    field :description, :string
    field :amount_cents, :integer
    field :currency, :string
    field :original_amount_cents, :integer
    field :original_currency, :string
    field :user_id, :id

    belongs_to :statement, ZaimuTomo.Statements.Statement
  end
end
