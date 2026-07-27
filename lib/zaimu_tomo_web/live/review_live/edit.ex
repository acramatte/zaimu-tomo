defmodule ZaimuTomoWeb.ReviewLive.Edit do
  use ZaimuTomoWeb, :live_view

  alias ZaimuTomo.Review
  alias ZaimuTomo.Review.ReviewDecision
  alias ZaimuTomo.Accounting
  alias ZaimuTomo.Accounts.Scope

  @impl true
  def render(assigns) do
    ~H"""
    <div style="display:flex;align-items:center;gap:12px;margin-bottom:6px">
      <a class="btn sm" href={~p"/reviews/#{@review_decision}"}>← Back</a>
    </div>
    <h1 class="view-title" style="margin-top:8px">Amend invoice</h1>

    <div class="card" style="max-width:640px;margin-top:16px">
      <.form for={@form} phx-submit="save" id="review_form">
        <div class="card-head" style="margin-bottom:12px">
          <div class="card-title">Corrected data</div>
        </div>
        <div style="display:grid;gap:12px">
          <.input name="decision_data[issuer]" value={@decision_data.issuer || ""} label="Issuer" />
          <div style="display:grid;grid-template-columns:1fr 1fr;gap:12px">
            <.input
              name="decision_data[invoice_number]"
              value={@decision_data.invoice_number || ""}
              label="Invoice #"
            />
            <.input
              name="decision_data[invoice_date]"
              value={@decision_data.invoice_date || ""}
              label="Date"
            />
          </div>
          <div style="display:grid;grid-template-columns:1fr 1fr;gap:12px">
            <.input
              name="decision_data[amount_to_pay_cents]"
              value={@decision_data.amount_to_pay_cents || ""}
              label="Amount (cents)"
              type="number"
            />
            <.input
              name="decision_data[currency]"
              value={@decision_data.currency || ""}
              label="Currency"
            />
          </div>
          <.input
            name="decision_data[reason_for_payment]"
            value={@decision_data.reason_for_payment || ""}
            label="Reason for payment"
            type="textarea"
          />
          <.input field={@form[:review_notes]} label="Internal notes" type="textarea" />
        </div>

        <div style="margin-top:16px;display:flex;gap:8px">
          <.button type="submit" variant="primary" phx-disable-with="Saving…">
            Amend &amp; post
          </.button>
          <a class="btn sm" href={~p"/reviews/#{@review_decision}"}>Cancel</a>
        </div>
      </.form>
    </div>
    """
  end

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    case socket.assigns.current_scope do
      %Scope{user: user} ->
        case Review.get_review_decision(id, user.id) do
          {:ok, %ReviewDecision{} = review_decision} ->
            decision_data =
              review_decision.original_data || %ZaimuTomo.DocumentProcessing.ExtractedData{}

            changeset = ReviewDecision.changeset_for_update(review_decision, %{})

            {:ok,
             socket
             |> assign(:page_title, "Amend invoice")
             |> assign(:current_path, "/reviews")
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
        "amended" -> Review.amend_invoice(extracted_content_id, user_id, decision_data, notes)
        _ -> {:error, "Invalid status"}
      end

    case result do
      {:ok, decision} when review_status in ["approved", "amended"] ->
        {:noreply, redirect_to_journal_entry(socket, decision, "Review saved successfully")}

      {:ok, _} when review_status == "rejected" ->
        {:noreply,
         socket |> put_flash(:info, "Review saved successfully") |> redirect(to: ~p"/reviews")}

      {:error, reason} when is_binary(reason) ->
        {:noreply, put_flash(socket, :error, reason)}

      {:error, changeset} ->
        {:noreply, assign(socket, :form, to_form(changeset))}
    end
  end

  defp redirect_to_journal_entry(socket, decision, flash_msg) do
    case Accounting.create_from_decision(decision) do
      {:ok, entry} ->
        socket |> put_flash(:info, flash_msg) |> redirect(to: ~p"/journal_entries/#{entry}")

      {:error, _changeset} ->
        socket
        |> put_flash(
          :error,
          "Could not create journal entry because the invoice date is missing or invalid"
        )
        |> redirect(to: ~p"/reviews/#{decision}")
    end
  end
end
