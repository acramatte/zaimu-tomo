defmodule ZaimuTomoWeb.ReviewLive.Show do
  use ZaimuTomoWeb, :live_view

  alias ZaimuTomo.Review
  alias ZaimuTomo.Review.ReviewDecision
  alias ZaimuTomo.Accounts.Scope

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <div class="mb-4">
        <.link navigate={~p"/reviews"} class="text-sm text-gray-500 hover:text-gray-700 dark:text-gray-400 dark:hover:text-gray-200 flex items-center gap-1">
          <.icon name="hero-arrow-left" class="w-4 h-4" /> Back to Reviews
        </.link>
      </div>

      <.header>
        <%= review_title(@review_decision) %>
        <:actions>
          <%= if @review_decision.review_status == "pending" do %>
            <.link patch={~p"/reviews/#{@review_decision}/edit"}>
              <.icon name="hero-pencil-square" /> Amend
            </.link>
          <% end %>
        </:actions>
      </.header>

      <.list>
        <:item title="Status"><span class={["px-2 py-1 rounded-full text-xs font-medium", status_class(@review_decision.review_status)]}><%= String.capitalize(@review_decision.review_status) %></span></:item>
        <:item title="Decision Type"><%= String.capitalize(@review_decision.decision_type || "N/A") %></:item>
        <:item title="Created At"><%= format_datetime(@review_decision.inserted_at) %></:item>
        <:item title="Updated At"><%= format_datetime(@review_decision.updated_at) %></:item>
      </.list>

      <.header>
        Invoice Data
      </.header>

      <.list>
        <:item title="Invoice Number"><%= @effective_data.invoice_number || "N/A" %></:item>
        <:item title="Invoice Date"><%= @effective_data.invoice_date || "N/A" %></:item>
        <:item title="Issuer"><%= @effective_data.issuer || "N/A" %></:item>
        <:item title="Currency"><%= @effective_data.currency || "N/A" %></:item>
        <:item title="Amount"><%= format_amount(@effective_data) %></:item>
        <:item title="Reason for Payment"><%= @effective_data.reason_for_payment || "N/A" %></:item>
      </.list>

      <%= if @review_decision.review_notes do %>
        <.header>Review Notes</.header>
        <div class="bg-gray-100 dark:bg-gray-800 p-4 rounded-lg"><%= @review_decision.review_notes %></div>
      <% end %>

      <%= if @review_decision.review_status == "pending" do %>
        <div class="mt-8 flex justify-between items-center">
          <.button phx-click="approve" variant="primary" phx-disable-with="Approving...">
            <.icon name="hero-check" /> Approve
          </.button>
          <.button phx-click="reject" class="btn btn-error" phx-disable-with="Rejecting...">
            <.icon name="hero-x-mark" /> Reject
          </.button>
        </div>
      <% end %>
    </Layouts.app>
    """
  end

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    case socket.assigns.current_scope do
      %Scope{user: user} ->
        case Review.get_review_decision(id, user.id) do
          {:ok, %ReviewDecision{} = rd} ->
            {:ok,
             socket
             |> assign(:review_decision, rd)
             |> assign(:effective_data, ReviewDecision.effective_data(rd))}
          {:error, reason} ->
            {:ok, put_flash(socket, :error, reason) |> redirect(to: ~p"/reviews")}
        end
      _ ->
        {:ok, put_flash(socket, :error, "Not authenticated") |> redirect(to: ~p"/")}
    end
  end

  @impl true
  def handle_event("approve", _params, socket) do
    user_id = socket.assigns.current_scope.user.id
    extracted_content_id = socket.assigns.review_decision.extracted_content_id

    case Review.approve_invoice(extracted_content_id, user_id) do
      {:ok, _} ->
        {:noreply, socket |> put_flash(:info, "Invoice approved") |> redirect(to: ~p"/reviews")}
      {:error, reason} ->
        {:noreply, put_flash(socket, :error, reason)}
    end
  end

  @impl true
  def handle_event("reject", _params, socket) do
    user_id = socket.assigns.current_scope.user.id
    extracted_content_id = socket.assigns.review_decision.extracted_content_id

    case Review.reject_invoice(extracted_content_id, user_id) do
      {:ok, _} ->
        {:noreply, socket |> put_flash(:info, "Invoice rejected") |> redirect(to: ~p"/reviews")}
      {:error, reason} ->
        {:noreply, put_flash(socket, :error, reason)}
    end
  end

  defp review_title(%ReviewDecision{} = rd) do
    data = ReviewDecision.effective_data(rd)
    cond do
      data.issuer && data.invoice_number -> "#{data.issuer} — #{data.invoice_number}"
      data.issuer                        -> data.issuer
      data.invoice_number                -> "Invoice #{data.invoice_number}"
      true                               -> "Invoice Review"
    end
  end

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

  defp format_datetime(%DateTime{} = datetime) do
    "#{DateTime.to_iso8601(datetime)}"
  end
  defp format_datetime(%Date{} = date) do
    Date.to_iso8601(date)
  end
  defp format_datetime(_), do: "N/A"

  defp format_currency(cents, currency) when is_integer(cents) do
    amount = cents / 100.0
    "#{currency} #{amount}"
  end
  defp format_currency(_cents, _currency), do: "N/A"
end
