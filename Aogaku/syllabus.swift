//
//  syllabus.swift
//  Aogaku
//
//  Created by 米沢怜生 on 2025/08/04.
//
// 追記　確認用
// 再追記　確認用
// 再再追記　確認用
// 再再追記　確認用 15:43
// 15:53
// 15:58

import UIKit

class syllabus: UIViewController, UITableViewDataSource, UITableViewDelegate, UISearchResultsUpdating {

    @IBOutlet weak var syllabus_table: UITableView!
    @IBOutlet weak var search_button: UIButton!
    
    struct SyllabusData {
        let class_name: String
        let teacher_name: String
        let time: String
        let campus: String
        let grade: String
        let category: String
        let credit: String
    }

    let data: [SyllabusData] = [
        SyllabusData(class_name: "フレッシャーズ・セミナー", teacher_name: "楠 由記子", time: "月1", campus: "青山", grade: "1のみ", category: "青山スタンダード科目", credit: "2"),
        SyllabusData(class_name: "フレッシャーズ・セミナー", teacher_name: "當間 麗", time: "月1", campus: "青山", grade: "1のみ", category: "青山スタンダード科目", credit: "2"),
        SyllabusData(class_name: "キリスト教概論Ⅰ", teacher_name: "伊藤 悟", time: "月1", campus: "青山", grade: "教教1D・E", category: "青山スタンダード科目", credit: "2"),
        SyllabusData(class_name: "キリスト教概論Ⅰ", teacher_name: "塩谷 直也", time: "月1", campus: "青山", grade: "法1D～F", category: "青山スタンダード科目", credit: "2"),

    ]
    // 🔸検索結果格納用
    var filteredData: [SyllabusData] = []

    // 🔸検索コントローラ
    let searchController = UISearchController(searchResultsController: nil)
    
    override func viewDidLoad() {
        super.viewDidLoad()
        syllabus_table.dataSource = self
        syllabus_table.delegate = self
        
            syllabus_table.dataSource = self
            syllabus_table.delegate = self

            // 検索バーの設定
            searchController.searchResultsUpdater = self
            searchController.obscuresBackgroundDuringPresentation = false
            searchController.searchBar.placeholder = "授業名や教員名で検索"
            navigationItem.searchController = searchController
            definesPresentationContext = true
        
        navigationController?.navigationBar.prefersLargeTitles = true
            navigationItem.largeTitleDisplayMode = .always
            navigationItem.hidesSearchBarWhenScrolling = false

        navigationItem.title = "シラバス"
            // 初期状態の filteredData を全データに
            filteredData = data

        }
    
    @IBAction func search_button(_ sender: Any){
        // 1. Main.storyboard（名前は適宜置き換え）を指定
           let sb = UIStoryboard(name: "Main", bundle: nil)
           
           // 2. "syllabus_search" という Storyboard ID のVCをインスタンス化
           guard let searchVC = sb.instantiateViewController(withIdentifier: "syllabus_search") as? syllabus_search else {
               print("syllabus_search が見つかりません")
               return
           }
           
           // 3. プッシュ遷移
           navigationController?.pushViewController(searchVC, animated: true)
    }

    func updateSearchResults(for searchController: UISearchController) {
            guard let searchText = searchController.searchBar.text, !searchText.isEmpty else {
                filteredData = data
                syllabus_table.reloadData()
                return
            }
        filteredData = data.filter { subject in
                   subject.class_name.contains(searchText) ||
                   subject.teacher_name.contains(searchText) ||
                   subject.time.contains(searchText) ||
                   subject.campus.contains(searchText) ||
                   subject.grade.contains(searchText) ||
                   subject.category.contains(searchText) ||
                   subject.credit.contains(searchText)
               }

               syllabus_table.reloadData()
     }
    
    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        return filteredData.count
    }
    
    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let subject = filteredData[indexPath.row]
            let cell = syllabus_table.dequeueReusableCell(withIdentifier: "class", for: indexPath) as! syllabusTableViewCell
            cell.class_name.text = subject.class_name
            cell.teacher_name.text = subject.teacher_name
            cell.time.text = subject.time
            cell.campus.text = subject.campus
            cell.grade.text = subject.grade
            cell.category.text = subject.category
            cell.credit.text = subject.credit
            return cell
    }
    
    func tableView(_ tableView: UITableView, heightForRowAt indexPath: IndexPath) -> CGFloat {
        return 90
    }
    
}
