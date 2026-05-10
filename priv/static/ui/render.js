/* ============================
   Zaimutomo — view rendering
   ============================ */

window.RENDER = (function () {

  const fmt = (n, currency = 'EUR') => {
    if (n == null || isNaN(n)) return '—';
    return new Intl.NumberFormat('en-IE', {
      style:'currency', currency, currencyDisplay:'symbol',
      minimumFractionDigits: 2, maximumFractionDigits: 2,
    }).format(n);
  };
  const fmtNum = (n) => new Intl.NumberFormat('en-IE',{ minimumFractionDigits: 2, maximumFractionDigits: 2 }).format(n);
  const splitEuro = (n) => {
    const [w,c] = n.toFixed(2).split('.');
    return { w: Number(w).toLocaleString('en-IE'), c };
  };
  const relTime = (iso) => {
    const d = new Date(iso); const now = new Date('2026-05-09T09:30:00Z');
    const diff = (now - d) / 1000;
    if (diff < 60) return 'just now';
    if (diff < 3600) return Math.floor(diff/60) + 'm ago';
    if (diff < 86400) return Math.floor(diff/3600) + 'h ago';
    return Math.floor(diff/86400) + 'd ago';
  };

  // ---------- Sparkline ----------
  function sparkline(values, w = 600, h = 56) {
    const min = Math.min(...values), max = Math.max(...values);
    const range = max - min || 1;
    const stepX = w / (values.length - 1);
    const pts = values.map((v, i) => [i * stepX, h - ((v - min) / range) * (h - 6) - 3]);
    const path = pts.map((p, i) => (i === 0 ? 'M' : 'L') + p[0].toFixed(1) + ' ' + p[1].toFixed(1)).join(' ');
    const area = path + ` L ${w} ${h} L 0 ${h} Z`;
    const last = pts[pts.length - 1];
    return `
      <svg class="spark" viewBox="0 0 ${w} ${h}" preserveAspectRatio="none">
        <defs>
          <linearGradient id="sparkfill" x1="0" x2="0" y1="0" y2="1">
            <stop offset="0%" stop-color="oklch(0.45 0.08 155)" stop-opacity="0.16"/>
            <stop offset="100%" stop-color="oklch(0.45 0.08 155)" stop-opacity="0"/>
          </linearGradient>
        </defs>
        <path d="${area}" fill="url(#sparkfill)"/>
        <path d="${path}" fill="none" stroke="oklch(0.45 0.08 155)" stroke-width="1.5"/>
        <circle cx="${last[0]}" cy="${last[1]}" r="3" fill="oklch(0.45 0.08 155)"/>
        <circle cx="${last[0]}" cy="${last[1]}" r="6" fill="oklch(0.45 0.08 155)" opacity="0.18"/>
      </svg>`;
  }

  // ---------- Donut ----------
  function donut(segments, size = 160) {
    const r = size / 2 - 12, cx = size/2, cy = size/2;
    const c = 2 * Math.PI * r;
    const total = segments.reduce((s,x) => s + x.value, 0) || 1;
    let off = 0;
    const arcs = segments.map(s => {
      const len = (s.value / total) * c;
      const arc = `<circle cx="${cx}" cy="${cy}" r="${r}" fill="none" stroke="${s.color}" stroke-width="14"
        stroke-dasharray="${len.toFixed(2)} ${(c - len).toFixed(2)}"
        stroke-dashoffset="${(-off).toFixed(2)}"/>`;
      off += len;
      return arc;
    }).join('');
    return `<svg viewBox="0 0 ${size} ${size}">${arcs}</svg>`;
  }

  // ---------- Status pill ----------
  function statusPill(status) {
    if (status === 'processing') return `<span class="pill processing"><span class="pulse"></span>Processing</span>`;
    if (status === 'review') return `<span class="pill review"><span class="pulse"></span>Needs review</span>`;
    if (status === 'posted') return `<span class="pill posted">Posted</span>`;
    if (status === 'failed') return `<span class="pill failed">Failed</span>`;
    return `<span class="pill">${status}</span>`;
  }

  function feedItemHTML(item, opts = {}) {
    const cat = window.DATA.CATEGORIES.find(c => c.id === item.category);
    const amt = item.amount != null ? fmt(item.amount, item.currency || 'EUR') : '—';
    let desc = '';
    if (item.status === 'processing') desc = 'Sent to OCR · extraction in progress';
    else if (item.status === 'review') desc = `<span class="amt">${amt}</span> · ${item.invoice_no || '—'} · ready to verify`;
    else if (item.status === 'posted') desc = `<span class="amt">${amt}</span>${cat ? ' · '+cat.name : ''}`;
    else if (item.status === 'failed') desc = item.error || 'Processing failed';
    const actions = item.status === 'review'
      ? `<button class="btn sm primary" data-review="${item.id}">Review</button>`
      : item.status === 'failed'
        ? `<button class="btn sm" data-retry="${item.id}">Retry</button>`
        : '';
    return `
      <div class="feed-item ${item.status}" data-id="${item.id}">
        <div class="stat">${item.filename ? item.filename.split('.').pop().slice(0,3).toUpperCase() : 'DOC'}</div>
        <div class="body">
          <div class="title">${item.merchant || (item.status==='processing' ? 'Scanning…' : 'Untitled')} ${statusPill(item.status)}</div>
          <div class="desc">${desc} · <span class="muted">${item.filename || ''}</span></div>
        </div>
        <div class="actions">
          ${actions}
          <time>${relTime(item.ts)}</time>
        </div>
      </div>`;
  }

  function miniFeedItemHTML(item) {
    const amt = item.amount != null ? fmt(item.amount, item.currency || 'EUR') : '';
    let n, s;
    if (item.status === 'processing') { n = 'Scanning ' + (item.filename || 'document') + '…'; s = 'OCR · ~3s'; }
    else if (item.status === 'review') { n = item.merchant; s = amt + ' · review'; }
    else if (item.status === 'posted') { n = item.merchant; s = amt + ' · posted'; }
    else { n = item.merchant; s = item.error || 'failed'; }
    return `
      <div class="mini-feed-item ${item.status}" data-id="${item.id}">
        <div class="dot"></div>
        <div class="t">
          <div class="n">${n}</div>
          <div class="s">${s}</div>
        </div>
        <time>${relTime(item.ts)}</time>
      </div>`;
  }

  // ---------- Dashboard ----------
  function renderDashboard(state) {
    const { SUMMARY, NETWORTH_HISTORY, CATEGORIES, ACTIVITY, UPCOMING } = window.DATA;
    const nw = splitEuro(SUMMARY.netWorth);

    // Filter top categories with spend > 0 (excluding income)
    const cats = CATEGORIES.filter(c => c.id !== 'income' && c.spent > 0)
                   .sort((a,b) => b.spent - a.spent);
    const totalSpent = cats.reduce((s,c) => s + c.spent, 0);
    const segments = cats.map(c => ({ value: c.spent, color: c.color }));

    const monthPct = Math.min(100, (SUMMARY.monthExpenses / SUMMARY.monthBudget) * 100);
    const budgetClass = monthPct > 100 ? 'over' : (monthPct > 85 ? 'warn' : '');

    const inFlight = ACTIVITY.filter(a => a.status === 'processing' || a.status === 'review');
    const heroVariant = state.async === 'hero' && inFlight.length > 0;
    const inboxVariant = state.async === 'inbox';

    let processingHero = '';
    if (heroVariant) {
      const proc = inFlight.find(a => a.status === 'processing');
      const review = inFlight.find(a => a.status === 'review');
      processingHero = `
        <div class="processing-hero">
          <div>
            <div style="display:flex;align-items:center;gap:10px;font-size:13.5px;font-weight:500">
              <span class="spinner"></span>
              ${proc ? `Reading <span class="mono">${proc.filename}</span> · OCR + extraction` : `${review.merchant} · ready for review`}
            </div>
            <div class="muted" style="font-size:12px;margin-top:2px">
              ${proc ? 'Async pipeline · usually <code class="mono">~3s</code>' : `${fmt(review.amount)} · invoice ${review.invoice_no} · low-confidence fields highlighted`}
            </div>
            ${proc ? '<div class="progress"><div class="progress-fill"></div></div>' : ''}
          </div>
          <div>
            ${review ? `<button class="btn primary" data-review="${review.id}">Review now</button>` : ''}
          </div>
        </div>`;
    }

    const mainColSpan = inboxVariant ? 'span-9' : 'span-12';

    return `
      <h1 class="view-title">Good morning, Sora <span class="accent">—</span> the books are quiet today.</h1>
      <p class="view-sub">May 2026 · everything reconciled through May 8 · ${inFlight.length} document${inFlight.length===1?'':'s'} in flight</p>

      ${processingHero}

      <div class="grid grid-12">
        <div class="${mainColSpan}">
          <div class="grid grid-12">

            <!-- HERO net worth + breakdown -->
            <div class="card span-12 hero">
              <div class="card-head" style="margin-bottom:6px">
                <div>
                  <div class="label">Net worth</div>
                </div>
                <div class="card-meta">
                  <span class="dim mono">+ ${fmt(SUMMARY.netWorth - NETWORTH_HISTORY[0])}</span>
                  <span class="muted"> over 6 months</span>
                </div>
              </div>
              <div class="hero-num">
                <span class="cur">€</span>
                <span>${nw.w}</span>
                <span class="cents">.${nw.c}</span>
              </div>
              <div style="margin-top:10px">
                ${sparkline(NETWORTH_HISTORY, 800, 56)}
              </div>
              <div class="hero-row">
                <div class="hero-stat">
                  <div class="label">Cash</div>
                  <div class="v">${fmt(SUMMARY.cash)}</div>
                  <div class="delta up">▲ €82.41 wk</div>
                </div>
                <div class="hero-stat">
                  <div class="label">Investments</div>
                  <div class="v">${fmt(SUMMARY.investments)}</div>
                  <div class="delta up">▲ 1.2% wk</div>
                </div>
                <div class="hero-stat">
                  <div class="label">Savings</div>
                  <div class="v">${fmt(SUMMARY.savings)}</div>
                  <div class="delta up">▲ €100 wk</div>
                </div>
                <div class="hero-stat">
                  <div class="label">Projected EoM</div>
                  <div class="v">${fmt(SUMMARY.projectionEom)}</div>
                  <div class="delta up">on track</div>
                </div>
              </div>
            </div>

            <!-- BUDGET vs spend -->
            <div class="card span-7">
              <div class="card-head">
                <div class="card-title">May spending</div>
                <div class="card-meta tnum mono">
                  <span class="dim">${fmt(SUMMARY.monthExpenses)}</span>
                  <span class="muted"> / ${fmt(SUMMARY.monthBudget)}</span>
                </div>
              </div>
              <div class="budget-bar ${budgetClass}" style="margin-bottom:14px">
                <div class="fill" style="width:${monthPct.toFixed(1)}%"></div>
              </div>
              <div style="margin-top:6px">
                ${cats.slice(0,6).map(c => {
                  const pct = Math.min(100, (c.spent / c.budget) * 100);
                  const over = c.spent > c.budget;
                  return `
                    <div class="budget-row">
                      <div class="name"><span class="cat-dot" style="background:${c.color}"></span>${c.name}</div>
                      <div class="num ${over?'over':''}">${fmt(c.spent)}</div>
                      <div class="num dim">${fmt(c.budget)}</div>
                      <div class="num ${over?'over':'dim'}">${over ? '+' : ''}${fmtNum(c.spent - c.budget)}</div>
                    </div>`;
                }).join('')}
              </div>
            </div>

            <!-- CATEGORIES donut -->
            <div class="card span-5">
              <div class="card-head">
                <div class="card-title">Where it goes</div>
                <div class="card-meta">May, by category</div>
              </div>
              <div class="donut-wrap">
                <div class="donut">
                  ${donut(segments, 160)}
                  <div class="donut-center">
                    <div>
                      <div class="v">${fmt(totalSpent).replace('€','')}</div>
                      <div class="l">€ this month</div>
                    </div>
                  </div>
                </div>
                <div class="cat-list">
                  ${cats.slice(0,6).map(c => `
                    <div class="cat-list-row">
                      <div class="left">
                        <span class="cat-dot" style="background:${c.color}"></span>
                        <span>${c.name}</span>
                        <span class="pct">${((c.spent/totalSpent)*100).toFixed(0)}%</span>
                      </div>
                      <div></div>
                      <div class="amt">${fmt(c.spent)}</div>
                    </div>`).join('')}
                </div>
              </div>
            </div>

            <!-- DROP zone + Upcoming -->
            <div class="card span-5">
              <div class="card-head" style="margin-bottom:8px">
                <div class="card-title">Quick add</div>
                <div class="card-meta">drop · paste · click</div>
              </div>
              <div class="drop-zone" id="drop-zone">
                <div class="glyph">+</div>
                <div class="h">Drop an invoice or receipt</div>
                <div class="sub">PDF, JPG, HEIC · sent to OCR · review takes <span class="kbd">~30s</span></div>
                <div class="sub" style="margin-top:10px">
                  or paste with <span class="kbd">⌘V</span>
                  · click to <span class="kbd">browse</span>
                </div>
              </div>
              <div style="display:flex;justify-content:space-between;margin-top:14px;font-size:11.5px" class="muted">
                <span>This month: <span class="mono dim">${ACTIVITY.filter(a=>a.status==='posted').length}</span> documents posted</span>
                <span class="mono">avg ${cats.length ? '~3.1s' : ''} OCR</span>
              </div>
            </div>

            <div class="card span-7">
              <div class="card-head">
                <div class="card-title">Upcoming this month</div>
                <div class="card-meta mono dim">${fmt(UPCOMING.reduce((s,u)=>s+u.amt,0))} planned</div>
              </div>
              ${UPCOMING.map(u => `
                <div class="upcoming-row">
                  <div class="date-chip">
                    <div class="d">${u.d}</div>
                    <div class="m">${u.m}</div>
                  </div>
                  <div>
                    <div class="name">${u.name}</div>
                    <div class="sub">${u.sub}</div>
                  </div>
                  <div class="amt">${fmt(u.amt)}</div>
                </div>`).join('')}
            </div>

            <!-- RECENT activity (only when async treatment is "subtle") -->
            ${state.async === 'subtle' ? `
              <div class="card span-12">
                <div class="card-head">
                  <div class="card-title">Recent activity</div>
                  <div class="card-meta"><a class="muted" data-route-link="activity" style="cursor:pointer">View all →</a></div>
                </div>
                <div class="feed" id="dash-feed">
                  ${ACTIVITY.slice(0, 5).map(a => feedItemHTML(a)).join('')}
                </div>
              </div>` : ''}
          </div>
        </div>

        ${inboxVariant ? `
          <div class="span-3">
            <div class="card inbox-panel">
              <div class="card-head">
                <div class="card-title" style="font-size:14px">Inbox</div>
                <div class="card-meta mono">${ACTIVITY.length}</div>
              </div>
              <div style="margin:0 -4px">
                ${ACTIVITY.slice(0,8).map(a => miniFeedItemHTML(a)).join('')}
              </div>
              <div class="hairline" style="margin-top:10px;padding-top:10px">
                <a class="muted" data-route-link="activity" style="font-size:12px;cursor:pointer">Open activity →</a>
              </div>
            </div>
          </div>` : ''}
      </div>
    `;
  }

  // ---------- Activity page ----------
  function renderActivity(state) {
    const { ACTIVITY } = window.DATA;
    const counts = {
      all: ACTIVITY.length,
      review: ACTIVITY.filter(a=>a.status==='review').length,
      processing: ACTIVITY.filter(a=>a.status==='processing').length,
      posted: ACTIVITY.filter(a=>a.status==='posted').length,
      failed: ACTIVITY.filter(a=>a.status==='failed').length,
    };
    const filter = state.activityFilter || 'all';
    const items = filter === 'all' ? ACTIVITY : ACTIVITY.filter(a => a.status === filter);

    return `
      <h1 class="view-title">Activity <span class="accent">·</span> async processing feed</h1>
      <p class="view-sub">Every uploaded document, every OCR job, every posted journal entry — chronological, live over websocket.</p>

      <div class="tab-row">
        ${[
          ['all', 'All'],
          ['review','Needs review'],
          ['processing','Processing'],
          ['posted','Posted'],
          ['failed','Failed'],
        ].map(([k,l]) => `
          <div class="tab ${filter===k?'active':''}" data-filter="${k}">
            ${l} <span class="count">${counts[k]}</span>
          </div>`).join('')}
      </div>

      <div class="card">
        <div class="feed">
          ${items.length ? items.map(a => feedItemHTML(a)).join('') :
            `<div class="muted" style="padding:32px;text-align:center">Nothing here yet.</div>`}
        </div>
      </div>

      <div style="margin-top:20px;display:flex;gap:24px;font-size:12px" class="muted">
        <span class="mono">events.zaimutomo.app · phx_socket connected</span>
        <span>·</span>
        <span>Average extraction confidence this week <span class="mono dim">0.91</span></span>
        <span>·</span>
        <span><span class="mono dim">${counts.posted}</span> auto-posted via rules</span>
      </div>
    `;
  }

  function renderStub(title, sub) {
    return `
      <h1 class="view-title">${title}</h1>
      <p class="view-sub">${sub}</p>
      <div class="card" style="padding:64px;text-align:center">
        <div class="serif-display" style="font-size:36px;color:var(--muted);margin-bottom:8px">— stub —</div>
        <div class="muted">This screen is out of scope for the current focus. Dashboard and Activity are the fleshed-out views.</div>
      </div>`;
  }

  return { renderDashboard, renderActivity, renderStub, feedItemHTML, miniFeedItemHTML, statusPill, fmt, fmtNum, splitEuro, sparkline, donut, relTime };
})();
