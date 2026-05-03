/* global window */
const { useState: useS_dash } = React;

// === Dashboard screen (画面3) ===============================================
const DashboardScreen = ({ onOpenListing }) => {
  return (
    <div className="screen">
      <div className="screen-scroll" style={{ paddingBottom: 24 }}>
        <div className="navbar">
          <div className="lg">ダッシュボード</div>
          <div className="nav-actions">
            <button className="icon-btn"><Icon name="search" size={20} /></button>
            <button className="icon-btn"><Icon name="more" size={22} /></button>
          </div>
        </div>

        {/* Search overview */}
        <div className="sec-h"><Icon name="chart-pie" size={18} color="var(--ios-blue)" /> 検索状況</div>
        <div className="market-grid">
          <div className="stat">
            <div className="lbl">候補物件</div>
            <div className="val">752</div>
            <div className="delta">件</div>
          </div>
          <div className="stat">
            <div className="lbl">本日新着</div>
            <div className="val" style={{ color: 'var(--ios-blue)' }}>12</div>
            <div className="delta pos">+3 前日比</div>
          </div>
          <div className="stat">
            <div className="lbl">お気に入り</div>
            <div className="val">18</div>
            <div className="delta pos">+2 今週</div>
          </div>
        </div>

        {/* Quick filters */}
        <div style={{ marginTop: 14 }}>
          <div className="quick-filter-row">
            {[
              ['本日の新着', 'sparkles'],
              ['値下げ物件', 'trending-down'],
              ['値上げ物件', 'trending-up'],
              ['お気に入り', 'heart'],
            ].map(([lbl, ic]) => (
              <button key={lbl} className="q">
                <Icon name={ic} size={14} color="var(--ios-blue)" /> {lbl}
              </button>
            ))}
          </div>
        </div>

        {/* AI Insights */}
        <div className="sec-h"><Spark size={14} color="var(--ai-accent)" /> AI Insights <AIInd /></div>
        <div className="ai-insight">
          <div className="head">
            <h4><Spark size={13} /> 今日の注目物件 Top 3</h4>
            <span style={{ font: 'var(--t-caption)', color: 'var(--fg-tertiary)' }}>本日 9:00更新</span>
          </div>
          {SPEC_LISTINGS.slice(0, 3).map((l, i) => (
            <div key={l.id} className="pick" onClick={() => onOpenListing(l)} style={{ cursor: 'pointer' }}>
              <div className="ic-thumb" />
              <div style={{ minWidth: 0 }}>
                <div className="nm" style={{ overflow: 'hidden', textOverflow: 'ellipsis', whiteSpace: 'nowrap' }}>{l.name}</div>
                <div className="row2">
                  <ScoreBadge grade={l.score} value={l.scoreVal} />
                  {l.badge && <Hl text={l.badge} style={l.badgeStyle || 'acc'} />}
                  <span>月々 約{l.monthly.toFixed(1)}万</span>
                </div>
              </div>
              <Icon name="chevron-right" size={14} color="var(--fg-tertiary)" />
            </div>
          ))}
        </div>

        {/* Dedup alert */}
        <div className="dedup-alert">
          <div className="ic"><Icon name="link" size={20} /></div>
          <div className="text">
            <b>3件の重複候補を検出</b>
            同マンション内の別出品の可能性があります
          </div>
          <Icon name="chevron-right" size={16} color="var(--ios-orange)" />
        </div>

        {/* Score distribution */}
        <div className="sec-h"><Icon name="chart-bar" size={18} color="var(--ios-blue)" /> おすすめ度の分布</div>
        <div className="score-dist-card">
          {[
            { g: 'S', ct: 18, color: SCORE_COLORS.S },
            { g: 'A', ct: 86, color: SCORE_COLORS.A },
            { g: 'B', ct: 312, color: SCORE_COLORS.B },
            { g: 'C', ct: 248, color: SCORE_COLORS.C },
            { g: 'D', ct: 88, color: SCORE_COLORS.D },
          ].map(d => (
            <div className="row" key={d.g}>
              <span className="gl" style={{ color: d.color }}>{d.g}</span>
              <span className="track">
                <span className="fill" style={{ width: `${(d.ct / 312) * 100}%`, background: d.color }} />
              </span>
              <span className="ct">{d.ct}件</span>
            </div>
          ))}
        </div>

        {/* Price movers */}
        <div className="sec-h">
          <Icon name="arrow-up-down" size={18} color="var(--fg-secondary)" /> 価格変動
          <span className="more">すべて<Icon name="chevron-right" size={14} /></span>
        </div>
        <div className="movers-card">
          <div style={{ font: 'var(--t-caption)', color: 'var(--price-down)', padding: '10px 0 4px', fontWeight: 600 }}>
            <Icon name="arrow-down" size={11} stroke={2.5} /> 値下げ Top 3
          </div>
          {[
            ['パークコート恵比寿', '6,980万', -300, '-4.1%'],
            ['プラウド白金', '8,200万', -150, '-1.8%'],
            ['シティタワー麻布', '1.45億', -120, '-0.8%'],
          ].map(([nm, p, d, pct], i) => (
            <div className="row" key={i}>
              <div>
                <div className="nm">{nm}</div>
                <div className="meta">2日前に値下げ</div>
              </div>
              <div>
                <div className="price">{p}</div>
                <div className="delta down">{d}万 {pct}</div>
              </div>
            </div>
          ))}
          <div style={{ font: 'var(--t-caption)', color: 'var(--price-up)', padding: '14px 0 4px', fontWeight: 600 }}>
            <Icon name="arrow-up" size={11} stroke={2.5} /> 値上げ Top 3
          </div>
          {[
            ['KAZAHANA 風花', '1.1億', 100, '+0.9%'],
            ['ザ・パークハウス渋谷', '1.32億', 80, '+0.6%'],
          ].map(([nm, p, d, pct], i) => (
            <div className="row" key={i}>
              <div>
                <div className="nm">{nm}</div>
                <div className="meta">5日前に値上げ</div>
              </div>
              <div>
                <div className="price">{p}</div>
                <div className="delta up">+{d}万 {pct}</div>
              </div>
            </div>
          ))}
        </div>

        {/* Area ranking */}
        <div className="sec-h"><Icon name="map-pin" size={18} color="var(--fg-secondary)" /> エリアランキング</div>
        <div className="area-rank">
          {[
            ['1', '港区', 78.4, 100],
            ['2', '渋谷区', 74.1, 94],
            ['3', '千代田区', 71.8, 91],
            ['4', '中央区', 70.2, 89],
            ['5', '目黒区', 68.5, 87],
          ].map(([rk, nm, score, w]) => (
            <div className="row" key={rk}>
              <span className="rk">{rk}</span>
              <span className="nm">{nm}</span>
              <span className="track"><span className="fill" style={{ width: `${w}%` }} /></span>
              <span className="v">{score}</span>
            </div>
          ))}
        </div>
      </div>
    </div>
  );
};

