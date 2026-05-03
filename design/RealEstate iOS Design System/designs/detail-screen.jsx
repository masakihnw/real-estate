/* global window */
const { useState: useS_det } = React;

// === Detail screen (画面2) ==================================================
const DetailScreen = ({ l, onBack }) => {
  const [section, setSection] = useS_det('info');
  const [galTab, setGalTab] = useS_det('exterior');
  const [rate, setRate] = useS_det(1.2);
  const [years, setYears] = useS_det(50);
  const [downPayment, setDownPayment] = useS_det(0);
  const [simOpen, setSimOpen] = useS_det(false);

  const sections = [
    ['summary', 'サマリー'], ['info', '情報'], ['sim', '月額'],
    ['commute', '通勤'], ['hazard', 'ハザード'], ['score', '資産性'], ['ai', 'AI'],
  ];

  // Loan sim — 借入額 = (物件価格 - 頭金) × 1.065（諸費用6.5%込み）, 元利均等
  const FEE_MULT = 1.065;
  const principal = Math.max(0, (l.price - downPayment)) * FEE_MULT; // 万円
  const r = (rate / 100) / 12;
  const n = years * 12;
  const loanMonthly = r > 0
    ? principal * r * Math.pow(1 + r, n) / (Math.pow(1 + r, n) - 1)
    : principal / n;
  const mgmt = 1.82, repair = 1.30;
  const total = loanMonthly + mgmt + repair;
  const loanPct = (loanMonthly / total) * 100;
  const mgmtPct = (mgmt / total) * 100;
  const repairPct = (repair / total) * 100;

  // Default-condition breakdown (1.2% / 50年, fixed) for static info-grid
  const defaultBreakdown = (typeof window.calcMonthly === 'function')
    ? window.calcMonthly(l.price)
    : { loan: loanMonthly, mgmt, repair, total: loanMonthly + mgmt + repair };

  const galleryCounts = { exterior: 8, interior: 12, water: 6, plan: 2, view: 3, common: 4 };

  return (
    <div className="screen">
      <div className="screen-scroll" style={{ paddingBottom: 24 }}>
        {/* Hero */}
        <div className="detail-hero">
          <div className="hero-controls">
            <button className="fab-circle" onClick={onBack}><Icon name="chevron-left" size={20} stroke={2.4} /></button>
            <div style={{ display: 'flex', gap: 8 }}>
              <button className="fab-circle"><Icon name="external" size={16} /></button>
              <button className="fab-circle">
                <Icon name="heart" size={18} color={l.liked ? 'var(--ios-red)' : 'var(--fg-primary)'} fill={l.liked ? 'var(--ios-red)' : 'none'} stroke={l.liked ? 0 : 2} />
              </button>
            </div>
          </div>
          <div className="hero-overlay">
            <ScoreBadge grade={l.score} value={l.scoreVal} />
            {l.badge && <Hl text={l.badge} style={l.badgeStyle || 'acc'} />}
          </div>
          <div className="img-counter">1 / 35</div>
        </div>

        {/* Section nav */}
        <div className="sec-nav">
          {sections.map(([k, lbl]) => (
            <button key={k} className={section === k ? 'on' : ''} onClick={() => setSection(k)}>
              {lbl}
            </button>
          ))}
        </div>

        {/* Title block */}
        <div className="detail-title">
          <h1 className="name">{l.name}</h1>
          <div className="addr"><Icon name="map-pin" size={13} /> {l.address}</div>
          <div className="price-block">
            <span className="big">{l.priceLabel}</span>
            {l.priceDelta < 0 && <span className="delta-down">{l.priceDelta}万↓ 値下げ</span>}
            {l.priceDelta > 0 && <span className="delta-up">+{l.priceDelta}万↑ 値上げ</span>}
          </div>
        </div>

        {/* Stat strip */}
        <div className="stat-strip">
          <div className="cell"><div className="lbl">月々</div><div className="val blue">約{l.monthly.toFixed(1)}万</div></div>
          <div className="cell"><div className="lbl">間取り / 面積</div><div className="val">{l.layout} {l.area}</div></div>
          <div className="cell"><div className="lbl">徒歩 / 築年</div><div className="val">{l.walk}分 / 築{l.age}年</div></div>
        </div>

        {/* AI Investment Summary */}
        {l.summary && ['S', 'A', 'B'].includes(l.score) && (
          <>
            <div className="sec-h"><Spark size={14} color="var(--ai-accent)" /> 購入判断サマリー <AIInd /></div>
            <div className="ai-card">
              <div className="text">{l.summary}</div>
              {l.strengths && (<>
                <div className="lbl">この物件の強み</div>
                <div className="chips">
                  {l.strengths.map((s, i) => <Hl key={i} text={s} style="pos" />)}
                </div>
              </>)}
              {l.risks && l.risks.length > 0 && (<>
                <div className="lbl">注意点</div>
                <div className="chips">
                  {l.risks.map((s, i) => <Hl key={i} text={s} style="warn" />)}
                </div>
              </>)}
            </div>
          </>
        )}

        {/* Score block with radar */}
        <div className="sec-h"><Icon name="chart-pie" size={18} color="var(--fg-secondary)" /> 総合スコア</div>
        <div className="score-block">
          <div className="head">
            <div className="big-score">
              <span className="num" style={{ color: SCORE_COLORS[l.score] }}>{l.scoreVal}</span>
              <span className="grade" style={{ color: SCORE_COLORS[l.score] }}>{l.score}</span>
              <span className="out">/ 100</span>
            </div>
            <div style={{ font: 'var(--t-caption)', color: 'var(--fg-secondary)', textAlign: 'right' }}>
              <div>掲載 23日</div>
              <div>更新 2日前</div>
            </div>
          </div>
          <RadarChart values={[88, 75, 92, 70, 80]} />
          <div className="price-hist">
            <div style={{ font: 'var(--t-caption)', color: 'var(--fg-secondary)', marginBottom: 6 }}>価格変動履歴</div>
            <PriceHistory />
          </div>
        </div>

        {/* Forecast (5/10年) — 売却時の参考 */}
        <div className="sec-h"><Icon name="trending-up" size={18} color="var(--positive)" /> 7〜13年後の資産価値</div>
        <div style={{ margin: '0 16px', background: 'var(--bg-card)', borderRadius: 'var(--radius-xl)' }}>
          <div style={{ padding: '12px 14px 0', font: 'var(--t-caption)', color: 'var(--fg-secondary)' }}>10年後 売却時の手残り（ローン残高との差）</div>）</div>
          <div className="forecast-bars">
            <div className="col">
              <div className="lbl">ワースト</div>
              <div className="gain neg">-180万</div>
              <div className="sub">−2.6%</div>
            </div>
            <div className="col" style={{ background: 'rgba(0,122,255,.06)', border: '1px solid rgba(0,122,255,.2)' }}>
              <div className="lbl" style={{ color: 'var(--ios-blue)' }}>標準</div>
              <div className="gain pos">+1,420万</div>
              <div className="sub">+20.3%</div>
            </div>
            <div className="col">
              <div className="lbl">ベスト</div>
              <div className="gain pos">+2,890万</div>
              <div className="sub">+41.4%</div>
            </div>
          </div>
        </div>

        {/* Monthly payment simulation */}
        <div className="sec-h"><Icon name="calculator" size={18} color="var(--fg-secondary)" /> 月額支払いシミュレーション</div>
        <div className="sim-block">
          <div className="total">
            <div>
              <span className="num" style={{ color: 'var(--ios-blue)' }}>約{total.toFixed(1)}</span>
              <span className="unit">万円/月</span>
            </div>
            <div className="lbl">借入額 {(Math.max(0, l.price - downPayment) * FEE_MULT).toLocaleString(undefined, { maximumFractionDigits: 1 })}万円（諸費用6.5%込）</div>
          </div>
          <div className="sim-breakdown">
            ローン{loanMonthly.toFixed(1)} + 管理費{mgmt.toFixed(1)} + 修繕{repair.toFixed(1)}
          </div>

          <button
            className={`sim-toggle ${simOpen ? 'open' : ''}`}
            onClick={() => setSimOpen(!simOpen)}
          >
            <Icon name="calculator" size={14} color="var(--ios-blue)" />
            <span>条件を変更してシミュレーション</span>
            <span className="cur">
              {rate.toFixed(1)}% / {years}年 / 頭金{downPayment > 0 ? `${downPayment}万` : '0'}
            </span>
            <Icon className="chev" name="chevron-down" size={14} stroke={2.5} color="var(--fg-tertiary)" />
          </button>

          {simOpen && (
            <>
              <div className="sim-bar">
                <div className="item">
                  <span className="lbl">ローン</span>
                  <span className="track"><span className="fill" style={{ width: `${loanPct}%`, background: 'var(--ios-blue)' }} /></span>
                  <span className="val">{loanMonthly.toFixed(1)}万</span>
                </div>
                <div className="item">
                  <span className="lbl">管理費</span>
                  <span className="track"><span className="fill" style={{ width: `${mgmtPct}%`, background: 'var(--positive)' }} /></span>
                  <span className="val">{mgmt.toFixed(1)}万</span>
                </div>
                <div className="item">
                  <span className="lbl">修繕積立</span>
                  <span className="track"><span className="fill" style={{ width: `${repairPct}%`, background: 'var(--ios-orange)' }} /></span>
                  <span className="val">{repair.toFixed(1)}万</span>
                </div>
              </div>
              <div className="sim-inputs">
                <div className="inp">
                  <label>金利</label>
                  <div className="field">
                    <input type="number" min="0" max="10" step="0.1" value={rate} onChange={(e) => setRate(+e.target.value)} />
                    <span className="suf">%</span>
                  </div>
                </div>
                <div className="inp">
                  <label>返済期間</label>
                  <div className="field">
                    <input type="number" min="1" max="50" step="1" value={years} onChange={(e) => setYears(+e.target.value)} />
                    <span className="suf">年</span>
                  </div>
                </div>
                <div className="inp">
                  <label>頭金</label>
                  <div className="field">
                    <input type="number" min="0" max={l.price} step="100" value={downPayment} onChange={(e) => setDownPayment(+e.target.value)} />
                    <span className="suf">万円</span>
                  </div>
                </div>
              </div>
              <div className="sim-presets">
                {[
                  { label: '基準', r: 1.2, y: 50, d: 0 },
                  { label: '頭金1割', r: 1.2, y: 50, d: Math.round(l.price * 0.1 / 100) * 100 },
                  { label: '頭金2割', r: 1.2, y: 50, d: Math.round(l.price * 0.2 / 100) * 100 },
                  { label: '35年返済', r: 1.2, y: 35, d: 0 },
                ].map(p => {
                  const isOn = rate === p.r && years === p.y && downPayment === p.d;
                  return (
                    <button key={p.label} className={`preset ${isOn ? 'on' : ''}`}
                      onClick={() => { setRate(p.r); setYears(p.y); setDownPayment(p.d); }}>
                      {p.label}
                    </button>
                  );
                })}
              </div>
            </>
          )}
        </div>

        {/* Property info grid */}
        <div className="sec-h">物件情報</div>
        <div className="info-grid">
          <div className="cell"><div className="lbl">価格</div><div className="val">{l.priceLabel}</div></div>
          <div className="cell"><div className="lbl">坪単価</div><div className="val">395万/坪</div></div>
          <div className="cell"><div className="lbl">間取り</div><div className="val">{l.layout}</div></div>
          <div className="cell"><div className="lbl">専有面積</div><div className="val">{l.area}</div></div>
          <div className="cell"><div className="lbl">築年月</div><div className="val">2019年3月</div></div>
          <div className="cell"><div className="lbl">築年数</div><div className="val">築{l.age}年</div></div>
          <div className="cell"><div className="lbl">所在階</div><div className="val">15階</div></div>
          <div className="cell"><div className="lbl">総階数</div><div className="val">45階</div></div>
          <div className="cell"><div className="lbl">方角</div><div className="val">南</div></div>
          <div className="cell"><div className="lbl">バルコニー</div><div className="val">12.3㎡</div></div>
          <div className="cell"><div className="lbl">管理費</div><div className="val">18,200円/月</div></div>
          <div className="cell"><div className="lbl">修繕積立金</div><div className="val">13,000円/月</div></div>
          <div className="cell highlight"><div className="lbl">月々合計</div><div className="val">約{l.monthly.toFixed(1)}万円</div></div>
          <div className="cell highlight"><div className="lbl">内訳</div><div className="val" style={{ font: 'var(--t-caption)', fontWeight: 400, color: 'var(--fg-secondary)', lineHeight: 1.35 }}>ローン{defaultBreakdown.loan.toFixed(1)} + 管理費{defaultBreakdown.mgmt.toFixed(1)} + 修繕{defaultBreakdown.repair.toFixed(1)}<br/><span style={{ color: 'var(--fg-tertiary)' }}>（諸費用6.5%込）</span></div></div>
          <div className="cell"><div className="lbl">権利形態</div><div className="val">所有権</div></div>
          <div className="cell"><div className="lbl">総戸数</div><div className="val">350戸</div></div>
        </div>

        {/* Commute */}
        <div className="sec-h"><Icon name="train" size={18} color="var(--fg-secondary)" /> 通勤時間</div>
        <div style={{ margin: '0 16px', background: 'var(--bg-card)', borderRadius: 'var(--radius-xl)' }}>
          <div className="commute-row">
            <div className="left">
              <span className="av pg">P</span>
              <div>
                <div style={{ font: 'var(--t-callout)', fontWeight: 500 }}>Playground社</div>
                <div className="meta">渋谷区 · 乗換1回</div>
              </div>
            </div>
            <div style={{ textAlign: 'right' }}>
              <div className="min" style={{ color: 'var(--commute-pg)' }}>32分</div>
              <div className="meta">9:00着</div>
            </div>
          </div>
          <div className="commute-row">
            <div className="left">
              <span className="av m3">M</span>
              <div>
                <div style={{ font: 'var(--t-callout)', fontWeight: 500 }}>M3Career社</div>
                <div className="meta">港区 · 乗換2回</div>
              </div>
            </div>
            <div style={{ textAlign: 'right' }}>
              <div className="min" style={{ color: 'var(--commute-m3)' }}>41分</div>
              <div className="meta">9:00着</div>
            </div>
          </div>
        </div>

        {/* Hazard */}
        <div className="sec-h"><Icon name="triangle-alert" size={18} color="var(--ios-orange)" /> ハザード情報</div>
        <div className="hazard-list">
          <div className="row">
            <span className="k"><span className="level-pip" style={{ background: HAZARD_COLORS.low }} />洪水浸水</span>
            <span className="v">想定 0.5m未満</span>
          </div>
          <div className="row">
            <span className="k"><span className="level-pip" style={{ background: HAZARD_COLORS.low }} />地震揺れやすさ</span>
            <span className="v">震度5弱</span>
          </div>
          <div className="row">
            <span className="k"><span className="level-pip" style={{ background: 'var(--positive)' }} />土砂災害</span>
            <span className="v safe">対象外</span>
          </div>
          <div className="row">
            <span className="k"><span className="level-pip" style={{ background: 'var(--positive)' }} />高潮 / 津波</span>
            <span className="v safe">対象外</span>
          </div>
        </div>

        {/* AI consultation — prompt template */}
        <div className="sec-h"><Spark size={14} color="var(--ai-accent)" /> AIに相談 <AIInd /></div>
        <AIPromptCard l={l} />

        {/* External link */}
        <div style={{ padding: '20px 16px 24px' }}>
          <button style={{
            width: '100%', padding: 14, background: 'var(--ios-blue)', color: '#fff',
            borderRadius: 12, font: 'var(--t-headline)',
            display: 'flex', alignItems: 'center', justifyContent: 'center', gap: 8,
          }}>
            掲載元（リハウス）で詳細を見る <Icon name="external" size={16} />
          </button>
        </div>
      </div>
    </div>
  );
};

