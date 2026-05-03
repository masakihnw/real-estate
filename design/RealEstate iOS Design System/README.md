# RealEstate iOS — Design System

A design system for a personal-use **iOS real-estate investment decision support app**. The app aggregates listings from 7 Japanese real-estate portals (SUUMO / HOME'S / リハウス / ノムコム / アットホーム / 住友不動産 / 東急リバブル), enriches them with Claude AI (dedup detection, image classification, text extraction, investment summaries), and helps the user decide whether to invest.

The product is **iOS-native, SwiftUI, iOS 17+** (with Liquid Glass on iOS 26+), Japanese-language, dark-mode required, Dynamic Type required. This design system is the web-accessible, HTML/CSS mirror of those tokens and components — used to prototype and iterate on the iOS app's visual language.

## Sources used to build this system

- **Codebase (mounted, read-only):** `real-estate-public/real-estate-ios/`
  - `RealEstateApp/Design/DesignSystem.swift` — design tokens (radii, spacing, semantic colors)
  - `RealEstateApp/Views/Components/*.swift` — InvestmentSummaryCard, HighlightBadgeView, AlternateSourcesSection, DedupCandidateCard, ExtractedFeaturesSection, CategorizedImageGallery, AIIndicator
  - `RealEstateApp/Views/{ListingListView, DashboardView, ListingDetailView, …}.swift`
  - `RealEstateApp/Assets.xcassets/` — AppIcon, tab icons, hazard icon, AI provider logos
  - `docs/DESIGN.md` — HIG / OOUI / Liquid Glass guidance
- **GitHub repo:** `masakihnw/real-estate` (mirror of above; same content)
- **Spec attached in brief:** tokens, AI accent rule, score grades, source colors, screen list

## Index

| File / Folder | What's in it |
|---|---|
| `colors_and_type.css` | All CSS variables — colors, radii, spacing, type roles. Import this first. |
| `assets/` | Real PNG assets copied from the iOS app: `AppIcon.png`, `AppIcon-Login.png`, `icon-hazard.png`, `logo-claude.png`, `logo-chatgpt.png`, `logo-gemini.png`, `logo-m3career.png`, `logo-playground.png`, `tab-chuko.png`, `tab-shinchiku.png`, `tab-favorites.png`, `tab-map.png`, `tab-settings.png` |
| `preview/` | Small HTML cards for the Design System tab — typography, color palettes, spacing tokens, component states |
| `ui_kits/ios_app/` | High-fidelity iOS UI kit: Dashboard, Listing list, Listing detail, Settings — clickable prototype with React components |
| `SKILL.md` | Agent skill manifest (cross-compatible with Claude Code Skills) |
| `ui_kits/ios_app/` | React/HTML recreation of the iOS app — see its own README |
| `preview/` | Per-token / per-component preview cards (Type, Colors, Spacing, Components, Brand) |

## Content fundamentals

The product UI is **Japanese**. Tone is **terse, factual, data-forward** — no marketing voice. The user is the developer himself ("個人利用"), so copy is for one expert reader, not a mass audience.

- **Casing:** Japanese has no case. English fragments stay short and lowercase ("AI", "S/A/B/C/D"). Brand names keep their canonical form: SUUMO, HOME'S, リハウス, ノムコム.
- **Pronouns:** Avoided. Sentences are **noun-led** ("値下げ物件", "本日の新着"), matching iOS HIG's object-first OOUI principle.
- **Numerals:** Half-width digits with full-width units ("3,580万円", "徒歩2分", "築10年", "確信度: 87%").
- **Price units:** 万円 (man-yen) and 億円 (oku-yen) used in display: `1億2,300万円`, never raw yen.
- **Emoji:** Not used. SF Symbols carry all glyph affordance.
- **Particles:** Removed when terse is clearer. "価格（安い順）" not "価格を安い順に".
- **AI-generated copy** is one or two short sentences in plain assertive Japanese — e.g. "築浅×駅2分の好条件。管理状態も良好で長期保有向き。" Always rendered with the AI indicator nearby so the user knows it isn't human-written.
- **Empty/error states** use ContentUnavailableView pattern: large SF Symbol, short title ("お気に入りがありません"), one-sentence description, optional single action.

Examples lifted directly from the codebase: `本日の新着`, `値下げ物件`, `掲載中`, `平均価格`, `スコア分布`, `他サイトの掲載価格`, `同じ物件の可能性あり`, `管理優良`, `築浅×駅2分`, `含み益S`, `値下げ注目`, `再開発エリア`.

## Visual foundations

### Layer model
1. **Window** — `--bg-secondary` (light: `#F2F2F7`, dark: pure black). This is `systemGroupedBackground`.
2. **Card** — `--bg-card` (`#F8F8FB` / `#1C1C1E`), corner radius 12, no border.
3. **Inset card** (e.g. AlternateSources, ExtractedFeatures) — `systemGray6` background, radius 8.
4. **Glass** — on iOS 26 the Listing rows use `.glassEffect(.regular)`. On iOS 17–25 it falls back to `.ultraThinMaterial`. We approximate web-side via `backdrop-filter: blur(20px) saturate(1.2)` over `--bg-glass`.

### Color
Semantic-first. Never hand-pick hexes; pull from the token list. Three color systems coexist:
- **HIG semantic** (`--ios-blue`, `--ios-green`, …) for system-aligned UI.
- **Brand semantic** (`--positive`, `--negative`, `--price-up`, `--price-down`) for finance signals — and these are **not** identical to the iOS palette. `--price-down` is its own teal-blue (`#2E87C2`), `--price-up` its own burnt-orange (`#E67D21`), so price moves don't collide with positive/negative gain coloring.
- **AI accent** (`--ai-accent: #5856D6`) — used only for AI indicator chips, AI-generated card borders (10–22% alpha), and "AI Insights" label. Never on prominent surfaces. The rule is **subtle differentiation, not loud branding**.

### Type
Pure system stack: SF Pro / Hiragino Sans on iOS, Yu Gothic / Noto Sans JP fallback on web. **No webfonts.** Dynamic Type is mandatory in the app, so we keep the type role list short and named (`headline`, `subheadline`, `caption`, `caption2`) — no arbitrary px values in components.

`--t-price` and `--t-price-lg` use `SF Pro Rounded` for prices: rounded numerics feel kinder on financial displays and visually distinguish numeric content.

### Spacing
Four canonical step sizes drive everything: **4, 8, 12, 16, 20**. These match the SwiftUI tokens (`listRowVerticalPadding: 12`, `detailGridSpacing: 16`, `detailSectionSpacing: 20`). Going off-grid is a smell.

### Corners
- `4` AI indicator chip
- `6` HighlightBadge, equipment chip
- `8` thumbnail, inset section background
- `12` card (the canonical app radius — `DesignSystem.cornerRadius`)
- `999` score pill, tab chip, capsule

### Backgrounds
No imagery, no patterns, no gradients on chrome. Cards are flat fills. Hero photo is the **only** raster surface in normal use, sourced from listing thumbnails. Empty states use SF Symbol + text only.

### Animation
- **Duration:** SwiftUI default (`.default` ≈ 0.35s, `.easeInOut(duration: 0.2)` for chips).
- **Curves:** ease-in-out only. No springs on data UI.
- **Patterns observed:** chip selection cross-fades; compare-mode toggle slides from leading edge with opacity; sheets are `fullScreenCover` with iOS native dismiss.
- **No bounces, no scale-on-hover, no parallax.** Data UI must feel calm.

### States
- **Hover (web mirror):** background tint `+4–8%` opacity step; never colored borders.
- **Pressed:** opacity drop to ~0.7, no scale transform (matches `.buttonStyle(.plain)`).
- **Selected:** filled accent background + white foreground for chips; `Color.accentColor.opacity(0.15)` background + accent foreground for tabs.
- **Disabled:** opacity 0.4, no pointer.

### Borders
Used only when contrast is otherwise insufficient — typically `1px solid rgba(tint,0.22)` over a same-tint `0.04–0.08` fill (see `tintedGlassBackground`). Cards on grouped backgrounds have **no** border.

### Shadows
Two systems:
- `--shadow-card` — barely-there elevation for floating cards (e.g. AI Insights card on Dashboard).
- `--shadow-floating` — for the right-edge floating filter/sort buttons (`.shadow(color: .black.opacity(0.15), radius: 4, x: 0, y: 2)` in code).
Inner shadows are not used. Pressed states drop shadow rather than press inward.

### Transparency & blur
- iOS 26: cards become Liquid Glass. We approximate with `backdrop-filter: blur(24px) saturate(1.4)`.
- iOS 17–25: `.ultraThinMaterial` (light = whitish translucent, dark = blackish translucent).
- Tinted glass uses **4–8% alpha** for the tint plus 12–22% alpha for the border. Never above 12% tint.

### Imagery vibe
Listing photos are real-estate marketing photography — bright, daylight-balanced, slightly cool. We crop tightly to 4:3 thumbnails with `radius: 8`. No filters, no overlays except score badge.

### Layout rules
- 16pt outer page padding (`listRowHorizontalPadding`).
- Section vertical rhythm: 20pt (`detailSectionSpacing`).
- Tab bar fixed bottom; nav bar fixed top.
- Floating filter/sort cluster: bottom-right, 12pt right inset, 20pt bottom inset, 8pt vertical gap between buttons.

## Iconography

The app uses **SF Symbols** for ~95% of glyphs — a stock iOS approach. A handful of branded raster assets ship in `Assets.xcassets`:

- `AppIcon.png`, `AppIcon-Login.png` — app icon, login splash.
- `icon-hazard.png` — single hazard glyph used inline with hazard badges.
- `logo-claude.png`, `logo-chatgpt.png`, `logo-gemini.png` — AI provider logos for the AI Consultation section (user can pick which model to ask).
- `logo-playground.png`, `logo-m3career.png` — commute-time destination chip logos (the user's two work destinations; specific to this personal app).
- `tab-chuko.png`, `tab-shinchiku.png`, `tab-favorites.png`, `tab-map.png`, `tab-settings.png` — custom tab bar icons (rendered as PDF templates in iOS, copied here as 3x PNGs).

**For web prototypes** we substitute SF Symbols with **Lucide** (CDN: `https://cdn.jsdelivr.net/npm/lucide-static@latest`) — same stroke weight philosophy. Specific name mappings used in the UI kit:

| SF Symbol | Lucide replacement |
|---|---|
| `sparkles` | `sparkles` |
| `chevron.right` | `chevron-right` |
| `arrow.up.arrow.down` | `arrows-up-down` |
| `heart` / `heart.fill` | `heart` |
| `magnifyingglass` | `search` |
| `line.3.horizontal.decrease.circle` | `sliders-horizontal` |
| `arrow.up.right.square` | `external-link` |
| `link.badge.plus` | `link-2` |
| `exclamationmark.triangle.fill` | `triangle-alert` |
| `checkmark.circle.fill` | `circle-check` |
| `building.2.fill` | `building-2` |
| `figure.walk` | `footprints` |
| `hammer.fill` | `hammer` |
| `doc.text.magnifyingglass` | `file-search` |

> **Substitution flag:** Lucide is a stand-in for the iOS-native SF Symbols; visual weight will not match perfectly. Final iOS builds always use SF Symbols. If you want pixel-perfect SF Symbol rendering on web, export as PNGs from SF Symbols.app and drop into `assets/sf-symbols/`.

**No emoji.** **No unicode glyph icons.** Brand names appear as text — there are no portal logos in the app for SUUMO/HOME'S/etc., only colored text labels.

## Caveats / open questions

- The full `ListingDetailView.swift` and several sub-views (~1700 lines each) were skimmed, not exhaustively read. Visual components in `Views/Components/*` were read in full.
- SF Symbols → Lucide substitution will look "close but not identical." Flag if you need pixel parity.
- Source-portal colors (SUUMO green, HOME'S orange, etc.) are inferred from each portal's public branding, not from a token in the codebase. Adjust if the user has internal brand swatches.
- "Liquid Glass" on web is approximated with `backdrop-filter`; real iOS 26 effect has refraction we cannot reproduce.
