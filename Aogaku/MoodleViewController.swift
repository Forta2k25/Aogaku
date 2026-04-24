//
//  MoodleViewController.swift
//  Aogaku
//
//  Created by 米沢怜生 on 2026/04/17.
//

import UIKit
import WebKit

final class MoodleViewController: UIViewController {

    @IBOutlet weak var containerView: UIView!
    private var webView: WKWebView!

    override func viewDidLoad() {
        super.viewDidLoad()

        let config = WKWebViewConfiguration()
        webView = WKWebView(frame: .zero, configuration: config)
        webView.translatesAutoresizingMaskIntoConstraints = false

        containerView.addSubview(webView)
        NSLayoutConstraint.activate([
            webView.topAnchor.constraint(equalTo: containerView.topAnchor),
            webView.bottomAnchor.constraint(equalTo: containerView.bottomAnchor),
            webView.leadingAnchor.constraint(equalTo: containerView.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: containerView.trailingAnchor)
        ])

        guard let url = URL(string: "https://agulms45.aim.aoyama.ac.jp/my/") else { return }
        webView.load(URLRequest(url: url))
    }
}
