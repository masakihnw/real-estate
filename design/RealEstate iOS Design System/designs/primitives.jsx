/* global window */
const { useState, useMemo } = React;

// Reusable icon set
const Icon = ({ name, size = 18, color = 'currentColor', stroke = 2, fill = 'none' }) => {
  const paths = {
    'chevron-right': <polyline points="9 6 15 12 9 18" />,
    'chevron-left': <polyline points="15 6 9 12 15 18" />,
    'chevron-down': <polyline points="6 9 12 15 18 9" />,
    'sparkles': <path d="M12 2l1.5 4.5L18 8l-4.5 1.5L12 14l-1.5-4.5L6 8l4.5-1.5L12 2z" />,
    'heart': <path d="M20.84 4.61a5.5 5.5 0 0 0-7.78 0L12 5.67l-1.06-1.06a5.5 5.5 0 1 0-7.78 7.78L12 21.23l8.84-8.84a5.5 5.5 0 0 0 0-7.78z" />,
    'search': <><circle cx="11" cy="11" r="8" /><line x1="21" y1="21" x2="16.65" y2="16.65" /></>,
    'sliders': <><line x1="4" y1="6" x2="20" y2="6" /><line x1="4" y1="12" x2="20" y2="12" /><line x1="4" y1="18" x2="20" y2="18" /><circle cx="9" cy="6" r="2" /><circle cx="15" cy="12" r="2" /><circle cx="7" cy="18" r="2" /></>,
    'sort': <><path d="M3 6h13M3 12h9M3 18h5" /><path d="M17 4v16M21 16l-4 4-4-4" /></>,
    'chart-bar': <><line x1="12" y1="20" x2="12" y2="10" /><line x1="18" y1="20" x2="18" y2="4" /><line x1="6" y1="20" x2="6" y2="16" /></>,
    'chart-pie': <><path d="M21 12a9 9 0 1 1-9-9" /><path d="M21 12A9 9 0 0 0 12 3v9z" /></>,
    'arrow-up-down': <><path d="M7 17V3M7 3l-4 4M7 3l4 4" /><path d="M17 7v14M17 21l-4-4M17 21l4-4" /></>,
    'building': <><path d="M6 22V4a2 2 0 0 1 2-2h8a2 2 0 0 1 2 2v18Z" /><path d="M10 6h4M10 10h4M10 14h4M10 18h4" /></>,
    'triangle-alert': <><path d="M10.29 3.86 1.82 18a2 2 0 0 0 1.71 3h16.94a2 2 0 0 0 1.71-3L13.71 3.86a2 2 0 0 0-3.42 0Z" /><line x1="12" y1="9" x2="12" y2="13" /><line x1="12" y1="17" x2="12.01" y2="17" /></>,
    'x': <><line x1="18" y1="6" x2="6" y2="18" /><line x1="6" y1="6" x2="18" y2="18" /></>,
    'external': <><path d="M18 13v6a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2V8a2 2 0 0 1 2-2h6" /><polyline points="15 3 21 3 21 9" /><line x1="10" y1="14" x2="21" y2="3" /></>,
    'link': <><path d="M9 17H7A5 5 0 0 1 7 7h2" /><path d="M15 7h2a5 5 0 1 1 0 10h-2" /><line x1="8" y1="12" x2="16" y2="12" /></>,
    'home': <><path d="M3 9.5L12 3l9 6.5V21a1 1 0 0 1-1 1h-5v-7H9v7H4a1 1 0 0 1-1-1z" /></>,
    'map-pin': <><path d="M21 10c0 7-9 13-9 13s-9-6-9-13a9 9 0 0 1 18 0z" /><circle cx="12" cy="10" r="3" /></>,
    'walk': <><circle cx="13" cy="4" r="2" /><path d="M9 20l3-6 2 1 3 5" /><path d="M6 9l3-1 4 4-2 2-2-1" /></>,
    'check': <polyline points="20 6 9 17 4 12" />,
    'copy': <><rect x="9" y="9" width="13" height="13" rx="2" /><path d="M5 15H4a2 2 0 0 1-2-2V4a2 2 0 0 1 2-2h9a2 2 0 0 1 2 2v1" /></>,
    'plus': <><line x1="12" y1="5" x2="12" y2="19" /><line x1="5" y1="12" x2="19" y2="12" /></>,
    'minus': <line x1="5" y1="12" x2="19" y2="12" />,
    'arrow-right': <><line x1="5" y1="12" x2="19" y2="12" /><polyline points="12 5 19 12 12 19" /></>,
    'train': <><rect x="4" y="3" width="16" height="16" rx="2" /><path d="M4 11h16M8 15h.01M16 15h.01" /><path d="M8 19l-2 3M16 19l2 3" /></>,
    'calculator': <><rect x="4" y="2" width="16" height="20" rx="2" /><line x1="8" y1="6" x2="16" y2="6" /><circle cx="8" cy="12" r=".5" fill="currentColor" /><circle cx="12" cy="12" r=".5" fill="currentColor" /><circle cx="16" cy="12" r=".5" fill="currentColor" /><circle cx="8" cy="16" r=".5" fill="currentColor" /><circle cx="12" cy="16" r=".5" fill="currentColor" /></>,
    'message': <path d="M21 15a2 2 0 0 1-2 2H7l-4 4V5a2 2 0 0 1 2-2h14a2 2 0 0 1 2 2z" />,
    'image': <><rect x="3" y="3" width="18" height="18" rx="2" /><circle cx="8.5" cy="8.5" r="1.5" /><polyline points="21 15 16 10 5 21" /></>,
    'trending-up': <><polyline points="22 7 13.5 15.5 8.5 10.5 2 17" /><polyline points="16 7 22 7 22 13" /></>,
    'trending-down': <><polyline points="22 17 13.5 8.5 8.5 13.5 2 7" /><polyline points="16 17 22 17 22 11" /></>,
    'eye': <><path d="M1 12s4-8 11-8 11 8 11 8-4 8-11 8-11-8-11-8z" /><circle cx="12" cy="12" r="3" /></>,
    'more': <><circle cx="5" cy="12" r="1.5" fill="currentColor" /><circle cx="12" cy="12" r="1.5" fill="currentColor" /><circle cx="19" cy="12" r="1.5" fill="currentColor" /></>,
    'arrow-down': <><line x1="12" y1="5" x2="12" y2="19" /><polyline points="19 12 12 19 5 12" /></>,
    'arrow-up': <><line x1="12" y1="19" x2="12" y2="5" /><polyline points="5 12 12 5 19 12" /></>,
    'compass': <><circle cx="12" cy="12" r="10" /><polygon points="16.24 7.76 14.12 14.12 7.76 16.24 9.88 9.88 16.24 7.76" /></>,
    'shield': <path d="M12 22s8-4 8-10V5l-8-3-8 3v7c0 6 8 10 8 10z" />,
    'users': <><path d="M17 21v-2a4 4 0 0 0-4-4H5a4 4 0 0 0-4 4v2" /><circle cx="9" cy="7" r="4" /><path d="M23 21v-2a4 4 0 0 0-3-3.87" /><path d="M16 3.13a4 4 0 0 1 0 7.75" /></>,
  }[name];
  return (
    <svg width={size} height={size} viewBox="0 0 24 24" fill={fill} stroke={color} strokeWidth={stroke} strokeLinecap="round" strokeLinejoin="round">
      {paths}
    </svg>
  );
};

