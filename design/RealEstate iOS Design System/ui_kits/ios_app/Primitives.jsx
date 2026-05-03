/* global window */
const { useState } = React;

// === Sample data ============================================================
const LISTINGS = [
  {
    id: 'l1', name: '4月26日オープンハウス開催予定!「10..."',
    score: 'B', scoreVal: 52, scoreColor: 'var(--score-b)',
    price: '9,150万', priceColor: 'var(--ios-blue)',
    deviation: null, appreciation: null,
    layout: '3LDK', area: '67.2㎡', age: '築16年', floor: '3階建', floorPos: '1階',
    station: '京王井の頭線「高井戸」徒歩5分',
    mgmt: '管理費1.9万 修繕1.0万', total: '計3.0万/月',
    hazards: [], commute: [{ kind: 'pg', val: 'P 55分' }, { kind: 'm3', val: 'M 55分' }],
    multi: 2,
    units: [
      { layout: '3LDK', area: '67.2㎡', price: '9,150万', floor: '1階/3階建' },
      { layout: '3LDK', area: '67.2㎡', price: '9,150万', floor: '1階/3階建' },
    ],
    expanded: true,
    summary: '駅近・築浅で投資効率良好。同マンションで2戸同時売出中、相場感が掴みやすい。',
    badge: '駅近×築浅', hl: 'acc',
    strengths: ['駅徒歩5分', '管理優良'], risks: ['1階住戸', '3階建てで規模小'],
    altSources: [
      { src: 'SUUMO', price: '9,150万', diff: 0 },
      { src: 'HOME\'S', price: '9,200万', diff: 50 },
    ],
    address: '東京都杉並区高井戸西1丁目',
    type: 'chuko', liked: false,
  },
  {
    id: 'l2', name: 'AQUA VISTA アクアヴィスタ',
    score: 'B', scoreVal: 61, scoreColor: 'var(--score-b)',
    price: '1.0億', priceColor: 'var(--ios-blue)',
    deviation: '61.4', appreciation: '↑78%',
    layout: '3LDK', area: '92.2㎡', age: '築11年', floor: '16階建', floorPos: '7階',
    station: '京成本線「千住大橋」徒歩3分',
    mgmt: '管理費1.3万 修繕1.2万', total: '計2.5万/月',
    hazards: [{ label: '洪水浸水', sev: 'high' }],
    commute: [{ kind: 'pg', val: 'P 51分' }, { kind: 'm3', val: 'M 48分' }],
    multi: 2,
    summary: '築浅×駅2分の好条件。管理良好で長期保有向き。同マンション内で他1戸が売出中。',
    badge: '含み益S', hl: 'pos',
    strengths: ['駅徒歩3分', '築浅', '管理良好'], risks: ['浸水リスク中'],
    altSources: [
      { src: 'SUUMO', price: '1.0億', diff: 0 },
      { src: 'HOME\'S', price: '9,950万', diff: -50 },
      { src: 'リハウス', price: '1.0億', diff: 0 },
    ],
    address: '東京都荒川区南千住8丁目',
    type: 'chuko', liked: true,
  },
  {
    id: 'l3', name: 'KAZAHANA',
    score: 'A', scoreVal: 72, scoreColor: 'var(--score-a)',
    price: '1.1億', priceColor: 'var(--ios-blue)',
    deviation: '54.1', appreciation: null,
    layout: '2LDK+S(納戸)', area: '73.8㎡', age: '築6年', floor: '3階建', floorPos: '1階', extra: '10戸',
    station: '東京メトロ南北線「白金高輪」徒歩7分',
    mgmt: '管理費1.5万 修繕0.9万', total: '計2.4万/月',
    hazards: [],
    commute: [{ kind: 'pg', val: 'P 32分' }, { kind: 'm3', val: 'M 41分' }],
    summary: '低層マンションで希少性高め。管理状態良好、リセール期待値Aクラス。',
    badge: '低層×希少', hl: 'neu',
    type: 'chuko', liked: false,
    address: '東京都港区白金1丁目',
  },
];

