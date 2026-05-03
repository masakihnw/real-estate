/* global window */
const { useState: useState_S } = React;

const DashboardScreen = () => (
  <div className="screen">
    <div className="screen-scroll">
      <NavBar title="ダッシュボード" lg right={<Icon name="more" size={22} color="var(--ios-blue)" />} />

      <div className="sec-h"><Icon name="chart-pie" size={18} color="var(--ios-blue)" /> マーケット概要</div>
      <div className="stat-grid">
        <StatCard label="全物件数" value="28" sub="+3 本日新着" />
        <StatCard label="平均価格" value="9,840万" sub="↓ 1.2% 前週比" accent="var(--positive)" />
        <StatCard label="お気に入り" value="6" sub="2件で値下げ" accent="var(--price-down)" />
        <StatCard label="重複候補" value="3" sub="要確認" accent="var(--ai-accent)" hasChev />
      </div>

      <div className="sec-h"><SparkIcon size={14}/> AI Insights <AIIndicator /></div>
      <div className="list-pad cards-stack">
        <AIInsightCard />
        <DedupAlert count={3} />
      </div>

      <div className="sec-h"><Icon name="chart-bar" size={18} color="var(--ios-blue)" /> スコア分布</div>
      <ScoreDistribution />

      <div className="sec-h"><Icon name="arrow-up-down" size={18} color="var(--price-down)" /> 価格変動</div>
      <div className="list-pad cards-stack">
        <div className="card">
          <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center' }}>
            <div>
              <div style={{ font: 'var(--t-headline)' }}>AQUA VISTA 7階</div>
              <div style={{ font: 'var(--t-caption)', color: 'var(--fg-secondary)', marginTop: 2 }}>2日前に値下げ</div>
            </div>
            <div style={{ textAlign: 'right' }}>
              <div style={{ font: 'var(--t-price)', color: 'var(--price-down)' }}>1.0億</div>
              <div style={{ font: 'var(--t-caption)', color: 'var(--price-down)' }}>↓ 50万</div>
            </div>
          </div>
        </div>
        <div className="card">
          <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center' }}>
            <div>
              <div style={{ font: 'var(--t-headline)' }}>KAZAHANA</div>
              <div style={{ font: 'var(--t-caption)', color: 'var(--fg-secondary)', marginTop: 2 }}>5日前に値上げ</div>
            </div>
            <div style={{ textAlign: 'right' }}>
              <div style={{ font: 'var(--t-price)', color: 'var(--price-up)' }}>1.1億</div>
              <div style={{ font: 'var(--t-caption)', color: 'var(--price-up)' }}>↑ 100万</div>
            </div>
          </div>
        </div>
      </div>

      <div className="sec-h">📍 エリアランキング</div>
      <div className="list-pad cards-stack" style={{ paddingBottom: 16 }}>
        <div className="card">
          {['港区 · 12件 · 平均1.3億', '杉並区 · 7件 · 平均8,500万', '荒川区 · 4件 · 平均9,200万'].map((t, i) => (
            <div key={i} style={{ display: 'flex', justifyContent: 'space-between', padding: '8px 0', borderBottom: i < 2 ? '1px solid var(--separator)' : 0, font: 'var(--t-callout)' }}>
              <span>{t}</span>
              <Icon name="chevron-right" size={14} color="var(--fg-tertiary)" />
            </div>
          ))}
        </div>
      </div>
    </div>
  </div>
);

const ListScreen = ({ kind = 'chuko', onOpen }) => {
  const [seg, setSeg] = useState_S('all');
  const filtered = LISTINGS;
  return (
    <div className="screen" style={{ position: 'relative' }}>
      <div className="screen-scroll">
        <NavBar title={kind === 'chuko' ? `中古マンション (${filtered.length})` : kind === 'shin' ? `新築マンション (${filtered.length})` : `お気に入り (${filtered.length})`} lg right={<Icon name="sliders" size={22} color="var(--ios-blue)" />} />
        <Search />
        <Segmented active={seg} onChange={setSeg} items={[
          { k: 'all', label: 'すべて' }, { k: 'score', label: 'スコア' }, { k: 'new', label: '新着' }, { k: 'down', label: '値下げ' },
        ]} />
        <div className="list-pad cards-stack" style={{ paddingBottom: 100 }}>
          {filtered.map(l => <ListingCard key={l.id} l={l} onClick={() => onOpen(l)} />)}
        </div>
      </div>
      <div className="fab-cluster">
        <button className="fab"><Icon name="sort" size={18} /></button>
        <button className="fab active"><Icon name="map" size={18} color="#fff" /></button>
      </div>
    </div>
  );
};

