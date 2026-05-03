---
name: realestate-ios-design
description: Use this skill to generate well-branded interfaces and assets for the Real Estate iOS investment-decision app, either for production SwiftUI work or throwaway prototypes/mocks. Contains essential design guidelines, color & type tokens, fonts, assets, and a React UI kit replicating the app's visual language (HIG-compliant cards, score badges, AI indicators, ListingCard, dashboard layout).
user-invocable: true
---

Read the README.md file within this skill, and explore the other available files.

If creating visual artifacts (slides, mocks, throwaway prototypes, etc), copy assets out and create static HTML files for the user to view. The React UI kit lives in `ui_kits/ios_app/` and includes ready-made components (`ListingCard`, `ScoreBadge`, `AIIndicator`, `DashboardScreen`, `ListScreen`, `DetailScreen`).

If working on production SwiftUI code, you can read the rules in README.md to become an expert in designing with this brand. Key constraints:
- iOS 17+ baseline; iOS 26+ uses `.glassEffect` / Liquid Glass
- Tab bar is fixed: ダッシュボード / 中古 / 新築 / お気に入り / 設定
- AI-generated content ALWAYS gets the AI indicator (sparkles + "AI", indigo `#5856D6`)
- Score grades S/A/B/C/D have fixed colors — never recolor them
- Each of the 7 portals (SUUMO, HOME'S, リハウス, ノムコム, アットホーム, 住友不動産, 東急リバブル) has a fixed identification color

If the user invokes this skill without any other guidance, ask them what they want to build or design — common asks: a new screen for the iOS app, a slide explaining a feature, a marketing one-pager, a dashboard widget. Ask 3–5 clarifying questions, then act as an expert designer who outputs HTML artifacts _or_ production SwiftUI code, depending on the need.
