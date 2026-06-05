# real-estate-public

## Project Overview

Real estate search and analysis platform with iOS app, web scraping pipeline, and cloud backend.

## Stack

| Component | Tech |
|-----------|------|
| iOS App | Swift, SwiftUI, Xcode (`real-estate-ios/`) |
| Scraping | Python (`scraping-tool/`) |
| Backend | Firebase (Firestore, Storage), Supabase (migrating) |
| Infra | `firebase.json`, `firestore.rules`, `storage.rules` |
| Build | Xcode via `project.yml` (XcodeGen) |

## ECC Rules

- iOS app: Follow `~/.claude/rules/ecc/swift/`
- Scraping tools: Follow `~/.claude/rules/ecc/python/`

## Key Directories

```
real-estate-public/
├── real-estate-ios/       # Swift iOS app (SwiftUI)
├── scraping-tool/         # Python scrapers (suumo, athome, nomucom, etc.)
├── supabase/migrations/   # Supabase DB migrations
├── scripts/               # Migration scripts
├── configs/               # Scraping configs
└── data/                  # Scraped data output
```

## Commands

```bash
# iOS build
cd real-estate-ios && xcodebuild -scheme RealEstateApp -destination 'platform=iOS Simulator,name=iPhone 16'

# Run a scraper
cd scraping-tool && python suumo_scraper.py
```

## Rules

- Verify no Swift compilation errors after iOS changes
- Scraping tools must handle rate limiting and error recovery
- Never hardcode API keys; use environment variables
- Test scraper changes against a small dataset before full run
- 方針が固まったタイミングと実装が終わったタイミングの2回、コードレビュー（code-reviewer agent）を必ず実施する
- 実装中はこまめにユニットテストを書き、テストが通ることを確認しながら進める（省略禁止）