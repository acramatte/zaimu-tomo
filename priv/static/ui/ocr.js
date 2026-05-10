/* ============================
   Zaimutomo — OCR pipeline simulation
   Mirrors a real async/event-driven flow:
     uploaded → enqueued → ocr_running → extracted → review_pending
     → user_reviewed → category_picked → posted
   Each transition emits an event everyone subscribes to.
   ============================ */

window.OCR = (function () {
  const subscribers = new Set();
  function emit(evt) { subscribers.forEach(fn => fn(evt)); }
  function subscribe(fn) { subscribers.add(fn); return () => subscribers.delete(fn); }

  let nextId = 22;

  function uploadFiles(files) {
    const created = [];
    files.forEach((file) => {
      const id = 'j-' + String(nextId++).padStart(3, '0');
      // Pick a sample payload — round-robin
      const sample = window.DATA.SAMPLES[(nextId) % window.DATA.SAMPLES.length];
      const item = {
        id, status: 'processing',
        merchant: '…',
        filename: file.name || sample.filename,
        amount: null, currency: null, date: null, category: null,
        ts: new Date().toISOString(),
        _sample: sample,
      };
      window.DATA.ACTIVITY.unshift(item);
      created.push(item);
      emit({ type: 'uploaded', item });
      // Simulate the async pipeline
      const delay = 2200 + Math.random() * 1600;
      setTimeout(() => {
        // hydrate with extracted data, mark needs review
        const s = item._sample;
        Object.assign(item, {
          status: 'review',
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
        });
        emit({ type: 'extracted', item });
      }, delay);
    });
    return created;
  }

  function approve(item, edits) {
    Object.assign(item, edits);
    emit({ type: 'reviewed', item });
  }
  function categorize(item, categoryId) {
    item.category = categoryId;
    item.status = 'posted';
    emit({ type: 'posted', item });
  }
  function reject(item) {
    item.status = 'failed';
    item.error = 'Rejected by user';
    emit({ type: 'rejected', item });
  }

  return { uploadFiles, approve, categorize, reject, subscribe };
})();
