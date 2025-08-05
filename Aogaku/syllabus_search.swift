//
//  syllabus_search.swift
//  Aogaku
//
//  Created by 米沢怜生 on 2025/08/05.
//

import UIKit

class syllabus_search: UIViewController {

    @IBOutlet weak var facultyButton: UIButton!
    @IBOutlet weak var departmentButton: UIButton!
    @IBOutlet weak var campusSegmentedControl: UISegmentedControl!
    @IBOutlet weak var placeSegmentedControl: UISegmentedControl!
    @IBOutlet var slotButtons: [UIButton]!
    @IBOutlet weak var gridContainerView: UIView!
    
    // 25 セル分の Bool 配列。初期は全部 false（未選択）
    private var selectedStates = Array(repeating: false, count: 25)
    
    let spacing: CGFloat   = 0
//    let topMargin: CGFloat = 0
    
    let faculties = [
        "指定なし",
        "文学部",
        "教育人間科学部",
        "経済学部",
        "法学部",
        "経営学部",
        "国際政治経済学部",
        "総合文化政策学部",
        "理工学部",
        "コミュニティ人間科学部",
        "社会情報学部",
        "地球社会共生学部",
        "青山スタンダード科目",
        "教職課程科目",
    ]

    let departments: [String: [String]] = [
        // 青山キャンパス
        "指定なし": ["指定なし"],
        "文学部": ["指定なし", "英米文学科", "フランス文学科", "日本文学科", "史学科", "比較芸術学科"],
        "教育人間科学部": ["指定なし", "教育学科", "心理学科"],
        "経済学部": ["指定なし", "経済学科", "現代経済デザイン学科"],
        "法学部": ["指定なし", "法学科", "ヒューマンライツ学科"],
        "経営学部": ["指定なし", "経営学科", "マーケティング学科"],
        "国際政治経済学部": ["指定なし", "国際政治学科", "国際経済学科", "国際コミュニケーション学科"],
        "総合文化政策学部": ["指定なし", "総合文化政策学科"],

        // 相模原キャンパス
        "理工学部": ["指定なし", "物理科学科", "数理サイエンス学科", "化学・生命科学科", "電気電子工学科", "機械創造工学科", "経営システム工学科", "情報テクノロジー学科"],
        "コミュニティ人間科学部": ["指定なし", "コミュニティ人間科学科"],
        "社会情報学部": ["指定なし", "社会情報学科"],
        "地球社会共生学部": ["指定なし", "地球社会共生学科"],
        "青山スタンダード科目": ["指定なし"],
        "教職課程科目": ["指定なし"]
    ]


    override func viewDidLoad() {
      super.viewDidLoad()
        
        // 1) container 側の AutoResizing はオフに
                gridContainerView.translatesAutoresizingMaskIntoConstraints = false
                // 2) ボタンもオフに
                slotButtons.forEach { $0.translatesAutoresizingMaskIntoConstraints = false }

                // Tag順にソート
                let buttons = slotButtons.sorted { $0.tag < $1.tag }

                for idx in 0..<buttons.count {
                    let btn = buttons[idx]
                    let row = idx / 5
                    let col = idx % 5

                    // ───── 横方向の制約 ─────
                    if col == 0 {
                        // 一番左は container の leading にピタッ
                        btn.leadingAnchor.constraint(
                            equalTo: gridContainerView.leadingAnchor
                        ).isActive = true
                    } else {
                        // 左隣の trailing + spacing
                        let left = buttons[idx - 1]
                        btn.leadingAnchor.constraint(
                            equalTo: left.trailingAnchor,
                            constant: spacing
                        ).isActive = true
                        // 幅は左隣とイコール
                        btn.widthAnchor.constraint(
                            equalTo: left.widthAnchor
                        ).isActive = true
                    }
                    if col == 4 {
                        // 一番右は container の trailing にピタッ
                        btn.trailingAnchor.constraint(
                            equalTo: gridContainerView.trailingAnchor
                        ).isActive = true
                    }

                    // ───── 縦方向の制約 ─────
                    if row == 0 {
                        // 一行目は container の top にピタッ
                        btn.topAnchor.constraint(
                            equalTo: gridContainerView.topAnchor
                        ).isActive = true
                    } else {
                        // 上の行の同じ列の bottom + spacing
                        let above = buttons[(row - 1) * 5 + col]
                        btn.topAnchor.constraint(
                            equalTo: above.bottomAnchor,
                            constant: spacing
                        ).isActive = true
                        // 高さは上の行とイコール
                        btn.heightAnchor.constraint(
                            equalTo: above.heightAnchor
                        ).isActive = true
                    }
                    if row == 4 {
                        // 最下行は container の bottom にピタッ
                        btn.bottomAnchor.constraint(
                            equalTo: gridContainerView.bottomAnchor
                        ).isActive = true
                    }
                }
        /////////////////
        let campuses = ["指定なし", "青山", "相模原"]
        
                campusSegmentedControl.removeAllSegments()
                for (i, title) in campuses.enumerated() {
                    campusSegmentedControl.insertSegment(withTitle: title, at: i, animated: false)
                }
                campusSegmentedControl.selectedSegmentIndex = 0
                campusSegmentedControl.setTitleTextAttributes([.foregroundColor: UIColor.gray], for: .normal)
                campusSegmentedControl.setTitleTextAttributes([.foregroundColor: UIColor.black], for: .selected)
            // 初期選択を「指定なし」に
            campusSegmentedControl.selectedSegmentIndex = 0

            // テキスト色：未選択時グレー、選択時は黒
            campusSegmentedControl.setTitleTextAttributes([.foregroundColor: UIColor.gray], for: .normal)
            campusSegmentedControl.setTitleTextAttributes([.foregroundColor: UIColor.black], for: .selected)
        
        // 画面表示時に学部メニュー・学科メニューを組み立て
            setupFacultyMenu()
            setupDepartmentMenu(initial: faculties[0])
        
        let places = ["指定なし", "対面", "オンライン"]
        
        placeSegmentedControl.removeAllSegments()
                        for (i, title) in places.enumerated() {
                            placeSegmentedControl.insertSegment(withTitle: title, at: i, animated: false)
                        }
                        placeSegmentedControl.selectedSegmentIndex = 0
                        placeSegmentedControl.setTitleTextAttributes([.foregroundColor: UIColor.gray], for: .normal)
                        placeSegmentedControl.setTitleTextAttributes([.foregroundColor: UIColor.black], for: .selected)
                    // 初期選択を「指定なし」に
                    placeSegmentedControl.selectedSegmentIndex = 0

                    // テキスト色：未選択時グレー、選択時は黒
                    placeSegmentedControl.setTitleTextAttributes([.foregroundColor: UIColor.gray], for: .normal)
                    placeSegmentedControl.setTitleTextAttributes([.foregroundColor: UIColor.black], for: .selected)
                
                // 画面表示時に学部メニュー・学科メニューを組み立て
                    setupFacultyMenu()
                    setupDepartmentMenu(initial: faculties[0])

        }



