// Zaimutomo — interactive JS for the dashboard
// Handles: tweaks panel, bell dropdown, drag/drop upload, OCR simulation,
//          review modal, category modal, toasts.
// Server renders the dashboard content; this file owns only the interactive layer.

// ─── Mock data for client-side OCR simulation ────────────────────────────────

const SAMPLES = [
  {
    filename: "IMG_8821.jpg",
    merchant_name: "MEDIAMARKT BRUSSEL CITY 2",
    address: "Rue Neuve 123, 1000 Brussel",
    invoice_no: "MM-2410581",
    date_iso: "2026-05-08",
    currency: "EUR",
    lines: [
      { d: "Logitech MX Master 3S", q: 1, p: 99.0 },
      { d: "USB-C dock 4-in-1", q: 1, p: 67.5 },
      { d: "HDMI cable 2m", q: 2, p: 12.95 },
      { d: "Carrying case M", q: 1, p: 26.6 },
    ],
    subtotal: 218.95, vat_pct: 21, vat: 38.02, total: 219.0,
    conf: { merchant: 0.96, amount: 0.99, date: 0.62, vat: 0.71, invoice_no: 0.42 },
    suggested_category: "office",
  },
  {
    filename: "recu-delhaize-9-mai.pdf",
    merchant_name: "Delhaize Châtelain",
    address: "Rue du Page 2, 1050 Ixelles",
    invoice_no: "20260509-21-440",
    date_iso: "2026-05-09",
    currency: "EUR",
    lines: [
      { d: "Pain au levain 600g", q: 1, p: 4.2 },
      { d: "Yaourt grec 1kg", q: 1, p: 5.85 },
      { d: "Tomates grappe", q: 1, p: 3.4 },
      { d: "Œufs bio x6", q: 2, p: 4.95 },
      { d: "Vin rouge Chinon", q: 1, p: 14.8 },
      { d: "Saumon frais 200g", q: 1, p: 8.3 },
    ],
    subtotal: 46.45, vat_pct: 6, vat: 2.79, total: 46.45,
    conf: { merchant: 0.99, amount: 0.97, date: 0.94, vat: 0.81, invoice_no: 0.55 },
    suggested_category: "groceries",
  },
  {
    filename: "taxi-receipt.pdf",
    merchant_name: "Heetch Bruxelles",
    address: "Trip 8aab21 · driver Karim",
    invoice_no: "HE-58210",
    date_iso: "2026-05-09",
    currency: "EUR",
    lines: [
      { d: "Course Schaerbeek → Ixelles", q: 1, p: 18.4 },
      { d: "Pourboire", q: 1, p: 2.0 },
    ],
    subtotal: 20.4, vat_pct: 21, vat: 3.54, total: 20.4,
    conf: { merchant: 0.92, amount: 0.96, date: 0.99, vat: 0.4, invoice_no: 0.88 },
    suggested_category: "transport",
  },
]

const CATEGORIES = [
  { id: "office",    name: "Office",           glyph: "o", color: "oklch(0.55 0.08 240)", spent: 184.2,  budget: 250 },
  { id: "groceries", name: "Groceries",        glyph: "g", color: "oklch(0.55 0.10 145)", spent: 412.83, budget: 500 },
  { id: "sport",     name: "Sport",            glyph: "s", color: "oklch(0.55 0.13 35)",  spent: 89.0,   budget: 80  },
  { id: "outings",   name: "Outings",          glyph: "O", color: "oklch(0.55 0.13 320)", spent: 268.4,  budget: 200 },
  { id: "transport", name: "Transport",        glyph: "T", color: "oklch(0.55 0.10 200)", spent: 142.1,  budget: 180 },
  { id: "home",      name: "Home & utilities", glyph: "h", color: "oklch(0.55 0.07 75)",  spent: 624.0,  budget: 700 },
  { id: "health",    name: "Health",           glyph: "H", color: "oklch(0.55 0.10 15)",  spent: 38.5,   budget: 120 },
  { id: "subs",      name: "Subscriptions",    glyph: "~", color: "oklch(0.55 0.10 280)", spent: 87.94,  budget: 100 },
  { id: "travel",    name: "Travel",           glyph: "✈", color: "oklch(0.55 0.10 250)", spent: 0,      budget: 150 },
  { id: "gifts",     name: "Gifts & giving",   glyph: "+", color: "oklch(0.55 0.10 350)", spent: 45.0,   budget: 60  },
  { id: "misc",      name: "Misc",             glyph: "·", color: "oklch(0.55 0.02 60)",  spent: 22.3,   budget: 80  },
]

