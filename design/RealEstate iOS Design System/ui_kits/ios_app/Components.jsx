/* global window */

const ListingCard = ({ l, onClick }) => {
  const scoreColors = { S: 'var(--score-s)', A: 'var(--score-a)', B: 'var(--score-b)', C: 'var(--score-c)', D: 'var(--score-d)' };
  return (
    <div className="listing" onClick={onClick}>
      <div className="thumb">
        <div className="score-badge" style={{ background: scoreColors[l.score] }}>
          {l.score} {l.scoreVal}
        </div>
      </div>
      <div>
        <div className="header">
          <div className="name">{l.name}</div>
          <Icon name="heart" size={18} color={l.liked ? 'var(--ios-red)' : 'var(--fg-tertiary)'} stroke={l.liked ? 0 : 2} />
        </div>
        <div className="meta">
          <span className={`price ${l.type === 'shinchiku' ? 'shinchiku' : ''}`}>{l.price}</span>
          {l.deviation && <span className="dev">↓ {l.deviation}</span>}
          {l.appreciation && <span className="pct-up">{l.appreciation}</span>}
        </div>
        <div className="info">{l.layout} · {l.area} · {l.age} · {l.floor}{l.floorPos ? ` ${l.floorPos}` : ''}{l.extra ? ` · ${l.extra}` : ''}</div>
        <div className="station">📍 {l.station}</div>
        <div className="cost">{l.mgmt} <b>{l.total}</b></div>
        <div className="badges">
          {l.hazards?.map((h, i) => (
            <span key={i} className="haz"><Icon name="triangle-alert" size={10} /> {h.label}</span>
          ))}
          {l.commute?.map((c, i) => (
            <span key={i} className={`commute ${c.kind}`}>{c.val}</span>
          ))}
        </div>
        {l.multi && (
          <div className="multi-row">
            <span>🏢 同マンション内 {l.multi}戸</span>
            <Icon name="chevron-right" size={14} />
          </div>
        )}
      </div>
    </div>
  );
};

const StatCard = ({ label, value, sub, accent, hasChev }) => (
  <div className={`stat ${hasChev ? 'tap' : ''}`}>
    <div>
      <div className="lbl">{label}</div>
      <div className="val" style={{ color: accent }}>{value}</div>
      {sub && <div className="sub">{sub}</div>}
    </div>
    {hasChev && <span className="chev">›</span>}
  </div>
);

const ScoreDistribution = () => {
  const data = [
    { g: 'S', ct: 1, color: 'var(--score-s)' },
    { g: 'A', ct: 4, color: 'var(--score-a)' },
    { g: 'B', ct: 12, color: 'var(--score-b)' },
    { g: 'C', ct: 8, color: 'var(--score-c)' },
    { g: 'D', ct: 3, color: 'var(--score-d)' },
  ];
  const max = Math.max(...data.map(d => d.ct));
  return (
    <div className="score-dist">
      <div style={{ font: 'var(--t-headline)', marginBottom: 12, display: 'flex', alignItems: 'center', gap: 6 }}>
        <Icon name="chart-bar" size={16} color="var(--ios-blue)" /> スコア分布
      </div>
      <div className="score-bars">
        {data.map(d => (
          <div className="score-col" key={d.g}>
            <div className="gl" style={{ color: d.color }}>{d.g}</div>
            <div className="bar" style={{ background: d.color, height: `${(d.ct/max)*60+8}px` }} />
            <div className="ct">{d.ct}件</div>
          </div>
        ))}
      </div>
    </div>
  );
};

const AIInsightCard = () => (
  <div className="ai-card">
    <div className="row">
      <h4><SparkIcon size={14}/> AI Insights</h4>
      <span className="hl hl-acc">Top 3</span>
    </div>
    <div style={{ font: 'var(--t-footnote)', color: 'var(--fg-secondary)', lineHeight: 1.45 }}>
      本日の注目物件: 駅近×築浅で含み益が見込める3件をピックアップしました。AQUA VISTAは管理状態が特に良好です。
    </div>
    <div style={{ display: 'flex', gap: 6, marginTop: 8, flexWrap: 'wrap' }}>
      <HighlightBadge text="含み益S" style="pos" />
      <HighlightBadge text="駅近" style="acc" />
      <HighlightBadge text="管理良好" style="neu" />
    </div>
  </div>
);

const DedupAlert = ({ count = 3 }) => (
  <div className="dedup">
    <div className="h">
      <Icon name="link-2" size={14} /> 重複候補 {count}件
      <AIIndicator />
    </div>
    <div className="cand">
      <div>
        <div className="nm">AQUA VISTA · 7階</div>
        <div className="meta">SUUMO / HOME'S / リハウス · 確信度 92%</div>
      </div>
      <Icon name="chevron-right" size={14} color="var(--fg-tertiary)" />
    </div>
    <div className="cand">
      <div>
        <div className="nm">高井戸西1丁目戸建</div>
        <div className="meta">SUUMO / アットホーム · 確信度 84%</div>
      </div>
      <Icon name="chevron-right" size={14} color="var(--fg-tertiary)" />
    </div>
  </div>
);

const TabBar = ({ active, onChange }) => {
  const tabs = [
    { k: 'dash', label: 'ダッシュボード', icon: 'home' },
    { k: 'chuko', label: '中古', icon: 'building-2' },
    { k: 'shin', label: '新築', icon: 'building-2' },
    { k: 'fav', label: 'お気に入り', icon: 'heart' },
    { k: 'set', label: '設定', icon: 'sliders' },
  ];
  return (
    <div className="tabbar">
      {tabs.map(t => (
        <button key={t.k} className={`tab ${active === t.k ? 'on' : ''}`} onClick={() => onChange(t.k)}>
          <span className="tab-ic-wrap"><Icon name={t.icon} size={20} /></span>
          {t.label}
        </button>
      ))}
    </div>
  );
};

const Search = ({ placeholder = '物件名・エリアで検索' }) => (
  <div className="search">
    <Icon name="search" size={16} /> {placeholder}
  </div>
);

const Segmented = ({ items, active, onChange }) => (
  <div className="seg">
    {items.map(i => (
      <button key={i.k} className={active === i.k ? 'on' : ''} onClick={() => onChange(i.k)}>{i.label}</button>
    ))}
  </div>
);

const NavBar = ({ title, lg, right }) => (
  <div className="navbar">
    <div className={lg ? 'lg' : ''} style={{ font: lg ? 'var(--t-title1)' : 'var(--t-headline)', flex: 1, minWidth: 0, overflow: 'hidden', textOverflow: 'ellipsis', whiteSpace: 'nowrap' }}>{title}</div>
    {right}
  </div>
);

Object.assign(window, { ListingCard, StatCard, ScoreDistribution, AIInsightCard, DedupAlert, TabBar, Search, Segmented, NavBar });
