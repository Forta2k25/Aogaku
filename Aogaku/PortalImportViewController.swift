//
//  PortalImportViewController.swift
//  Aogaku
//
//  ポータル取り込みの手順を案内する画面。
//
//  ─ なぜ WKWebView でパスキーが使えないか ─
//  Apple の仕様で「Associated Domains」に登録していないドメインの
//  パスキーは WKWebView 内では使用不可。大学側サーバの設定変更が
//  必要なため現実的に対応不可 → Safari を使う方式に切り替え。
//
//  ─ フロー ─
//  1. このVCでブックマークレットをSafariに設定（初回のみ）
//  2. Safariでポータルにログイン（パスキーOK）
//  3. ブックマークレットをタップ
//  4. aogaku://import?d=... でアプリが起動
//  5. DeepLinkRouter がデータを受け取り時間割に保存
//

import UIKit

final class PortalImportViewController: UIViewController {

    // MARK: - Bookmarklet source (Safari 用 aogaku:// リダイレクト版)
    private static let bookmarkletJS: String = {
        // Safari で動くブックマークレット。
        // 1) my_rishuu.aspx から授業一覧を取得
        // 2) 各授業の詳細ページ(jugyou_kamoku)へ sequential postBack して
        //    Shousai.aspx URL（= portalSyllabusURL = FNを含む非公開URL）を取得
        // 3) aogaku://import?d=<base64> でアプリへ送信
        // ※ Action Extension 内の completionFunction と異なり、Safari の
        //    ブックマークレットは async/await + 複数 fetch が自由に使えるため
        //    ここで各授業分の postBack を行っても payload が壊れない。
        return """
javascript:(async()=>{const toast=Object.assign(document.createElement('div'),{style:'position:fixed;top:24px;left:50%;transform:translateX(-50%);background:#1c3d6e;color:white;padding:12px 24px;border-radius:10px;z-index:99999;font:600 14px -apple-system,sans-serif;max-width:80vw;text-align:center',textContent:'📚 取得中...'});document.body.appendChild(toast);try{const tx=e=>e?e.textContent.replace(/\\s+/g,' ').trim():'';const nd=s=>(s||'').replace(/[０-９]/g,c=>String.fromCharCode(c.charCodeAt(0)-0xFEE0));const di=d=>({月:0,火:1,水:2,木:3,金:4,土:5,日:6}[d]);const clean=s=>(s||'').replace(/^[青相]\\)\\s*/,'').replace(/\\s+/g,' ').trim();const hiddenFields=doc=>{const p=new URLSearchParams();const f=doc.querySelector('form');if(!f)return p;[...f.querySelectorAll('input')].forEach(i=>{if(!i.name)return;const t=(i.type||'').toLowerCase();if((t==='checkbox'||t==='radio')&&!i.checked)return;p.set(i.name,i.value||'');});return p;};const postBack=async(fromDoc,fromURL,target)=>{const p=hiddenFields(fromDoc);p.set('__EVENTTARGET',target);p.set('__EVENTARGUMENT','');const r=await fetch(fromURL,{method:'POST',credentials:'include',headers:{'Content-Type':'application/x-www-form-urlencoded'},body:p.toString()});return new DOMParser().parseFromString(await r.text(),'text/html');};const parseR=doc=>{const tbl=doc.querySelector('#cph_content_gvw_rishuu')||doc.querySelector('table.tbl-rishuu')||doc.querySelector('table[id*="gvw_rishuu" i]');const subs=[];if(!tbl)return{days:[],subjects:subs};[...tbl.querySelectorAll('tbody tr')].forEach(row=>{const code=tx(row.querySelector('[id*="lbl_touroku"]'))||tx(row.querySelector('.col1'));const time=tx(row.querySelector('[id*="lbl_jigen_name"]'))||tx(row.querySelector('.col2'));const link=row.querySelector('.col3 a[href*="__doPostBack"]')||row.querySelector('.col3 a[href^="javascript:"]');const href=link?(link.getAttribute('href')||''):'';const et=(href.match(/__doPostBack\\('([^']+)'/)|| [])[1]||'';const name=clean(tx(row.querySelector('[id*="lbt_Kamoku_Name_lbl"]'))||tx(row.querySelector('.col3 a'))||tx(row.querySelector('[id*="lbl_Kamoku_Name2"]'))||tx(row.querySelector('.col6')));const credit=parseInt(nd(tx(row.querySelector('[id*="lbl_each_tani"]'))||tx(row.querySelector('.col4'))),10)||null;const teacher=tx(row.querySelector('[id*="lbl_kyouin_name"]'))||tx(row.querySelector('.col5'));if(!name||!time)return;const sem=(time.match(/[（(](前期|後期|通年)[）)]/)||[])[1]||'';const campus=(time.match(/[［\\[]([^］\\]]+)[］\\]]/)||[])[1]||'';let m,re=/(月|火|水|木|金|土|日)\\s*[\\/／]\\s*(\\d+)/g,nt=nd(time);while((m=re.exec(nt))){subs.push({id:code,name,period:parseInt(m[2],10),dayIndex:di(m[1]),dayLabel:m[1],credits:credit,teacher,campus,semester:sem,status:'normal',source:'rishuu',_et:et});}});return{days:['月','火','水','木','金','土'],subjects:subs};};const base=location.href.replace(/[^\\/]+(\\?.*)?$/,'');let rishuuDoc,rishuuURL;if(location.href.includes('my_rishuu')){rishuuDoc=document;rishuuURL=location.href;}else{rishuuURL=base+'my_rishuu.aspx';const h=await fetch(rishuuURL,{credentials:'include'}).then(r=>r.text());rishuuDoc=new DOMParser().parseFromString(h,'text/html');}const res=parseR(rishuuDoc);if(!res.subjects.length)throw new Error('授業データが見つかりません');const uniqueETs=[...new Set(res.subjects.map(s=>s._et).filter(Boolean))];if(uniqueETs.length>0){toast.textContent=`📚 シラバスURLを取得中... (0/${uniqueETs.length})`;const urlMap={};let done=0;for(const et of uniqueETs){try{const dd=await postBack(rishuuDoc,rishuuURL,et);const a=dd.querySelector('a[href*="Shousai.aspx"]')||dd.querySelector('a[href*="/kouginaiyou/"]');if(a){try{urlMap[et]=new URL(a.getAttribute('href'),rishuuURL).href;}catch(e){}}}catch(e){}done++;toast.textContent=`📚 シラバスURLを取得中... (${done}/${uniqueETs.length})`;}res.subjects.forEach(s=>{if(s._et&&urlMap[s._et])s.portalSyllabusURL=urlMap[s._et];delete s._et;});}else{res.subjects.forEach(s=>delete s._et);}const data={subjects:res.subjects,days:res.days,username:tx(document.querySelector('[id*="lbl_gakusei_name"]'))};toast.textContent='📤 アプリに送信中...';const enc=btoa(unescape(encodeURIComponent(JSON.stringify(data)))).replace(/\\+/g,'-').replace(/\\//g,'_').replace(/=+$/,'');location.href='aogaku://import?d='+enc;}catch(e){toast.style.background='#c0392b';toast.textContent='❌ '+e.message;setTimeout(()=>toast.remove(),5000);}})();
"""
    }()

