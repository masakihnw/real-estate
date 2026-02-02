# real-estate (public)

**本プロジェクトの正規リポジトリ**: [https://github.com/masakihnw/real-estate](https://github.com/masakihnw/real-estate)  
GitHub Actions（物件情報の定期取得・レポート・Slack 通知）はこのリポジトリのみで実行します。

10年住み替え前提で「インデックスに勝つ」ための中古マンション購入を検討するためのドキュメントとツール群。

## フォルダ構成

```
real-estate/
├── README.md           # 本ファイル
├── docs/               # ドキュメント
│   ├── 10year-index-mansion-conditions-draft.md   # 購入条件（ドラフト）
│   └── initial-consultation.md   # 初回相談メモ
└── scraping-tool/      # 条件を満たす物件を探すスクレイピングツール（検討・実装）
    ├── README.md
    └── docs/
        └── feasibility-study.md   # 実装可否の検討結果
```

## リンク

- **購入条件（ドラフト）**: [docs/10year-index-mansion-conditions-draft.md](docs/10year-index-mansion-conditions-draft.md)
- **スクレイピング実装可否検討**: [scraping-tool/docs/feasibility-study.md](scraping-tool/docs/feasibility-study.md)
- **スクレイピングツール**: [scraping-tool/README.md](scraping-tool/README.md)

## 定期更新

物件情報は GitHub Actions で自動更新されています（毎日朝8時 JST）。

- **最新レポート**: [scraping-tool/results/report/report.md](scraping-tool/results/report/report.md)（検索条件・物件一覧・差分を含む）
- **実行履歴**: GitHub Actions の [Actions タブ](https://github.com/masakihnw/real-estate/actions) で確認可能