// === Radar chart (5 axes) ====================================================
const RadarChart = ({ values }) => {
  const labels = ['価格妥当性', '売りやすさ', '立地', '将来性', '管理'];
  const cx = 100, cy = 100, R = 70;
  const angle = (i) => (Math.PI * 2 * i) / 5 - Math.PI / 2;
  const point = (i, v) => {
    const r = (v / 100) * R;
    return [cx + r * Math.cos(angle(i)), cy + r * Math.sin(angle(i))];
  };
  const polyPoints = values.map((v, i) => point(i, v).join(',')).join(' ');
  const labelPoints = labels.map((_, i) => {
    const r = R + 14;
    return [cx + r * Math.cos(angle(i)), cy + r * Math.sin(angle(i))];
  });
  return (
    <div className="radar-wrap">
      <svg viewBox="0 0 200 200">
        {[0.25, 0.5, 0.75, 1].map((s, i) => (
          <polygon key={i}
            points={[0, 1, 2, 3, 4].map(idx => {
              const [x, y] = [cx + R * s * Math.cos(angle(idx)), cy + R * s * Math.sin(angle(idx))];
              return `${x},${y}`;
            }).join(' ')}
            fill="none" stroke="var(--separator)" strokeWidth="0.5" />
        ))}
        {[0, 1, 2, 3, 4].map(i => (
          <line key={i} x1={cx} y1={cy} x2={cx + R * Math.cos(angle(i))} y2={cy + R * Math.sin(angle(i))}
                stroke="var(--separator)" strokeWidth="0.5" />
        ))}
        <polygon points={polyPoints} fill="rgba(0,122,255,.20)" stroke="var(--ios-blue)" strokeWidth="1.6" />
        {values.map((v, i) => {
          const [x, y] = point(i, v);
          return <circle key={i} cx={x} cy={y} r="3" fill="var(--ios-blue)" />;
        })}
      </svg>
      {labels.map((lbl, i) => (
        <div key={i} className="radar-axis-label" style={{ left: `${(labelPoints[i][0] / 200) * 100}%`, top: `${(labelPoints[i][1] / 200) * 100}%` }}>
          {lbl}
        </div>
      ))}
    </div>
  );
};