    private func createFacultyActions() -> [UIAction] {
        return faculties.map { name in
            UIAction(title: name) { [weak self] action in
                guard let self = self else { return }
                // 学部を選んだときは黒文字に
                self.facultyButton.setTitle(action.title, for: .normal)
                self.facultyButton.setTitleColor(.black, for: .normal)

                // 学科は選び直しなのでプレースホルダーに戻す
                self.departmentButton.setTitle("学科", for: .normal)
                self.departmentButton.setTitleColor(.lightGray, for: .normal)
                // ここで学科メニューを組み直し
                self.setupDepartmentMenu(initial: action.title)
            }
        }
    }
    
    func setupFacultyMenu() {
      // UIAction を用意
      let actions = faculties.map { name in
          
          // 学部選択アクションの中で…
          UIAction(title: name) { [weak self] action in
              guard let self = self else { return }

              // 文字をセット
              self.facultyButton.setTitle(action.title, for: .normal)

              // Configuration を取り出して色を黒に
              if var config = self.facultyButton.configuration {
                  config.baseForegroundColor = .black
                  self.facultyButton.configuration = config
              }
              
              // 学科はプレースホルダーに戻してグレーに
              self.departmentButton.setTitle("学科", for: .normal)
              if var deptConfig = self.departmentButton.configuration {
                  deptConfig.baseForegroundColor = .lightGray
                  self.departmentButton.configuration = deptConfig
              }
              
              // 学科メニュー再構築
              self.setupDepartmentMenu(initial: action.title)
          }

          
      }
      // メニューをセット
      facultyButton.menu = UIMenu(children: actions)
      facultyButton.showsMenuAsPrimaryAction = true
    }

    @IBAction func slotTapped(_ sender: UIButton) {
        let idx = sender.tag                  // 何番目のボタンか
        selectedStates[idx].toggle()          // Bool を反転

        if selectedStates[idx] {
            // 選択されたとき
            sender.backgroundColor = .systemGreen
            sender.setTitleColor(.white, for: .normal)
        } else {
            // 選択解除されたとき
            sender.backgroundColor = .white    // 元に戻す
            sender.setTitleColor(.lightGray, for: .normal)
        }
    }

    
    func setupDepartmentMenu(initial faculty: String) {
        guard let list = departments[faculty] else { return }

        // list.map { deptName in … } の中で deptName を使う
        let actions = list.map { deptName in
            UIAction(title: deptName) { [weak self] _ in
                guard let self = self else { return }
                // 学科ボタンに選択された deptName をセット
                self.departmentButton.setTitle(deptName, for: .normal)
                // Filled スタイルなら configuration 経由で文字色を黒に
                if var config = self.departmentButton.configuration {
                    config.baseForegroundColor = .black
                    self.departmentButton.configuration = config
                }
            }
        }

        // メニューをボタンに取り付け
        departmentButton.menu = UIMenu(children: actions)
        departmentButton.showsMenuAsPrimaryAction = true

        // 初期表示はプレースホルダー色のまま
        departmentButton.setTitle("学科", for: .normal)
        if var config = departmentButton.configuration {
            config.baseForegroundColor = .lightGray
            departmentButton.configuration = config
        }
    }


  
}
