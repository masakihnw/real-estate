/* global window */
const { useState: useS_card } = React;

// === Listing Card (compact, collapsible AI summary) =========================
const ListingCard = ({ l, onClick }) => {
  const [expanded, setExpanded] = useS_card(false);
  const [aiOpen, setAiOpen] = useS_card(false);
  const isDelta = l.priceDelta !== undefined && l.priceDelta !== 0;
  const deltaDir = l.priceDelta < 0 ? 'down' : 'up';
  const showSummary = l.summary && ['S', 'A', 'B'].includes(l.score);

  return (
    <div className="listing" onClick={onClick}>
      <div className="thumb">
        {l.multi && <div className="multi-badge">他{l.multi.count - 1}</div>}
      </div>

      <div style={{ minWidth: 0 }}>
        <div className="head">
          <div className="name">{l.name}</div>
          <ScoreBadge grade={l.score} value={l.scoreVal} />
          <button className="like" onClick={(e) => { e.stopPropagation(); }} aria-label="like">
            <Icon name="heart" size={16} color={l.liked ? 'var(--ios-red)' : 'var(--fg-tertiary)'} fill={l.liked ? 'var(--ios-red)' : 'none'} stroke={l.liked ? 0 : 2} />
          </button>
        </div>

        {l.badge && (
          <div className="badge-row">
            <Hl text={l.badge} style={l.badgeStyle || 'acc'} />
          </div>
        )}

        <div className="price-row">
          <span className="price">{l.priceLabel}</span>
          {isDelta && (
            <span className={`price-delta ${deltaDir}`}>
              {l.priceDelta > 0 ? '+' : ''}{l.priceDelta}万{l.priceDelta < 0 ? '↓' : '↑'}
            </span>
          )}
          <span className="monthly"><b>月々 約{l.monthly.toFixed(1)}万{l.monthlyExact ? '' : '〜'}</b></span>
        </div>

        <div className="specs">
          <span>{l.layout}</span><span className="sep">·</span>
          <span>{l.area}</span><span className="sep">·</span>
          <span style={{ display: 'inline-flex', alignItems: 'center', gap: 2 }}>
            <Icon name="walk" size={11} /> {l.walk}分
          </span>
          <span className="sep">·</span>
          <span>築{l.age}年</span>
          {l.hazards?.slice(0, 2).map((h, i) => (
            <React.Fragment key={i}><span className="sep">·</span><HazardChip label={h.label} sev={h.sev} /></React.Fragment>
          ))}
        </div>
      </div>

      {showSummary && (
        <button
          className={`summary-toggle ${aiOpen ? 'open' : ''}`}
          onClick={(e) => { e.stopPropagation(); setAiOpen(!aiOpen); }}
        >
          <Spark size={11} color="var(--ai-accent)" />
          <span>AI評価</span>
          <span style={{ color: 'var(--fg-tertiary)', fontWeight: 400, marginLeft: 4 }}>
            {aiOpen ? '閉じる' : 'タップで表示'}
          </span>
          <Icon className="chev" name="chevron-down" size={12} stroke={2.5} color="var(--ai-accent)" />
        </button>
      )}

      {showSummary && aiOpen && (
        <div className="summary" onClick={(e) => e.stopPropagation()}>
          {l.summary}
        </div>
      )}

      {l.multi && (
        <>
          <button
            className="footer-row"
            onClick={(e) => { e.stopPropagation(); setExpanded(!expanded); }}
            style={{
              gridColumn: '1 / -1', marginTop: 6, padding: '8px 0 0',
              borderTop: '1px solid var(--separator)',
              fontSize: 12, color: 'var(--ios-blue)',
              display: 'flex', justifyContent: 'space-between', alignItems: 'center',
              cursor: 'pointer',
            }}
          >
            <span style={{ display: 'inline-flex', alignItems: 'center', gap: 4 }}>
              <Icon name="building" size={12} /> 同マンションで{l.multi.count}戸売出中
            </span>
            <Icon name="chevron-down" size={14} stroke={2.5} color="var(--ios-blue)" />
          </button>
          {expanded && (
            <div className="multi-units" style={{ gridColumn: '1 / -1' }}>
              {l.multi.units.map((u, i) => (
                <div key={i} className="multi-row">
                  <span>{u.layout}</span>
                  <span>{u.area}</span>
                  <span className="floor">{u.floor}</span>
                  <span className="month">{u.monthly}</span>
                  <span className="price">{u.price}</span>
                </div>
              ))}
            </div>
          )}
        </>
      )}
    </div>
  );
};

