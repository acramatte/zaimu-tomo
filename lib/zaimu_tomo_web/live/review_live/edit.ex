defmodule ZaimuTomoWeb.ReviewLive.Edit do
  use ZaimuTomoWeb, :live_view

  alias ZaimuTomo.Review
  alias ZaimuTomo.Review.ReviewDecision
  alias ZaimuTomo.Accounting
  alias ZaimuTomo.DocumentProcessing.ExtractedData
  alias ZaimuTomo.Accounts.Scope

  @impl true
  def render(assigns) do
    ~H"""
    <div style="display:flex;align-items:center;gap:12px;margin-bottom:6px">
      <a class="btn sm" href={~p"/reviews/#{@review_decision}"}>← Back</a>
    </div>
    <h1 class="view-title" style="margin-top:8px">Amend invoice</h1>

    <div
      :if={@duplicates.candidates != []}
      style="max-width:640px;margin-top:16px;border:1px solid var(--warn);border-radius:8px;padding:14px"
    >
      <div style="font-weight:600;margin-bottom:6px">
        {if @duplicates.strong?, do: "Invoice already recorded", else: "Possible duplicate"}
      </div>
      <div class="muted" style="font-size:14px;margin-bottom:10px">
        <%= if @duplicates.strong? do %>
          This invoice number is already recorded for this issuer. Correct the data below before posting.
        <% else %>
          An invoice with the same issuer, date, amount, and currency was already recorded. Verify the document before posting.
        <% end %>
      </div>
      <.duplicate_candidate :for={candidate <- @duplicates.candidates} candidate={candidate} />
      <button
        :if={not @duplicates.strong? and @pending_save}
        class="btn sm primary"
        type="button"
        phx-click="confirm_duplicate_save"
        phx-disable-with="Posting…"
      >
        Post anyway
      </button>
    </div>

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
             |> assign(
               :duplicates,
               duplicates(review_decision, decision_data, false)
             )
             |> assign(:pending_save, nil)
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
    notes = form_params["review_notes"]
    user_id = socket.assigns.current_scope.user.id
    extracted_content_id = socket.assigns.review_decision.extracted_content_id
    extracted = to_extracted_data(decision_data)
    duplicates = duplicates(socket.assigns.review_decision, extracted, true)

    cond do
      duplicates.strong? ->
        {:noreply,
         socket
         |> assign(:duplicates, duplicates)
         |> assign(:pending_save, nil)
         |> put_flash(:error, "This invoice number has already been recorded for this issuer")}

      duplicates.candidates != [] and is_nil(socket.assigns.pending_save) ->
        {:noreply,
         socket
         |> assign(:duplicates, duplicates)
         |> assign(:pending_save, {decision_data, notes})}

      true ->
        save(socket, extracted_content_id, user_id, decision_data, notes)
    end
  end

  @impl true
  def handle_event("confirm_duplicate_save", _params, socket) do
    case socket.assigns.pending_save do
      {decision_data, notes} ->
        user_id = socket.assigns.current_scope.user.id
        extracted_content_id = socket.assigns.review_decision.extracted_content_id
        {:noreply, save(socket, extracted_content_id, user_id, decision_data, notes)}

      nil ->
        {:noreply, socket}
    end
  end

  defp save(socket, extracted_content_id, user_id, decision_data, notes) do
    case Review.amend_invoice(extracted_content_id, user_id, decision_data, notes) do
      {:ok, decision} ->
        {:noreply, redirect_to_journal_entry(socket, decision, "Review saved successfully")}

      {:error, :duplicate_invoice} ->
        {:noreply,
         socket
         |> assign(
           :duplicates,
           duplicates(socket.assigns.review_decision, to_extracted_data(decision_data), true)
         )
         |> assign(:pending_save, nil)
         |> put_flash(:error, "This invoice number has already been recorded for this issuer")}

      {:error, reason} when is_binary(reason) ->
        {:noreply, put_flash(socket, :error, reason)}

      {:error, changeset} ->
        {:noreply, assign(socket, :form, to_form(changeset))}
    end
  end

  # The submitted form data (string keys, string amounts) checked against
  # recorded entries before the review is amended and posted.
  defp to_extracted_data(decision_data) when is_map(decision_data) do
    attrs =
      decision_data
      |> Map.new(fn {k, v} -> {String.to_atom(k), blank_to_nil(v)} end)

    struct(ExtractedData, attrs)
  end

  defp to_extracted_data(_), do: %ExtractedData{}

  defp blank_to_nil(nil), do: nil
  defp blank_to_nil(""), do: nil
  defp blank_to_nil(value), do: value

  defp duplicates(%ReviewDecision{} = decision, data, _from_form) do
    candidates = Accounting.duplicate_candidates(decision.user_id, data)
    %{candidates: candidates, strong?: Accounting.strong_candidate?(candidates)}
  end

  defp redirect_to_journal_entry(socket, decision, flash_msg) do
    case Accounting.get_journal_entry_for_decision(decision.id) do
      {:ok, entry} ->
        socket |> put_flash(:info, flash_msg) |> redirect(to: ~p"/journal_entries/#{entry}")

      :error ->
        socket
        |> put_flash(
          :error,
          "Could not create journal entry because the invoice date is missing or invalid"
        )
        |> redirect(to: ~p"/reviews/#{decision}")
    end
  end
end
