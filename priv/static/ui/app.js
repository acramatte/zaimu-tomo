/* ============================
   Zaimutomo — main app wiring
   Routes, events, modals, drag/drop, OCR pipeline subscription
   ============================ */

(function () {
  const $ = (s, root = document) => root.querySelector(s);
  const $$ = (s, root = document) => Array.from(root.querySelectorAll(s));

  const state = {
    route: 'dashboard',
    activityFilter: 'all',
    density: 'comfortable',
    async: 'subtle',
    review: { item: null, edits: {} },
    pickedCategory: null,
  };

  // ---------- Density / async re-render ----------
  function applyDensity() {
    document.body.classList.toggle('density-compact', state.density === 'compact');
    document.body.classList.toggle('density-comfortable', state.density !== 'compact');
  }

  // ---------- Routes ----------
  function setRoute(r) {
    state.route = r;
    $$('.nav-item').forEach(n => n.classList.toggle('active', n.dataset.route === r));
    const titles = {
      dashboard: ['Dashboard', '· May 2026'],
      activity:  ['Activity',  '· async pipeline'],
      journal:   ['Journal entries', '· general ledger'],
      documents: ['Documents', '· archive'],
      budgets:   ['Budgets', '· May 2026'],
      account:   ['Account', '· profile'],
      rules:     ['Rules & categories', '· auto-routing'],
    };
    const [title, sub] = titles[r] || [r, ''];
    $('#route-name').textContent = title;
    $('#route-sub').textContent = sub;
    render();
  }

  function render() {
    const view = $('#view');
    if (state.route === 'dashboard') view.innerHTML = window.RENDER.renderDashboard(state);
    else if (state.route === 'activity') view.innerHTML = window.RENDER.renderActivity(state);
    else if (state.route === 'journal') view.innerHTML = window.RENDER.renderStub('Journal entries', 'Every posted line, double-entry, exportable to CSV / Phoenix import.');
    else if (state.route === 'documents') view.innerHTML = window.RENDER.renderStub('Documents', 'Original files attached to entries — searchable, OCRed, tagged.');
    else if (state.route === 'budgets') view.innerHTML = window.RENDER.renderStub('Budgets', 'Per-category budgets, monthly and annual ceilings, rollover rules.');
    else if (state.route === 'account') view.innerHTML = window.RENDER.renderStub('Account', 'Profile, currency, locale, integrations, billing.');
    else if (state.route === 'rules') view.innerHTML = window.RENDER.renderStub('Rules & categories', 'Define how merchants map to categories — auto-post when confidence is high.');
    bindViewEvents();
    updateBell();
  }

  function bindViewEvents() {
    // Dashboard drop zone
    const dz = $('#drop-zone');
    if (dz) {
      dz.addEventListener('click', () => $('#file-input').click());
      ['dragenter','dragover'].forEach(e => dz.addEventListener(e, ev => { ev.preventDefault(); dz.classList.add('drag'); }));
      ['dragleave','drop'].forEach(e => dz.addEventListener(e, ev => { ev.preventDefault(); dz.classList.remove('drag'); }));
      dz.addEventListener('drop', ev => {
        const files = Array.from(ev.dataTransfer.files);
        if (files.length) handleUpload(files);
      });
    }
    // Review buttons
    $$('[data-review]').forEach(b => b.addEventListener('click', e => {
      e.stopPropagation();
      const id = b.dataset.review;
      const item = window.DATA.ACTIVITY.find(a => a.id === id);
      if (item) openReview(item);
    }));
    // Retry buttons
    $$('[data-retry]').forEach(b => b.addEventListener('click', e => {
      const id = b.dataset.retry;
      const item = window.DATA.ACTIVITY.find(a => a.id === id);
      if (item) {
        item.status = 'processing';
        item.error = null;
        item._sample = window.DATA.SAMPLES[1];
        window.OCR.uploadFiles([{ name: item.filename || 'retry.pdf' }]);
        // Re-trigger sample for this item
        setTimeout(() => {
          const sample = window.DATA.SAMPLES[1];
          Object.assign(item, {
            status: 'review',
            merchant: sample.merchant_name,
            amount: sample.total,
            currency: sample.currency,
            date: sample.date_iso,
            invoice_no: sample.invoice_no,
            vat_pct: sample.vat_pct,
            conf: sample.conf,
            ocr: { merchant_name: sample.merchant_name, address: sample.address, invoice_no: sample.invoice_no, date_raw: sample.date_iso, lines: sample.lines, subtotal: sample.subtotal, vat: sample.vat, total: sample.total },
            suggested_category: sample.suggested_category,
          });
          render();
        }, 2200);
        render();
      }
    }));
    // Activity tabs
    $$('.tab[data-filter]').forEach(t => t.addEventListener('click', () => {
      state.activityFilter = t.dataset.filter;
      render();
    }));
    // Inbox / route links
    $$('[data-route-link]').forEach(a => a.addEventListener('click', () => setRoute(a.dataset.routeLink)));
  }

  // ---------- Bell / notifications dropdown ----------
  function updateBell() {
    const inFlight = window.DATA.ACTIVITY.filter(a => a.status === 'processing' || a.status === 'review');
    const bell = $('#bell');
    bell.classList.toggle('has-unread', inFlight.length > 0);
    $('#bell-count').textContent = inFlight.length;
    const navBadge = $('#nav-activity-badge');
    if (navBadge) {
      navBadge.textContent = inFlight.length;
      navBadge.style.display = inFlight.length ? '' : 'none';
    }
    // Notif feed dropdown content
    const feed = $('#notif-feed');
    if (feed) {
      const recent = window.DATA.ACTIVITY.slice(0, 6);
      feed.innerHTML = recent.map(window.RENDER.feedItemHTML).join('');
      // Re-bind review buttons in dropdown
      $$('[data-review]', feed).forEach(b => b.addEventListener('click', e => {
        e.stopPropagation();
        const id = b.dataset.review;
        const item = window.DATA.ACTIVITY.find(a => a.id === id);
        if (item) { closeNotif(); openReview(item); }
      }));
    }
  }
  function toggleNotif() { $('#notif-pop').classList.toggle('show'); }
  function closeNotif() { $('#notif-pop').classList.remove('show'); }

  // ---------- File upload / drag-drop ----------
  function handleUpload(files) {
    const created = window.OCR.uploadFiles(files);
    pushToast(`Uploaded ${files.length} document${files.length===1?'':'s'} · OCR running`);
    render();
  }

  // ---------- Toasts ----------
  function pushToast(msg, action) {
    const t = document.createElement('div');
    t.className = 'toast';
    t.innerHTML = `
      <svg class="ico" width="14" height="14" viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.5"><circle cx="8" cy="8" r="6"/><path d="M5 8l2 2 4-4"/></svg>
      <span>${msg}</span>
      ${action ? `<button data-toast-action>${action.label}</button>` : ''}
    `;
    if (action) t.querySelector('[data-toast-action]').addEventListener('click', () => {
      action.fn(); t.remove();
    });
    $('#toasts').appendChild(t);
    setTimeout(() => { t.classList.add('exit'); setTimeout(() => t.remove(), 240); }, action ? 8000 : 3200);
  }

  // ---------- Review modal ----------
  function openReview(item) {
    state.review = { item, edits: {
      merchant: item.merchant, amount: item.amount, currency: item.currency,
      date: item.date, invoice_no: item.invoice_no, vat_pct: item.vat_pct,
      reason: '',
    }};
    renderReview();
    $('#review-modal').classList.add('show');
  }
  function closeReview() { $('#review-modal').classList.remove('show'); }

  function renderReview() {
    const { item, edits } = state.review;
    if (!item || !item.ocr) return;
    const ocr = item.ocr, conf = item.conf || {};
    const body = $('#review-body');

    const confBar = (key) => {
      const v = conf[key] != null ? conf[key] : 0.9;
      const low = v < 0.75;
      const cls = low ? 'low low-conf' : 'high';
      return { v, low, html: `<span class="conf ${low?'low':''}">${(v*100).toFixed(0)}% <span class="bar"><i style="width:${(v*100).toFixed(0)}%"></i></span></span>` };
    };

    const cm = confBar('merchant'), ca = confBar('amount'), cd = confBar('date'),
          cv = confBar('vat'), ci = confBar('invoice_no');

    body.innerHTML = `
      <div class="doc-preview">
        <div class="receipt">
          <div class="receipt-head">${ocr.merchant_name}</div>
          <div class="receipt-meta">
            ${ocr.address}<br>
            Invoice <span class="ocr-hl ${ci.low?'':'confident'}" data-field="invoice_no">${ocr.invoice_no}</span>
            · <span class="ocr-hl ${cd.low?'':'confident'}" data-field="date">${ocr.date_raw}</span>
          </div>
          ${ocr.lines.map(l => `
            <div class="receipt-line">
              <span>${l.q}× ${l.d}</span>
              <span>${(l.p * l.q).toFixed(2)}</span>
            </div>`).join('')}
          <div class="receipt-line" style="margin-top:8px;color:var(--muted)">
            <span>Subtotal</span><span>${ocr.subtotal.toFixed(2)}</span>
          </div>
          <div class="receipt-line" style="color:var(--muted)">
            <span>TVA <span class="ocr-hl ${cv.low?'':'confident'}" data-field="vat_pct">${item.vat_pct||21}%</span></span>
            <span>${ocr.vat.toFixed(2)}</span>
          </div>
          <div class="receipt-line total">
            <span>TOTAL</span>
            <span><span class="ocr-hl ${ca.low?'':'confident'}" data-field="amount">€${ocr.total.toFixed(2)}</span></span>
          </div>
          <div class="receipt-foot">Original: ${item.filename} · scanned ${window.RENDER.relTime(item.ts)}</div>
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
          <input type="text" data-edit="merchant" class="${cm.low?'low-conf':''}" value="${edits.merchant || ''}">
        </div>

        <div class="field-row three">
          <div class="field">
            <label>Amount ${ca.html}</label>
            <input type="number" data-edit="amount" class="amt-input ${ca.low?'low-conf':''}" step="0.01" value="${edits.amount ?? ''}">
          </div>
          <div class="field">
            <label>Currency</label>
            <select data-edit="currency">
              <option ${edits.currency==='EUR'?'selected':''}>EUR</option>
              <option ${edits.currency==='USD'?'selected':''}>USD</option>
              <option ${edits.currency==='GBP'?'selected':''}>GBP</option>
              <option ${edits.currency==='JPY'?'selected':''}>JPY</option>
            </select>
          </div>
          <div class="field">
            <label>Date ${cd.html}</label>
            <input type="date" data-edit="date" class="${cd.low?'low-conf':''}" value="${edits.date || ''}">
          </div>
        </div>

        <div class="field-row">
          <div class="field">
            <label>Invoice no. ${ci.html}</label>
            <input type="text" data-edit="invoice_no" class="${ci.low?'low-conf':''}" value="${edits.invoice_no || ''}">
          </div>
          <div class="field">
            <label>VAT % ${cv.html}</label>
            <input type="number" data-edit="vat_pct" class="num-input ${cv.low?'low-conf':''}" value="${edits.vat_pct ?? 21}">
          </div>
        </div>

        <div class="field">
          <label>Reason / note <span class="muted" style="text-transform:none;letter-spacing:0;font-size:11px;font-weight:400">optional</span></label>
          <textarea data-edit="reason" placeholder="e.g. office hardware refresh, replacing 3-year-old mouse">${edits.reason || ''}</textarea>
        </div>

        ${ci.low || cd.low || cv.low ? `
          <div style="background:var(--warn-tint);border:1px solid color-mix(in oklab, var(--warn) 30%, transparent);padding:10px 12px;border-radius:6px;font-size:12.5px;color:oklch(0.35 0.13 70);display:flex;gap:10px">
            <span style="flex-shrink:0">⚠</span>
            <span>Low-confidence fields are highlighted. Verify before approving — your edits retrain the extractor for this merchant.</span>
          </div>` : ''}
      </div>
    `;

    // Wire up edit fields
    $$('[data-edit]', body).forEach(el => {
      el.addEventListener('input', () => {
        const key = el.dataset.edit;
        let v = el.value;
        if (el.type === 'number') v = parseFloat(v);
        state.review.edits[key] = v;
      });
    });
    // Receipt highlight clicks → focus form field
    $$('.ocr-hl', body).forEach(hl => {
      hl.addEventListener('click', () => {
        const field = hl.dataset.field;
        const target = body.querySelector(`[data-edit="${field}"]`);
        if (target) { target.focus(); target.select && target.select(); }
        $$('.ocr-hl', body).forEach(h => h.classList.toggle('active', h === hl));
      });
    });
  }

  // ---------- Category modal ----------
  function openCategory() {
    const item = state.review.item;
    closeReview();
    $('#cat-amount-pill').textContent =
      window.RENDER.fmt(state.review.edits.amount || item.amount, state.review.edits.currency || 'EUR');
    state.pickedCategory = null;
    renderCategoryGrid();
    $('#cat-modal').classList.add('show');
  }
  function closeCategory() { $('#cat-modal').classList.remove('show'); }
  function renderCategoryGrid() {
    const item = state.review.item;
    const suggestedId = item.suggested_category || 'misc';
    const merchant = (state.review.edits.merchant || '').toLowerCase();

    // Suggested = sample's hint + a near-match heuristic
    const cats = window.DATA.CATEGORIES.filter(c => c.id !== 'income');
    const suggested = cats.filter(c =>
      c.id === suggestedId || merchant.includes(c.id) || (c.id === 'groceries' && /carrefour|delhaize|lidl/.test(merchant))
    );
    const all = cats;

    const tile = (c) => `
      <button class="cat-tile ${state.pickedCategory===c.id?'selected':''}" data-cat="${c.id}">
        <div class="glyph" style="color:${c.color}">${c.glyph}</div>
        <div class="name">${c.name}</div>
        <div class="meta mono">${window.RENDER.fmt(c.spent)} / ${window.RENDER.fmt(c.budget)}</div>
      </button>`;
    $('#cat-suggested').innerHTML = suggested.map(tile).join('') ||
      '<div class="muted" style="grid-column:1/-1;font-size:12.5px">No automatic suggestion — pick one below.</div>';
    $('#cat-all').innerHTML = all.map(tile).join('');

    $$('.cat-tile', $('#cat-modal')).forEach(t => t.addEventListener('click', () => {
      state.pickedCategory = t.dataset.cat;
      renderCategoryGrid();
      const cat = window.DATA.CATEGORIES.find(c => c.id === state.pickedCategory);
      $('#cat-selected-label').innerHTML = cat
        ? `Posting to <strong style="color:var(--ink)">${cat.name}</strong> — your spend in this category becomes <span class="mono dim">${window.RENDER.fmt(cat.spent + (state.review.edits.amount || 0))}</span>`
        : 'Pick one to post the journal entry';
      $('#cat-confirm').disabled = !state.pickedCategory;
    }));
  }

  // ---------- Init ----------
  function init() {
    // Sidebar nav
    $$('.nav-item[data-route]').forEach(n => n.addEventListener('click', () => setRoute(n.dataset.route)));

    // Topbar
    $('#quick-add').addEventListener('click', () => $('#file-input').click());
    $('#bell').addEventListener('click', (e) => { e.stopPropagation(); toggleNotif(); });
    document.addEventListener('click', (e) => {
      if (!$('#notif-pop').contains(e.target) && !$('#bell').contains(e.target)) closeNotif();
    });

    // File input
    $('#file-input').addEventListener('change', (e) => {
      const files = Array.from(e.target.files || []);
      if (files.length) handleUpload(files);
      e.target.value = '';
    });

    // Global drag & drop
    let dragDepth = 0;
    const overlay = $('#drop-overlay');
    window.addEventListener('dragenter', (e) => { e.preventDefault(); dragDepth++; overlay.classList.add('show'); });
    window.addEventListener('dragleave', (e) => { e.preventDefault(); dragDepth = Math.max(0, dragDepth-1); if (!dragDepth) overlay.classList.remove('show'); });
    window.addEventListener('dragover',  (e) => e.preventDefault());
    window.addEventListener('drop', (e) => {
      e.preventDefault(); dragDepth = 0; overlay.classList.remove('show');
      const files = Array.from(e.dataTransfer.files);
      if (files.length) handleUpload(files);
    });
    // Paste
    window.addEventListener('paste', (e) => {
      const files = Array.from(e.clipboardData?.files || []);
      if (files.length) handleUpload(files);
    });

    // Review modal buttons
    $('#review-cancel').addEventListener('click', closeReview);
    $('#review-reject').addEventListener('click', () => {
      window.OCR.reject(state.review.item);
      closeReview();
      pushToast('Document rejected — moved to failed');
      render();
    });
    $('#review-approve').addEventListener('click', () => {
      window.OCR.approve(state.review.item, state.review.edits);
      openCategory();
    });
    // Category modal buttons
    $('#cat-back').addEventListener('click', () => {
      closeCategory();
      $('#review-modal').classList.add('show');
    });
    $('#cat-confirm').addEventListener('click', () => {
      const item = state.review.item;
      window.OCR.categorize(item, state.pickedCategory);
      // Add to category spent
      const cat = window.DATA.CATEGORIES.find(c => c.id === state.pickedCategory);
      if (cat && state.review.edits.amount) cat.spent += state.review.edits.amount;
      window.DATA.SUMMARY.monthExpenses += state.review.edits.amount || 0;
      closeCategory();
      pushToast(`Posted to ${cat.name} · ${window.RENDER.fmt(state.review.edits.amount)}`, {
        label: 'View',
        fn: () => setRoute('activity'),
      });
      render();
    });

    // Tweaks
    window.TWEAKS.subscribe((t) => {
      state.density = t.density;
      state.async = t.async;
      applyDensity();
      render();
    });
    window.TWEAKS.init();
    state.density = window.TWEAKS.get().density;
    state.async = window.TWEAKS.get().async;
    applyDensity();

    // Demo button in tweaks
    $('#demo-upload').addEventListener('click', () => {
      const sample = window.DATA.SAMPLES[Math.floor(Math.random()*window.DATA.SAMPLES.length)];
      handleUpload([{ name: sample.filename }]);
    });

    // Subscribe to OCR events for toasts + re-render
    window.OCR.subscribe((evt) => {
      if (evt.type === 'extracted') {
        pushToast(`${evt.item.merchant} · ready for review`, {
          label: 'Review',
          fn: () => openReview(evt.item),
        });
      }
      render();
    });

    setRoute('dashboard');
  }

  if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', init);
  else init();
})();