    // MARK: - UI

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "ポータルから取り込む"
        view.backgroundColor = .systemGroupedBackground
        navigationItem.leftBarButtonItem = UIBarButtonItem(
            barButtonSystemItem: .close, target: self, action: #selector(handleClose)
        )
        buildUI()
    }

    @objc private func handleClose() { dismiss(animated: true) }

    // MARK: - Build UI

    private func buildUI() {
        let scroll = UIScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            scroll.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])

        let stack = UIStackView()
        stack.axis = .vertical
        stack.spacing = 16
        stack.translatesAutoresizingMaskIntoConstraints = false
        scroll.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: scroll.topAnchor, constant: 20),
            stack.leadingAnchor.constraint(equalTo: scroll.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: scroll.trailingAnchor, constant: -16),
            stack.bottomAnchor.constraint(equalTo: scroll.bottomAnchor, constant: -40),
            stack.widthAnchor.constraint(equalTo: scroll.widthAnchor, constant: -32),
        ])

        // ── 説明 ──
        let header = makeLabel(
            "Safariを使って取り込む",
            font: .systemFont(ofSize: 20, weight: .bold),
            color: .label
        )

        let sub = makeLabel(
            "パスキー認証はSafari専用のため、\nアプリ内ブラウザでは動作しません。\n以下の手順で一度設定すれば、次回から数秒で取り込めます。",
            font: .systemFont(ofSize: 14),
            color: .secondaryLabel
        )

        stack.addArrangedSubview(header)
        stack.addArrangedSubview(sub)
        stack.setCustomSpacing(24, after: sub)

        // ── STEP 1 ──
        stack.addArrangedSubview(makeStepCard(
            step: "STEP 1",
            title: "ブックマークレットをコピー",
            body: "下のボタンをタップしてJavaScriptコードをコピーします。",
            actionTitle: "コードをコピー",
            action: #selector(copyBookmarklet)
        ))

        // ── STEP 2 ──
        stack.addArrangedSubview(makeStepCard(
            step: "STEP 2",
            title: "Safariにブックマークとして保存",
            body: """
            ① Safariで任意のページを開き ⎙ → ブックマーク追加
            ② 保存後、ブックマーク一覧でいま追加したものを「編集」
            ③ タイトルを「📚 AGU 取り込み」に変更
            ④ URLの欄をすべて消してコピーしたコードを貼り付け → 完了
            """,
            actionTitle: nil,
            action: nil
        ))

        // ── STEP 3 ──
        stack.addArrangedSubview(makeStepCard(
            step: "STEP 3",
            title: "ポータルでブックマークをタップ",
            body: "Safariでポータルにログインし、ブックマークバーの「📚 AGU 取り込み」をタップするとAogakuが自動で起動します。",
            actionTitle: "Safariでポータルを開く",
            action: #selector(openPortalInSafari)
        ))

        // ── 注記 ──
        let note = makeLabel(
            "※ 設定は初回のみ。次回からはSafariでポータルを開いてブックマークをタップするだけです。",
            font: .systemFont(ofSize: 12),
            color: .tertiaryLabel
        )
        stack.addArrangedSubview(note)
    }

    // MARK: - Actions

    @objc private func copyBookmarklet() {
        UIPasteboard.general.string = Self.bookmarkletJS
        let alert = UIAlertController(
            title: "コピーしました ✓",
            message: "次はSafariのブックマーク編集画面でURLに貼り付けてください。",
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        present(alert, animated: true)
    }

    @objc private func openPortalInSafari() {
        guard let url = URL(string: "https://aguinfo.jm.aoyama.ac.jp/AGUInfo/jikanwari.aspx") else { return }
        UIApplication.shared.open(url)
    }

    // MARK: - Helpers

    private func makeLabel(_ text: String,
                            font: UIFont,
                            color: UIColor) -> UILabel {
        let l = UILabel()
        l.text = text
        l.font = font
        l.textColor = color
        l.numberOfLines = 0
        return l
    }

    private func makeStepCard(step: String,
                               title: String,
                               body: String,
                               actionTitle: String?,
                               action: Selector?) -> UIView {
        let card = UIView()
        card.backgroundColor = .secondarySystemGroupedBackground
        card.layer.cornerRadius = 12
        card.layer.cornerCurve = .continuous

        let stepLbl = UILabel()
        stepLbl.text = step
        stepLbl.font = .systemFont(ofSize: 11, weight: .bold)
        stepLbl.textColor = .systemBlue

        let titleLbl = UILabel()
        titleLbl.text = title
        titleLbl.font = .systemFont(ofSize: 15, weight: .semibold)
        titleLbl.textColor = .label
        titleLbl.numberOfLines = 0

        let bodyLbl = UILabel()
        bodyLbl.text = body
        bodyLbl.font = .systemFont(ofSize: 13)
        bodyLbl.textColor = .secondaryLabel
        bodyLbl.numberOfLines = 0

        let inner = UIStackView(arrangedSubviews: [stepLbl, titleLbl, bodyLbl])
        inner.axis = .vertical
        inner.spacing = 6
        inner.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(inner)

        var bottomAnchor = inner.bottomAnchor

        if let actionTitle, let action {
            let btn = UIButton(type: .system)
            var cfg = UIButton.Configuration.filled()
            cfg.title = actionTitle
            cfg.cornerStyle = .capsule
            cfg.baseForegroundColor = .white
            cfg.baseBackgroundColor = .systemBlue
            cfg.contentInsets = .init(top: 9, leading: 20, bottom: 9, trailing: 20)
            cfg.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { a in
                var b = a; b.font = UIFont.systemFont(ofSize: 14, weight: .semibold); return b
            }
            btn.configuration = cfg
            btn.addTarget(self, action: action, for: .touchUpInside)
            btn.translatesAutoresizingMaskIntoConstraints = false
            card.addSubview(btn)
            NSLayoutConstraint.activate([
                btn.topAnchor.constraint(equalTo: inner.bottomAnchor, constant: 12),
                btn.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 16),
                btn.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -16),
            ])
            bottomAnchor = card.bottomAnchor
            _ = bottomAnchor
        }

        NSLayoutConstraint.activate([
            inner.topAnchor.constraint(equalTo: card.topAnchor, constant: 16),
            inner.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 16),
            inner.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -16),
        ])
        if actionTitle == nil {
            inner.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -16).isActive = true
        }

        return card
    }
}