// === Mini price history line ================================================
const PriceHistory = () => {
  const data = [7400, 7400, 7280, 7280, 7100, 7100, 6980];
  const max = Math.max(...data), min = Math.min(...data);
  const w = 280, h = 60;
  const xs = data.map((_, i) => (i / (data.length - 1)) * w);
  const ys = data.map(v => h - ((v - min) / (max - min)) * h * 0.85 - 4);
  const path = data.map((_, i) => `${i === 0 ? 'M' : 'L'} ${xs[i]} ${ys[i]}`).join(' ');
  return (
    <svg viewBox={`0 0 ${w} ${h + 16}`}>
      <path d={`${path} L ${xs[xs.length - 1]} ${h} L 0 ${h} Z`} fill="rgba(0,122,255,.10)" />
      <path d={path} stroke="var(--ios-blue)" strokeWidth="2" fill="none" />
      {data.map((v, i) => <circle key={i} cx={xs[i]} cy={ys[i]} r="2.5" fill="var(--ios-blue)" />)}
      <text x={xs[xs.length - 1]} y={ys[ys.length - 1] - 8} textAnchor="end" fontSize="10" fill="var(--ios-blue)" fontWeight="600">¥6,980万</text>
      <text x="0" y={h + 12} fontSize="9" fill="var(--fg-tertiary)">3ヶ月前</text>
      <text x={w} y={h + 12} textAnchor="end" fontSize="9" fill="var(--fg-tertiary)">現在</text>
    </svg>
  );
};

