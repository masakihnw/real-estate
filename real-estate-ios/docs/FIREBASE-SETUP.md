# Firebaseセットアップ手順

Firebaseは、アプリの次の機能に使っている。いいねとコメントはSupabaseに保存する（[REQUIREMENTS.md](REQUIREMENTS.md) を参照）。

| 機能 | 使うFirebaseサービス | 実装 |
|---|---|---|
| Googleログイン | Authentication | `AuthService.swift` |
| リモートプッシュ通知 | Cloud Messaging（FCM） | `PushNotificationService.swift` |
| 内見写真の家族間共有 | Storage（写真本体）とFirestore（`annotations` コレクションのメタデータ） | `PhotoSyncService.swift` |
| スクレイピングログの閲覧 | Firestore（`scraping_logs/latest`） | `ScrapingLogService.swift` |
| クラッシュ収集 | Crashlytics | `RealEstateAppApp.swift` |

過去にはFirestoreでいいねとメモを共有し、設定画面からFirestoreの `scraping_config` を編集していた。どちらもアプリから撤去済みである。現在の設定の正は Supabase の `scraping_config` である（[リファクタリング提案書](../../docs/refactor-proposals.md) のP1とP2を参照）。

プロジェクトは作成済みで、実際の `GoogleService-Info.plist` が `RealEstateApp/GoogleService-Info.plist` にコミットされている。以下の手順は、プロジェクトを作り直すときや、別のFirebaseプロジェクトに接続するときに使う。

---

## 1. Firebaseプロジェクトを作成する

1. [Firebase Console](https://console.firebase.google.com/) を開く。
2. 「プロジェクトを追加」をクリックする。
3. プロジェクト名を入力する（例: `real-estate-app`）。
4. Google Analyticsは不要なのでOFFにする。
5. 「プロジェクトを作成」をクリックする。

---

## 2. iOSアプリを追加する

1. Firebase Consoleのプロジェクトトップで「iOS」アイコンをクリックする。
2. バンドルIDに `com.hanawa.realestate.app` を入力する。
3. アプリのニックネームに `物件情報` を入力する（任意）。
4. 「アプリを登録」をクリックする。
5. `GoogleService-Info.plist` をダウンロードする。
6. ダウンロードしたplistで `RealEstateApp/GoogleService-Info.plist` を上書きする。

---

## 3. Authentication（Googleログイン）を有効にする

1. Firebase Consoleの左メニューで「Authentication」を開く。
2. 「始める」をクリックし、「Sign-in method」タブを開く。
3. 「Google」を選んで有効にする。
4. プロジェクトのサポートメールに自分のGmailを選んで保存する。

### GoogleService-Info.plistを再ダウンロードする（重要）

Googleログインを有効にすると、plistに `CLIENT_ID` と `REVERSED_CLIENT_ID` が加わる。有効にする前にダウンロードしたplistには、この2つがない。

1. Firebase Consoleのプロジェクト設定（歯車アイコン）で「全般」タブを開く。
2. 「マイアプリ」セクションで、iOSアプリの `GoogleService-Info.plist` を再ダウンロードする。
3. `RealEstateApp/GoogleService-Info.plist` を再度上書きする。

### URL Schemeを設定する（重要）

1. 再ダウンロードした `GoogleService-Info.plist` を開き、`REVERSED_CLIENT_ID` の値をコピーする（例: `com.googleusercontent.apps.481688023840-xxxxxxxxxxxx`）。
2. `RealEstateApp/Info.plist` を開く。`project.yml` が `Info.plist` を生成する構成なので、`project.yml` の `CFBundleURLTypes` にも同じ値を入れる。
3. `CFBundleURLTypes` の `CFBundleURLSchemes` の1つ目を、コピーした値に置き換える。2つ目の `realestate` は別の用途なので変えない。

### ログインを許可するアカウント

ログインできるのは、アプリバンドルに含めた `AllowedEmails.plist` に載っているアカウントだけである。ひな形は `RealEstateApp/AllowedEmails.sample.plist` で、`AllowedEmails.plist` にコピーして実際のアカウントを書く。このファイルは `.gitignore` の対象で、コミットしない。ファイルがないと、許可リストが空になって全アカウントが拒否される。

---

## 4. Firestore Databaseを作成する

1. Firebase Consoleの左メニューで「Firestore Database」を開く。
2. 「データベースを作成」をクリックする。
3. ロケーションは `asia-northeast1`（東京）を推奨する。
4. セキュリティルールは、まず「テストモードで開始」を選ぶ（30日間、read/writeが開放される）。
5. 「作成」をクリックする。

### セキュリティルール

テストモードの期限（30日）が切れる前に、リポジトリの `firestore.rules` をデプロイして置き換える。`firestore.rules` の内容は次のとおり。

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
      // GitHub Actions のサービスアカウント（Firebase Admin SDK）はルールの制約を受けない
      allow read, write: if request.auth != null;
    }
    match /scraping_logs/{docId} {
      // 認証済みユーザーは読み取り可能（iOS アプリからログ閲覧用）
      // 書き込みは GitHub Actions の Admin SDK のみ（ルールの制約を受けない）
      allow read: if request.auth != null;
    }
  }
}
```

`scraping_config` のルールは、設定画面から条件を編集していた時代の名残で、現在のアプリはこのコレクションを読み書きしない。`annotations` は内見写真のメタデータに使い、`scraping_logs` はスクレイピングログの閲覧に使う。ルール自体はリポジトリの `firestore.rules` が正で、この文書は内容を写しているだけである。

Storageのルールは `storage.rules` にある。内見写真は認証済みユーザーだけが読み書きでき、書き込みは10MB未満の画像に限る。

---

## 5. Cloud Messaging（FCM）を設定する

1. Apple Developer ConsoleでAPNs認証キー（.p8）を作成する。
2. Firebase ConsoleのCloud Messagingに、作成したAPNsキーをアップロードする。
3. Firebaseのサービスアカウントを作成し、そのJSONをGitHubリポジトリのシークレット `FIREBASE_SERVICE_ACCOUNT` に設定する。GitHub Actionsの `scraping-tool/scripts/send_push.py` がFCM HTTP v1 APIでトピック `new_listings` に送信する。

---

## 6. 動作確認

1. Xcodeでビルドして実行する。
2. Googleアカウントでログインする。
3. 物件詳細で内見写真を追加する。
4. 別の端末で同じアプリを起動し、同じGoogleアカウントでログインする。
5. 写真が共有されていることを確認する。いいねとコメントはSupabase経由で同期される。

---

## トラブルシューティング

- 起動時にクラッシュする: `GoogleService-Info.plist` が正しいファイルでない可能性がある。Firebase Consoleからダウンロードしたファイルで上書きする。
- 「Firebase Client IDが見つかりません」というエラーが出る: Googleログインを有効にした後で `GoogleService-Info.plist` を再ダウンロードしていない可能性がある。ステップ3の再ダウンロードを実行する。
- Googleログインが開かない、またはコールバックが戻らない: `Info.plist` のURL Schemeを確認する。正しい `REVERSED_CLIENT_ID` が設定されている必要がある。
- 写真が共有されない: Firebase ConsoleでFirestoreとStorageのルールを確認する。
- `GoogleService-Info.plist` の `BUNDLE_ID` が違う: plist内の `BUNDLE_ID` が `com.hanawa.realestate.app` であることを確認する。