const DetailScreen = ({ l, onBack }) => {
  const [tab, setTab] = useState_S('exterior');
  return (
    <div className="screen">
      <div className="screen-scroll" style={{ paddingBottom: 24 }}>
        <div className="hero">
          <div style={{ position: 'absolute', top: 12, left: 12, right: 12, display: 'flex', justifyContent: 'space-between' }}>
            <button className="fab" onClick={onBack} style={{ width: 36, height: 36 }}>
              <Icon name="chevron-right" size={18} stroke={2.5} />
              <span style={{ display: 'none' }}>back</span>
            </button>
            <button className="fab" style={{ width: 36, height: 36 }}>
              <Icon name="heart" size={18} color={l.liked ? 'var(--ios-red)' : 'var(--ios-blue)'} stroke={l.liked ? 0 : 2} />
            </button>
          </div>
          <div className="hero-overlay">
            <ScoreBadge grade={l.score} value={l.scoreVal} />
            <span className="hl hl-acc">{l.badge}</span>
          </div>
        </div>

        <div className="detail-block" style={{ paddingBottom: 4 }}>
          <div className="ai-card">
            <div className="row">
              <h4><SparkIcon size={14}/> 投資サマリー</h4>
              <AIIndicator />
            </div>
            <div style={{ font: 'var(--t-callout)', lineHeight: 1.5 }}>
              {l.summary}
            </div>
            <div style={{ marginTop: 10, font: 'var(--t-caption)', color: 'var(--fg-secondary)' }}>強み</div>
            <div style={{ display: 'flex', gap: 6, flexWrap: 'wrap', marginTop: 4 }}>
              {(l.strengths || []).map((s, i) => <HighlightBadge key={i} text={s} style="pos" />)}
            </div>
            <div style={{ marginTop: 10, font: 'var(--t-caption)', color: 'var(--fg-secondary)' }}>リスク</div>
            <div style={{ display: 'flex', gap: 6, flexWrap: 'wrap', marginTop: 4 }}>
              {(l.risks || []).map((s, i) => <HighlightBadge key={i} text={s} style="warn" />)}
            </div>
          </div>
        </div>

        <div className="detail-block" style={{ paddingTop: 12 }}>
          <h2>{l.name}</h2>
          <div className="addr">{l.address}</div>
          <div style={{ display: 'flex', gap: 8, marginTop: 8, alignItems: 'baseline' }}>
            <span className="price" style={{ color: l.priceColor }}>{l.price}</span>
            {l.deviation && <span className="dev">↓ 偏差値 {l.deviation}</span>}
          </div>
        </div>

        {l.altSources && (
          <div className="detail-block" style={{ paddingTop: 0 }}>
            <div className="sec-h" style={{ padding: '0 0 8px' }}><Icon name="external-link" size={16} /> 他サイト価格比較</div>
            <div className="alt-src">
              {l.altSources.map((s, i) => (
                <div className="row" key={i}>
                  <span className="src-name">{s.src}</span>
                  <span className="pr">{s.price}</span>
                  <span className="spacer" />
                  {s.diff !== 0 && <span className={`diff ${s.diff < 0 ? 'down' : 'up'}`}>{s.diff > 0 ? '+' : ''}{s.diff}万</span>}
                  {s.diff === 0 && <span style={{ font: 'var(--t-caption)', color: 'var(--fg-tertiary)' }}>最安</span>}
                </div>
              ))}
            </div>
          </div>
        )}

        <div className="detail-block" style={{ paddingTop: 0 }}>
          <div className="sec-h" style={{ padding: '0 0 8px' }}>📷 画像 <AIIndicator /></div>
          <div className="gallery-tabs">
            {[['exterior','外観',8],['interior','室内',12],['water','水回り',6],['plan','間取り',2],['view','眺望',3],['common','共用部',4]].map(([k,n,c]) => (
              <button key={k} className={tab===k?'on':''} onClick={() => setTab(k)}>{n}<span className="ct">{c}</span></button>
            ))}
          </div>
          <div className="gallery-thumbs">
            {[1,2,3].map(i => <div key={i} className="gt" />)}
          </div>
        </div>

        <div className="detail-block" style={{ paddingTop: 0 }}>
          <div className="sec-h" style={{ padding: '0 0 8px' }}><SparkIcon size={14}/> 抽出特徴 <AIIndicator /></div>
          <div className="card">
            <div style={{ font: 'var(--t-caption)', color: 'var(--fg-secondary)', marginBottom: 6 }}>設備ハイライト</div>
            <div style={{ display: 'flex', gap: 6, flexWrap: 'wrap' }}>
              {['宅配BOX','オートロック','ペット可','床暖房','ディスポーザー'].map(t => <span key={t} className="pill pill-acc">{t}</span>)}
            </div>
            <div style={{ font: 'var(--t-caption)', color: 'var(--fg-secondary)', marginTop: 12, marginBottom: 6 }}>注意点</div>
            <div style={{ display: 'flex', gap: 6, flexWrap: 'wrap' }}>
              {['1階住戸','管理費高め'].map(t => <span key={t} className="pill pill-warn">{t}</span>)}
            </div>
          </div>
        </div>

        <div className="detail-block" style={{ paddingTop: 0 }}>
          <div className="sec-h" style={{ padding: '0 0 8px' }}>基本情報</div>
          <div className="detail-grid">
            <div className="dg-cell"><div className="lbl">価格</div><div className="val">{l.price}</div></div>
            <div className="dg-cell"><div className="lbl">間取り</div><div className="val">{l.layout}</div></div>
            <div className="dg-cell"><div className="lbl">専有面積</div><div className="val">{l.area}</div></div>
            <div className="dg-cell"><div className="lbl">築年数</div><div className="val">{l.age}</div></div>
            <div className="dg-cell"><div className="lbl">所在階</div><div className="val">{l.floorPos || '—'}</div></div>
            <div className="dg-cell"><div className="lbl">構造</div><div className="val">{l.floor}</div></div>
          </div>
        </div>

        <div className="detail-block" style={{ paddingTop: 4 }}>
          <div className="sec-h" style={{ padding: '0 0 8px' }}><Icon name="triangle-alert" size={16} color="var(--ios-orange)" /> ハザード</div>
          <div className="card">
            <div className="spec-list" style={{ padding: 0 }}>
              <div className="row"><span className="k">洪水浸水</span><span className="haz"><Icon name="triangle-alert" size={10}/> 想定2.0m</span></div>
              <div className="row"><span className="k">地震揺れやすさ</span><span style={{ font: 'var(--t-callout)' }}>普通</span></div>
              <div className="row"><span className="k">土砂災害</span><span style={{ font: 'var(--t-callout)', color: 'var(--positive)' }}>なし</span></div>
            </div>
          </div>
        </div>
      </div>
    </div>
  );
};

Object.assign(window, { DashboardScreen, ListScreen, DetailScreen });
