// Action.js
// Safari の AGU ポータルページから時間割データを抽出して
// Swift の ActionViewController に渡す。
// ・jikanwari.aspx 上で実行 → ページを直接スクレイプ
// ・それ以外のページ（message_list.aspx など）→ fetch() で jikanwari.aspx を取得してスクレイプ

var Action = function() {};

Action.prototype = {

    run: function(parameters) {

        // ─── ヘルパー ───────────────────────────────────────────────
        var tx = function(el) { return el ? el.textContent.replace(/\s+/g, ' ').trim() : ''; };
        var isDayLabel = function(text) {
            return /^(月|火|水|木|金|土|日)(曜|曜日)?$/.test((text || '').trim());
        };
        var dayLabelFromText = function(text) {
            var t = (text || '').replace(/\s+/g, '');
            var m = t.match(/[（(](月|火|水|木|金|土|日)(?:曜|曜日)?[）)]/);
            if (m) return m[1];
            m = t.match(/^(月|火|水|木|金|土|日)(?:曜|曜日)?$/);
            return m ? m[1] : '';
        };
        var cleanSubjectName = function(text) {
            return (text || '')
                .replace(/^[青相]\)\s*/, '')
                .replace(/\s+/g, ' ')
                .trim();
        };
        var normalizeDigits = function(text) {
            return (text || '').replace(/[０-９]/g, function(ch) {
                return String.fromCharCode(ch.charCodeAt(0) - 0xFEE0);
            });
        };
        var dayIndexFor = function(day) {
            return { '月': 0, '火': 1, '水': 2, '木': 3, '金': 4, '土': 5, '日': 6 }[day];
        };
        var publicSyllabusBQ = '3f5e5d46524048535c48584c4959336c647d22233127225448512b3e2e296c6f54714344415772021a1d495f401d180a02055e5d5f7b534f4c1f6564796b7b7114001004110803091c746c14131b070a0702061200101112161c081a08120c62542350205423205e4e2b3f562e385f493b264f553f384b513330475d3f2d4f42efefa4c0d4b1bbe8e6afcdc9bdcfd1bfadb7d5d8d6a8b0d3d4a4f0fabacecaa286f1e59e969d80f7eb949f989a8bfee68d8384';
        var absoluteURL = function(url, baseHint) {
            // baseHint: 文字列URL か Document。
            // DOMParser 生成ドキュメントは doc.URL = 'about:blank' になるため
            // 文字列ベースURLを優先し、Document は URL が有効なときだけ使う。
            if (!url) return '';
            var base = (typeof baseHint === 'string' && baseHint && baseHint !== 'about:blank')
                ? baseHint
                : ((baseHint && typeof baseHint === 'object'
                        && baseHint.URL && baseHint.URL !== 'about:blank')
                    ? baseHint.URL
                    : window.location.href);
            try {
                return new URL(url, base).href;
            } catch(e) {
                return url;
            }
        };
        var normalizeSyllabusURL = function(url, baseHint) {
            var absolute = absoluteURL(url, baseHint);
            if (!absolute) return '';
            try {
                var u = new URL(absolute);
                if (u.pathname.indexOf('/kouginaiyou/Shousai.aspx') >= 0) {
                    var fn = u.searchParams.get('FN');
                    var yr = u.searchParams.get('YR');
                    if (!fn || !yr) return absolute;
                    var out = new URL('https://syllabus.aoyama.ac.jp/shousai.ashx');
                    out.searchParams.set('YR', yr);
                    out.searchParams.set('FN', fn);
                    out.searchParams.set('KW', '');
                    out.searchParams.set('BQ', publicSyllabusBQ);
                    return out.href;
                }
                return absolute;
            } catch(e) {
                return absolute;
            }
        };
        var hiddenFormFields = function(doc) {
            var params = new URLSearchParams();
            var form = doc.querySelector('form');
            if (!form) return params;
            Array.prototype.forEach.call(form.querySelectorAll('input'), function(input) {
                var name = input.name;
                if (!name) return;
                var type = (input.type || '').toLowerCase();
                if ((type === 'checkbox' || type === 'radio') && !input.checked) return;
                params.set(name, input.value || '');
            });
            return params;
        };
        var postBack = function(doc, url, target) {
            var params = hiddenFormFields(doc);
            params.set('__EVENTTARGET', target || '');
            params.set('__EVENTARGUMENT', '');
            return fetch(url, {
                method: 'POST',
                credentials: 'include',
                headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
                body: params.toString()
            }).then(function(resp) {
                if (!resp.ok) throw new Error('HTTP ' + resp.status);
                return resp.text();
            }).then(function(html) {
                return new DOMParser().parseFromString(html, 'text/html');
            });
        };
        var parsePortalSyllabusFields = function(doc) {
            var data = {};
            var lectureItems = [];
            var evalItems = [];
            var clean = function(s) { return (s || '').trim().replace(/[\s\u3000\n\r]+/g, ''); };
            var cleanVal = function(s) { return (s || '').trim().replace(/[ \t\u3000]+\n/g, '\n').replace(/\n{3,}/g, '\n\n'); };
            var cleanLine = function(s) { return (s || '').replace(/[\s\u3000\n\r]+/g, ' ').trim(); };
            var isNum = function(s) { return /^\d+$/.test((s || '').trim()); };

            var numEls = Array.prototype.slice.call(doc.querySelectorAll('[id*="gvKeikaku_lblSQ_NO_"]'));
            var contentEls = Array.prototype.slice.call(doc.querySelectorAll('[id*="gvKeikaku_lblKeikaku_"]'));
            var rowIdx = function(el) {
                var m = el.id.match(/\d+$/);
                return m ? parseInt(m[0], 10) : 0;
            };
            numEls.sort(function(a,b){ return rowIdx(a) - rowIdx(b); });
            contentEls.sort(function(a,b){ return rowIdx(a) - rowIdx(b); });
            for (var i = 0; i < Math.min(numEls.length, contentEls.length); i++) {
                var num = tx(numEls[i]);
                var content = cleanLine(contentEls[i].innerText || contentEls[i].textContent || '');
                if (num && content) lectureItems.push(num + '. ' + content);
            }

            Array.prototype.forEach.call(doc.querySelectorAll('table.table-seiseki tr'), function(row) {
                var c1 = row.querySelector('td.col1');
                var c2 = row.querySelector('td.col2');
                var c3 = row.querySelector('td.col3');
                var c4 = row.querySelector('td.col4');
                if (!c1 || !c2 || !c3 || !isNum(tx(c1))) return;
                var nm = cleanLine(c2.innerText || c2.textContent || '');
                var pct = tx(c3);
                var desc = c4 ? cleanLine(c4.innerText || c4.textContent || '') : '';
                if (nm && pct.indexOf('%') >= 0) evalItems.push(nm + '\t' + pct + '\t' + desc);
            });

            Array.prototype.forEach.call(doc.querySelectorAll('table tr'), function(row) {
                if (row.closest && (row.closest('table.keikakuDetail') || row.closest('table.table-seiseki'))) return;
                var ths = row.querySelectorAll('th');
                var tds = row.querySelectorAll('td');
                if (ths.length > 0 && tds.length > 0) {
                    var k = clean(ths[0].innerText || ths[0].textContent || '');
                    var v = cleanVal(tds[0].innerText || tds[0].textContent || '');
                    if (k && v && v !== k && k.length < 30) data[k] = v;
                    return;
                }
                if (tds.length < 2) return;
                var t0 = (tds[0].innerText || tds[0].textContent || '').trim();
                var t1 = (tds[1].innerText || tds[1].textContent || '').trim();
                var t2 = tds.length >= 3 ? (tds[2].innerText || tds[2].textContent || '').trim() : '';
                var t3 = tds.length >= 4 ? (tds[3].innerText || tds[3].textContent || '').trim() : '';
                if (isNum(t0) && tds.length >= 3) {
                    if (lectureItems.length === 0 && (t1.indexOf('授業計画') >= 0 || t1.indexOf('Lecture') >= 0 || t1.indexOf('Class') >= 0)) {
                        if (t2) lectureItems.push(t0 + '. ' + cleanLine(t2));
                    } else if (t2.indexOf('%') >= 0 && evalItems.length === 0) {
                        evalItems.push(cleanLine(t1) + '\t' + t2 + '\t' + cleanLine(t3));
                    } else if (t3.indexOf('%') >= 0 && evalItems.length === 0) {
                        evalItems.push(cleanLine(t1) + '\t' + t3 + '\t' + cleanLine(t2));
                    }
                } else {
                    var key = clean(t0);
                    var val = cleanVal(t1);
                    if (key && val && key !== val && key.length < 30 && !data[key]) data[key] = val;
                }
            });

            if (lectureItems.length) data['授業計画'] = lectureItems.join('\n');
            if (evalItems.length) data['成績評価'] = evalItems.join('\n');
            Array.prototype.forEach.call(doc.querySelectorAll('dt'), function(dt) {
                var dd = dt.nextElementSibling;
                if (dd && dd.tagName === 'DD') {
                    var k = clean(dt.innerText || dt.textContent || '');
                    var v = cleanVal(dd.innerText || dd.textContent || '');
                    if (k && v) data[k] = v;
                }
            });

            Array.prototype.forEach.call(doc.querySelectorAll('table.editTable tr'), function(row) {
                var th = row.querySelector('th');
                var td = row.querySelector('td');
                if (!th || !td) return;
                var k = (th.textContent || '').replace(/[\s\u3000\n\r\/]+/g, '');
                var v = (td.textContent || '').trim();
                if (!v) return;
                if (!data['__年度'] && k.indexOf('年度') >= 0) data['__年度'] = v;
                if (!data['__授業科目名'] && k.indexOf('授業科目名') >= 0) data['__授業科目名'] = v;
                if (!data['__教員名'] && k.indexOf('教員名') >= 0 && k.indexOf('英文') < 0) data['__教員名'] = v;
            });
            var gakkiRow = doc.getElementById('CPH1_trGakki');
            if (gakkiRow) {
                var gs = gakkiRow.querySelectorAll('td');
                if (gs.length >= 2) {
                    data['__学期'] = tx(gs[0]);
                    data['__単位'] = tx(gs[1]);
                }
            }
            var gaiyou = doc.getElementById('CPH1_lblGaiyou');
            if (gaiyou) data['__講義概要'] = (gaiyou.textContent || '').trim();
            var moku = doc.getElementById('CPH1_lblMokuhyou');
            if (moku) data['__達成目標'] = (moku.innerText || moku.textContent || '').trim();
            var jouken = doc.getElementById('CPH1_lblJouken');
            if (jouken) data['__履修条件'] = (jouken.textContent || '').trim();
            return data;
        };
        var parseCourseInfoPage = function(doc, baseURL) {
            // baseURL: fetch 元の URL 文字列。DOMParser ドキュメントでは doc.URL = 'about:blank' に
            // なるため、ルート相対パスを正しく絶対化するために明示的に渡す。
            var base = baseURL || doc;
            var detailLink = doc.querySelector('#cph_content_dtg_kougi a[href*="Shousai.aspx"]')
                          || doc.querySelector('a[href*="/kouginaiyou/Shousai.aspx"]')
                          || doc.querySelector('a[href*="Shousai.aspx"]');
            // 開講学部・学科（科目区分）の取得：ポータル詳細ページの各種 ID パターンを試みる
            var kaikouEl = doc.querySelector('[id*="lbl_kaikou"]')
                        || doc.querySelector('[id*="lblKaikou"]')
                        || doc.querySelector('[id*="lbl_kamoku_bunsho"]')
                        || doc.querySelector('[id*="lbl_kbn"]');
            var kaikou = kaikouEl ? tx(kaikouEl) : '';
            // FN コードからも取れるが、テキストが取れた場合はそちらを優先
            if (!kaikou && detailLink) {
                // シラバスリンクが直接含む場合（anchor テキストなど）は FN コードを別途使用しない
                // — Swift 側 categoryFromFNCode() が URL から自動解決するため JS では不要
            }
            return {
                room: tx(doc.querySelector('[id*="lbl_jikanwari_room"]')),
                detailURL: detailLink ? normalizeSyllabusURL(detailLink.getAttribute('href'), base) : '',
                kaikou: kaikou
            };
        };
        var extractCourseInfoSubject = function(doc) {
            var table = doc.querySelector('#cph_content_gvw_class')
                    || doc.querySelector('table[id*="gvw_class" i]');
            var detail = parseCourseInfoPage(doc);
            if (!table || !detail.detailURL) return { days: [], subjects: [] };

            var row = table.querySelector('tbody tr');
            if (!row) return { days: [], subjects: [] };

            var timeText = tx(row.querySelector('[id*="lbl_youbi_jigen"]')) || tx(row.querySelector('[data-label="曜日時限"]'));
            var normalizedTime = normalizeDigits(timeText);
            var m = normalizedTime.match(/(月|火|水|木|金|土|日)\s*[\/／]\s*(\d+)/);
            if (!m) return { days: [], subjects: [] };

            var day = m[1];
            var period = parseInt(m[2], 10);
            var semesterMatch = timeText.match(/[（(](前期|後期|通年)[）)]/);
            var campusMatch = timeText.match(/[［\[]([^］\]]+)[］\]]/);
            var creditText = normalizeDigits(tx(row.querySelector('[id*="lbl_tani"]')) || tx(row.querySelector('[data-label="単位"]')));
            var subject = {
                id: tx(row.querySelector('[id*="lbl_touroku_no"]')) || '',
                name: cleanSubjectName(tx(row.querySelector('[id*="lbl_kamoku_name"]')) || tx(row.querySelector('[data-label="科目名"]'))),
                period: period,
                dayIndex: dayIndexFor(day),
                dayLabel: day,
                teacher: tx(row.querySelector('[id*="lbl_kyouin_name"]')) || tx(row.querySelector('[data-label="教員名"]')),
                room: detail.room || tx(row.querySelector('[id*="lbl_jikanwari_room"]')) || tx(row.querySelector('[data-label="教室"]')),
                credits: parseInt(creditText, 10),
                campus: campusMatch ? campusMatch[1] : '',
                semester: semesterMatch ? semesterMatch[1] : '',
                status: 'normal',
                source: 'jugyou_kamoku',
                portalSyllabusURL: detail.detailURL
            };
            if (isNaN(subject.credits)) delete subject.credits;
            if (!subject.name) return { days: [], subjects: [] };
            return { days: ['月', '火', '水', '木', '金', '土'], subjects: [subject] };
        };
        // onProgress(done, total) は各 postBack 完了後に呼ばれる任意コールバック
        var enrichSubjectsWithPortalDetails = function(subjects, listDoc, listURL, onProgress) {
            // 同一 eventTarget を持つ科目（例：月3・水5 の同一科目）をまとめて1回だけ postBack する
            var etSeen = {};
            var uniqueTargets = [];
            subjects.forEach(function(s) {
                if (s.eventTarget && !etSeen[s.eventTarget]) {
                    etSeen[s.eventTarget] = true;
                    uniqueTargets.push(s.eventTarget);
                }
            });
            var cursor = 0;
            // iOS の JS コンテキストが強制終了される前に確実に処理を抜けるための時間予算。
            // 1科目あたりおよそ1〜2秒かかるため、20科目でも余裕を持って完了できる値にする。
            var deadline = Date.now() + 30000;
            var worker = function() {
                if (cursor >= uniqueTargets.length) return Promise.resolve();
                if (Date.now() >= deadline) return Promise.resolve(); // 時間切れ → 取得済みで終了
                var et = uniqueTargets[cursor++];
                return postBack(listDoc, listURL, et)
                    .then(function(infoDoc) {
                        var info = parseCourseInfoPage(infoDoc, listURL);
                        // 同じ eventTarget を持つ全エントリに結果を反映
                        subjects.forEach(function(s) {
                            if (s.eventTarget !== et) return;
                            if (info.room) s.room = info.room;
                            if (info.detailURL) s.portalSyllabusURL = info.detailURL;
                            if (info.kaikou) s.category = info.kaikou;  // 開講学部・学科
                        });
                    })
                    .catch(function(e) {
                        subjects.forEach(function(s) {
                            if (s.eventTarget === et) s.detailError = e.message || String(e);
                        });
                    })
                    .then(function() {
                        if (onProgress) onProgress(cursor, uniqueTargets.length);
                        return worker();
                    });
            };
            // 詳細本文は取得しない。授業科目情報ページから教室と詳細URLだけ拾う。
            // 並列数は1にして、Safari Action の property-list 返却を安定させる。
            return worker().then(function() { return subjects; });
        };

        // 履修科目一覧から恒常的な曜日時限を解析する。
        // 祝日・休講週でも表示が欠けないので、時間割表よりこちらを優先する。
        var extractRegisteredCourses = function(doc) {
            var table = doc.querySelector('#cph_content_gvw_rishuu')
                    || doc.querySelector('table.tbl-rishuu')
                    || doc.querySelector('table[id*="gvw_rishuu" i]');
            var subjects = [];
            if (!table) { return { days: [], subjects: subjects }; }

            var rows = table.querySelectorAll('tbody tr');
            for (var r = 0; r < rows.length; r++) {
                var row = rows[r];
                var code = tx(row.querySelector('[id*="lbl_touroku"]')) || tx(row.querySelector('.col1'));
                var link = row.querySelector('.col3 a[href*="__doPostBack"]') || row.querySelector('.col3 a[href^="javascript:"]');
                var href = link ? (link.getAttribute('href') || '') : '';
                var eventTargetMatch = href.match(/__doPostBack\('([^']+)'/);
                var timeText = tx(row.querySelector('[id*="lbl_jigen_name"]')) || tx(row.querySelector('.col2'));
                var name = cleanSubjectName(tx(row.querySelector('[id*="lbt_Kamoku_Name_lbl"]')) ||
                                            tx(row.querySelector('.col3 a')) ||
                                            tx(row.querySelector('[id*="lbl_Kamoku_Name2"]')) ||
                                            tx(row.querySelector('.col6')));
                var creditText = normalizeDigits(tx(row.querySelector('[id*="lbl_each_tani"]')) || tx(row.querySelector('.col4')));
                var teacher = tx(row.querySelector('[id*="lbl_kyouin_name"]')) || tx(row.querySelector('.col5'));
                if (!name || !timeText) continue;

                var semesterMatch = timeText.match(/[（(](前期|後期|通年)[）)]/);
                var semester = semesterMatch ? semesterMatch[1] : '';
                var campusMatch = timeText.match(/[［\[]([^］\]]+)[］\]]/);
                var campus = campusMatch ? campusMatch[1] : '';
                var normalizedTime = normalizeDigits(timeText);
                var re = /(月|火|水|木|金|土|日)\s*[\/／]\s*(\d+)/g;
                var m;
                while ((m = re.exec(normalizedTime)) !== null) {
                    var day = m[1];
                    var period = parseInt(m[2], 10);
                    if (!period) continue;
                    var subject = {
                        id: code,
                        name: name,
                        period: period,
                        dayIndex: dayIndexFor(day),
                        dayLabel: day,
                        teacher: teacher,
                        campus: campus,
                        semester: semester,
                        status: 'normal',
                        source: 'rishuu',
                        eventTarget: eventTargetMatch ? eventTargetMatch[1] : ''
                    };
                    var credits = parseInt(creditText, 10);
                    if (!isNaN(credits)) subject.credits = credits;
                    subjects.push(subject);
                }
            }
            return { days: ['月', '火', '水', '木', '金', '土'], subjects: subjects };
        };

        // doc から時間割テーブルを解析して { days, subjects } を返す
        var extractTimetable = function(doc) {
            var tbl = doc.querySelector('table.jikanwari')
                   || doc.querySelector('table[id*="jikanwari" i]')
                   || doc.querySelector('table[class*="jikanwari" i]')
                   || (function() {
                          var tables = doc.querySelectorAll('table');
                          for (var i = 0; i < tables.length; i++) {
                              var text = tx(tables[i]);
                              var hasPortalLink = tables[i].querySelector('a[href*="doPostBack"]') ||
                                                  tables[i].querySelector('a[onclick*="doPostBack"]') ||
                                                  tables[i].querySelector('a[href*="__doPostBack"]') ||
                                                  tables[i].querySelector('a[onclick*="__doPostBack"]');
                              var hasTimetableWords = /月.*火.*水.*木.*金/.test(text) ||
                                                      /時限|校時|時間割/.test(text);
                              if (hasPortalLink || hasTimetableWords) {
                                  return tables[i];
                              }
                          }
                          return null;
                      })();

            var days = [];
            var subjects = [];

            if (!tbl) { return { days: days, subjects: subjects }; }

            // 曜日ヘッダー（thead が無い ASP.NET table もあるので全 tr から探す）
            var rowsAll = Array.prototype.slice.call(tbl.querySelectorAll('tr'));
            for (var hr = 0; hr < rowsAll.length && days.length === 0; hr++) {
                var headerCells = rowsAll[hr].querySelectorAll('th, td');
                var found = [];
                for (var h = 0; h < headerCells.length; h++) {
                    var label = dayLabelFromText(tx(headerCells[h]));
                    if (label) found.push(label);
                }
                if (found.length >= 3) days = found;
            }

            // 授業行
            var rows = tbl.querySelectorAll('tbody tr');
            if (!rows.length) rows = rowsAll;
            for (var r = 0; r < rows.length; r++) {
                var cells = rows[r].querySelectorAll('th, td');
                if (!cells.length) continue;

                var periodStr = tx(cells[0]).replace(/\D/g, '');
                var period = parseInt(periodStr);
                if (isNaN(period)) continue;

                for (var c = 1; c < cells.length; c++) {
                    var td = cells[c];
                    var a = td.querySelector('a');

                    var name = cleanSubjectName(a ? tx(a) : tx(td));
                    if (!name) continue;
                    if (isDayLabel(name) || /^(時限|校時|\d+\s*(時限|校時)?)$/.test(name)) continue;

                    var src = a ? ((a.getAttribute('href') || '') + (a.getAttribute('onclick') || '')) : '';
                    var m = src.match(/__doPostBack\('([^']+)'/);
                    var cl = td.className || '';

                    subjects.push({
                        name:        name,
                        period:      period,
                        dayIndex:    c - 1,
                        dayLabel:    days[c - 1] || '',
                        status:      cl.indexOf('roomhenkou') >= 0 ? 'room-change' :
                                     cl.indexOf('kyuukou')    >= 0 ? 'cancelled'   : 'normal',
                        eventTarget: m ? m[1] : ''
                    });
                }
            }

            return { days: days, subjects: subjects };
        };

        // 現在のページの学生情報（どのページにも表示されている）
        var username   = tx(document.querySelector('[id*="lbl_gakusei_name"]'));
        var department = tx(document.querySelector('[id*="lbl_sanbuka"]'));
        var completeWith = function(result, docForUser) {
            var payload = {
                subjects:   result.subjects,
                days:       result.days,
                username:   username   || tx((docForUser || document).querySelector('[id*="lbl_gakusei_name"]')),
                department: department || tx((docForUser || document).querySelector('[id*="lbl_sanbuka"]'))
            };
            parameters.completionFunction({ payloadJSON: JSON.stringify(payload) });
        };
        // URL-scheme 経由でアプリにデータを送る。
        // completionFunction のタイムアウト制約を受けないため、
        // sequential postBack 後のデータ転送に使う。
        // gradesData が渡された場合は成績データも同一ペイロードに含める。
        var sendToApp = function(result, docForUser, gradesData) {
            var payload = {
                subjects:   result.subjects,
                days:       result.days,
                username:   username   || tx((docForUser || document).querySelector('[id*="lbl_gakusei_name"]')),
                department: department || tx((docForUser || document).querySelector('[id*="lbl_sanbuka"]'))
            };
            if (gradesData && (gradesData.grades.length > 0 || gradesData.gpa)) {
                payload.grades        = gradesData.grades;
                payload.creditSummary = gradesData.creditSummary;
                payload.gpa           = gradesData.gpa;
                payload.onlineCredits = gradesData.onlineCredits || '';
            }
            var json = JSON.stringify(payload);
            var enc = btoa(unescape(encodeURIComponent(json)))
                .replace(/\+/g, '-')
                .replace(/\//g, '_')
                .replace(/=+$/, '');
            location.href = 'aogaku://import?d=' + enc;
        };
        var completeFromCurrentPageOrError = function(message) {
            try {
                var registered = extractRegisteredCourses(document);
                if (registered.subjects.length > 0) {
                    completeWith(registered, document);
                    return;
                }
                var timetable = extractTimetable(document);
                if (timetable.subjects.length > 0) {
                    completeWith(timetable, document);
                    return;
                }
            } catch(e) {}
            parameters.completionFunction({ payloadJSON: JSON.stringify({ error: message }) });
        };

        // ─── ページ内プログレスオーバーレイ ──────────────────────
        // Action Extension のシートで隠れる可能性があるが、ページ上部に固定表示するため
        // シートが小さい端末（iPad等）や横向き時に見える。シートを閉じるとすぐ消える。
        var overlayEl      = null;
        var overlayTitleEl = null;
        var overlayFillEl  = null;
        var overlayTimeEl  = null;
        var enrichStartTime = null;

        var showOverlay = function(msg) {
            if (!overlayEl) {
                overlayEl = document.createElement('div');
                overlayEl.style.cssText = [
                    'position:fixed', 'top:20px', 'left:50%',
                    'transform:translateX(-50%)',
                    'background:rgba(22,52,98,0.96)',
                    'color:#fff',
                    'padding:18px 26px 16px',
                    'border-radius:18px',
                    'z-index:2147483647',
                    'font-family:-apple-system,BlinkMacSystemFont,sans-serif',
                    'min-width:240px',
                    'max-width:86vw',
                    'text-align:center',
                    'box-shadow:0 6px 28px rgba(0,0,0,0.40)',
                    'pointer-events:none',
                    '-webkit-backdrop-filter:blur(10px)',
                    'backdrop-filter:blur(10px)'
                ].join(';');

                // タイトル（大きめ・太字）
                overlayTitleEl = document.createElement('div');
                overlayTitleEl.style.cssText = [
                    'font-size:17px', 'font-weight:700',
                    'letter-spacing:-0.2px', 'margin-bottom:14px',
                    'line-height:1.35'
                ].join(';');

                // プログレスバー（初期は非表示）
                var track = document.createElement('div');
                track.style.cssText = [
                    'background:rgba(255,255,255,0.20)',
                    'border-radius:5px', 'height:7px',
                    'overflow:hidden', 'margin-bottom:9px',
                    'display:none'
                ].join(';');
                overlayFillEl = document.createElement('div');
                overlayFillEl.style.cssText = [
                    'background:#fff', 'height:100%', 'width:0%',
                    'border-radius:5px',
                    'transition:width 0.35s ease'
                ].join(';');
                track.appendChild(overlayFillEl);
                overlayEl._track = track;   // あとで表示切替するために保持

                // 残り時間
                overlayTimeEl = document.createElement('div');
                overlayTimeEl.style.cssText = [
                    'font-size:13px', 'opacity:0.70', 'min-height:17px'
                ].join(';');

                overlayEl.appendChild(overlayTitleEl);
                overlayEl.appendChild(track);
                overlayEl.appendChild(overlayTimeEl);
                document.body.appendChild(overlayEl);
            }
            overlayTitleEl.textContent = msg;
        };

        // enrichSubjectsWithPortalDetails の onProgress コールバック用
        // done/total でバーを更新し、経過時間から残り秒数を推定して表示する
        var updateEnrichProgress = function(done, total) {
            if (!overlayEl) return;
            // バー初回表示
            if (overlayEl._track) overlayEl._track.style.display = '';
            // バー幅
            var pct = total > 0 ? Math.round(done / total * 100) : 0;
            if (overlayFillEl) overlayFillEl.style.width = pct + '%';
            // タイトル
            if (overlayTitleEl) overlayTitleEl.textContent = '📊 シラバスURLを取得中...';
            // 残り時間
            if (overlayTimeEl) {
                var remaining = total - done;
                if (done > 0 && remaining > 0 && enrichStartTime) {
                    var elapsed = (Date.now() - enrichStartTime) / 1000;
                    var est = Math.max(1, Math.round((elapsed / done) * remaining));
                    overlayTimeEl.textContent = '残り約 ' + est + ' 秒';
                } else if (remaining === 0) {
                    overlayTimeEl.textContent = '取得完了 ✓';
                }
            }
        };

        var removeOverlay = function() {
            if (overlayEl && overlayEl.parentNode) overlayEl.parentNode.removeChild(overlayEl);
            overlayEl = null; overlayTitleEl = null;
            overlayFillEl = null; overlayTimeEl = null;
            enrichStartTime = null;
        };

        // ─── 成績通知書（tuutisho.aspx）パーサー ───────────────
        var extractGrades = function(doc) {
            var grades = [];
            var gradeTable = doc.querySelector('#cph_content_gvw_seiseki');
            if (gradeTable) {
                var rows = gradeTable.querySelectorAll('tbody tr');
                for (var r = 0; r < rows.length; r++) {
                    var cells = rows[r].querySelectorAll('td');
                    if (cells.length < 6) continue;
                    var name = tx(cells[0]);
                    if (!name) continue;
                    var credits = parseInt(normalizeDigits(tx(cells[3])), 10);
                    var year    = parseInt(normalizeDigits(tx(cells[4])), 10);
                    // 全角文字を半角に正規化（ポータルは "ＡＡ" "Ａ" など全角で出す場合がある）
                    var rawGrade = tx(cells[2]);
                    var normalizedGrade = rawGrade.replace(/[！-～]/g, function(c) {
                        return String.fromCharCode(c.charCodeAt(0) - 0xFEE0);
                    }).replace(/\s+/g, '').trim();
                    grades.push({
                        name:     name,
                        teacher:  tx(cells[1]),
                        grade:    normalizedGrade || rawGrade,
                        credits:  isNaN(credits) ? 0 : credits,
                        year:     isNaN(year)    ? 0 : year,
                        category: tx(cells[5])
                    });
                }
            }

            var creditSummary = [];
            var taniTable = doc.querySelector('#cph_content_gvw_tani');
            if (taniTable) {
                var taniRows = taniTable.querySelectorAll('tbody tr');
                for (var t = 0; t < taniRows.length; t++) {
                    var tcells = taniRows[t].querySelectorAll('td');
                    if (tcells.length < 3) continue;
                    var label = tx(tcells[0]);
                    if (!label) continue;
                    var req    = parseInt(normalizeDigits(tx(tcells[1])), 10);
                    var earned = parseInt(normalizeDigits(tx(tcells[2])), 10);
                    creditSummary.push({
                        label:    label,
                        required: isNaN(req)    ? null : req,
                        earned:   isNaN(earned) ? null : earned
                    });
                }
            }

            var onlineText = tx(doc.querySelector('[id*="lbl_online"]'));
            var gpa = tx(doc.querySelector('#cph_content_lbl_gpa'));
            return { grades: grades, creditSummary: creditSummary, gpa: gpa, onlineCredits: onlineText };
        };

        // 成績データを completionFunction 経由でアプリに送る
        // （location.href 方式は Action Extension 内では届かないため App Group 経由に統一）
        var sendGradesToApp = function(gradesData) {
            var payload = {
                type:          'grades',
                grades:        gradesData.grades,
                creditSummary: gradesData.creditSummary,
                gpa:           gradesData.gpa,
                onlineCredits: gradesData.onlineCredits || '',
                username:      username,
                department:    department
            };
            parameters.completionFunction({ payloadJSON: JSON.stringify(payload) });
        };

        // ─── 成績通知書ページなら直接スクレイプ ─────────────────
        if (window.location.href.indexOf('tuutisho') >= 0 || document.querySelector('#cph_content_gvw_seiseki')) {
            try {
                showOverlay('📊 成績データを取得中...');
                var gradesData = extractGrades(document);
                removeOverlay();
                if (gradesData.grades.length > 0 || gradesData.gpa) {
                    sendGradesToApp(gradesData);
                    // completionFunction は sendGradesToApp 内で呼ばれる
                } else {
                    // テーブルは見つかったがデータが0件 → セレクタが合っているか確認用に詳細を返す
                    var dbgTable = document.querySelector('#cph_content_gvw_seiseki');
                    var dbgRows  = dbgTable ? dbgTable.querySelectorAll('tbody tr').length : -1;
                    parameters.completionFunction({ payloadJSON: JSON.stringify({
                        error: '成績データが見つかりませんでした（tbody tr: ' + dbgRows + '行）'
                    })});
                }
            } catch(e) {
                removeOverlay();
                parameters.completionFunction({ payloadJSON: JSON.stringify({ error: e.message }) });
            }
            return;
        }

        // ─── 履修科目一覧なら直接スクレイプ ───────────────────
        if (window.location.href.indexOf('jugyou_kamoku') >= 0 || document.querySelector('#cph_content_gvw_class')) {
            try {
                var courseInfo = extractCourseInfoSubject(document);
                if (courseInfo.subjects.length > 0) {
                    completeWith(courseInfo, document);
                } else {
                    parameters.completionFunction({ payloadJSON: JSON.stringify({ error: '授業科目情報から詳細表示リンクを取得できませんでした。' }) });
                }
            } catch(e) {
                parameters.completionFunction({ payloadJSON: JSON.stringify({ error: e.message }) });
            }
            return;
        }

        if (window.location.href.indexOf('my_rishuu') >= 0) {
            try {
                showOverlay('📊 時間割と単位状況を取得中...');
                var registered = extractRegisteredCourses(document);
                if (registered.subjects.length > 0) {
                    var rishuuHref = window.location.href;
                    var rishuuBase2 = rishuuHref.replace(/[^\/]+(\?.*)?$/, '');
                    var tuutishoLinkA = document.querySelector('a[href*="tuutisho"]');
                    var tuutishoURLA  = tuutishoLinkA
                        ? absoluteURL(tuutishoLinkA.getAttribute('href'), document)
                        : (rishuuBase2 + 'tuutisho.aspx');

                    // 成績通知書を時間割エンリッチと並行取得（エラーは無視して null を返す）
                    var gradesFetchA = fetch(tuutishoURLA, { credentials: 'include' })
                        .then(function(r) { return r.ok ? r.text() : ''; })
                        .then(function(html) {
                            if (!html) return null;
                            return extractGrades(new DOMParser().parseFromString(html, 'text/html'));
                        })
                        .catch(function() { return null; });

                    // 20秒で打ち切り。subjects は参照渡しなので取得済み分は反映される。
                    // ★ completionFunction にデータを乗せると複数 fetch 後に iOS がタイムアウトして
                    //   ペイロードが破損するため、sendToApp（location.href）で転送し
                    //   completionFunction({}) は拡張を閉じるためだけに使う。
                    enrichStartTime = Date.now();
                    var enrichLimit = new Promise(function(r) { setTimeout(r, 20000); });
                    Promise.all([
                        Promise.race([
                            enrichSubjectsWithPortalDetails(registered.subjects, document, rishuuHref,
                                updateEnrichProgress),
                            enrichLimit
                        ]),
                        gradesFetchA
                    ]).then(function(results) {
                        var gradesData = results[1];
                        removeOverlay();
                        sendToApp(registered, document, gradesData);
                        parameters.completionFunction({});
                    }).catch(function() {
                        removeOverlay();
                        sendToApp(registered, document, null);
                        parameters.completionFunction({});
                    });
                } else {
                    removeOverlay();
                    parameters.completionFunction({ payloadJSON: JSON.stringify({ error: '履修科目一覧から授業が見つかりませんでした。' }) });
                }
            } catch(e) {
                removeOverlay();
                parameters.completionFunction({ payloadJSON: JSON.stringify({ error: e.message }) });
            }
            return;
        }

        // ─── それ以外のページ → fetch で my_rishuu.aspx を優先取得 ────
        // 現在の URL のファイル名部分を各ページに置換
        // 例: "https://portal.example.com/student/message_list.aspx?foo=bar"
        //   → "https://portal.example.com/student/my_rishuu.aspx"
        var base          = window.location.href.replace(/[^\/]+(\?.*)?$/, '');
        var rishuuLink    = document.querySelector('a[href*="my_rishuu.aspx"]');
        var jikanwariLink = document.querySelector('a[href*="jikanwari.aspx"]');
        var rishuuURL    = rishuuLink    ? absoluteURL(rishuuLink.getAttribute('href'),    document) : (base + 'my_rishuu.aspx');
        var jikanwariURL = jikanwariLink ? absoluteURL(jikanwariLink.getAttribute('href'), document) : (base + 'jikanwari.aspx');
        // tuutisho の URL は my_rishuu.aspx 取得後にそのページのナビから確定させる（より確実）
        // ページにリンクがあればそれを使い、なければ base から組み立てる
        var tuutishoLink = document.querySelector('a[href*="tuutisho"]');
        var tuutishoURLFallback = tuutishoLink
            ? absoluteURL(tuutishoLink.getAttribute('href'), document)
            : (base + 'tuutisho.aspx');

        showOverlay('📊 時間割と単位状況を取得中...');
        fetch(rishuuURL, { credentials: 'include' })
            .then(function(resp) {
                if (!resp.ok) { throw new Error('HTTP ' + resp.status); }
                return resp.text();
            })
            .then(function(html) {
                var parser = new DOMParser();
                var doc    = parser.parseFromString(html, 'text/html');
                var registered = extractRegisteredCourses(doc);
                if (registered.subjects.length > 0) {
                    // my_rishuu.aspx のナビリンクから tuutisho URL を確定
                    // （このページのサイドメニューに成績通知書リンクがあれば確実）
                    var tuutishoNavLink = doc.querySelector('a[href*="tuutisho"]');
                    var tuutishoURLFinal = tuutishoNavLink
                        ? absoluteURL(tuutishoNavLink.getAttribute('href'), rishuuURL)
                        : tuutishoURLFallback;

                    // ★ 成績取得とエンリッチを並行して開始
                    var gradesFetch = fetch(tuutishoURLFinal, { credentials: 'include' })
                        .then(function(r) { return r.ok ? r.text() : ''; })
                        .then(function(gradesHtml) {
                            if (!gradesHtml) return null;
                            return extractGrades(new DOMParser().parseFromString(gradesHtml, 'text/html'));
                        })
                        .catch(function() { return null; });

                    enrichStartTime = Date.now();
                    var enrichLimit2 = new Promise(function(r) { setTimeout(r, 20000); });
                    return Promise.all([
                        Promise.race([
                            enrichSubjectsWithPortalDetails(registered.subjects, doc, rishuuURL,
                                updateEnrichProgress),
                            enrichLimit2
                        ]),
                        gradesFetch
                    ]).then(function(results) {
                        var gradesData = results[1];
                        removeOverlay();
                        sendToApp(registered, doc, gradesData);
                        parameters.completionFunction({});
                    }).catch(function() {
                        removeOverlay();
                        sendToApp(registered, doc, null);
                        parameters.completionFunction({});
                    });
                }

                showOverlay('📊 時間割を取得中...');
                return fetch(jikanwariURL, { credentials: 'include' })
                    .then(function(resp) {
                        if (!resp.ok) { throw new Error('HTTP ' + resp.status); }
                        return resp.text();
                    })
                    .then(function(html) {
                        var fallbackDoc = parser.parseFromString(html, 'text/html');
                        var result = extractTimetable(fallbackDoc);
                        if (result.subjects.length === 0) {
                            removeOverlay();
                            parameters.completionFunction({ payloadJSON: JSON.stringify({ error: '履修科目一覧・時間割のどちらからも授業が見つかりませんでした。' }) });
                            return;
                        }
                        removeOverlay();
                        // jikanwari はデータ量が少ないため completionFunction 直渡しで OK（成績なし）
                        completeWith(result, fallbackDoc);
                    });
            })
            .catch(function(e) {
                removeOverlay();
                completeFromCurrentPageOrError('ページ取得に失敗しました: ' + e.message);
            });
    },

    finalize: function(parameters) {}
};

var ExtensionPreprocessingJS = new Action;
