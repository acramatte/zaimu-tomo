defmodule ZaimuTomoWeb.ReviewLive.Index do
  use ZaimuTomoWeb, :live_view

  alias ZaimuTomo.Review
  alias ZaimuTomo.Accounts.Scope

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <.header>
        Reviews
        <:actions>
          <.link navigate={~p"/documents/new"}>
            <.icon name="hero-plus" /> New Document
          </.link>
        </:actions>
      </.header>

      <.table
        id="reviews"
        rows={@streams.reviews}
        row_click={fn {_id, review} -> JS.navigate(~p"/reviews/#{review}") end}
      >
        <:col :let={{_id, review}} label="Status">
          <span class={["px-2 py-1 rounded-full text-xs font-medium", status_class(review.review_status)]}>
            <%= String.capitalize(review.review_status) %>
          </span>
        </:col>
        <:col :let={{_id, review}} label="Invoice #">
          <%= effective(review).invoice_number || "N/A" %>
        </:col>
        <:col :let={{_id, review}} label="Issuer">
          <%= effective(review).issuer || "N/A" %>
        </:col>
        <:col :let={{_id, review}} label="Amount">
          <%= format_amount(effective(review)) %>
        </:col>
        <:col :let={{_id, review}} label="Date">
          <%= effective(review).invoice_date || "N/A" %>
        </:col>
        <:col :let={{_id, review}} label="Created">
          <%= format_date(review.inserted_at) %>
        </:col>
        <:action :let={{_id, review}}>
          <.link navigate={~p"/reviews/#{review}"}>Show</.link>
        </:action>
      </.table>
    </Layouts.app>
    """
  end

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      # Subscribe to reviews if needed
    end

    {:ok,
     socket
     |> assign(:page_title, "Reviews")
     |> stream(:reviews, list_reviews(socket.assigns.current_scope))}
  end

  defp list_reviews(current_scope) do
    case current_scope do
      %Scope{user: user} -> Review.list_review_decisions(user.id)
      _ -> []
    end
  end

  defp effective(review), do: review.decision_data || review.original_data

  defp status_class(status) do
    case status do
      "pending" -> "bg-yellow-100 text-yellow-800 dark:bg-yellow-900 dark:text-yellow-300"
      "approved" -> "bg-green-100 text-green-800 dark:bg-green-900 dark:text-green-300"
      "rejected" -> "bg-red-100 text-red-800 dark:bg-red-900 dark:text-red-300"
      "amended" -> "bg-blue-100 text-blue-800 dark:bg-blue-900 dark:text-blue-300"
      _ -> "bg-gray-100 text-gray-800 dark:bg-gray-700 dark:text-gray-300"
    end
  end

  defp format_amount(%{amount_to_pay_cents: nil}), do: "N/A"
  defp format_amount(%{amount_to_pay_cents: cents, currency: currency}) do
    format_currency(cents, currency || "USD")
  end

  defp format_currency(cents, currency) when is_integer(cents), do: "#{currency} #{cents / 100.0}"
  defp format_currency(_cents, _currency), do: "N/A"

  defp format_date(%DateTime{} = datetime), do: DateTime.to_date(datetime) |> Date.to_iso8601()
  defp format_date(%Date{} = date), do: Date.to_iso8601(date)
  defp format_date(_), do: "N/A"
end
