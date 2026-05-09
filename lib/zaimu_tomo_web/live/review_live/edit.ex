defmodule ZaimuTomoWeb.ReviewLive.Edit do
  use ZaimuTomoWeb, :live_view

  alias ZaimuTomo.Review
  alias ZaimuTomo.Review.ReviewDecision
  alias ZaimuTomo.Accounting
  alias ZaimuTomo.Accounts.Scope

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <.header>
        Amend Review
      </.header>

      <.form for={@form} phx-submit="save" id="review_form">
        <div class="grid grid-cols-1 md:grid-cols-2 gap-4">
          <.input field={@form[:review_status]} label="Status" type="select" options={@status_options} />
        </div>

        <div class="my-6 border-t border-gray-200 dark:border-gray-700" />

        <h3 class="text-lg font-medium text-gray-900 dark:text-white mb-4">Invoice Data (Amended)</h3>
        <div class="grid grid-cols-1 md:grid-cols-2 gap-4">
          <.input name="decision_data[invoice_number]" value={@decision_data.invoice_number || ""} label="Invoice Number" />
          <.input name="decision_data[invoice_date]" value={@decision_data.invoice_date || ""} label="Invoice Date" />
          <div class="md:col-span-2">
            <.input name="decision_data[issuer]" value={@decision_data.issuer || ""} label="Issuer" />
          </div>
          <.input name="decision_data[amount_to_pay_cents]" value={@decision_data.amount_to_pay_cents || ""} label="Amount (cents)" type="number" />
          <.input name="decision_data[currency]" value={@decision_data.currency || ""} label="Currency" />
          <div class="md:col-span-2">
            <.input name="decision_data[reason_for_payment]" value={@decision_data.reason_for_payment || ""} label="Reason for Payment" type="textarea" />
          </div>
        </div>

        <div class="my-6 border-t border-gray-200 dark:border-gray-700" />

        <.input field={@form[:review_notes]} label="Review Notes" type="textarea" />

        <div class="mt-6 flex justify-between items-center">
          <.button type="submit" variant="primary">
            <.icon name="hero-check" /> Save Amendments
          </.button>
          <.button patch={~p"/reviews/#{@review_decision}"} class="btn btn-neutral">
            <.icon name="hero-x-mark" /> Cancel
          </.button>
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
            decision_data = review_decision.original_data || %ZaimuTomo.DocumentProcessing.ExtractedData{}
            
            changeset = ReviewDecision.changeset_for_update(review_decision, %{})

            {:ok,
             socket
             |> assign(:review_decision, review_decision)
             |> assign(:form, to_form(changeset))
             |> assign(:decision_data, decision_data)
             |> assign(:status_options, ["pending", "approved", "rejected", "amended"])}
          
          {:error, reason} ->
            {:ok, put_flash(socket, :error, reason) |> redirect(to: ~p"/reviews")}
        end
      _ ->
        {:ok, put_flash(socket, :error, "Not authenticated") |> redirect(to: ~p"/")}
    end
  end

  @impl true
  def handle_event("save", %{"review_decision" => form_params} = params, socket) do
    decision_data = Map.get(params, "decision_data", %{})
    review_status = form_params["review_status"]
    notes = form_params["review_notes"]
    user_id = socket.assigns.current_scope.user.id
    extracted_content_id = socket.assigns.review_decision.extracted_content_id

    result =
      case review_status do
        "approved" -> Review.approve_invoice(extracted_content_id, user_id, notes)
        "rejected" -> Review.reject_invoice(extracted_content_id, user_id, notes)
        "amended"  -> Review.amend_invoice(extracted_content_id, user_id, decision_data, notes)
        _          -> {:error, "Invalid status"}
      end

    case result do
      {:ok, decision} when review_status in ["approved", "amended"] ->
        {:noreply, redirect_to_journal_entry(socket, decision, "Review saved successfully")}

      {:ok, _} when review_status == "rejected" ->
        {:noreply, socket |> put_flash(:info, "Review saved successfully") |> redirect(to: ~p"/reviews")}

      {:error, reason} when is_binary(reason) ->
        {:noreply, put_flash(socket, :error, reason)}

      {:error, changeset} ->
        {:noreply, assign(socket, :form, to_form(changeset))}
    end
  end

  defp redirect_to_journal_entry(socket, decision, flash_msg) do
    case Accounting.create_from_decision(decision) do
      {result, entry} when result in [:ok, :duplicate] ->
        socket |> put_flash(:info, flash_msg) |> redirect(to: ~p"/journal_entries/#{entry}")
      {:error, _} ->
        socket |> put_flash(:info, flash_msg) |> redirect(to: ~p"/reviews")
    end
  end
end
