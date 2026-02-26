# AGENTS.md

## Cursor Cloud specific instructions

### Repository overview

This is a monorepo with two products:

1. **scraping-tool/** — Python pipeline that scrapes Japanese real estate listings (SUUMO / HOME'S), enriches with commute times, hazard data, price predictions, and generates reports / Slack notifications.
2. **real-estate-ios/** — SwiftUI iOS app (requires macOS + Xcode 15+; cannot build on Linux).

On Linux cloud VMs, only the **scraping-tool** can be developed and tested.

### Running the scraping tool

```bash
cd scraping-tool
python3 main.py --source suumo --max-pages 1 -o /tmp/result.json
```

See `scraping-tool/README.md` for the full CLI reference and all script options.

### Running tests

```bash
cd scraping-tool
python3 -m pytest tests/ -v
```

3 tests in `test_validate_data.py` are known-failing (pre-existing `has_errors` attribute mismatch). The remaining 35 tests should pass.

### Generating reports

```bash
cd scraping-tool
python3 generate_report.py result.json -o report.md
```

### Key gotchas

- `~/.local/bin` must be on `PATH` for `pytest` and `playwright` CLI commands to work (`export PATH="$HOME/.local/bin:$PATH"`).
- Playwright Chromium must be installed after pip dependencies: `playwright install chromium --with-deps`.
- Optional environment variables (`SLACK_WEBHOOK_URL`, `REINFOLIB_API_KEY`, `ESTAT_API_KEY`, `SUMAI_USER`/`SUMAI_PASS`, `FIREBASE_SERVICE_ACCOUNT`) are gracefully skipped when unset; core scraping/report/test functionality works without them.
- The iOS app (`real-estate-ios/`) requires macOS + Xcode and cannot be built or tested on this Linux VM.
