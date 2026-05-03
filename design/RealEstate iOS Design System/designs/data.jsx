/* global window */

// === Monthly payment calculator =============================================
// 条件: 金利1.2% / 50年 / 頭金0 / 元利均等返済 / 諸費用込み
// 借入額 = 物件価格 × 1.065（購入諸費用6.5%を含む）
// 月々 = ローン返済額 + 管理費 + 修繕積立金 + 地代（将来対応）
const LOAN_RATE = 0.012;            // 年利1.2%
const LOAN_YEARS = 50;
const LOAN_FEE_MULT = 1.065;        // 諸費用6.5%込み
const DEFAULT_MGMT = 1.82;          // 万円/月（既定）
const DEFAULT_REPAIR = 1.30;        // 万円/月（既定）

// price: 万円, mgmt/repair/land: 万円/月 → returns 万円/月 breakdown
function calcMonthly(price, opts = {}) {
  const mgmt = opts.mgmt ?? DEFAULT_MGMT;
  const repair = opts.repair ?? DEFAULT_REPAIR;
  const land = opts.land ?? 0;
  const r = LOAN_RATE / 12;
  const n = LOAN_YEARS * 12;
  const P = price * LOAN_FEE_MULT;
  const loan = P * r * Math.pow(1 + r, n) / (Math.pow(1 + r, n) - 1);
  const total = loan + mgmt + repair + land;
  return { loan, mgmt, repair, land, total, principal: P };
}

// Round to one decimal (万円)
const r1 = (v) => Math.round(v * 10) / 10;

// Sample listings — covers all states from the spec
const SPEC_LISTINGS = [
  {
    id: 'l1',
    name: 'パークコート恵比寿ヒルトップレジデンス',
    score: 'S', scoreVal: 86,
    price: 6980, priceLabel: '¥6,980万', priceDelta: -300,
    monthly: r1(calcMonthly(6980).total), monthlyExact: true,
    layout: '2LDK', area: '58.4㎡', walk: 2, age: 5,
    station: 'JR山手線「恵比寿」',
    badge: '駅2分×築浅', badgeStyle: 'acc',
    summary: '駅2分の築浅タワマン。資産性◎ 10年後も価値維持。同マンション内に他2戸が売出中で相場が掴みやすい。',
    strengths: ['駅徒歩2分', '築5年', '高層階', '南向き'],
    risks: ['修繕積立金上昇傾向'],
    hazards: [{ label: '浸水0.5m', sev: 'low' }, { label: '震度5弱', sev: 'low' }],
    altCount: 2,
    multi: { count: 3, units: [
      { layout: '2LDK', area: '58.4㎡', floor: '15階', price: '6,980万', monthly: `${r1(calcMonthly(6980).total)}万` },
      { layout: '3LDK', area: '72.8㎡', floor: '22階', price: '8,950万', monthly: `${r1(calcMonthly(8950).total)}万` },
      { layout: '1LDK', area: '42.1㎡', floor: '8階', price: '5,200万', monthly: `${r1(calcMonthly(5200).total)}万` },
    ] },
    address: '東京都渋谷区恵比寿2丁目',
    type: 'chuko', liked: true,
    altSources: [
      { src: 'rehouse', label: 'リハウス', price: '6,980万', diff: 0, isThis: true },
      { src: 'suumo', label: 'SUUMO', price: '6,980万', diff: 0 },
      { src: 'homes', label: "HOME'S", price: '6,950万', diff: -30, cheapest: true },
    ],
  },
  {
    id: 'l2',
    name: 'AQUA VISTA アクアヴィスタ',
    score: 'A', scoreVal: 74,
    price: 10200, priceLabel: '¥1.02億', priceDelta: -50,
    monthly: r1(calcMonthly(10200).total), monthlyExact: true,
    layout: '3LDK', area: '92.2㎡', walk: 3, age: 11,
    station: '京成本線「千住大橋」',
    badge: '管理良好', badgeStyle: 'pos',
    summary: '築浅×駅3分の好立地。管理状態が特に良好で、長期保有に向く。',
    strengths: ['駅徒歩3分', '管理良好', '広めの3LDK'],
    risks: ['浸水注意', '築11年'],
    hazards: [{ label: '浸水2.0m', sev: 'mid' }],
    altCount: 3,
    address: '東京都荒川区南千住8丁目',
    type: 'chuko', liked: true,
  },
  {
    id: 'l3',
    name: 'KAZAHANA 風花レジデンス',
    score: 'A', scoreVal: 71,
    price: 11000, priceLabel: '¥1.1億', priceDelta: 100,
    monthly: r1(calcMonthly(11000).total), monthlyExact: false,
    layout: '2LDK+S', area: '73.8㎡', walk: 7, age: 6,
    station: '東京メトロ南北線「白金高輪」',
    badge: '低層×希少', badgeStyle: 'neu',
    summary: '低層マンションで希少性高め。リセール期待値Aクラス。',
    strengths: ['築浅', '希少な低層', '都心'],
    risks: ['駅徒歩やや遠い'],
    hazards: [],
    address: '東京都港区白金1丁目',
    type: 'chuko', liked: false,
  },
  {
    id: 'l4',
    name: 'プラウドタワー目黒MARC',
    score: 'B', scoreVal: 65,
    price: 8500, priceLabel: '¥8,500万',
    monthly: r1(calcMonthly(8500).total), monthlyExact: true,
    layout: '1LDK', area: '45.2㎡', walk: 5, age: 8,
    station: 'JR山手線「目黒」',
    badge: null,
    summary: null,
    hazards: [{ label: '震度6弱', sev: 'mid' }],
    address: '東京都品川区上大崎3丁目',
    type: 'chuko', liked: false,
  },
  {
    id: 'l5',
    name: '中野坂上シティハウス',
    score: 'C', scoreVal: 54,
    price: 7200, priceLabel: '¥7,200万', priceDelta: -120,
    monthly: r1(calcMonthly(7200).total), monthlyExact: true,
    layout: '2LDK', area: '55.0㎡', walk: 4, age: 14,
    station: '東京メトロ丸ノ内線「中野坂上」',
    hazards: [],
    address: '東京都中野区本町2丁目',
    type: 'chuko', liked: false,
  },
];

// Color helpers
const SCORE_COLORS = { S: '#FFB300', A: 'var(--ios-blue)', B: 'var(--positive)', C: 'var(--ios-gray)', D: 'var(--negative)' };
const HAZARD_COLORS = { high: 'var(--negative)', mid: 'var(--ios-orange)', low: 'var(--ios-yellow)' };
const SOURCE_COLORS = {
  suumo: '#76C049', homes: '#FF6B35', rehouse: '#003DA5',
  nomucom: '#E60012', athome: '#00A4E4', stepon: '#006633', livable: '#DC000C',
};

Object.assign(window, {
  SPEC_LISTINGS, SCORE_COLORS, HAZARD_COLORS, SOURCE_COLORS,
  calcMonthly, LOAN_RATE, LOAN_YEARS, LOAN_FEE_MULT, DEFAULT_MGMT, DEFAULT_REPAIR, r1,
});