// === Top tab bar (中古/新築/お気に入り) =====================================
const TopTabs = ({ active, onChange, counts }) => {
  const tabs = [
    { k: 'chuko', label: '中古', n: counts.chuko },
    { k: 'shin', label: '新築', n: counts.shin },
    { k: 'fav', label: 'お気に入り', n: counts.fav },
  ];
  return (
    <div className="tab-bar-top">
      {tabs.map(t => (
        <button key={t.k} className={active === t.k ? 'on' : ''} onClick={() => onChange(t.k)}>
          {t.label}<span className="ct">{t.n}</span>
        </button>
      ))}
    </div>
  );
};

// === Bottom tab bar =========================================================
const BottomBar = ({ active, onChange }) => {
  const tabs = [
    { k: 'dash', label: 'ホーム', icon: 'home' },
    { k: 'chuko', label: '中古', icon: 'building' },
    { k: 'shin', label: '新築', icon: 'building' },
    { k: 'fav', label: 'お気に入り', icon: 'heart' },
    { k: 'set', label: '設定', icon: 'sliders' },
  ];
  return (
    <div className="tabbar">
      {tabs.map(t => (
        <button key={t.k} className={`tab ${active === t.k ? 'on' : ''}`} onClick={() => onChange(t.k)}>
          <Icon name={t.icon} size={22} stroke={active === t.k ? 2.2 : 1.8} fill={t.k === 'fav' && active === t.k ? 'var(--ios-blue)' : 'none'} />
          <span>{t.label}</span>
        </button>
      ))}
    </div>
  );
};

// === Sort sheet =============================================================
const SortSheet = ({ value, onPick, onClose }) => {
  const groups = [
    { name: '基本', items: [
      ['addedDesc', '追加日（新しい順）'],
      ['priceAsc', '価格（安い順）'],
      ['priceDesc', '価格（高い順）'],
      ['monthlyAsc', '月額支払い（安い順）'],
      ['walkAsc', '駅徒歩（近い順）'],
      ['areaDesc', '面積（広い順）'],
      ['ageAsc', '築年数（浅い順）'],
    ]},
    { name: 'おすすめ度・資産性', items: [
      ['scoreDesc', 'おすすめ度（高い順）'],
      ['fairnessDesc', '価格妥当性（高い順）'],
      ['liquidityDesc', '売りやすさ（高い順）'],
      ['profitDesc', '住み替え時の手残り（多い順）'],
      ['deviationDesc', '偏差値（高い順）'],
      ['appreciationDesc', '値上がり率（高い順）'],
    ]},
    { name: '維持費', items: [
      ['mgmtAsc', '管理費（安い順）'],
      ['repairAsc', '修繕積立金（安い順）'],
      ['runAsc', '月額維持費（安い順）'],
      ['tsuboAsc', '坪単価（安い順）'],
    ]},
  ];
  return (
    <div className="sort-sheet" onClick={(e) => e.stopPropagation()}>
      {groups.map((g, gi) => (
        <React.Fragment key={gi}>
          <div className="grp">{g.name}</div>
          {g.items.map(([k, lbl]) => (
            <button key={k} className={k === value ? 'on' : ''} onClick={() => { onPick(k); onClose(); }}>
              {k === value && <Icon name="check" size={14} stroke={2.5} />}
              <span style={{ marginLeft: k === value ? 0 : 22 }}>{lbl}</span>
            </button>
          ))}
        </React.Fragment>
      ))}
    </div>
  );
};