// ─── Helpers ──────────────────────────────────────────────────────────────────

const fmt = (n, currency = "EUR") => {
  if (n == null || isNaN(n)) return "—"
  return new Intl.NumberFormat("en-IE", {
    style: "currency", currency, currencyDisplay: "symbol",
    minimumFractionDigits: 2, maximumFractionDigits: 2,
  }).format(n)
}

const relTime = (iso) => {
  const d = new Date(iso), now = new Date()
  const diff = (now - d) / 1000
  if (diff < 60) return "just now"
  if (diff < 3600) return `${Math.floor(diff / 60)}m ago`
  if (diff < 86400) return `${Math.floor(diff / 3600)}h ago`
  return `${Math.floor(diff / 86400)}d ago`
}

// ─── OCR pipeline simulation ──────────────────────────────────────────────────

let nextId = 22
const sessionActivity = []
const ocrSubs = new Set()

const ocrEmit = (evt) => ocrSubs.forEach((fn) => fn(evt))
const ocrSubscribe = (fn) => { ocrSubs.add(fn); return () => ocrSubs.delete(fn) }

function uploadFiles(files) {
  files.forEach(() => {
    const id = `j-${String(nextId++).padStart(3, "0")}`
    const sample = SAMPLES[nextId % SAMPLES.length]
    const item = {
      id, status: "processing",
      merchant: "…",
      filename: files[0]?.name || sample.filename,
      amount: null, currency: null, date: null, category: null,
      ts: new Date().toISOString(),
      _sample: sample,
    }
    sessionActivity.unshift(item)
    ocrEmit({ type: "uploaded", item })

    const delay = 2200 + Math.random() * 1600
    setTimeout(() => {
      const s = item._sample
      Object.assign(item, {
        status: "review",
        merchant: s.merchant_name,
        amount: s.total,
        currency: s.currency,
        date: s.date_iso,
        invoice_no: s.invoice_no,
        vat_pct: s.vat_pct,
        conf: s.conf,
        ocr: {
          merchant_name: s.merchant_name,
          address: s.address,
          invoice_no: s.invoice_no,
          date_raw: s.date_iso,
          lines: s.lines,
          subtotal: s.subtotal, vat: s.vat, total: s.total,
        },
        suggested_category: s.suggested_category,
      })
      ocrEmit({ type: "extracted", item })
    }, delay)
  })
}

// ─── State ────────────────────────────────────────────────────────────────────

let reviewState = { item: null, edits: {} }
let pickedCategory = null

// ─── Init ─────────────────────────────────────────────────────────────────────

export function initZaimu() {
  setupTweaks()
  setupBell()
  setupUpload()
  setupReviewModal()
  setupCategoryModal()

  document.getElementById("demo-upload")?.addEventListener("click", () => {
    const sample = SAMPLES[Math.floor(Math.random() * SAMPLES.length)]
    handleUpload([{ name: sample.filename }])
  })

  ocrSubscribe((evt) => {
    if (evt.type === "extracted") {
      pushToast(`${evt.item.merchant} · ready for review`, {
        label: "Review",
        fn: () => openReview(evt.item),
      })
    }
    updateBell()
  })
}

// ─── Tweaks panel ─────────────────────────────────────────────────────────────

function setupTweaks() {
  const panel = document.getElementById("tweaks-panel")
  if (!panel) return

  panel.querySelectorAll(".seg").forEach((seg) => {
    const key = seg.getAttribute("data-tweak")
    seg.addEventListener("click", (e) => {
      const btn = e.target.closest("button[data-val]")
      if (!btn) return
      seg.querySelectorAll("button").forEach((b) => b.classList.toggle("active", b === btn))
      const val = btn.getAttribute("data-val")
      if (key === "density") {
        document.body.classList.toggle("density-compact", val === "compact")
        document.body.classList.toggle("density-comfortable", val !== "compact")
      }
      if (key === "async") updateAsyncHelp(val)
    })
  })

  document.getElementById("tweaks-close")?.addEventListener("click", () =>
    panel.classList.remove("show")
  )
  document.getElementById("tweaks-toggle")?.addEventListener("click", () =>
    panel.classList.toggle("show")
  )
}

