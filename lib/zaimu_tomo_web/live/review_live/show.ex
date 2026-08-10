defmodule ZaimuTomoWeb.ReviewLive.Show do
  use ZaimuTomoWeb, :live_view

  alias ZaimuTomo.Review
  alias ZaimuTomo.Review.ReviewDecision
  alias ZaimuTomo.Accounting
  alias ZaimuTomo.Accounting.TaxDeductionClaim
  alias ZaimuTomo.Accounts.Scope

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    case socket.assigns.current_scope do
      %Scope{user: user} ->
        case Review.get_review_decision(id, user.id) do
          {:ok, %ReviewDecision{} = rd} ->
            {:ok,
             socket
             |> assign(:page_title, review_title(rd))
             |> assign(:current_path, "/reviews")
             |> assign(:review_decision, rd)
             |> assign(:verification, verifier_feedback(rd))
             |> assign(:rejection_form, to_form(ReviewDecision.changeset_for_update(rd, %{})))
             |> assign(:approval_form, to_form(%{"status" => "undecided"}, as: :tax_claim))
             |> assign(:show_rejection_form, false)
             |> assign(:effective_data, rd.decision_data || rd.original_data)
             |> assign(:feedback, feedback_assigns(rd))}

          {:error, reason} ->
            {:ok, put_flash(socket, :error, reason) |> redirect(to: ~p"/reviews")}
        end

      _ ->
        {:ok, put_flash(socket, :error, "Not authenticated") |> redirect(to: ~p"/")}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div style="display:flex;align-items:center;gap:12px;margin-bottom:6px">
      <a class="btn sm" href={~p"/reviews"}>← Reviews</a>
      <.status_pill status={pill_status(@review_decision.review_status)} />
    </div>
    <h1 class="view-title" style="margin-top:8px">{@page_title}</h1>

    <section :if={@verification} class="card" style="margin:16px 0;border-color:var(--warn)">
      <div class="card-head" style="margin-bottom:10px">
        <div class="card-title">Verifier flagged this extraction</div>
        <.status_pill status="review" />
      </div>
      <div class="detail-row">
        <div class="name muted">Verifier result</div>
        <div>{verification_status_label(@verification["status"])}</div>
      </div>
      <div :if={@verification["field_issues"]} class="detail-row">
        <div class="name muted">Flagged fields</div>
        <div class="mono dim">{@verification["field_issues"]}</div>
      </div>
      <div class="detail-row">
        <div class="name muted">Reason</div>
        <div>{@verification["reason"]}</div>
      </div>
    </section>

    <div class="grid grid-12">
      <div class="card span-7">
        <div class="card-head">
          <div class="card-title">Invoice data</div>
          <div :if={@review_decision.review_status == "pending"} class="card-meta">
            <a class="btn sm" href={~p"/reviews/#{@review_decision}/edit"}>Amend</a>
          </div>
        </div>
        <div
          class="detail-row"
          style="border-bottom:1px solid var(--hairline);padding-bottom:10px;margin-bottom:10px"
        >
          <div class="name muted">Amount</div>
          <div class="num" style="font-size:20px;font-weight:600">
            {if @effective_data.amount_to_pay_cents && @effective_data.currency,
              do: fmt_cents(@effective_data.amount_to_pay_cents, @effective_data.currency),
              else: "—"}
          </div>
        </div>
        <div class="detail-row">
          <div class="name muted">Issuer</div>
          <div>{@effective_data.issuer || "—"}</div>
        </div>
        <div class="detail-row">
          <div class="name muted">Date</div>
          <div>{@effective_data.invoice_date || "—"}</div>
        </div>
        <div class="detail-row">
          <div class="name muted">Invoice #</div>
          <div class="mono dim">{@effective_data.invoice_number || "—"}</div>
        </div>
        <div class="detail-row">
          <div class="name muted">Currency</div>
          <div>{@effective_data.currency || "—"}</div>
        </div>
        <div class="detail-row">
          <div class="name muted">Reason</div>
          <div>{@effective_data.reason_for_payment || "—"}</div>
        </div>
        <div
          :if={@review_decision.review_notes}
          class="detail-row"
          style="margin-top:8px;border-top:1px solid var(--hairline);padding-top:10px"
        >
          <div class="name muted">Notes</div>
          <div>{@review_decision.review_notes}</div>
        </div>
      </div>

      <div class="card span-5">
        <div class="card-head">
          <div class="card-title">Decision</div>
        </div>
        <div class="detail-row">
          <div class="name muted">Submitted</div>
          <div>
            {ZaimuTomoWeb.Layouts.rel_time(DateTime.to_iso8601(@review_decision.inserted_at))}
          </div>
        </div>
        <div :if={@review_decision.rejection_reason} class="detail-row">
          <div class="name muted">Rejection reason</div>
          <div>{@review_decision.rejection_reason}</div>
        </div>
        <%= if @review_decision.review_status == "pending" do %>
          <%= if @show_rejection_form do %>
            <.form
              for={@rejection_form}
              phx-submit="reject"
              id="rejection_form"
              style="margin-top:16px"
            >
              <.input
                field={@rejection_form[:rejection_reason]}
                label="Why are you rejecting this invoice?"
                type="textarea"
                placeholder="For example: duplicate invoice or incorrect extraction"
                required
              />
              <div style="display:flex;gap:8px">
                <.button type="submit" phx-disable-with="Rejecting…">Reject invoice</.button>
                <button class="btn sm" type="button" phx-click="hide_rejection_form">Cancel</button>
              </div>
            </.form>
          <% else %>
            <div style="margin-top:16px">
              <.form for={@approval_form} id="approval-form" phx-submit="approve">
                <.input
                  field={@approval_form[:status]}
                  type="select"
                  label="Tax treatment"
                  options={TaxDeductionClaim.status_options()}
                />
                <div style="display:flex;gap:8px">
                  <button class="btn sm primary" type="submit" phx-disable-with="Approving…">
                    Approve &amp; post
                  </button>
                  <button class="btn sm" type="button" phx-click="show_rejection_form">Reject</button>
                </div>
              </.form>
            </div>
          <% end %>
        <% end %>
      </div>

      <div :if={@feedback.available?} class="card span-12" style="margin-top:16px">
        <div class="card-head">
          <div class="card-title">Extraction feedback</div>
          <div class="card-meta">Sent to Langfuse as a score on this document's trace</div>
        </div>
        <p class="muted" style="margin-bottom:12px">
          Did the extracted data match the document? Your feedback helps improve the extraction
          pipeline.
        </p>
        <%= if @feedback.submitted do %>
          <div class="detail-row">
            <div class="name muted">Thanks!</div>
            <div>Your feedback has been recorded.</div>
          </div>
        <% else %>
          <%= if @feedback.value do %>
            <div style="display:flex;align-items:center;gap:12px;margin-bottom:12px">
              <span class="muted" style="font-size:14px">
                {if @feedback.value == 1, do: "👍 Correct", else: "👎 Incorrect"}
              </span>
              <button class="btn sm" type="button" phx-click="clear_feedback">Change</button>
            </div>
            <.form for={@feedback.form} phx-submit="submit_feedback" id="feedback_form">
              <.input
                field={@feedback.form[:comment]}
                label="Optional comment"
                type="textarea"
                placeholder={
                  if @feedback.value == 1,
                    do: "Anything that was extracted especially well?",
                    else: "For example: the amount was parsed incorrectly"
                }
              />
              <div style="display:flex;gap:8px">
                <.button type="submit" phx-disable-with="Sending…">Send feedback</.button>
                <button class="btn sm" type="button" phx-click="clear_feedback">Cancel</button>
              </div>
            </.form>
          <% else %>
            <div style="display:flex;gap:8px">
              <button class="btn sm" phx-click="select_feedback" phx-value-thumbs="1">
                👍 Correct
              </button>
              <button class="btn sm" phx-click="select_feedback" phx-value-thumbs="0">
                👎 Incorrect
              </button>
            </div>
          <% end %>
        <% end %>
      </div>
    </div>
    """
  end

  @impl true
  def handle_event("approve", %{"tax_claim" => tax_claim_attrs}, socket) do
    user_id = socket.assigns.current_scope.user.id
    extracted_content_id = socket.assigns.review_decision.extracted_content_id

    case Review.approve_invoice(extracted_content_id, user_id) do
      {:ok, decision} ->
        {:noreply,
         redirect_to_journal_entry(
           socket,
           decision,
           "Invoice approved and posted",
           tax_claim_attrs
         )}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, reason)}
    end
  end

  @impl true
  def handle_event("show_rejection_form", _params, socket) do
    {:noreply, assign(socket, :show_rejection_form, true)}
  end

  @impl true
  def handle_event("hide_rejection_form", _params, socket) do
    {:noreply, assign(socket, :show_rejection_form, false)}
  end

  @impl true
  def handle_event("reject", %{"review_decision" => params}, socket) do
    user_id = socket.assigns.current_scope.user.id
    extracted_content_id = socket.assigns.review_decision.extracted_content_id
    rejection_reason = params["rejection_reason"]

    case Review.reject_invoice(extracted_content_id, user_id, rejection_reason) do
      {:ok, _} ->
        {:noreply, socket |> put_flash(:info, "Invoice rejected") |> redirect(to: ~p"/reviews")}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply,
         socket
         |> assign(:rejection_form, to_form(changeset))
         |> assign(:show_rejection_form, true)}

      {:error, reason} when is_binary(reason) ->
        {:noreply, put_flash(socket, :error, reason)}
    end
  end

  @impl true
  def handle_event("select_feedback", %{"thumbs" => value}, socket)
      when value in ["0", "1"] do
    feedback = socket.assigns.feedback
    {:noreply, assign(socket, :feedback, %{feedback | value: String.to_integer(value)})}
  end

  @impl true
  def handle_event("clear_feedback", _params, socket) do
    feedback = socket.assigns.feedback

    {:noreply,
     assign(socket, :feedback, %{
       feedback
       | value: nil,
         form: to_form(%{"comment" => ""}, as: :feedback)
     })}
  end

  @impl true
  def handle_event("submit_feedback", %{"feedback" => %{"comment" => comment}}, socket) do
    user_id = socket.assigns.current_scope.user.id
    extracted_content_id = socket.assigns.review_decision.extracted_content_id
    feedback = socket.assigns.feedback

    case Review.submit_extraction_feedback(
           extracted_content_id,
           user_id,
           feedback.value,
           comment
         ) do
      :ok ->
        {:noreply, assign(socket, :feedback, %{feedback | submitted: true})}

      {:error, reason} when is_binary(reason) ->
        {:noreply, put_flash(socket, :error, reason)}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, "Could not record feedback. Please try again.")}
    end
  end

  defp redirect_to_journal_entry(socket, decision, flash_msg, tax_claim_attrs) do
    case Accounting.create_from_decision(decision, tax_claim_attrs) do
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

  defp review_title(%ReviewDecision{} = rd) do
    data = rd.decision_data || rd.original_data

    cond do
      data.issuer && data.invoice_number -> "#{data.issuer} — #{data.invoice_number}"
      data.issuer -> data.issuer
      data.invoice_number -> "Invoice #{data.invoice_number}"
      true -> "Invoice review"
    end
  end

  defp pill_status("pending"), do: "review"
  defp pill_status(s) when s in ["approved", "amended"], do: "posted"
  defp pill_status("rejected"), do: "failed"
  defp pill_status(other), do: other

  defp verifier_feedback(%ReviewDecision{
         extracted_content: %{analysis: %{"verification" => %{"status" => status} = verification}}
       })
       when status in ["needs_review", "rejected", "verification_failed"],
       do: verification

  defp verifier_feedback(_review_decision), do: nil

  defp verification_status_label("rejected"), do: "Rejected"
  defp verification_status_label("needs_review"), do: "Needs review"
  defp verification_status_label("verification_failed"), do: "Could not verify"

  defp feedback_assigns(%ReviewDecision{} = rd) do
    %{
      # Feedback is only meaningful while the review is open and a Langfuse
      # trace exists to attach the score to.
      available?: rd.review_status == "pending" && trace_id(rd) != nil,
      value: nil,
      submitted: false,
      form: to_form(%{"comment" => ""}, as: :feedback)
    }
  end

  defp trace_id(%ReviewDecision{} = rd) do
    case rd.extracted_content do
      %{trace_id: trace_id} when is_binary(trace_id) -> trace_id
      _ -> nil
    end
  end
end