// === AI Prompt Card =========================================================
const AIPromptCard = ({ l }) => {
  const [copied, setCopied] = useS_det(false);
  const prompt = `以下のマンションの購入を検討しています。住む家として、また将来の住み替えも見据えた上で評価してください。

【物件情報】
名称: ${l.name}
所在地: ${l.address}
価格: ${l.priceLabel}
間取り: ${l.layout} / ${l.area}
築年数: 築${l.age}年
駅徒歩: ${l.walk}分（${l.station || '最寄駅'}）
方角: 南向き
所在階: 15階 / 45階建て
管理費: 18,200円/月
修繕積立金: 13,000円/月
月々支払額: 約${l.monthly.toFixed(1)}万円（金利1.2%/50年/頭金0/諸費用6.5%込）

【質問】
1. 住む家として、この物件の良い点と注意点は？
2. 同価格帯の他物件と比べて妥当な価格か？
3. 7〜13年後にライフステージ変化で住み替える場合、資産価値は維持できそうか？
4. 修繕積立金は将来的に上昇する可能性が高いか？`;

  const onCopy = (e) => {
    e.stopPropagation();
    if (navigator.clipboard) navigator.clipboard.writeText(prompt);
    setCopied(true);
    setTimeout(() => setCopied(false), 1800);
  };

  const ais = [
    { k: 'chatgpt', label: 'ChatGPT', logo: 'logo-chatgpt.png' },
    { k: 'claude', label: 'Claude', logo: 'logo-claude.png' },
    { k: 'gemini', label: 'Gemini', logo: 'logo-gemini.png' },
  ];

  return (
    <div className="ai-prompt-card">
      <div className="intro">
        <div className="title">プロンプトテンプレート</div>
        <div className="sub">物件情報を含むプロンプトを生成します。コピーしてお好みのAIに貼り付けてご利用ください。</div>
      </div>

      <div className="prompt-box">
        <pre className="prompt-text">{prompt}</pre>
        <button className={`copy-btn ${copied ? 'copied' : ''}`} onClick={onCopy}>
          {copied
            ? (<><Icon name="check" size={14} stroke={2.5} /> コピーしました</>)
            : (<><Icon name="copy" size={14} /> プロンプトをコピー</>)}
        </button>
      </div>

      <div className="ai-launch-row">
        {ais.map(a => (
          <button key={a.k} className="ai-launch">
            <img src={a.logo} alt="" className="logo" />
            <div className="meta">
              <div className="nm">{a.label}</div>
              <div className="action">で開く<Icon name="external" size={11} stroke={2.2} /></div>
            </div>
          </button>
        ))}
      </div>
    </div>
  );
};

Object.assign(window, { DetailScreen, RadarChart, PriceHistory, AIPromptCard });
