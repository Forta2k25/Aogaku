//
//  PixelToggleControl.swift
//  Aogaku
//
//  「ポータル / AIハック」切り替え用のトグル。
//  UISegmentedControlに似たAPIを持つが、"AIハック"セグメントだけ選択時に
//  専用の配色・ピクセルフォント・ピクセル稲妻アイコンで描画する。
//

import UIKit

final class PixelToggleControl: UIControl {

    /// このタイトルのセグメントが選択された時だけ、専用の「ハックらしい」配色を使う
    private static let hackSegmentTitle = "ノート"
    private static let hackSegmentDisplayTitle = "AIハック"

    private static let hackBackgroundColor = UIColor(red: 0x1a/255.0, green: 0x1a/255.0, blue: 0x2e/255.0, alpha: 1)
    private static let hackForegroundColor = UIColor(red: 0x7f/255.0, green: 0xff/255.0, blue: 0xd4/255.0, alpha: 1)
    private static let hackIconColor = UIColor(red: 0xff/255.0, green: 0xe3/255.0, blue: 0x4f/255.0, alpha: 1)

    private let stack = UIStackView()
    private var buttons: [UIButton] = []
    private var titles: [String] = []

    private var normalAttributes: [NSAttributedString.Key: Any] = [.foregroundColor: UIColor.label]
    private var selectedAttributes: [NSAttributedString.Key: Any] = [.foregroundColor: UIColor.white]

    var selectedSegmentIndex: Int = 0 {
        didSet { updateAppearance() }
    }

    var numberOfSegments: Int { titles.count }

    convenience init(items: [String]) {
        self.init(frame: .zero)
        items.forEach { insertSegment(withTitle: $0, at: numberOfSegments, animated: false) }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        setupStack()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func setupStack() {
        backgroundColor = .secondarySystemBackground
        layer.cornerRadius = 19
        layer.masksToBounds = true

        stack.axis = .horizontal
        stack.distribution = .fillEqually
        stack.spacing = 0
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 2),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -2),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -2),
            heightAnchor.constraint(equalToConstant: 38)
        ])
    }

    func insertSegment(withTitle title: String, at index: Int, animated: Bool) {
        titles.insert(title, at: index)
        let button = UIButton(type: .system)
        button.layer.cornerRadius = 17
        button.layer.masksToBounds = true
        button.addTarget(self, action: #selector(segmentTapped(_:)), for: .touchUpInside)
        buttons.insert(button, at: index)
        stack.insertArrangedSubview(button, at: index)
        updateAppearance()
    }

    func setTitleTextAttributes(_ attributes: [NSAttributedString.Key: Any]?, for state: UIControl.State) {
        guard let attributes else { return }
        if state == .selected {
            selectedAttributes = attributes
        } else {
            normalAttributes = attributes
        }
        updateAppearance()
    }

    @objc private func segmentTapped(_ sender: UIButton) {
        guard let index = buttons.firstIndex(of: sender), index != selectedSegmentIndex else { return }
        selectedSegmentIndex = index
        sendActions(for: .valueChanged)
    }

    private func updateAppearance() {
        for (index, button) in buttons.enumerated() {
            let title = titles[index]
            let isSelected = index == selectedSegmentIndex
            let isHackSegment = title == Self.hackSegmentTitle

            if isSelected && isHackSegment {
                button.backgroundColor = Self.hackBackgroundColor
                let font = UIFont(name: "DotGothic16-Regular", size: 14) ?? .systemFont(ofSize: 13, weight: .semibold)
                button.setAttributedTitle(
                    NSAttributedString(string: Self.hackSegmentDisplayTitle, attributes: [
                        .foregroundColor: Self.hackForegroundColor,
                        .font: font,
                        .kern: 1.0
                    ]),
                    for: .normal
                )
                button.setImage(Self.lightningBoltImage(color: Self.hackIconColor), for: .normal)
                button.imageEdgeInsets = UIEdgeInsets(top: 0, left: -6, bottom: 0, right: 6)
            } else if isSelected {
                button.backgroundColor = UIColor(red: 0/255, green: 120/255, blue: 87/255, alpha: 1)
                button.setAttributedTitle(NSAttributedString(string: title, attributes: selectedAttributes), for: .normal)
                button.setImage(nil, for: .normal)
            } else if isHackSegment {
                // 選択されていなくても、AIハックはピクセルフォントと稲妻アイコンを保つ(選択時と見た目を揃える)
                button.backgroundColor = .clear
                let font = UIFont(name: "DotGothic16-Regular", size: 14) ?? .systemFont(ofSize: 13, weight: .semibold)
                let color = (normalAttributes[.foregroundColor] as? UIColor) ?? .label
                button.setAttributedTitle(
                    NSAttributedString(string: Self.hackSegmentDisplayTitle, attributes: [
                        .foregroundColor: color,
                        .font: font,
                        .kern: 1.0
                    ]),
                    for: .normal
                )
                button.setImage(Self.lightningBoltImage(color: Self.hackIconColor), for: .normal)
                button.imageEdgeInsets = UIEdgeInsets(top: 0, left: -6, bottom: 0, right: 6)
            } else {
                button.backgroundColor = .clear
                button.setAttributedTitle(NSAttributedString(string: title, attributes: normalAttributes), for: .normal)
                button.setImage(nil, for: .normal)
            }
        }
    }

    /// E1案: 細身のクラシックな稲妻(10x8のピクセルグリッド)をUIImageとして描画する
    private static func lightningBoltImage(color: UIColor) -> UIImage {
        let pattern = [
            "0000110000",
            "0001100000",
            "0011000000",
            "0111111000",
            "0001110000",
            "0000110000",
            "0001100000",
            "0011000000"
        ]
        let pixelSize: CGFloat = 1.6
        let cols = pattern[0].count
        let rows = pattern.count
        let size = CGSize(width: CGFloat(cols) * pixelSize, height: CGFloat(rows) * pixelSize)
        let renderer = UIGraphicsImageRenderer(size: size)
        let image = renderer.image { ctx in
            color.setFill()
            for (rowIndex, row) in pattern.enumerated() {
                for (colIndex, char) in row.enumerated() where char == "1" {
                    let rect = CGRect(
                        x: CGFloat(colIndex) * pixelSize,
                        y: CGFloat(rowIndex) * pixelSize,
                        width: pixelSize,
                        height: pixelSize
                    )
                    ctx.fill(rect)
                }
            }
        }
        return image.withRenderingMode(.alwaysOriginal)
    }
}
