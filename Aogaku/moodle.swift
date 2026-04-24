//
//  moodle.swift
//  Aogaku
//
//  Created by 米沢怜生 on 2026/04/17.
//

import Foundation
import UIKit
import WebKit

final class LMSViewController: UIViewController {

    @IBOutlet weak var webView: WKWebView!

    override func viewDidLoad() {
        super.viewDidLoad()

        guard let url = URL(string: "https://agulms45.aim.aoyama.ac.jp/my/") else { return }
        let request = URLRequest(url: url)
        webView.load(request)
    }
}
