defmodule ZaimuTomoWeb.DocumentLive.Show do
  @moduledoc """
  The invoice page: one home for an uploaded document from upload to posted
  journal entry.

  The file preview stays on the left; the right column follows the invoice's
  lifecycle (processing, check and book, posted or rejected). Checking and
  booking is one form with one Post action, so the journal entry is created
  already categorized, with its tax treatment and the reviewer's comment.
  """
  use ZaimuTomoWeb, :live_view

  alias ZaimuTomo.Accounting
  alias ZaimuTomo.Accounting.JournalEntry
  alias ZaimuTomo.Accounting.TaxDeductionClaim
  alias ZaimuTomo.DocumentProcessing
  alias ZaimuTomo.DocumentProcessing.ExtractedData
  alias ZaimuTomo.Documents
  alias ZaimuTomo.MediaPreview
  alias ZaimuTomo.Review
  alias ZaimuTomo.Review.ReviewDecision
  alias ZaimuTomoWeb.DocumentLive.Duplicates

  @data_fields ~w(issuer amount currency invoice_date invoice_number reason_for_payment)
  # journal_entries.amount_cents is a 4-byte integer.
  @max_amount_cents 2_147_483_647

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    if connected?(socket) do
      Documents.subscribe_documents(socket.assigns.current_scope)
      DocumentProcessing.subscribe_events(socket.assigns.current_scope)
    end

    document = Documents.get_document_with_content!(socket.assigns.current_scope, id)

    socket =
      socket
      |> assign(:current_path, "/documents")
      |> assign(:preview_kind, preview_kind(document))
      |> assign(:categories, Accounting.list_categories(socket.assigns.current_scope))
      |> assign(:show_rejection_form, false)
      |> assign(:feedback_value, nil)
      |> assign(:duplicate_error, false)
      |> load_document(document)

    if connected?(socket), do: schedule_refresh(socket.assigns.processing_state)

    {:ok, socket}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div style="display:flex;align-items:center;gap:12px;margin-bottom:6px">
      <.link class="btn sm" navigate={~p"/documents"}>← Documents</.link>
      <span id="invoice-status">
        <.status_pill status={stage_pill(@stage, @processing_state, @entry)} />
      </span>
      <button
        :if={@processing_state in [:failed, :stuck]}
        type="button"
        phx-click="retry_processing"
        class="btn sm"
      >
        <.icon name="hero-arrow-path" class="w-4 h-4" /> Retry processing
      </button>
    </div>
    <h1 class="view-title" style="margin-top:8px">{@page_title}</h1>
    <p class="view-sub">{subtitle(@stage, @data, @document)}</p>

    <div class="review-layout">
      <aside class="card review-doc" id="review-document-viewer">
        <div class="review-doc-toolbar">
          <.icon name="hero-document" class="ico muted" />
          <span class="review-doc-name" title={@document.filename}>{@document.filename}</span>
          <.document_actions document={@document} preview_kind={@preview_kind} />
        </div>
        <div
          class="review-doc-body"
          id="review-document-body"
          phx-hook=".DesktopPreview"
          phx-update="ignore"
        >
          <%= case @preview_kind do %>
            <% :pdf -> %>
              <iframe
                data-src={~p"/documents/#{@document}/preview" <> "#navpanes=0&view=FitH"}
                title={"Preview of #{@document.filename}"}
              ></iframe>
            <% :image -> %>
              <div class="doc-modal-image">
                <img data-src={~p"/documents/#{@document}/preview"} alt={@document.filename} />
              </div>
            <% nil -> %>
              <div class="doc-modal-empty">
                <div class="view-sub">Inline preview not available for this file type.</div>
              </div>
          <% end %>
        </div>
        <script :type={Phoenix.LiveView.ColocatedHook} name=".DesktopPreview">
          // The viewer is hidden below 1025px (see .review-doc in zaimutomo.css),
          // where the Source document card links out instead. Browsers still fetch
          // hidden iframes, so only set src once the viewer can actually show.
          export default {
            mounted() {
              this.media = window.matchMedia("(min-width: 1025px)")
              this.load = () => {
                if (!this.media.matches) return
                this.el.querySelectorAll("[data-src]").forEach((el) => {
                  el.src = el.dataset.src
                  el.removeAttribute("data-src")
                })
              }
              this.load()
              this.media.addEventListener("change", this.load)
            },
            destroyed() {
              this.media.removeEventListener("change", this.load)
            }
          }
        </script>
      </aside>

      <div class="review-main">
        <section class="card review-doc-card" id="review-document-card">
          <div class="review-doc-card-body">
            <div class="review-doc-card-icon">
              <.icon name="hero-document-text" class="w-6 h-6" />
            </div>
            <div style="min-width:0">
              <div class="review-doc-name" title={@document.filename}>{@document.filename}</div>
              <div class="muted" style="font-size:12px;margin-top:2px">
                {file_type_label(@document)}{if !@preview_kind, do: " · Preview not available"}
              </div>
              <div style="display:flex;flex-wrap:wrap;gap:8px;margin-top:10px">
                <.document_actions document={@document} preview_kind={@preview_kind} />
              </div>
            </div>
          </div>
        </section>

        <ol class="invoice-steps" id="invoice-steps" aria-label="Invoice progress">
          <li :for={{label, state} <- steps(@stage)} class={"invoice-step #{state}"}>
            <span class="invoice-step-dot" aria-hidden="true">
              <.icon :if={state == "done"} name="hero-check" class="w-3 h-3" />
              <.icon :if={state == "bad"} name="hero-x-mark" class="w-3 h-3" />
            </span>
            {label}
          </li>
        </ol>

        <section :if={@verification && @stage == :check} class="card" style="border-color:var(--warn)">
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

        <section :if={@typesafe_shadow && @stage == :check} class="card">
          <div class="card-head" style="margin-bottom:10px">
            <div class="card-title">Quality checks</div>
            <.status_pill status={typesafe_pill_status(@typesafe_shadow["status"])} />
          </div>
          <p class="muted" style="margin:0;font-size:12px">
            Independent check: {typesafe_status_label(@typesafe_shadow["status"])}. It does not change posting.
          </p>
          <details class="quality-check-details" style="margin-top:10px">
            <summary>View independent check</summary>
            <div class="detail-row" style="margin-top:10px">
              <div class="name muted">Jev result</div>
              <div>{typesafe_status_label(@typesafe_shadow["status"])}</div>
            </div>
            <div :if={@typesafe_shadow["model"]} class="detail-row">
              <div class="name muted">Model</div>
              <div class="mono dim">{@typesafe_shadow["model"]}</div>
            </div>
            <div :if={@typesafe_shadow["max_error_probability"]} class="detail-row">
              <div class="name muted">Highest error probability</div>
              <div class="mono dim">
                {format_probability(@typesafe_shadow["max_error_probability"])}
              </div>
            </div>
            <div :if={@typesafe_shadow["review_threshold"]} class="detail-row">
              <div class="name muted">Review threshold</div>
              <div class="mono dim">{format_probability(@typesafe_shadow["review_threshold"])}</div>
            </div>
            <div :if={@typesafe_shadow["field_issues"]} class="detail-row">
              <div class="name muted">Flagged fields</div>
              <div class="mono dim">{@typesafe_shadow["field_issues"]}</div>
            </div>
            <div :if={@typesafe_shadow["error"]} class="detail-row">
              <div class="name muted">Error</div>
              <div class="mono dim">{@typesafe_shadow["error"]}</div>
            </div>
            <div :if={typesafe_field_probabilities(@typesafe_shadow) != []} class="detail-row">
              <div class="name muted">Field probabilities</div>
              <div class="mono dim">
                {typesafe_field_probabilities(@typesafe_shadow)
                |> Enum.map_join(" · ", fn {field, probability} ->
                  "#{field} #{format_probability(probability)}"
                end)}
              </div>
            </div>
          </details>
        </section>

        <div
          :if={@stage == :check and (@duplicate_error or @duplicates.candidates != [])}
          id="duplicate-panel"
          class="card"
          style="border-color:var(--warn)"
        >
          <%!-- Enter submits with the first submit button in document order, so
          this one goes before the confirmations: Enter must never confirm. --%>
          <button
            :if={@pending_verdict}
            id="invoice-default-submit"
            class="sr-only"
            type="submit"
            form="invoice-form"
            tabindex="-1"
            aria-hidden="true"
          >
            Post
          </button>
          <div class="card-title" style="margin-bottom:6px">
            {Duplicates.title(@duplicates.verdict)}
          </div>
          <div class="muted" style="font-size:14px;margin-bottom:10px">
            <%= case @duplicates.verdict do %>
              <% :same_file_blocked -> %>
                This is the same uploaded file as a recorded entry, and the invoice details match it. Reject this duplicate review.
              <% :file_reuse -> %>
                Same file as the entry posted on {Duplicates.file_match_posted_on(@duplicates)}. Is this a reused bill for a new period?
              <% :invoice_number -> %>
                This invoice number is already recorded for this issuer. Correct the data below or reject the document.
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
            :if={@pending_verdict == :possible}
            class="btn sm primary"
            type="submit"
            form="invoice-form"
            name="confirm"
            value="possible"
            phx-disable-with="Posting…"
          >
            Post anyway
          </button>
          <button
            :if={@pending_verdict == :file_reuse}
            id="confirm-file-reuse"
            class="btn sm primary"
            type="submit"
            form="invoice-form"
            name="confirm"
            value="file_reuse"
            phx-disable-with="Posting…"
          >
            Yes, post as a reused bill
          </button>
        </div>

        <%= case @stage do %>
          <% :processing -> %>
            <.processing_card document={@document} processing_state={@processing_state} />
          <% :check -> %>
            <.check_card
              values={@values}
              original={@original_values}
              changed={@changed}
              amount_error={@amount_error}
              categories={@categories}
              trace?={@trace?}
              feedback_value={@feedback_value}
              show_rejection_form={@show_rejection_form}
              rejection_form={@rejection_form}
            />
          <% :posted -> %>
            <.posted_card
              data={@data}
              changes={@changes}
              review_decision={@review_decision}
              entry={@entry}
              values={@values}
              categories={@categories}
              document={@document}
              extracted_content={@extracted_content}
            />
          <% :rejected -> %>
            <.rejected_card
              review_decision={@review_decision}
              document={@document}
              extracted_content={@extracted_content}
            />
        <% end %>
      </div>
    </div>
    """
  end

  # ── Stage cards ────────────────────────────────────────────────────────────

  attr :document, :map, required: true
  attr :processing_state, :atom, required: true

  defp processing_card(assigns) do
    ~H"""
    <div class="card" id="invoice-processing">
      <div class="card-head">
        <div class="card-title">Extracted data</div>
      </div>
      <div class="muted" style="padding:16px 0">
        <%= case @processing_state do %>
          <% :processing -> %>
            OCR in progress. The form appears here when extraction is done, usually within a minute.
          <% :stuck -> %>
            Processing stalled. No OCR run is active; retry processing to try again.
          <% :failed -> %>
            {failure_message(@document)}
          <% _ -> %>
            No extracted data available
        <% end %>
      </div>
    </div>
    """
  end

  attr :values, :map, required: true
  attr :original, :map, required: true
  attr :changed, :list, required: true
  attr :amount_error, :string, default: nil
  attr :categories, :list, required: true
  attr :trace?, :boolean, required: true
  attr :feedback_value, :integer, default: nil
  attr :show_rejection_form, :boolean, required: true
  attr :rejection_form, :map, required: true

  defp check_card(assigns) do
    ~H"""
    <div class="card" id="invoice-check">
      <.form for={%{}} as={:invoice} id="invoice-form" phx-change="validate" phx-submit="post">
        <div class="card-head" style="margin-bottom:12px">
          <div class="card-title">Extracted data</div>
          <div class="card-meta">
            {if @changed == [],
              do: "As extracted",
              else: "#{length(@changed)} corrected"}
          </div>
        </div>
        <div class="invoice-fields">
          <.data_field
            name="issuer"
            label="Issuer"
            values={@values}
            original={@original}
            changed={@changed}
          />
          <div class="invoice-field-pair">
            <.data_field
              name="amount"
              label="Amount"
              values={@values}
              original={@original}
              changed={@changed}
              inputmode="decimal"
              errors={if @amount_error, do: [@amount_error], else: []}
            />
            <.data_field
              name="currency"
              label="Currency"
              values={@values}
              original={@original}
              changed={@changed}
            />
          </div>
          <div class="invoice-field-pair">
            <.data_field
              name="invoice_date"
              label="Invoice date"
              values={@values}
              original={@original}
              changed={@changed}
              placeholder="YYYY-MM-DD"
            />
            <.data_field
              name="invoice_number"
              label="Invoice #"
              values={@values}
              original={@original}
              changed={@changed}
            />
          </div>
          <.data_field
            name="reason_for_payment"
            label="Reason for payment"
            values={@values}
            original={@original}
            changed={@changed}
          />
          <.input
            id="invoice-comment"
            name="invoice[comment]"
            value={@values["comment"]}
            type="textarea"
            label="Comment"
            placeholder={
              if @changed == [], do: "Optional", else: "Why did you correct the extracted data?"
            }
          />
        </div>

        <div class="invoice-section-title">Booking</div>
        <.booking_fields values={@values} categories={@categories} />

        <div :if={@trace?} class="invoice-feedback" id="extraction-feedback">
          <span class="muted">Extraction correct?</span>
          <button
            type="button"
            class={["btn sm", @feedback_value == 1 && "primary"]}
            phx-click="feedback"
            phx-value-thumbs="1"
            aria-pressed={to_string(@feedback_value == 1)}
          >
            👍 Correct
          </button>
          <button
            type="button"
            class={["btn sm", @feedback_value == 0 && "primary"]}
            phx-click="feedback"
            phx-value-thumbs="0"
            aria-pressed={to_string(@feedback_value == 0)}
          >
            👎 Incorrect
          </button>
          <span class="invoice-feedback-hint">
            Sent to Langfuse when you post. Without a choice, corrections count as incorrect.
          </span>
        </div>

        <div :if={!@show_rejection_form} class="invoice-actions">
          <button
            type="button"
            class="btn sm ghost danger-text"
            phx-click="show_rejection_form"
          >
            Reject
          </button>
          <button id="post-invoice" type="submit" class="btn sm primary" phx-disable-with="Posting…">
            Post to journal
          </button>
        </div>
      </.form>

      <.form
        :if={@show_rejection_form}
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
    </div>
    """
  end

  attr :name, :string, required: true
  attr :label, :string, required: true
  attr :values, :map, required: true
  attr :original, :map, required: true
  attr :changed, :list, required: true
  attr :errors, :list, default: []
  attr :rest, :global, include: ~w(inputmode placeholder)

  defp data_field(assigns) do
    assigns = assign(assigns, :changed?, assigns.name in assigns.changed)

    ~H"""
    <div class={["invoice-field", @changed? && "corrected"]}>
      <.input
        id={"invoice-#{@name}"}
        name={"invoice[#{@name}]"}
        value={@values[@name]}
        label={@label}
        errors={@errors}
        {@rest}
      />
      <div :if={@changed?} class="invoice-was">
        Extracted <s>{blank_dash(@original[@name])}</s>
        <button type="button" phx-click="undo" phx-value-field={@name}>Undo</button>
      </div>
    </div>
    """
  end

  attr :values, :map, required: true
  attr :categories, :list, required: true

  defp booking_fields(assigns) do
    ~H"""
    <div class="invoice-fields">
      <.input
        id="invoice-category"
        name="invoice[category]"
        value={@values["category"]}
        label="Budget category"
        placeholder="e.g. Software, Travel, Office"
        list="invoice-category-suggestions"
        autocomplete="off"
        required
      />
      <datalist id="invoice-category-suggestions">
        <option :for={category <- @categories} value={category} />
      </datalist>
      <div class="invoice-field-pair">
        <.input
          id="invoice-need-or-want"
          name="invoice[need_or_want]"
          value={@values["need_or_want"]}
          type="select"
          label="Need or want"
          prompt="Choose one"
          options={[Need: "need", Want: "want"]}
          required
        />
        <.input
          id="invoice-tax-treatment-status"
          name="invoice[tax_treatment_status]"
          value={@values["tax_treatment_status"]}
          type="select"
          label="Tax treatment"
          options={TaxDeductionClaim.status_options()}
        />
      </div>
    </div>
    """
  end

  attr :data, :map, required: true
  attr :changes, :list, required: true
  attr :review_decision, :map, required: true
  attr :entry, :map, default: nil
  attr :values, :map, required: true
  attr :categories, :list, required: true
  attr :document, :map, required: true
  attr :extracted_content, :map, required: true

  defp posted_card(assigns) do
    assigns = assign(assigns, :changed, Enum.map(assigns.changes, &elem(&1, 0)))

    ~H"""
    <div class="card" id="invoice-posted">
      <div class="card-head">
        <div class="card-title">Invoice</div>
        <div class="card-meta">
          {if @changes == [], do: "As extracted", else: "#{length(@changes)} corrected"}
        </div>
      </div>
      <.summary_row
        :for={{field, label} <- summary_fields()}
        label={label}
        value={display_value(field, @data)}
        was={
          if field in @changed,
            do: display_value(field, @review_decision.original_data || %ExtractedData{})
        }
      />
      <div :if={@review_decision.review_notes} class="detail-row" id="invoice-comment-display">
        <div class="name muted">Comment</div>
        <div class="invoice-quote">{@review_decision.review_notes}</div>
      </div>

      <div class="invoice-section-title">
        Booking
        <.link
          :if={@entry}
          navigate={~p"/journal_entries/#{@entry}?from=invoice"}
          class="btn sm"
          id="open-journal-entry"
        >
          Open in journal
        </.link>
      </div>
      <%= cond do %>
        <% @entry && @entry.status == "posted" -> %>
          <div class="detail-row">
            <div class="name muted">Category</div>
            <div>{@entry.category || "—"}</div>
          </div>
          <div class="detail-row">
            <div class="name muted">Need or want</div>
            <div>{need_or_want_label(@entry.need_or_want)}</div>
          </div>
          <div class="detail-row" id="invoice-tax-treatment">
            <div class="name muted">Tax treatment</div>
            <div>{tax_label(@entry.tax_deduction_claim)}</div>
          </div>
        <% @entry -> %>
          <p class="muted" style="font-size:13px;margin:0 0 12px">
            Approved before booking was part of posting. Book it to finish.
          </p>
          <.form for={%{}} as={:invoice} id="invoice-booking-form" phx-submit="book">
            <.booking_fields values={@values} categories={@categories} />
            <div class="invoice-actions">
              <span></span>
              <button type="submit" class="btn sm primary" phx-disable-with="Booking…">
                Book entry
              </button>
            </div>
          </.form>
        <% true -> %>
          <p class="muted" style="font-size:13px;margin:0">No journal entry was created.</p>
      <% end %>

      <.history
        document={@document}
        extracted_content={@extracted_content}
        review_decision={@review_decision}
        changes={@changes}
      />
    </div>
    """
  end

  attr :review_decision, :map, required: true
  attr :document, :map, required: true
  attr :extracted_content, :map, required: true

  defp rejected_card(assigns) do
    ~H"""
    <div class="card" id="invoice-rejected">
      <div class="card-head">
        <div class="card-title">Rejected</div>
      </div>
      <div class="detail-row">
        <div class="name muted">Reason</div>
        <div class="invoice-quote">{@review_decision.rejection_reason || "—"}</div>
      </div>
      <.history
        document={@document}
        extracted_content={@extracted_content}
        review_decision={@review_decision}
        changes={[]}
      />
    </div>
    """
  end

  attr :label, :string, required: true
  attr :value, :string, required: true
  attr :was, :string, default: nil

  defp summary_row(assigns) do
    ~H"""
    <div class="detail-row">
      <div class="name muted">{@label}</div>
      <div>
        {@value}
        <div :if={@was} class="invoice-was-inline">Extracted <s>{@was}</s></div>
      </div>
    </div>
    """
  end

  attr :document, :map, required: true
  attr :extracted_content, :map, required: true
  attr :review_decision, :map, required: true
  attr :changes, :list, required: true

  defp history(assigns) do
    ~H"""
    <div class="invoice-section-title">History</div>
    <ul class="invoice-history" id="invoice-history">
      <li>
        <time>{fmt_datetime(@document.inserted_at)}</time>
        <span>Uploaded {@document.filename}</span>
      </li>
      <li>
        <time>{fmt_datetime(@extracted_content.inserted_at)}</time>
        <span>Extracted</span>
      </li>
      <li :for={{field, from, to} <- @changes}>
        <time>{fmt_datetime(@review_decision.review_completed_at)}</time>
        <span>
          {field_label(field)} corrected: {display_raw(field, from)} → {display_raw(field, to)}
        </span>
      </li>
      <li>
        <time>{fmt_datetime(@review_decision.review_completed_at)}</time>
        <span>
          {if @review_decision.review_status == "rejected",
            do: "Rejected, no journal entry created",
            else: "Posted to journal"}
        </span>
      </li>
    </ul>
    """
  end

  attr :document, :map, required: true
  attr :preview_kind, :atom, required: true

  defp document_actions(assigns) do
    ~H"""
    <a
      :if={@preview_kind}
      class="btn sm"
      href={~p"/documents/#{@document}/preview"}
      target="_blank"
      rel="noopener"
    >
      <.icon name="hero-arrow-top-right-on-square" class="ico" /> Open
    </a>
    <a class="btn sm" href={~p"/documents/#{@document}/download"}>
      <.icon name="hero-arrow-down-tray" class="ico" /> Download
    </a>
    """
  end

  # ── Events ─────────────────────────────────────────────────────────────────

  @impl true
  def handle_event("validate", %{"invoice" => params}, socket) do
    {:noreply, assign_values(socket, params)}
  end

  def handle_event("undo", %{"field" => field}, socket) when field in @data_fields do
    values = Map.put(socket.assigns.values, field, socket.assigns.original_values[field])
    {:noreply, assign_values(socket, values)}
  end

  def handle_event("feedback", %{"thumbs" => thumbs}, socket) when thumbs in ["0", "1"] do
    value = String.to_integer(thumbs)
    value = if socket.assigns.feedback_value == value, do: nil, else: value
    {:noreply, assign(socket, :feedback_value, value)}
  end

  # The confirmation buttons submit the invoice form too (as `confirm`), so a
  # confirmed posting always carries the booking and the data on screen, and
  # it applies only to the verdict for that data: edits since the warning are
  # checked again.
  def handle_event("post", %{"invoice" => params} = event, socket) do
    socket = assign_values(socket, params)

    case parsed_data(socket) do
      {:ok, data} ->
        duplicates = Review.duplicate_check(socket.assigns.review_decision, data)
        post_after_check(socket, data, duplicates, event["confirm"])

      {:error, socket} ->
        {:noreply, socket}
    end
  end

  def handle_event("book", %{"invoice" => params}, socket) do
    %{entry: entry, review_decision: rd, current_scope: scope} = socket.assigns

    case Accounting.post_entry(
           entry,
           scope.user.id,
           params["category"],
           params["need_or_want"],
           rd.review_notes,
           %{"status" => params["tax_treatment_status"] || "undecided"}
         ) do
      {:ok, _entry} ->
        {:noreply, socket |> put_flash(:info, "Entry booked") |> reload()}

      {:error, changeset} ->
        {:noreply,
         socket
         |> assign_values(Map.merge(socket.assigns.values, params))
         |> put_flash(:error, "Could not book this entry: #{error_summary(changeset)}")}
    end
  end

  def handle_event("show_rejection_form", _params, socket) do
    {:noreply, assign(socket, :show_rejection_form, true)}
  end

  def handle_event("hide_rejection_form", _params, socket) do
    {:noreply, assign(socket, :show_rejection_form, false)}
  end

  def handle_event("reject", %{"review_decision" => params}, socket) do
    %{current_scope: scope, extracted_content: ec} = socket.assigns

    case Review.reject_invoice(ec.id, scope.user.id, params["rejection_reason"]) do
      {:ok, _} ->
        Review.score_rejected_extraction(ec, socket.assigns.feedback_value)

        {:noreply,
         socket
         |> assign(:show_rejection_form, false)
         |> put_flash(:info, "Invoice rejected")
         |> reload()}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign(socket, :rejection_form, to_form(changeset))}

      {:error, reason} when is_binary(reason) ->
        {:noreply, put_flash(socket, :error, reason)}
    end
  end

  def handle_event("retry_processing", _params, socket) do
    %{current_scope: scope, document: document} = socket.assigns

    case DocumentProcessing.retry_document(scope, document) do
      {:ok, _job} ->
        schedule_refresh(:processing)

        {:noreply,
         socket
         |> assign(:processing_state, :processing)
         |> assign(:stage, :processing)
         |> put_flash(:info, "Processing restarted")}

      {:error, {:not_retryable, state}} ->
        {:noreply,
         socket
         |> assign(:processing_state, state)
         |> put_flash(:info, "Nothing to retry: processing is already running or completed.")}

      {:error, :not_found} ->
        {:noreply, put_flash(socket, :error, "Document not found.")}
    end
  end

  # ── PubSub and refresh ─────────────────────────────────────────────────────

  @impl true
  def handle_info(
        {:updated, %ZaimuTomo.Documents.Document{id: id}},
        %{assigns: %{document: %{id: id}}} = socket
      ) do
    {:noreply, reload(socket)}
  end

  def handle_info(
        {:deleted, %ZaimuTomo.Documents.Document{id: id}},
        %{assigns: %{document: %{id: id}}} = socket
      ) do
    {:noreply,
     socket
     |> put_flash(:error, "This document was deleted.")
     |> push_navigate(to: ~p"/documents")}
  end

  def handle_info({type, %ZaimuTomo.Documents.Document{}}, socket)
      when type in [:created, :updated, :deleted] do
    {:noreply, socket}
  end

  def handle_info(%{document_id: id}, %{assigns: %{document: %{id: id}}} = socket) do
    {:noreply, reload(socket)}
  end

  def handle_info(%{document_id: _id}, socket) do
    {:noreply, socket}
  end

  def handle_info(:refresh_processing, socket) do
    socket = reload(socket)
    schedule_refresh(socket.assigns.processing_state)
    {:noreply, socket}
  end

  # ── Posting ────────────────────────────────────────────────────────────────

  # A possible duplicate or an exact-file match always needs the explicit
  # confirmation for the data just submitted; posting again re-checks.
  defp post_after_check(socket, data, %{verdict: :none}, nil), do: post(socket, data, [])

  defp post_after_check(socket, data, %{verdict: :possible}, "possible"),
    do: post(socket, data, [])

  defp post_after_check(socket, data, %{verdict: :file_reuse}, "file_reuse"),
    do: post(socket, data, confirm_file_reuse: true)

  defp post_after_check(socket, _data, %{verdict: verdict} = duplicates, nil)
       when verdict in [:possible, :file_reuse] do
    {:noreply, socket |> assign_duplicates(duplicates) |> assign(:duplicate_error, false)}
  end

  defp post_after_check(socket, _data, %{verdict: verdict} = duplicates, _confirm) do
    {:noreply,
     socket
     |> assign_duplicates(duplicates)
     |> assign(:duplicate_error, verdict != :none)
     |> put_flash(:error, Duplicates.refusal_message(verdict))}
  end

  defp post(socket, data, opts) do
    %{current_scope: scope, extracted_content: ec, values: values} = socket.assigns
    changes = ExtractedData.changes(original_data(socket), data)
    comment = blank_to_nil(values["comment"])

    opts =
      opts ++
        [
          booking: %{
            category: values["category"],
            need_or_want: values["need_or_want"],
            notes: comment
          },
          tax_claim_attrs: %{"status" => values["tax_treatment_status"] || "undecided"}
        ]

    result =
      if changes == [] do
        Review.approve_invoice(ec.id, scope.user.id, comment, opts)
      else
        Review.amend_invoice(ec.id, scope.user.id, Map.from_struct(data), comment, opts)
      end

    case result do
      {:ok, _decision} ->
        Review.score_posted_extraction(ec, changes, socket.assigns.feedback_value)

        {:noreply,
         socket
         |> assign(:pending_verdict, nil)
         |> assign(:duplicate_error, false)
         |> put_flash(:info, "Invoice posted to the journal")
         |> reload()}

      {:error, reason} when reason in [:duplicate_invoice, :file_reuse_not_applicable] ->
        # Another posting may have landed since the page was rendered; show
        # the current matches instead of a stale verdict.
        duplicates = Review.duplicate_check(socket.assigns.review_decision, data)

        {:noreply,
         socket
         |> assign(:duplicates, duplicates)
         |> assign(:pending_verdict, nil)
         |> assign(:duplicate_error, true)
         |> put_flash(:error, Duplicates.refusal_message(duplicates.verdict))}

      {:error, reason} when is_binary(reason) ->
        {:noreply, put_flash(socket, :error, reason)}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply,
         put_flash(socket, :error, "Could not post this invoice: #{error_summary(changeset)}")}
    end
  end

  defp parsed_data(socket) do
    case parse_values(socket.assigns.values) do
      {:ok, data} ->
        {:ok, data}

      :error ->
        {:error,
         socket
         |> assign(:amount_error, "Enter an amount like 89.90")
         |> put_flash(:error, "The amount is not a valid number.")}
    end
  end

  # Casts the form values with the invoice schema, so the duplicate check and
  # the comparison with the extraction use the same typed values the posting
  # persists. The amount is entered in major units ("89.90").
  defp parse_values(values) do
    with {:ok, cents} <- parse_amount(values["amount"]) do
      data =
        values
        |> Map.take(@data_fields -- ["amount"])
        |> Map.new(fn {field, value} -> {field, normalize(value)} end)
        |> Map.put("amount_to_pay_cents", cents)
        |> ExtractedData.changeset()
        |> Ecto.Changeset.apply_changes()

      {:ok, data}
    end
  end

  defp parse_amount(value) when value in [nil, ""], do: {:ok, nil}

  # At most two decimals, so "1,234" is refused instead of being read as 1.234.
  # The format also rules out NaN, Infinity and exponents.
  defp parse_amount(value) when is_binary(value) do
    amount = String.trim(value)

    with true <- String.match?(amount, ~r/\A-?\d+(?:[.,]\d{1,2})?\z/),
         decimal = amount |> String.replace(",", ".") |> Decimal.new(),
         cents = decimal |> Decimal.mult(100) |> Decimal.to_integer(),
         true <- abs(cents) <= @max_amount_cents do
      {:ok, cents}
    else
      false -> :error
    end
  end

  # ── Loading ────────────────────────────────────────────────────────────────

  defp reload(socket) do
    document =
      Documents.get_document_with_content!(
        socket.assigns.current_scope,
        socket.assigns.document.id
      )

    load_document(socket, document)
  end

  defp load_document(socket, document) do
    processing_state = DocumentProcessing.processing_state(document)
    ec = List.first(document.extracted_content)
    rd = ec && ec.review_decision
    stage = stage(processing_state, rd)
    entry = journal_entry(rd)
    data = if rd, do: ReviewDecision.effective_data(rd), else: ec && ec.extracted_data
    original = if rd, do: rd.original_data || %ExtractedData{}, else: %ExtractedData{}
    original_values = data_values(original)

    socket
    |> assign(:document, document)
    |> assign(:processing_state, processing_state)
    |> assign(:stage, stage)
    |> assign(:extracted_content, ec)
    |> assign(:review_decision, rd)
    |> assign(:entry, entry)
    |> assign(:data, data)
    |> assign(:page_title, title(data, document))
    |> assign(:changes, if(rd, do: ExtractedData.changes(original, data), else: []))
    |> assign(:trace?, is_binary(ec && ec.trace_id))
    |> assign(:verification, verifier_feedback(ec))
    |> assign(:typesafe_shadow, typesafe_shadow(ec))
    |> assign(:original_values, original_values)
    |> assign(:rejection_form, rejection_form(rd))
    |> assign(:amount_error, nil)
    |> assign_values(initial_values(socket, stage, original_values, rd))
    |> assign_current_duplicates()
  end

  # A refresh while the form is open (a PubSub broadcast) keeps what the
  # reviewer typed; a stage change starts from the decision again.
  defp initial_values(%{assigns: %{stage: stage, values: values}}, stage, _original, _rd),
    do: values

  defp initial_values(_socket, _stage, original_values, rd) do
    Map.merge(original_values, %{
      "comment" => (rd && rd.review_notes) || "",
      "category" => "",
      "need_or_want" => "",
      "tax_treatment_status" => "undecided"
    })
  end

  defp assign_values(socket, params) do
    values = Map.merge(socket.assigns[:values] || %{}, params)

    changed =
      for field <- @data_fields,
          normalize(values[field]) != normalize(socket.assigns.original_values[field]),
          do: field

    socket
    |> assign(:values, values)
    |> assign(:changed, changed)
    |> assign(:amount_error, nil)
  end

  defp normalize(value) when is_binary(value), do: String.trim(value)
  defp normalize(nil), do: ""

  defp original_data(socket), do: socket.assigns.review_decision.original_data || %ExtractedData{}

  defp data_values(%ExtractedData{} = data) do
    %{
      "issuer" => data.issuer || "",
      "amount" => amount_string(data.amount_to_pay_cents),
      "currency" => data.currency || "",
      "invoice_date" => data.invoice_date || "",
      "invoice_number" => data.invoice_number || "",
      "reason_for_payment" => data.reason_for_payment || ""
    }
  end

  defp amount_string(nil), do: ""

  defp amount_string(cents) when is_integer(cents) do
    cents |> Decimal.new() |> Decimal.div(100) |> Decimal.round(2) |> Decimal.to_string(:normal)
  end

  defp stage(:processing, _rd), do: :processing
  defp stage(_state, %ReviewDecision{review_status: "pending"}), do: :check

  defp stage(_state, %ReviewDecision{review_status: s}) when s in ["approved", "amended"],
    do: :posted

  defp stage(_state, %ReviewDecision{review_status: "rejected"}), do: :rejected
  defp stage(_state, _rd), do: :processing

  defp journal_entry(%ReviewDecision{review_status: s, id: id})
       when s in ["approved", "amended"] do
    case Accounting.get_journal_entry_for_decision(id) do
      {:ok, entry} -> entry
      :error -> nil
    end
  end

  defp journal_entry(_rd), do: nil

  defp assign_duplicates(socket, duplicates) do
    socket
    |> assign(:duplicates, duplicates)
    |> assign(:pending_verdict, confirmable(duplicates.verdict))
  end

  defp confirmable(verdict) when verdict in [:possible, :file_reuse], do: verdict
  defp confirmable(_verdict), do: nil

  # While checking, the verdict describes the values on screen, which a refresh
  # keeps. Stored data is the fallback for an amount that does not parse yet.
  defp assign_current_duplicates(%{assigns: %{stage: :check, review_decision: rd}} = socket) do
    data =
      case parse_values(socket.assigns.values) do
        {:ok, data} -> data
        :error -> ReviewDecision.effective_data(rd)
      end

    assign_duplicates(socket, Review.duplicate_check(rd, data))
  end

  defp assign_current_duplicates(socket) do
    assign_duplicates(socket, %{verdict: :none, candidates: []})
  end

  defp rejection_form(%ReviewDecision{} = rd),
    do: to_form(ReviewDecision.changeset_for_update(rd, %{}))

  defp rejection_form(_rd), do: to_form(%{}, as: :review_decision)

  # The worker broadcasts before Oban acknowledges the job, and cancelled or
  # discarded jobs never broadcast, so a broadcast alone can leave a stale
  # "Processing" pill. While a run is live, re-read the durable state.
  defp schedule_refresh(:processing) do
    interval = Application.get_env(:zaimu_tomo, :processing_refresh_interval_ms, 3_000)
    Process.send_after(self(), :refresh_processing, interval)
  end

  defp schedule_refresh(_state), do: :ok

  # ── View helpers ───────────────────────────────────────────────────────────

  defp steps(stage) do
    current = %{processing: 1, check: 2, posted: 4, rejected: 3}[stage]

    last =
      case stage do
        :rejected -> {"Rejected", "bad"}
        :posted -> {"Posted", "done"}
        _ -> {"Posted", ""}
      end

    [{"Uploaded", 0}, {"Extracted", 1}, {"Check and book", 2}]
    |> Enum.map(fn {label, index} ->
      {label,
       cond do
         index < current -> "done"
         index == current -> "current"
         true -> ""
       end}
    end)
    |> Kernel.++([last])
  end

  # An entry approved before booking was part of posting still needs booking.
  defp stage_pill(:posted, _state, %JournalEntry{status: "uncategorized"}), do: "review"
  defp stage_pill(stage, state, _entry), do: stage_pill(stage, state)

  defp stage_pill(_stage, :processing), do: "processing"
  # A stuck document has no live run to report on; the pill must not keep
  # pulsing "Processing" forever.
  defp stage_pill(_stage, :stuck), do: "Processing stalled"
  defp stage_pill(:check, _state), do: "review"
  defp stage_pill(:posted, _state), do: "posted"
  defp stage_pill(:rejected, _state), do: "rejected"
  defp stage_pill(_stage, :failed), do: "failed"
  defp stage_pill(_stage, _state), do: "review"

  defp title(%ExtractedData{issuer: issuer, invoice_number: number}, _document)
       when is_binary(issuer) and is_binary(number) and number != "",
       do: "#{issuer} — #{number}"

  defp title(%ExtractedData{issuer: issuer}, _document) when is_binary(issuer), do: issuer
  defp title(_data, document), do: document.filename

  defp subtitle(:processing, _data, document), do: document.filename

  defp subtitle(_stage, %ExtractedData{} = data, document) do
    [
      data.amount_to_pay_cents && data.currency &&
        fmt_cents(data.amount_to_pay_cents, data.currency),
      data.invoice_date,
      document.filename
    ]
    |> Enum.filter(& &1)
    |> Enum.join(" · ")
  end

  defp subtitle(_stage, _data, document), do: document.filename

  defp summary_fields do
    [
      {:amount_to_pay_cents, "Amount"},
      {:issuer, "Issuer"},
      {:invoice_date, "Invoice date"},
      {:invoice_number, "Invoice #"},
      {:currency, "Currency"},
      {:reason_for_payment, "Reason"}
    ]
  end

  defp field_label(:amount_to_pay_cents), do: "Amount"
  defp field_label(:invoice_date), do: "Invoice date"
  defp field_label(:invoice_number), do: "Invoice #"
  defp field_label(:reason_for_payment), do: "Reason"
  defp field_label(field), do: field |> to_string() |> String.capitalize()

  defp display_value(:amount_to_pay_cents, %ExtractedData{amount_to_pay_cents: cents, currency: c})
       when is_integer(cents) and is_binary(c),
       do: fmt_cents(cents, c)

  defp display_value(field, %ExtractedData{} = data), do: display_raw(field, Map.get(data, field))

  defp display_raw(:amount_to_pay_cents, cents) when is_integer(cents), do: amount_string(cents)
  defp display_raw(_field, value), do: blank_dash(value)

  defp blank_dash(value) when value in [nil, ""], do: "—"
  defp blank_dash(value), do: to_string(value)

  defp blank_to_nil(value) when is_binary(value) do
    if String.trim(value) == "", do: nil, else: value
  end

  defp blank_to_nil(_value), do: nil

  defp fmt_datetime(nil), do: "—"
  defp fmt_datetime(%NaiveDateTime{} = dt), do: Calendar.strftime(dt, "%d %b %Y %H:%M")
  defp fmt_datetime(%DateTime{} = dt), do: Calendar.strftime(dt, "%d %b %Y %H:%M")

  defp need_or_want_label("need"), do: "Need"
  defp need_or_want_label("want"), do: "Want"
  defp need_or_want_label(_), do: "—"

  defp tax_label(%{status: status}), do: TaxDeductionClaim.status_label(status)
  defp tax_label(_claim), do: "—"

  defp failure_message(document) do
    case List.first(document.extracted_content) do
      %{error_details: %{"message" => message}} when is_binary(message) -> message
      _ -> "Processing failed. Retry processing to try again."
    end
  end

  defp error_summary(%Ecto.Changeset{} = changeset) do
    changeset
    |> Ecto.Changeset.traverse_errors(fn {message, opts} ->
      Enum.reduce(opts, message, fn {key, value}, acc ->
        String.replace(acc, "%{#{key}}", to_string(value))
      end)
    end)
    |> flatten_errors()
    |> Enum.join(", ")
  end

  defp flatten_errors(errors) when is_map(errors) do
    Enum.flat_map(errors, fn
      {field, messages} when is_list(messages) ->
        Enum.map(messages, &"#{String.replace(to_string(field), "_", " ")} #{&1}")

      {_field, nested} when is_map(nested) ->
        flatten_errors(nested)
    end)
  end

  defp preview_kind(document) do
    case MediaPreview.previewable?(
           MIME.from_path(document.filename),
           Path.extname(document.filename)
         ) do
      {:ok, kind} -> kind
      {:error, :not_previewable} -> nil
    end
  end

  defp file_type_label(document) do
    document.filename |> Path.extname() |> String.trim_leading(".") |> String.upcase()
  end

  defp verifier_feedback(%{analysis: %{"verification" => %{"status" => status} = verification}})
       when status in ["needs_review", "rejected", "verification_failed"],
       do: verification

  defp verifier_feedback(_content), do: nil

  defp verification_status_label("rejected"), do: "Rejected"
  defp verification_status_label("needs_review"), do: "Needs review"
  defp verification_status_label("verification_failed"), do: "Could not verify"

  defp typesafe_shadow(%{analysis: %{"verification" => %{"typesafe_shadow" => shadow}}})
       when is_map(shadow),
       do: shadow

  defp typesafe_shadow(_content), do: nil

  defp typesafe_status_label("verified"), do: "Verified"
  defp typesafe_status_label("needs_review"), do: "Needs review"
  defp typesafe_status_label("verification_failed"), do: "Could not verify"
  defp typesafe_status_label(other) when is_binary(other), do: other
  defp typesafe_status_label(_other), do: "Unknown"

  defp typesafe_pill_status("verified"), do: "verified"
  defp typesafe_pill_status("needs_review"), do: "review"
  defp typesafe_pill_status(_status), do: "failed"

  defp typesafe_field_probabilities(%{"field_probabilities" => probabilities})
       when is_map(probabilities) do
    Enum.sort_by(probabilities, fn {field, _probability} -> field end)
  end

  defp typesafe_field_probabilities(_shadow), do: []

  defp format_probability(probability) when is_number(probability) do
    :erlang.float_to_binary(probability / 1, decimals: 2)
  end

  defp format_probability(_probability), do: "—"
end
