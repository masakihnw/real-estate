# Firebase セットアップ手順

いいね・メモを家族間で共有するために Firebase Firestore を使用しています。
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

## 3. Authentication（匿名認証）を有効化

1. Firebase Console → 左メニュー「Authentication」
2. 「始める」→「Sign-in method」タブ
3. 「匿名」を選択 → **有効にする** → 保存

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
  }
}
```

---

## 5. 動作確認

1. Xcode でビルド・実行
2. 物件を「いいね」またはメモを入力
3. 別の端末で同じアプリを起動 → 更新ボタンを押す
4. いいね・メモが共有されていることを確認

---

## トラブルシューティング

- **起動時にクラッシュする**: `GoogleService-Info.plist` がプレースホルダーのままの可能性。正しいファイルで上書きしてください。
- **いいねが共有されない**: Firebase Console → Authentication で匿名認証が有効か確認。Firestore のルールを確認。
- **`GoogleService-Info.plist` の BUNDLE_ID が違う**: plist 内の `BUNDLE_ID` が `com.hanawa.realestate.app` であることを確認。
