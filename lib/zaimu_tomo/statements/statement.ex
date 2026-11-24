defmodule ZaimuTomo.Statements.Statement do
  @moduledoc """
  A bank or credit card statement uploaded against one financial account.

  The upload fields come from `upload_changeset/2`. The extracted header,
  `extracted_at`, and `failure_code` are written only by
  `ZaimuTomo.Statements.ExtractJob`. The status is derived, never stored: see
  `ZaimuTomo.Statements.status/2`.
  """
  use Ecto.Schema
  import Ecto.Changeset

  alias ZaimuTomo.FinancialAccounts.FinancialAccount
  alias ZaimuTomo.Fingerprint
  alias ZaimuTomo.Statements.StatementLine

  @type t :: %__MODULE__{}

  schema "statements" do
    field :filename, :string
    field :object_key, :string
    field :content_sha256, :string, redact: true
    field :extracted_at, :utc_datetime
    field :account_ref, :string
    field :period_start, :date
    field :period_end, :date
    field :currency, :string
    field :opening_balance_cents, :integer
    field :closing_balance_cents, :integer
    field :failure_code, :string
    field :user_id, :id

    belongs_to :financial_account, FinancialAccount
    has_many :lines, StatementLine, preload_order: [asc: :position]

    timestamps(type: :utc_datetime)
  end

  @doc false
  def upload_changeset(statement, attrs) do
    statement
    |> cast(attrs, [:financial_account_id, :filename, :object_key, :content_sha256])
    |> validate_required([:financial_account_id, :filename, :object_key, :content_sha256])
    |> validate_length(:filename, max: 255)
    |> validate_length(:object_key, max: 255)
    |> validate_format(:content_sha256, Fingerprint.format())
    |> foreign_key_constraint(:financial_account_id)
    |> unique_constraint(:object_key)
    |> unique_constraint(:content_sha256, name: :statements_user_id_content_sha256_index)
  end
end
