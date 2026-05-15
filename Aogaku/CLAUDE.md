# 青山ハック（Aogaku）

青山学院大学生向けiOSアプリ。Swift/UIKit + Firebase (Auth, Firestore) 構成。

---

## アーキテクチャ概要

| ファイル | 役割 |
|---|---|
| `CourseDetailViewController.swift` | 授業詳細シート。時間割・シラバス・保存一覧から共用。フラグで表示を切り替え |
| `AssignmentListViewController.swift` | 課題タブ。Moodle iCal連携。カレンダー/リスト表示切り替え機能あり |
| `FavoritesListViewControlle.swift` | ブックマーク一覧。Firestore から授業詳細を取得 |
| `FriendTimetableViewController.swift` | 友だちの時間割表示 |
| `SyllabusListViewController` (`syllabus.swift`) | シラバス検索・一覧 |
| `ScreenTracker.swift` | 画面滞在時間を Firestore `analytics_events` に記録するシングルトン |
| `AdsConfig.swift` | AdMob ON/OFF。`UserDefaults "ads_enabled"` で上書き可能 |
| `TimetableSettingsViewController.swift` | 時間割の表示設定（時限数・曜日） |
| `MoodleService.swift` | iCal取得・パース・キャッシュ |

---

## 直近のセッションでやった変更

### AssignmentListViewController
- `upcomingSections` の型を `(date: Date, dateStr: String, events: [MoodleEvent])` に変更（date追加）
- 通知デバッグメニュー（`#if DEBUG` ブロック）を削除
- セクションヘッダーの日付色を `moodleGreen` → `.label` に変更
- 当日セクションに「今日」緑バッジを追加
- **カレンダー表示モード追加**（左上ボタンでトグル）
  - `UICalendarView`（iOS 16+）をテーブルヘッダーに設置
  - 課題がある日付に緑ドット装飾
  - 日付タップで下のリストをフィルタリング
  - `UserDefaults "assignment.calendarMode"` で状態を永続化
  - `cellForRowAt` を `eventAt(_:)` 経由に統一（index out of range バグ修正済み）

### CourseDetailViewController
- シラバスキャッシュキーを `course.id` → `syllabusURL` に変更（同名授業のキャッシュ混入バグ修正）
- `showsSyllabusActions: Bool`・`syllabusDocID: String?` パラメータを追加
- 「時間割に追加」「ブックマーク」ボタンをスタック先頭（緑ヘッダーの直下）に挿入
- 追加フローを曜日時限ピッカーなしに簡略化（既存の `location` データを直接使用）

### FavoritesListViewController
- `FavoriteItem` に `syllabusURL / room / campus / category / term / credits` を追加
- `didSelectRowAt` を `SyllabusDetailViewController` → `CourseDetailViewController` に変更

### ScreenTracker
- バックグラウンド期間を計測から除外（`willResignActive` / `didBecomeActive` で開始時刻をずらす）
- 1時間超の duration を異常値として破棄

### TimetableSettingsViewController
- セグメントコントロールの選択時テキストを白に（`.selected` の `foregroundColor: .white`）
- `#if DEBUG` の広告トグル（UISwitch）を末尾に追加

### AdsConfig.swift
- `#if DEBUG` の `AdsDebugState` enum を追加（UserDefaults `"ads_enabled"` のトグル）
- `Notification.Name.adsEnabledDidChange` を追加

---

## 次にやろうとしていること

### 授業レビュー機能（新規）
- **前期**: データ収集のみ（非公開）。後期から一般公開予定
- **読む場所**: シラバスタブの `CourseDetailViewController`（`showsSyllabusActions: true` のとき）
- **書く場所**: 時間割タブの `CourseDetailViewController`（`showsAttendanceControls: true` のとき）
- `CourseDetailViewController` に `showsReview: Bool` フラグを追加する方針
- Firestore 構造案: `classes/{docID}/reviews/{uid}`（1ユーザー1レビューをドキュメントIDで保証）
- レビュー項目: 総合評価（★1〜5）・難易度・出席の厳しさ・一言コメント（150字）・受講学期
- 公開フラグ `isPublic: false` を持たせ、後期に一括 `true` に切り替える設計

---

## Firebase
- プロジェクト: `forta-aogaku`
- `analytics_events` コレクション: ScreenTracker が書き込む（screen / duration / userId / timestamp / hour / date）
- 広告は AdMob 連携済み。`AdsConfig.enabled` が各 VC の `setupAdBanner()` で参照される

## その他メモ
- Moodle: `agulms45.aim.aoyama.ac.jp`。Web Services は有効（`/webservice/rest/server.php` が応答）。ただし SSO 構成のためトークン取得の可否は未確認
- ミスコン投票UI（HTML モック）: `misscon_vote.html` を作成済み
