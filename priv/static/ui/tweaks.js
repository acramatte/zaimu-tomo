/* ============================
   Zaimutomo — Tweaks panel
   Vanilla JS implementation of the tweaks protocol
   ============================ */

window.TWEAKS = (function () {
  const TWEAK_DEFAULTS = /*EDITMODE-BEGIN*/{
    "density": "comfortable",
    "async": "subtle"
  }/*EDITMODE-END*/;

  let state = { ...TWEAK_DEFAULTS };
  let active = false;
  const subs = new Set();

  function get() { return { ...state }; }
  function subscribe(fn) { subs.add(fn); return () => subs.delete(fn); }
  function set(key, val) {
    state[key] = val;
    try {
      window.parent.postMessage({ type: '__edit_mode_set_keys', edits: { [key]: val } }, '*');
    } catch(e){}
    subs.forEach(fn => fn(state));
  }

  function show() {
    active = true;
    document.getElementById('tweaks-panel').classList.add('show');
  }
  function hide() {
    active = false;
    document.getElementById('tweaks-panel').classList.remove('show');
  }

  function init() {
    // Wire up the panel
    const panel = document.getElementById('tweaks-panel');
    panel.querySelectorAll('.seg').forEach(seg => {
      const key = seg.getAttribute('data-tweak');
      seg.addEventListener('click', (e) => {
        const btn = e.target.closest('button[data-val]');
        if (!btn) return;
        seg.querySelectorAll('button').forEach(b => b.classList.toggle('active', b === btn));
        set(key, btn.getAttribute('data-val'));
        if (key === 'async') updateAsyncHelp(btn.getAttribute('data-val'));
      });
    });
    document.getElementById('tweaks-close').addEventListener('click', () => {
      hide();
      try { window.parent.postMessage({ type: '__edit_mode_dismissed' }, '*') } catch(e){}
    });

    // Listen for parent messages — handler MUST be registered before announce
    window.addEventListener('message', (e) => {
      const t = e.data && e.data.type;
      if (t === '__activate_edit_mode') show();
      else if (t === '__deactivate_edit_mode') hide();
    });
    try {
      window.parent.postMessage({ type: '__edit_mode_available' }, '*');
    } catch(e){}
  }

  function updateAsyncHelp(val) {
    const help = document.getElementById('async-help');
    if (!help) return;
    if (val === 'subtle') help.textContent = 'Toast + bell badge. Activity feed lives at the bottom of the dashboard.';
    else if (val === 'inbox') help.textContent = 'Persistent inbox panel on the dashboard right rail.';
    else if (val === 'hero') help.textContent = 'Live processing card replaces the dashboard hero when documents are in flight.';
  }

  return { get, set, subscribe, init, show, hide };
})();