function updateAsyncHelp(val) {
  const help = document.getElementById("async-help")
  if (!help) return
  if (val === "subtle") help.textContent = "Toast + bell badge when documents finish processing."
  else if (val === "inbox") help.textContent = "Persistent inbox panel on the dashboard right rail."
  else if (val === "hero") help.textContent = "Live processing card replaces the dashboard hero when in flight."
}

// ─── Bell & notification dropdown ────────────────────────────────────────────

function setupBell() {
  const bell = document.getElementById("bell")
  const pop = document.getElementById("notif-pop")
  if (!bell || !pop) return

  bell.addEventListener("click", (e) => { e.stopPropagation(); pop.classList.toggle("show") })
  document.addEventListener("click", (e) => {
    if (!pop.contains(e.target) && !bell.contains(e.target)) pop.classList.remove("show")
  })
}

function updateBell() {
  const inFlight = sessionActivity.filter((a) => a.status === "processing" || a.status === "review")
  const serverCount = parseInt(document.getElementById("bell-count")?.dataset.serverCount ?? "0", 10)
  const total = serverCount + inFlight.length

  const bell = document.getElementById("bell")
  const countEl = document.getElementById("bell-count")
  if (bell) bell.classList.toggle("has-unread", total > 0)
  if (countEl) countEl.textContent = total > 0 ? String(total) : ""

  const navBadge = document.getElementById("nav-activity-badge")
  if (navBadge) {
    navBadge.textContent = String(total)
    navBadge.style.display = total ? "" : "none"
  }

  // Prepend session items to the notif feed
  const feed = document.getElementById("notif-feed")
  if (feed && sessionActivity.length > 0) {
    let sessionEl = feed.querySelector("[data-session-items]")
    if (!sessionEl) {
      sessionEl = document.createElement("div")
      sessionEl.dataset.sessionItems = ""
      feed.prepend(sessionEl)
    }
    sessionEl.innerHTML = sessionActivity.slice(0, 4).map(feedItemHTML).join("")
    sessionEl.querySelectorAll("[data-review]").forEach((b) =>
      b.addEventListener("click", (e) => {
        e.stopPropagation()
        const item = sessionActivity.find((a) => a.id === b.dataset.review)
        if (item) { document.getElementById("notif-pop")?.classList.remove("show"); openReview(item) }
      })
    )
  }
}

function statusPill(status) {
  if (status === "processing") return `<span class="pill processing"><span class="pulse"></span>Processing</span>`
  if (status === "review") return `<span class="pill review"><span class="pulse"></span>Needs review</span>`
  if (status === "posted") return `<span class="pill posted">Posted</span>`
  if (status === "failed") return `<span class="pill failed">Failed</span>`
  return `<span class="pill">${status}</span>`
}

function feedItemHTML(item) {
  const cat = CATEGORIES.find((c) => c.id === item.category)
  const amt = item.amount != null ? fmt(item.amount, item.currency || "EUR") : "—"
  let desc = ""
  if (item.status === "processing") desc = "Sent to OCR · extraction in progress"
  else if (item.status === "review") desc = `<span class="amt">${amt}</span> · ${item.invoice_no || "—"} · ready to verify`
  else if (item.status === "posted") desc = `<span class="amt">${amt}</span>${cat ? " · " + cat.name : ""}`
  else if (item.status === "failed") desc = item.error || "Processing failed"
  const actions =
    item.status === "review"
      ? `<button class="btn sm primary" data-review="${item.id}">Review</button>`
      : item.status === "failed"
        ? `<button class="btn sm">Retry</button>`
        : ""
  return `
    <div class="feed-item ${item.status}" data-id="${item.id}">
      <div class="stat">${item.filename ? item.filename.split(".").pop().slice(0, 3).toUpperCase() : "DOC"}</div>
      <div class="body">
        <div class="title">${item.merchant || (item.status === "processing" ? "Scanning…" : "Untitled")} ${statusPill(item.status)}</div>
        <div class="desc">${desc} · <span class="muted">${item.filename || ""}</span></div>
      </div>
      <div class="actions">${actions}<time>${relTime(item.ts)}</time></div>
    </div>`
}

