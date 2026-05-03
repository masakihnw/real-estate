# iOS App UI Kit — 不動産投資判断支援

iOS 17+ SwiftUI app recreation. ダークモード default; ここでは light theme で表示。

## Files
- `index.html` — interactive demo (Dashboard + 中古一覧 → 詳細 click-thru)
- `Primitives.jsx` — `Icon`, `AIIndicator`, `HighlightBadge`, `ScoreBadge`, sample `LISTINGS`
- `Components.jsx` — `ListingCard`, `StatCard`, `ScoreDistribution`, `AIInsightCard`, `DedupAlert`, `TabBar`, `Search`, `Segmented`, `NavBar`
- `Screens.jsx` — `DashboardScreen`, `ListScreen`, `DetailScreen`
- `ios-frame.jsx` — device frame (starter component)
- `styles.css` — kit-local styles; tokens come from root `colors_and_type.css`

## Demo flow
1. Dashboard tile → tap on left frame
2. Right frame: 中古一覧 → tap any listing → 詳細
3. Tab bar swap (中古 ↔ 新築 ↔ お気に入り)

## Notes / caveats
- Icons: Lucide-style strokes drawn inline as SF Symbols substitute (SF Symbols can't run in HTML). Match weight ≈ regular(2px) at 18–22px sizes.
- Hero / thumbnail images: gradient placeholders — real app uses `bestThumbnailURL`.
- Charts (radar, 価格推移 line) omitted in detail to keep card compact; `ScoreDistribution` shown on dashboard.
- Glass / .glassEffect: approximated with `backdrop-filter: blur(20px) saturate(1.4)` on nav + tab bar.