// === List screen wrapper (画面1) ============================================
const ListScreen = ({ kind, onOpenListing }) => {
  const [tab, setTab] = useS_dash(kind);
  const [showSort, setShowSort] = useS_dash(false);
  const [showFilter, setShowFilter] = useS_dash(false);
  const [sort, setSort] = useS_dash('addedDesc');
  const [filterState, setFilterState] = useS_dash({});
  const [search, setSearch] = useS_dash('');

  const filterCount = Object.values(filterState).reduce((acc, arr) => acc + (Array.isArray(arr) ? arr.length : 0), 0);

  const counts = { chuko: 752, shin: 124, fav: 18 };
  const list = SPEC_LISTINGS.filter(l => tab === 'fav' ? l.liked : true);

  const sortLabel = ({
    addedDesc: '新しい順', priceAsc: '価格・安い', priceDesc: '価格・高い',
    monthlyAsc: '月額・安い', walkAsc: '徒歩・近い', areaDesc: '面積・広い',
    ageAsc: '築年・浅い', scoreDesc: 'おすすめ度順', fairnessDesc: '価格妥当性',
    liquidityDesc: '売りやすさ順', profitDesc: '住み替え時の手残り', deviationDesc: '偏差値順',
    appreciationDesc: '値上がり率', mgmtAsc: '管理費・安い', repairAsc: '修繕・安い',
    runAsc: '維持費・安い', tsuboAsc: '坪単価・安い',
  })[sort];

  return (
    <div className="screen" style={{ position: 'relative' }} onClick={() => setShowSort(false)}>
      <div className="screen-scroll" style={{ paddingBottom: 100 }}>
        <div className="navbar">
          <div className="lg">物件一覧</div>
          <div className="nav-actions">
            <button className="icon-btn" onClick={(e) => { e.stopPropagation(); setShowSort(!showSort); }}>
              <Icon name="sort" size={20} />
            </button>
            <button className="icon-btn" onClick={() => setShowFilter(true)}>
              <Icon name="sliders" size={20} />
              {filterCount > 0 && <span className="badge">{filterCount}</span>}
            </button>
          </div>
        </div>

        <TopTabs active={tab} onChange={setTab} counts={counts} />

        <div className="search">
          <Icon name="search" size={16} color="var(--fg-secondary)" />
          <input placeholder="物件名・マンション名で検索" value={search} onChange={(e) => setSearch(e.target.value)} />
        </div>

        <div style={{ padding: '0 16px 8px', display: 'flex', alignItems: 'center', gap: 6, font: 'var(--t-footnote)', color: 'var(--fg-secondary)' }}>
          <span><b style={{ color: 'var(--fg-primary)' }}>{list.length}</b>件 · {sortLabel}</span>
          <span style={{ marginLeft: 'auto', display: 'inline-flex', alignItems: 'center', gap: 3, color: 'var(--ios-blue)' }} onClick={(e) => { e.stopPropagation(); setShowSort(true); }}>
            並べ替え <Icon name="chevron-down" size={12} stroke={2.5} />
          </span>
        </div>

        <div className="list-pad cards-stack">
          {list.map(l => <ListingCard key={l.id} l={l} onClick={() => onOpenListing(l)} />)}
        </div>
      </div>

      {showSort && (
        <SortSheet value={sort} onPick={setSort} onClose={() => setShowSort(false)} />
      )}
      {showFilter && (
        <FilterSheet onClose={() => setShowFilter(false)} state={filterState} setState={setFilterState} />
      )}
    </div>
  );
};

Object.assign(window, { DashboardScreen, ListScreen });