// ─── Upload & drag/drop ───────────────────────────────────────────────────────

function setupUpload() {
  const fileInput = document.getElementById("file-input")
  fileInput?.addEventListener("change", (e) => {
    const files = Array.from(e.target.files || [])
    if (files.length) handleUpload(files)
    e.target.value = ""
  })

  document.getElementById("quick-add")?.addEventListener("click", () => fileInput?.click())

  const dz = document.getElementById("drop-zone")
  if (dz) {
    dz.addEventListener("click", () => fileInput?.click())
    ;["dragenter", "dragover"].forEach((ev) =>
      dz.addEventListener(ev, (e) => { e.preventDefault(); dz.classList.add("drag") })
    )
    ;["dragleave", "drop"].forEach((ev) =>
      dz.addEventListener(ev, (e) => { e.preventDefault(); dz.classList.remove("drag") })
    )
    dz.addEventListener("drop", (e) => {
      const files = Array.from(e.dataTransfer.files)
      if (files.length) handleUpload(files)
    })
  }

  let dragDepth = 0
  const overlay = document.getElementById("drop-overlay")
  window.addEventListener("dragenter", (e) => { e.preventDefault(); dragDepth++; overlay?.classList.add("show") })
  window.addEventListener("dragleave", (e) => { e.preventDefault(); dragDepth = Math.max(0, dragDepth - 1); if (!dragDepth) overlay?.classList.remove("show") })
  window.addEventListener("dragover", (e) => e.preventDefault())
  window.addEventListener("drop", (e) => {
    e.preventDefault(); dragDepth = 0; overlay?.classList.remove("show")
    const files = Array.from(e.dataTransfer.files)
    if (files.length) handleUpload(files)
  })

  window.addEventListener("paste", (e) => {
    const files = Array.from(e.clipboardData?.files || [])
    if (files.length) handleUpload(files)
  })
}

function handleUpload(files) {
  uploadFiles(files)
  pushToast(`Uploaded ${files.length} document${files.length === 1 ? "" : "s"} · OCR running`)
  updateBell()
}

// ─── Review modal ─────────────────────────────────────────────────────────────

function setupReviewModal() {
  document.getElementById("review-cancel")?.addEventListener("click", closeReview)
  document.getElementById("review-reject")?.addEventListener("click", () => {
    if (!reviewState.item) return
    reviewState.item.status = "failed"
    reviewState.item.error = "Rejected by user"
    ocrEmit({ type: "rejected", item: reviewState.item })
    closeReview()
    pushToast("Document rejected — moved to failed")
    updateBell()
  })
  document.getElementById("review-approve")?.addEventListener("click", () => {
    if (!reviewState.item) return
    Object.assign(reviewState.item, reviewState.edits)
    ocrEmit({ type: "reviewed", item: reviewState.item })
    openCategory()
  })
}

function openReview(item) {
  reviewState = {
    item,
    edits: {
      merchant: item.merchant, amount: item.amount, currency: item.currency,
      date: item.date, invoice_no: item.invoice_no, vat_pct: item.vat_pct,
      reason: "",
    },
  }
  renderReview()
  document.getElementById("review-modal")?.classList.add("show")
}

function closeReview() {
  document.getElementById("review-modal")?.classList.remove("show")
}