// === Filter sheet ===========================================================
const FilterSheet = ({ onClose, state, setState }) => {
  const toggle = (k, v) => {
    setState(s => {
      const cur = s[k] || [];
      return { ...s, [k]: cur.includes(v) ? cur.filter(x => x !== v) : [...cur, v] };
    });
  };
  const isOn = (k, v) => (state[k] || []).includes(v);
  const total = Object.values(state).reduce((acc, arr) => acc + (Array.isArray(arr) ? arr.length : 0), 0);

  return (
    <div className="filter-sheet">
      <div className="head">
        <button onClick={onClose} style={{ color: 'var(--ios-blue)', font: 'var(--t-callout)' }}>キャンセル</button>
        <h2>絞り込み {total > 0 && <span style={{ color: 'var(--ios-blue)' }}>({total})</span>}</h2>
        <button onClick={() => setState({})} style={{ color: 'var(--ios-blue)', font: 'var(--t-callout)' }}>クリア</button>
      </div>
      <div className="body">
        <div className="flt-section">
          <h3>価格帯 <span className="count">{(state.price || []).length}</span></h3>
          <div className="chips">
            {['〜5,000万', '〜7,000万', '〜9,000万', '〜1.2億', '〜1.5億', '1.5億+'].map(v => (
              <button key={v} className={`chip ${isOn('price', v) ? 'on' : ''}`} onClick={() => toggle('price', v)}>{v}</button>
            ))}
          </div>
        </div>

        <div className="flt-section">
          <h3>月額支払額 <span className="count">{(state.monthly || []).length}</span></h3>
          <div className="chips">
            {['〜15万', '〜20万', '〜25万', '〜30万', '〜40万', '40万+'].map(v => (
              <button key={v} className={`chip ${isOn('monthly', v) ? 'on' : ''}`} onClick={() => toggle('monthly', v)}>{v}</button>
            ))}
          </div>
          <div style={{ font: 'var(--t-caption)', color: 'var(--fg-tertiary)', marginTop: 6 }}>金利1.2% / 50年 / 頭金0で算出</div>
        </div>

        <div className="flt-section">
          <h3>間取り <span className="count">{(state.layout || []).length}</span></h3>
          <div className="chips">
            {['1K','1LDK','2LDK','3LDK','4LDK+'].map(v => (
              <button key={v} className={`chip ${isOn('layout', v) ? 'on' : ''}`} onClick={() => toggle('layout', v)}>{v}</button>
            ))}
          </div>
        </div>

        <div className="flt-section">
          <h3>駅徒歩 <span className="count">{(state.walk || []).length}</span></h3>
          <div className="chips">
            {['3分以内','5分以内','7分以内','10分以内','15分以内'].map(v => (
              <button key={v} className={`chip ${isOn('walk', v) ? 'on' : ''}`} onClick={() => toggle('walk', v)}>{v}</button>
            ))}
          </div>
        </div>

        <div className="flt-section">
          <h3>広さ <span className="count">{(state.area || []).length}</span></h3>
          <div className="chips">
            {['45㎡+','55㎡+','65㎡+','75㎡+','85㎡+'].map(v => (
              <button key={v} className={`chip ${isOn('area', v) ? 'on' : ''}`} onClick={() => toggle('area', v)}>{v}</button>
            ))}
          </div>
        </div>

        <div className="flt-section">
          <h3>向き <span className="count">{(state.facing || []).length}</span></h3>
          <div className="chips">
            {['南','南東','南西','東','西','北'].map(v => (
              <button key={v} className={`chip ${isOn('facing', v) ? 'on' : ''}`} onClick={() => toggle('facing', v)}>{v}</button>
            ))}
          </div>
        </div>

        <div className="flt-section">
          <h3>エリア（区） <span className="count">{(state.ward || []).length}</span></h3>
          <div className="chips">
            {['港区','渋谷区','千代田区','中央区','新宿区','目黒区','品川区','世田谷区','杉並区','中野区'].map(v => (
              <button key={v} className={`chip ${isOn('ward', v) ? 'on' : ''}`} onClick={() => toggle('ward', v)}>{v}</button>
            ))}
          </div>
        </div>

        <div className="flt-section">
          <h3>権利形態</h3>
          <div className="chips">
            {['所有権','定期借地'].map(v => (
              <button key={v} className={`chip ${isOn('right', v) ? 'on' : ''}`} onClick={() => toggle('right', v)}>{v}</button>
            ))}
          </div>
        </div>

        <div className="flt-section">
          <h3>築年数</h3>
          <div style={{ padding: '0 4px' }}>
            <input type="range" min="0" max="50" defaultValue="20" style={{ width: '100%' }} />
            <div style={{ display: 'flex', justifyContent: 'space-between', font: 'var(--t-caption)', color: 'var(--fg-secondary)' }}>
              <span>新築</span><span>築50年</span>
            </div>
          </div>
        </div>
      </div>
      <div className="foot">
        <button className="reset" onClick={() => setState({})}>リセット</button>
        <button className="apply" onClick={onClose}>{total > 0 ? `${total}件の条件で表示` : '適用'}</button>
      </div>
    </div>
  );
};

Object.assign(window, { ListingCard, TopTabs, BottomBar, SortSheet, FilterSheet });
