defmodule ZaimuTomoWeb.ReviewLive.Edit do
  use ZaimuTomoWeb, :live_view

  alias ZaimuTomo.Review
  alias ZaimuTomo.Review.ReviewDecision
  alias ZaimuTomo.Accounting
  alias ZaimuTomo.DocumentProcessing.ExtractedData
  alias ZaimuTomo.Accounts.Scope
  alias ZaimuTomoWeb.ReviewLive.Duplicates

  @impl true
  def render(assigns) do
    ~H"""
    <div style="display:flex;align-items:center;gap:12px;margin-bottom:6px">
      <a class="btn sm" href={~p"/reviews/#{@review_decision}"}>← Back</a>
    </div>
    <h1 class="view-title" style="margin-top:8px">Amend invoice</h1>

    <div
      :if={@duplicates.candidates != []}
      id="duplicate-panel"
      style="max-width:640px;margin-top:16px;border:1px solid var(--warn);border-radius:8px;padding:14px"
    >
      <div style="font-weight:600;margin-bottom:6px">
        {Duplicates.title(@duplicates.verdict)}
      </div>
      <div class="muted" style="font-size:14px;margin-bottom:10px">
        <%= case @duplicates.verdict do %>
          <% :same_file_blocked -> %>
            This is the same uploaded file as a recorded entry, and the details below match it. Reject this duplicate review.
          <% :file_reuse -> %>
            Same file as the entry posted on {Duplicates.file_match_posted_on(@duplicates)}. Is this a reused bill for a new period?
          <% :invoice_number -> %>
            This invoice number is already recorded for this issuer. Correct the data below before posting.
          <% _ -> %>
            An invoice with the same issuer, date, amount, and currency was already recorded. Verify the document before posting.
        <% end %>
      </div>
      <.duplicate_candidate
        :for={%{entry: entry, reason: reason} <- @duplicates.candidates}
        candidate={entry}
        reason={reason}
      />
      <button
        :if={pending_verdict(@pending_save) == :possible}
        class="btn sm primary"
        type="button"
        phx-click="confirm_duplicate_save"
        phx-disable-with="Posting…"
      >
        Post anyway
      </button>
      <button
        :if={pending_verdict(@pending_save) == :file_reuse}
        id="confirm-file-reuse"
        class="btn sm primary"
        type="button"
        phx-click="confirm_file_reuse_save"
        phx-disable-with="Posting…"
      >
        Yes, post as a reused bill
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
               duplicates(review_decision, decision_data)
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
    duplicates = duplicates(socket.assigns.review_decision, to_extracted_data(decision_data))

    # A possible duplicate or an exact-file match always needs the explicit
    # confirmation for the data just submitted; saving again re-checks and
    # re-asks.
    case duplicates.verdict do
      :none ->
        save(socket, decision_data, notes, [])

      verdict when verdict in [:possible, :file_reuse] ->
        {:noreply,
         socket
         |> assign(:duplicates, duplicates)
         |> assign(:pending_save, %{verdict: verdict, data: decision_data, notes: notes})}

      verdict ->
        {:noreply,
         socket
         |> assign(:duplicates, duplicates)
         |> assign(:pending_save, nil)
         |> put_flash(:error, Duplicates.refusal_message(verdict))}
    end
  end

  @impl true
  def handle_event("confirm_duplicate_save", _params, socket) do
    case socket.assigns.pending_save do
      %{verdict: :possible, data: decision_data, notes: notes} ->
        save(socket, decision_data, notes, [])

      _ ->
        {:noreply, socket}
    end
  end

  @impl true
  def handle_event("confirm_file_reuse_save", _params, socket) do
    case socket.assigns.pending_save do
      %{verdict: :file_reuse, data: decision_data, notes: notes} ->
        save(socket, decision_data, notes, confirm_file_reuse: true)

      _ ->
        {:noreply, socket}
    end
  end

  defp save(socket, decision_data, notes, opts) do
    user_id = socket.assigns.current_scope.user.id
    extracted_content_id = socket.assigns.review_decision.extracted_content_id

    case Review.amend_invoice(extracted_content_id, user_id, decision_data, notes, opts) do
      {:ok, decision} ->
        {:noreply, redirect_to_journal_entry(socket, decision, "Review saved successfully")}

      {:error, reason} when reason in [:duplicate_invoice, :file_reuse_not_applicable] ->
        duplicates =
          duplicates(socket.assigns.review_decision, to_extracted_data(decision_data))

        {:noreply,
         socket
         |> assign(:duplicates, duplicates)
         |> assign(:pending_save, nil)
         |> put_flash(:error, Duplicates.refusal_message(duplicates.verdict))}

      {:error, reason} when is_binary(reason) ->
        {:noreply, put_flash(socket, :error, reason)}

      {:error, changeset} ->
        {:noreply, assign(socket, :form, to_form(changeset))}
    end
  end

  defp pending_verdict(%{verdict: verdict}), do: verdict
  defp pending_verdict(nil), do: nil

  # Casts the submitted form data with the invoice schema, so the duplicate
  # pre-check compares the same typed values the amendment would persist.
  # Values that fail to cast (for example, a non-integer amount) stay nil and
  # never match.
  defp to_extracted_data(decision_data) when is_map(decision_data) do
    decision_data
    |> ExtractedData.changeset()
    |> Ecto.Changeset.apply_changes()
  end

  defp to_extracted_data(_), do: %ExtractedData{}

  defp duplicates(%ReviewDecision{} = decision, %ExtractedData{} = data) do
    Review.duplicate_check(decision, data)
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