// === SVG icon helpers =======================================================
const Icon = ({ name, size = 18, color = 'currentColor', stroke = 2 }) => {
  const paths = {
    'chevron-right': <polyline points="9 6 15 12 9 18" />,
    'sparkles': <><path d="M12 2l1.5 4.5L18 8l-4.5 1.5L12 14l-1.5-4.5L6 8l4.5-1.5L12 2z" /><path d="M5 16l.7 2L8 18.7 5.7 19.4 5 22l-.7-2L2 19.4 4.3 18.7 5 16z" /><path d="M19 14l.7 2L22 16.7 19.7 17.4 19 20l-.7-2L16 17.4 18.3 16.7 19 14z" /></>,
    'heart': <path d="M20.84 4.61a5.5 5.5 0 0 0-7.78 0L12 5.67l-1.06-1.06a5.5 5.5 0 1 0-7.78 7.78L12 21.23l8.84-8.84a5.5 5.5 0 0 0 0-7.78z" />,
    'search': <><circle cx="11" cy="11" r="8" /><line x1="21" y1="21" x2="16.65" y2="16.65" /></>,
    'sliders': <><line x1="4" y1="6" x2="20" y2="6" /><line x1="4" y1="12" x2="20" y2="12" /><line x1="4" y1="18" x2="20" y2="18" /><circle cx="9" cy="6" r="2" /><circle cx="15" cy="12" r="2" /><circle cx="7" cy="18" r="2" /></>,
    'sort': <><path d="M3 6h18" /><path d="M6 12h12" /><path d="M9 18h6" /></>,
    'chart-bar': <><line x1="12" y1="20" x2="12" y2="10" /><line x1="18" y1="20" x2="18" y2="4" /><line x1="6" y1="20" x2="6" y2="16" /></>,
    'chart-pie': <><path d="M21 12a9 9 0 1 1-9-9" /><path d="M21 12A9 9 0 0 0 12 3v9z" /></>,
    'arrow-up-down': <><path d="M7 17V3M7 3l-4 4M7 3l4 4" /><path d="M17 7v14M17 21l-4-4M17 21l4-4" /></>,
    'building-2': <><path d="M6 22V4a2 2 0 0 1 2-2h8a2 2 0 0 1 2 2v18Z" /><path d="M6 12H4a2 2 0 0 0-2 2v8h4" /><path d="M18 9h2a2 2 0 0 1 2 2v11h-4" /></>,
    'triangle-alert': <><path d="M10.29 3.86 1.82 18a2 2 0 0 0 1.71 3h16.94a2 2 0 0 0 1.71-3L13.71 3.86a2 2 0 0 0-3.42 0Z" /><line x1="12" y1="9" x2="12" y2="13" /><line x1="12" y1="17" x2="12.01" y2="17" /></>,
    'x': <><line x1="18" y1="6" x2="6" y2="18" /><line x1="6" y1="6" x2="18" y2="18" /></>,
    'external-link': <><path d="M18 13v6a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2V8a2 2 0 0 1 2-2h6" /><polyline points="15 3 21 3 21 9" /><line x1="10" y1="14" x2="21" y2="3" /></>,
    'link-2': <><path d="M9 17H7A5 5 0 0 1 7 7h2" /><path d="M15 7h2a5 5 0 1 1 0 10h-2" /><line x1="8" y1="12" x2="16" y2="12" /></>,
    'home': <><path d="M3 9.5L12 3l9 6.5V21a1 1 0 0 1-1 1h-5v-7H9v7H4a1 1 0 0 1-1-1z" /></>,
    'map': <><polygon points="3 6 9 3 15 6 21 3 21 18 15 21 9 18 3 21" /><line x1="9" y1="3" x2="9" y2="18" /><line x1="15" y1="6" x2="15" y2="21" /></>,
    'more': <><circle cx="5" cy="12" r="1.5"/><circle cx="12" cy="12" r="1.5"/><circle cx="19" cy="12" r="1.5"/></>,
    'check-circle': <><path d="M22 11.08V12a10 10 0 1 1-5.93-9.14" /><polyline points="22 4 12 14.01 9 11.01" /></>,
    'arrow-up-right': <><line x1="7" y1="17" x2="17" y2="7"/><polyline points="7 7 17 7 17 17"/></>,
  }[name];
  return (
    <svg width={size} height={size} viewBox="0 0 24 24" fill="none" stroke={color} strokeWidth={stroke} strokeLinecap="round" strokeLinejoin="round">
      {paths}
    </svg>
  );
};

const SparkIcon = ({ size = 12 }) => (
  <svg width={size} height={size} viewBox="0 0 24 24" fill="currentColor"><path d="M12 2l1.5 4.5L18 8l-4.5 1.5L12 14l-1.5-4.5L6 8l4.5-1.5L12 2z"/></svg>
);

const AIIndicator = () => (
  <span className="ai-ind"><SparkIcon size={9} />AI</span>
);

const HighlightBadge = ({ text, style = 'acc' }) => (
  <span className={`hl hl-${style}`}>{text}</span>
);

const ScoreBadge = ({ grade, value, abs = false }) => {
  const colorMap = { S: 'var(--score-s)', A: 'var(--score-a)', B: 'var(--score-b)', C: 'var(--score-c)', D: 'var(--score-d)' };
  const cls = abs ? 'score-badge' : 'pill';
  const style = { background: colorMap[grade], color: '#fff' };
  return <span className={cls} style={{ ...style, padding: '2px 7px', borderRadius: 6, font: 'var(--t-score-badge)' }}>{grade} {value}</span>;
};

Object.assign(window, { Icon, SparkIcon, AIIndicator, HighlightBadge, ScoreBadge, LISTINGS });