function renderReview() {
  const { item, edits } = reviewState
  if (!item?.ocr) return
  const { ocr, conf = {} } = item
  const body = document.getElementById("review-body")
  if (!body) return

  const confBar = (key) => {
    const v = conf[key] ?? 0.9
    const low = v < 0.75
    return {
      low,
      html: `<span class="conf ${low ? "low" : ""}">${(v * 100).toFixed(0)}% <span class="bar"><i style="width:${(v * 100).toFixed(0)}%"></i></span></span>`,
    }
  }
  const cm = confBar("merchant"), ca = confBar("amount"), cd = confBar("date")
  const cv = confBar("vat"), ci = confBar("invoice_no")

  body.innerHTML = `
    <div class="doc-preview">
      <div class="receipt">
        <div class="receipt-head">${ocr.merchant_name}</div>
        <div class="receipt-meta">
          ${ocr.address}<br>
          Invoice <span class="ocr-hl ${ci.low ? "" : "confident"}" data-field="invoice_no">${ocr.invoice_no}</span>
          · <span class="ocr-hl ${cd.low ? "" : "confident"}" data-field="date">${ocr.date_raw}</span>
        </div>
        ${ocr.lines.map((l) => `<div class="receipt-line"><span>${l.q}× ${l.d}</span><span>${(l.p * l.q).toFixed(2)}</span></div>`).join("")}
        <div class="receipt-line" style="margin-top:8px;color:var(--muted)"><span>Subtotal</span><span>${ocr.subtotal.toFixed(2)}</span></div>
        <div class="receipt-line" style="color:var(--muted)">
          <span>TVA <span class="ocr-hl ${cv.low ? "" : "confident"}" data-field="vat_pct">${item.vat_pct ?? 21}%</span></span>
          <span>${ocr.vat.toFixed(2)}</span>
        </div>
        <div class="receipt-line total">
          <span>TOTAL</span>
          <span><span class="ocr-hl ${ca.low ? "" : "confident"}" data-field="amount">€${ocr.total.toFixed(2)}</span></span>
        </div>
        <div class="receipt-foot">Original: ${item.filename} · scanned just now</div>
      </div>
    </div>
    <div class="review-form">
      <div class="form-meta">
        <span class="mono">${item.id}</span>
        <span>·</span>
        <span>OCR via <code class="mono">claude-vision-3</code></span>
        <span>·</span>
        <span>extracted in <span class="mono">2.8s</span></span>
      </div>
      <div class="field">
        <label>Merchant ${cm.html}</label>
        <input type="text" data-edit="merchant" class="${cm.low ? "low-conf" : ""}" value="${edits.merchant || ""}">
      </div>
      <div class="field-row three">
        <div class="field">
          <label>Amount ${ca.html}</label>
          <input type="number" data-edit="amount" class="amt-input ${ca.low ? "low-conf" : ""}" step="0.01" value="${edits.amount ?? ""}">
        </div>
        <div class="field">
          <label>Currency</label>
          <select data-edit="currency">
            <option ${edits.currency === "EUR" ? "selected" : ""}>EUR</option>
            <option ${edits.currency === "USD" ? "selected" : ""}>USD</option>
            <option ${edits.currency === "GBP" ? "selected" : ""}>GBP</option>
          </select>
        </div>
        <div class="field">
          <label>Date ${cd.html}</label>
          <input type="date" data-edit="date" class="${cd.low ? "low-conf" : ""}" value="${edits.date || ""}">
        </div>
      </div>
      <div class="field-row">
        <div class="field">
          <label>Invoice no. ${ci.html}</label>
          <input type="text" data-edit="invoice_no" class="${ci.low ? "low-conf" : ""}" value="${edits.invoice_no || ""}">
        </div>
        <div class="field">
          <label>VAT % ${cv.html}</label>
          <input type="number" data-edit="vat_pct" class="num-input ${cv.low ? "low-conf" : ""}" value="${edits.vat_pct ?? 21}">
        </div>
      </div>
      <div class="field">
        <label>Reason / note <span class="muted" style="text-transform:none;letter-spacing:0;font-size:11px;font-weight:400">optional</span></label>
        <textarea data-edit="reason" placeholder="e.g. office hardware refresh">${edits.reason || ""}</textarea>
      </div>
      ${ci.low || cd.low || cv.low ? `<div style="background:var(--warn-tint);border:1px solid color-mix(in oklab,var(--warn) 30%,transparent);padding:10px 12px;border-radius:6px;font-size:12.5px;color:oklch(0.35 0.13 70);display:flex;gap:10px"><span>⚠</span><span>Low-confidence fields highlighted. Verify before approving — your edits retrain the extractor.</span></div>` : ""}
    </div>`

  body.querySelectorAll("[data-edit]").forEach((el) => {
    el.addEventListener("input", () => {
      reviewState.edits[el.dataset.edit] = el.type === "number" ? parseFloat(el.value) : el.value
    })
  })
  body.querySelectorAll(".ocr-hl").forEach((hl) => {
    hl.addEventListener("click", () => {
      const target = body.querySelector(`[data-edit="${hl.dataset.field}"]`)
      if (target) { target.focus(); target.select?.() }
      body.querySelectorAll(".ocr-hl").forEach((h) => h.classList.toggle("active", h === hl))
    })
  })
}

