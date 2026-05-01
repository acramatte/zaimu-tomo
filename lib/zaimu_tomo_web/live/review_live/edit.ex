defmodule ZaimuTomoWeb.ReviewLive.Edit do
  use ZaimuTomoWeb, :live_view

  alias ZaimuTomo.Review
  alias ZaimuTomo.Review.ReviewDecision
  alias ZaimuTomo.Accounts.Scope

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <.header>
        Edit Review <%= @review_decision.id %>
        <:actions>
          <.button type="submit" variant="primary">
            <.icon name="hero-check" /> Save
          </.button>
        </:actions>
      </.header>

      <.form for={@form} phx-submit="save" id="review_form">
        <div class="grid grid-cols-1 md:grid-cols-2 gap-4">
          <.input field={@form[:review_status]} label="Status" type="select" options={@status_options} />
          <.input field={@form[:decision_type]} label="Decision Type" type="select" options={@decision_type_options} />
        </div>

        <div class="my-6 border-t border-gray-200 dark:border-gray-700" />

        <h3 class="text-lg font-medium text-gray-900 dark:text-white mb-4">Invoice Data (Amended)</h3>
        <div class="grid grid-cols-1 md:grid-cols-2 gap-4">
          <.input name="decision_data[invoice_number]" value={@decision_data["invoice_number"] || ""} label="Invoice Number" />
          <.input name="decision_data[invoice_date]" value={@decision_data["invoice_date"] || ""} label="Invoice Date" />
          <.input name="decision_data[issuer]" value={@decision_data["issuer"] || ""} label="Issuer" />
          <.input name="decision_data[currency]" value={@decision_data["currency"] || ""} label="Currency" />
          <.input name="decision_data[amount_to_pay_cents]" value={@decision_data["amount_to_pay_cents"] || ""} label="Amount (cents)" type="number" />
          <.input name="decision_data[reason_for_payment]" value={@decision_data["reason_for_payment"] || ""} label="Reason for Payment" />
        </div>

        <div class="my-6 border-t border-gray-200 dark:border-gray-700" />

        <.input field={@form[:review_notes]} label="Review Notes" type="textarea" />

        <div class="mt-6 flex gap-4">
          <.button type="submit" variant="primary">
            <.icon name="hero-check" /> Save Changes
          </.button>
          <.link patch={~p"/reviews/#{@review_decision}"}>
            <.icon name="hero-x-mark" /> Cancel
          </.link>
        </div>
      </.form>
    </Layouts.app>
    """
  end

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    case socket.assigns.current_scope do
      %Scope{user: user} ->
        case Review.get_review_decision(id, user.id) do
          {:ok, %ReviewDecision{} = review_decision} ->
            # Pre-populate decision_data with original_data for editing
            decision_data = review_decision.original_data || %{}
            
            changeset = ReviewDecision.changeset_for_update(review_decision, %{})
            form = to_form(changeset)
            
            {:ok,
             socket
             |> assign(:review_decision, review_decision)
             |> assign(:form, form)
             |> assign(:decision_data, decision_data)
             |> assign(:status_options, ["pending", "approved", "rejected", "amended"])
             |> assign(:decision_type_options, ["initial", "amended", "approved", "rejected"])}
          
          {:error, reason} ->
            {:ok, put_flash(socket, :error, reason) |> redirect(to: ~p"/reviews")}
        end
      _ ->
        {:ok, put_flash(socket, :error, "Not authenticated") |> redirect(to: ~p"/")}
    end
  end

  @impl true
  def handle_event("save", %{"review_decision" => params}, socket) do
    # Extract decision_data from nested params
    decision_data = extract_nested_params(params, "decision_data")
    
    attrs = %{
      decision_data: decision_data,
      review_status: params["review_status"],
      decision_type: params["decision_type"],
      review_notes: params["review_notes"],
      review_completed_at: DateTime.utc_now(),
      status: "completed"
    }

    case Review.update_review_decision(socket.assigns.review_decision, attrs) do
      {:ok, _review_decision} ->
        {:noreply,
         socket
         |> put_flash(:info, "Review updated successfully")
         |> redirect(to: ~p"/reviews")}
      
      {:error, changeset} ->
        form = to_form(changeset)
        {:noreply, assign(socket, :form, form)}
    end
  end

  defp extract_nested_params(params, prefix) do
    params
    |> Enum.filter(fn {k, _} -> String.starts_with?(k, "#{prefix}[") end)
    |> Enum.map(fn {k, v} ->
      # k is like "decision_data[invoice_number]"
      # Remove the prefix and brackets: "decision_data[" -> "", "]" -> ""
      key = k |> String.replace("#{prefix}[", "") |> String.replace("]", "")
      {key, v}
    end)
    |> Map.new()
  end
end
