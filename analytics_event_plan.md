# Analytics Event Plan

## 初期導入済み

| Event | Trigger | Parameters |
| --- | --- | --- |
| `app_launch` | `didFinishLaunchingWithOptions` | none |
| `tab_view` | 初期タブ表示 / タブ切り替え | `tab_name`, `tab_index` |

## キャリアMVPで呼ぶ予定

| Event | Trigger | Parameters |
| --- | --- | --- |
| `career_list_view` | キャリア一覧表示 | none |
| `career_detail_view` | 求人詳細表示 | `job_id`, `company_id` |
| `career_save` | 求人保存 | `job_id`, `company_id` |
| `career_apply_click` | 応募ボタンタップ | `job_id`, `company_id` |

## 既存機能で次に足す予定

| Event | Trigger | Parameters |
| --- | --- | --- |
| `circle_list_view` | サークル一覧表示 | none |
| `circle_detail_view` | サークル詳細表示 | `circle_id` |

## 方針

- 個人名、メールアドレス、学籍番号などの個人情報は送らない。
- 企業向けレポートに使うため、キャリア系イベントは `job_id` と `company_id` を必ず揃える。
- 画面ごとの細かい操作を増やしすぎず、まずは閲覧・保存・応募クリックに絞る。