// ─── Category modal ───────────────────────────────────────────────────────────

function setupCategoryModal() {
  document.getElementById("cat-back")?.addEventListener("click", () => {
    closeCategory()
    document.getElementById("review-modal")?.classList.add("show")
  })
  document.getElementById("cat-confirm")?.addEventListener("click", () => {
    const item = reviewState.item
    if (!item || !pickedCategory) return
    item.category = pickedCategory
    item.status = "posted"
    ocrEmit({ type: "posted", item })
    const cat = CATEGORIES.find((c) => c.id === pickedCategory)
    if (cat && reviewState.edits.amount) cat.spent += reviewState.edits.amount
    closeCategory()
    pushToast(`Posted to ${cat?.name ?? pickedCategory} · ${fmt(reviewState.edits.amount)}`, {
      label: "View",
      fn: () => { window.location.href = "/documents" },
    })
    updateBell()
  })
}

function openCategory() {
  closeReview()
  const pill = document.getElementById("cat-amount-pill")
  if (pill) pill.textContent = fmt(reviewState.edits.amount ?? reviewState.item?.amount, reviewState.edits.currency ?? "EUR")
  pickedCategory = null
  renderCategoryGrid()
  document.getElementById("cat-modal")?.classList.add("show")
}

function closeCategory() {
  document.getElementById("cat-modal")?.classList.remove("show")
}

function renderCategoryGrid() {
  const item = reviewState.item
  const suggestedId = item?.suggested_category ?? "misc"
  const merchant = (reviewState.edits.merchant ?? "").toLowerCase()

  const cats = CATEGORIES
  const suggested = cats.filter(
    (c) =>
      c.id === suggestedId ||
      merchant.includes(c.id) ||
      (c.id === "groceries" && /carrefour|delhaize|lidl/.test(merchant))
  )

  const tile = (c) => `
    <button class="cat-tile ${pickedCategory === c.id ? "selected" : ""}" data-cat="${c.id}">
      <div class="glyph" style="color:${c.color}">${c.glyph}</div>
      <div class="name">${c.name}</div>
      <div class="meta mono">${fmt(c.spent)} / ${fmt(c.budget)}</div>
    </button>`

  const suggestedEl = document.getElementById("cat-suggested")
  const allEl = document.getElementById("cat-all")
  if (suggestedEl)
    suggestedEl.innerHTML = suggested.map(tile).join("") ||
      `<div class="muted" style="grid-column:1/-1;font-size:12.5px">No automatic suggestion — pick one below.</div>`
  if (allEl) allEl.innerHTML = cats.map(tile).join("")

  document.getElementById("cat-modal")?.querySelectorAll(".cat-tile").forEach((t) => {
    t.addEventListener("click", () => {
      pickedCategory = t.dataset.cat
      renderCategoryGrid()
      const cat = CATEGORIES.find((c) => c.id === pickedCategory)
      const label = document.getElementById("cat-selected-label")
      if (label && cat)
        label.innerHTML = `Posting to <strong style="color:var(--ink)">${cat.name}</strong> — spend becomes <span class="mono dim">${fmt(cat.spent + (reviewState.edits.amount ?? 0))}</span>`
      const confirm = document.getElementById("cat-confirm")
      if (confirm) confirm.disabled = !pickedCategory
    })
  })
}

// ─── Toasts ───────────────────────────────────────────────────────────────────

export function pushToast(msg, action) {
  const t = document.createElement("div")
  t.className = "toast"
  t.innerHTML = `
    <svg class="ico" width="14" height="14" viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.5"><circle cx="8" cy="8" r="6"/><path d="M5 8l2 2 4-4"/></svg>
    <span>${msg}</span>
    ${action ? `<button data-toast-action>${action.label}</button>` : ""}
  `
  if (action) t.querySelector("[data-toast-action]").addEventListener("click", () => { action.fn(); t.remove() })
  document.getElementById("toasts")?.appendChild(t)
  setTimeout(() => { t.classList.add("exit"); setTimeout(() => t.remove(), 240) }, action ? 8000 : 3200)
}
