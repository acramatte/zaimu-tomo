/* ============================
   Zaimutomo — mocked data
   "Lived-in" personal account, EUR, May 2026
   ============================ */

window.DATA = (function () {

  const CATEGORIES = [
    { id: 'office',     name: 'Office',         glyph: 'o', color: 'oklch(0.55 0.08 240)', spent: 184.20,  budget: 250 },
    { id: 'groceries',  name: 'Groceries',      glyph: 'g', color: 'oklch(0.55 0.10 145)', spent: 412.83,  budget: 500 },
    { id: 'sport',      name: 'Sport',          glyph: 's', color: 'oklch(0.55 0.13 35)',  spent: 89.00,   budget: 80  },
    { id: 'outings',    name: 'Outings',        glyph: 'O', color: 'oklch(0.55 0.13 320)', spent: 268.40,  budget: 200 },
    { id: 'transport',  name: 'Transport',      glyph: 'T', color: 'oklch(0.55 0.10 200)', spent: 142.10,  budget: 180 },
    { id: 'home',       name: 'Home & utilities', glyph: 'h', color: 'oklch(0.55 0.07 75)', spent: 624.00, budget: 700 },
    { id: 'health',     name: 'Health',         glyph: 'H', color: 'oklch(0.55 0.10 15)',  spent: 38.50,   budget: 120 },
    { id: 'subs',       name: 'Subscriptions',  glyph: '~', color: 'oklch(0.55 0.10 280)', spent: 87.94,   budget: 100 },
    { id: 'travel',     name: 'Travel',         glyph: '✈', color: 'oklch(0.55 0.10 250)', spent: 0,       budget: 150 },
    { id: 'gifts',      name: 'Gifts & giving', glyph: '+', color: 'oklch(0.55 0.10 350)', spent: 45.00,   budget: 60  },
    { id: 'misc',       name: 'Misc',           glyph: '·', color: 'oklch(0.55 0.02 60)',  spent: 22.30,   budget: 80  },
    { id: 'income',     name: 'Income',         glyph: '↓', color: 'oklch(0.50 0.09 155)', spent: 0,       budget: 0   },
  ];

  // Recent activity feed — mix of states. Newest first.
  const ACTIVITY = [
    { id:'j-021', status:'review',     merchant:'Mediamarkt',         filename:'IMG_8821.jpg',   amount: 219.00, currency:'EUR', date:'2026-05-08', category:null,
      conf: { merchant: 0.96, amount: 0.99, date: 0.62, vat: 0.71, invoice_no: 0.42 },
      invoice_no: 'MM-2410581', vat_pct: 21, ts: '2026-05-09T09:14:00Z',
      ocr: {
        merchant_name: 'MEDIAMARKT BRUSSEL CITY 2',
        address: 'Rue Neuve 123, 1000 Brussel',
        invoice_no: 'MM-2410581',
        date_raw: '08.05.26',
        lines: [
          { d: 'Logitech MX Master 3S', q:1, p: 99.00 },
          { d: 'USB-C dock 4-in-1',    q:1, p: 67.50 },
          { d: 'HDMI cable 2m',        q:2, p: 12.95 },
          { d: 'Carrying case M',      q:1, p: 26.60 },
        ],
        subtotal: 218.95, vat: 38.02, total: 219.00,
      } },
    { id:'j-020', status:'processing', merchant:'…', filename:'scan-2026-05-09-091011.pdf', amount: null, currency:null, date:null, category:null, ts: '2026-05-09T09:10:11Z' },
    { id:'j-019', status:'posted',     merchant:'Carrefour Express',  filename:'recu-carrefour.pdf', amount: 41.62,  currency:'EUR', date:'2026-05-08', category:'groceries', ts: '2026-05-08T18:42:00Z' },
    { id:'j-018', status:'posted',     merchant:'STIB-MIVB',          filename:'mobib-mai.pdf',  amount: 49.00,  currency:'EUR', date:'2026-05-07', category:'transport', ts: '2026-05-07T07:11:00Z' },
    { id:'j-017', status:'posted',     merchant:'Brussels Boulders',  filename:'climb-pass.pdf', amount: 89.00,  currency:'EUR', date:'2026-05-06', category:'sport',     ts: '2026-05-06T20:02:00Z' },
    { id:'j-016', status:'failed',     merchant:'(unreadable)',       filename:'IMG_3344.heic',  amount: null,  currency:null, date:null, category:null, ts: '2026-05-06T11:30:00Z',
      error:'Image too blurry — confidence 0.18' },
    { id:'j-015', status:'posted',     merchant:'Café Belga',         filename:'cafe-belga.pdf', amount: 14.80,  currency:'EUR', date:'2026-05-05', category:'outings',   ts: '2026-05-05T16:20:00Z' },
    { id:'j-014', status:'posted',     merchant:'Spotify',            filename:'inv-spotify.pdf',amount: 11.99,  currency:'EUR', date:'2026-05-05', category:'subs',      ts: '2026-05-05T03:01:00Z' },
    { id:'j-013', status:'posted',     merchant:'Delhaize',           filename:'recu-delhaize.pdf', amount: 67.40, currency:'EUR', date:'2026-05-04', category:'groceries', ts: '2026-05-04T19:11:00Z' },
    { id:'j-012', status:'posted',     merchant:'Salary · Acme NV',   filename:'paystub-04.pdf', amount: 4280.00,currency:'EUR', date:'2026-04-30', category:'income',    ts: '2026-04-30T09:00:00Z' },
    { id:'j-011', status:'posted',     merchant:'Engie · electricity',filename:'engie-apr.pdf',  amount: 96.40,  currency:'EUR', date:'2026-04-28', category:'home',      ts: '2026-04-28T08:40:00Z' },
    { id:'j-010', status:'posted',     merchant:'Decathlon',          filename:'decathlon.pdf',  amount: 128.99, currency:'EUR', date:'2026-04-25', category:'sport',     ts: '2026-04-25T14:15:00Z' },
  ];

  const UPCOMING = [
    { d: 12, m: 'MAY', name: 'Rent · Av. Louise',    sub: 'Recurring · Home', amt: 1180.00 },
    { d: 15, m: 'MAY', name: 'Proximus mobile',       sub: 'Recurring · Subs', amt: 24.99 },
    { d: 21, m: 'MAY', name: 'Climbing membership',   sub: 'Annual · Sport',   amt: 56.00 },
    { d: 28, m: 'MAY', name: 'Spotify family',        sub: 'Recurring · Subs', amt: 17.99 },
    { d:  3, m: 'JUN', name: 'Tax prepayment Q2',     sub: 'Scheduled',         amt: 482.00 },
  ];

  // 26 weeks of net worth, slow upward drift with a couple dips
  const NETWORTH_HISTORY = [
    41200, 41850, 41100, 42400, 43020, 43180, 43900, 43700,
    44320, 44600, 45100, 44800, 45400, 45900, 46300, 46150,
    46700, 47100, 46900, 47350, 47500, 47200, 47600, 47900,
    47720, 47328
  ];

  const SUMMARY = {
    netWorth:    47328.42,
    cash:         8978.42,
    investments:18450.00,
    savings:    19900.00,
    monthIncome:  4280.00,
    monthExpenses: 1914.27,
    monthBudget:   2240.00,
    monthDelta:   +325.73,
    projectionEom: 47640,
  };

  // Sample invoice payloads keyed by id — used when the user uploads a "sample"
  const SAMPLES = [
    {
      filename: 'IMG_8821.jpg',
      merchant_name: 'MEDIAMARKT BRUSSEL CITY 2',
      address: 'Rue Neuve 123, 1000 Brussel',
      invoice_no: 'MM-2410581',
      date_iso: '2026-05-08',
      currency: 'EUR',
      lines: [
        { d: 'Logitech MX Master 3S', q:1, p: 99.00 },
        { d: 'USB-C dock 4-in-1',    q:1, p: 67.50 },
        { d: 'HDMI cable 2m',        q:2, p: 12.95 },
        { d: 'Carrying case M',      q:1, p: 26.60 },
      ],
      subtotal: 218.95, vat_pct: 21, vat: 38.02, total: 219.00,
      conf: { merchant: 0.96, amount: 0.99, date: 0.62, vat: 0.71, invoice_no: 0.42 },
      suggested_category: 'office',
    },
    {
      filename: 'recu-delhaize-9-mai.pdf',
      merchant_name: 'Delhaize Châtelain',
      address: 'Rue du Page 2, 1050 Ixelles',
      invoice_no: '20260509-21-440',
      date_iso: '2026-05-09',
      currency: 'EUR',
      lines: [
        { d: 'Pain au levain 600g',   q:1, p: 4.20 },
        { d: 'Yaourt grec 1kg',       q:1, p: 5.85 },
        { d: 'Tomates grappe',        q:1, p: 3.40 },
        { d: 'Œufs bio x6',           q:2, p: 4.95 },
        { d: 'Vin rouge Chinon',      q:1, p: 14.80 },
        { d: 'Saumon frais 200g',     q:1, p: 8.30 },
      ],
      subtotal: 46.45, vat_pct: 6, vat: 2.79, total: 46.45,
      conf: { merchant: 0.99, amount: 0.97, date: 0.94, vat: 0.81, invoice_no: 0.55 },
      suggested_category: 'groceries',
    },
    {
      filename: 'taxi-receipt.pdf',
      merchant_name: 'Heetch Bruxelles',
      address: 'Trip 8aab21 · driver Karim',
      invoice_no: 'HE-58210',
      date_iso: '2026-05-09',
      currency: 'EUR',
      lines: [
        { d: 'Course Schaerbeek → Ixelles', q:1, p: 18.40 },
        { d: 'Pourboire',                    q:1, p: 2.00 },
      ],
      subtotal: 20.40, vat_pct: 21, vat: 3.54, total: 20.40,
      conf: { merchant: 0.92, amount: 0.96, date: 0.99, vat: 0.4, invoice_no: 0.88 },
      suggested_category: 'transport',
    },
  ];

  return { CATEGORIES, ACTIVITY, UPCOMING, NETWORTH_HISTORY, SUMMARY, SAMPLES };
})();
