defmodule ZaimuTomo.FinancialAccounts do
  @moduledoc """
  Financial accounts and their dated balance snapshots.
  """

  import Ecto.Query, warn: false

  alias Ecto.Multi
  alias ZaimuTomo.Accounts.Scope
  alias ZaimuTomo.FinancialAccounts.{BalanceSnapshot, FinancialAccount}
  alias ZaimuTomo.Repo

  def subscribe_financial_accounts(%Scope{} = scope) do
    Phoenix.PubSub.subscribe(ZaimuTomo.PubSub, topic(scope))
  end

  def list_financial_accounts(%Scope{} = scope) do
    FinancialAccount
    |> where(user_id: ^scope.user.id)
    |> order_by([account], asc: account.name)
    |> Repo.all()
  end

  def list_financial_accounts_with_latest_balance(%Scope{} = scope) do
    latest_balances =
      scope
      |> latest_balance_snapshots()
      |> Map.new(&{&1.financial_account_id, &1})

    Enum.map(list_financial_accounts(scope), fn account ->
      %{account: account, balance_snapshot: Map.get(latest_balances, account.id)}
    end)
  end

  def list_savings_accounts_with_latest_balance(%Scope{} = scope) do
    scope
    |> list_financial_accounts_with_latest_balance()
    |> Enum.filter(&(&1.account.account_type == :savings))
  end

  def list_cash_accounts_with_latest_balance(%Scope{} = scope) do
    scope
    |> list_financial_accounts_with_latest_balance()
    |> Enum.filter(&(&1.account.account_type == :cash))
  end

  def get_financial_account!(%Scope{} = scope, id) do
    Repo.get_by!(FinancialAccount, id: id, user_id: scope.user.id)
  end

  def create_financial_account_with_balance(%Scope{} = scope, account_attrs, balance_attrs) do
    multi =
      Multi.new()
      |> Multi.insert(
        :financial_account,
        FinancialAccount.changeset(%FinancialAccount{}, account_attrs, scope)
      )
      |> Multi.insert(:balance_snapshot, fn %{financial_account: account} ->
        BalanceSnapshot.changeset(
          %BalanceSnapshot{},
          Map.put(balance_attrs, :financial_account_id, account.id)
        )
      end)

    case Repo.transaction(multi) do
      {:ok, %{financial_account: account, balance_snapshot: snapshot}} ->
        broadcast(scope, {:created, account})
        {:ok, %{account: account, balance_snapshot: snapshot}}

      {:error, _operation, changeset, _changes} ->
        {:error, changeset}
    end
  end

  def update_financial_account(%Scope{} = scope, %FinancialAccount{} = account, attrs) do
    true = account.user_id == scope.user.id

    case account |> FinancialAccount.changeset(attrs, scope) |> Repo.update() do
      {:ok, updated_account} ->
        broadcast(scope, {:updated, updated_account})
        {:ok, updated_account}

      {:error, changeset} ->
        {:error, changeset}
    end
  end

  def delete_financial_account(%Scope{} = scope, %FinancialAccount{} = account) do
    true = account.user_id == scope.user.id

    case Repo.delete(account) do
      {:ok, deleted_account} ->
        broadcast(scope, {:deleted, deleted_account})
        {:ok, deleted_account}

      {:error, changeset} ->
        {:error, changeset}
    end
  end

  def change_financial_account(%Scope{} = scope, %FinancialAccount{} = account, attrs \\ %{}) do
    true = account.user_id == scope.user.id
    FinancialAccount.changeset(account, attrs, scope)
  end

  def list_balance_snapshots(%Scope{} = scope, %FinancialAccount{} = account) do
    true = account.user_id == scope.user.id

    BalanceSnapshot
    |> where(financial_account_id: ^account.id)
    |> order_by([snapshot], desc: snapshot.recorded_on, desc: snapshot.inserted_at)
    |> Repo.all()
  end

  def record_balance(%Scope{} = scope, %FinancialAccount{} = account, attrs) do
    true = account.user_id == scope.user.id

    result =
      attrs
      |> Map.put(:financial_account_id, account.id)
      |> then(&BalanceSnapshot.changeset(%BalanceSnapshot{}, &1))
      |> Repo.insert()

    case result do
      {:ok, snapshot} ->
        broadcast(scope, {:balance_recorded, snapshot})
        {:ok, snapshot}

      {:error, changeset} ->
        {:error, changeset}
    end
  end

  def change_balance_snapshot(%BalanceSnapshot{} = snapshot, attrs \\ %{}) do
    BalanceSnapshot.changeset(snapshot, attrs)
  end

  defp latest_balance_snapshots(%Scope{} = scope) do
    from(snapshot in BalanceSnapshot,
      join: account in FinancialAccount,
      on: account.id == snapshot.financial_account_id,
      where: account.user_id == ^scope.user.id,
      distinct: snapshot.financial_account_id,
      order_by: [
        asc: snapshot.financial_account_id,
        desc: snapshot.recorded_on,
        desc: snapshot.inserted_at
      ]
    )
    |> Repo.all()
  end

  defp topic(scope), do: "user:#{scope.user.id}:financial_accounts"

  defp broadcast(scope, message),
    do: Phoenix.PubSub.broadcast(ZaimuTomo.PubSub, topic(scope), message)
end