const Spark = ({ size = 11 }) => (
  <svg width={size} height={size} viewBox="0 0 24 24" fill="currentColor"><path d="M12 2l1.5 4.5L18 8l-4.5 1.5L12 14l-1.5-4.5L6 8l4.5-1.5L12 2z" /></svg>
);

const AIInd = () => (
  <span className="ai-ind"><Spark size={9} /> AI</span>
);

const ScoreBadge = ({ grade, value }) => (
  <span className={`score-badge ${grade.toLowerCase()}`} style={{ background: SCORE_COLORS[grade] }}>
    {grade} {value}
  </span>
);

const HazardChip = ({ label, sev }) => (
  <span className={`haz-chip ${sev}`}>
    <Icon name="triangle-alert" size={9} />
    {label}
  </span>
);

const Hl = ({ text, style = 'acc' }) => <span className={`hl hl-${style}`}>{text}</span>;

// Format helpers
const fmtPriceDelta = (n) => `${n > 0 ? '+' : ''}${n}万${n < 0 ? '↓' : '↑'}`;
const fmtMonthly = (n, exact) => `月々 約${n.toFixed(1)}万円${exact ? '' : '〜'}`;

Object.assign(window, { Icon, Spark, AIInd, ScoreBadge, HazardChip, Hl, fmtPriceDelta, fmtMonthly });
