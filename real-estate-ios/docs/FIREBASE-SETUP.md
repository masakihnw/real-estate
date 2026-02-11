# Firebase セットアップ手順

いいね・メモを家族間で共有するために Firebase Firestore を使用しています。
認証方式は **Google アカウントログイン** です。
以下の手順で Firebase プロジェクトを作成し、アプリと接続してください。

---

## 1. Firebase プロジェクト作成

1. [Firebase Console](https://console.firebase.google.com/) にアクセス
2. 「プロジェクトを追加」をクリック
3. プロジェクト名を入力（例: `real-estate-app`）
4. Google Analytics は不要（OFF でOK）
5. 「プロジェクトを作成」

---

## 2. iOS アプリを追加

1. Firebase Console のプロジェクトトップ → 「iOS」アイコンをクリック
2. **バンドルID**: `com.hanawa.realestate.app`
3. アプリのニックネーム: `物件情報`（任意）
4. 「アプリを登録」
5. **`GoogleService-Info.plist` をダウンロード**
6. ダウンロードした plist で `RealEstateApp/GoogleService-Info.plist`（プレースホルダー）を**上書き**

---

## 3. Authentication（Google ログイン）を有効化

1. Firebase Console → 左メニュー「Authentication」
2. 「始める」→「Sign-in method」タブ
3. 「Google」を選択 → **有効にする**
4. プロジェクトのサポートメール（自分の Gmail）を選択 → 保存

### GoogleService-Info.plist の再ダウンロード（重要）

Google ログインを有効化すると、plist に `CLIENT_ID` と `REVERSED_CLIENT_ID` が追加されます。

1. Firebase Console → プロジェクト設定（⚙） → 「全般」タブ
2. 「マイアプリ」セクション → iOS アプリの `GoogleService-Info.plist` を**再ダウンロード**
3. `RealEstateApp/GoogleService-Info.plist` を再度上書き

### URL Scheme の設定（重要）

1. 再ダウンロードした `GoogleService-Info.plist` を開く
2. `REVERSED_CLIENT_ID` の値をコピー（例: `com.googleusercontent.apps.481688023840-xxxxxxxxxxxx`）
3. `RealEstateApp/Info.plist` を開く
4. `CFBundleURLTypes` → `CFBundleURLSchemes` の `REPLACE_WITH_REVERSED_CLIENT_ID` を、コピーした値に**置換**

---

## 4. Firestore Database を作成

1. Firebase Console → 左メニュー「Firestore Database」
2. 「データベースを作成」
3. **ロケーション**: `asia-northeast1`（東京）推奨
4. **セキュリティルール**: 「テストモードで開始」を選択（30日間 read/write 開放）
5. 「作成」

### セキュリティルール（テストモード終了後に設定）

テストモードの30日期限が切れる前に、以下のルールに変更してください:

```
rules_version = '2';
service cloud.firestore {
  match /databases/{database}/documents {
    match /annotations/{docId} {
      // 認証済みユーザーのみ読み書き可能
      allow read, write: if request.auth != null;
    }
    match /scraping_config/{docId} {
      // 認証済みユーザーのみ読み書き可能（設定画面からのスクレイピング条件編集用）
      // GitHub Actions のサービスアカウントは読み取りのみ必要
      allow read, write: if request.auth != null;
    }
  }
}
```

**スクレイピング条件**: `scraping_config/default` に価格・専有面積・築年などの条件を保存します。設定画面で編集すると、次回の GitHub Actions 実行時にスクレイピングツールが読み込みます。Firebase Admin SDK（Python）はサービスアカウントで認証され、Firestore ルールの制約を受けないため、上記ルールで問題ありません。

---

## 5. 動作確認

1. Xcode でビルド・実行
2. Google アカウントでログイン
3. 物件を「いいね」またはメモを入力
4. 別の端末で同じアプリを起動 → 同じ Google アカウントでログイン
5. いいね・メモが共有されていることを確認

---

## トラブルシューティング

- **起動時にクラッシュする**: `GoogleService-Info.plist` がプレースホルダーのままの可能性。正しいファイルで上書きしてください。
- **「Firebase Client ID が見つかりません」エラー**: Google ログインを有効化した後に GoogleService-Info.plist を再ダウンロードしていない可能性。ステップ3の「再ダウンロード」を実行してください。
- **Google ログインが開かない / コールバックが戻らない**: Info.plist の URL Scheme に正しい `REVERSED_CLIENT_ID` が設定されているか確認してください。
- **いいねが共有されない**: Firebase Console → Firestore のルールを確認。
- **`GoogleService-Info.plist` の BUNDLE_ID が違う**: plist 内の `BUNDLE_ID` が `com.hanawa.realestate.app` であることを確認。
