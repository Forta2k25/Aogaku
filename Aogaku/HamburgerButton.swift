import UIKit

/// 右上の三本線ボタン（34x34, 背景透明）
func makeHamburgerButton(target: Any?, action: Selector) -> UIButton {
    let img = UIImage(
        systemName: "line.3.horizontal",
        withConfiguration: UIImage.SymbolConfiguration(pointSize: 22, weight: .regular)
    )

    let b = UIButton(type: .system)
    b.setImage(img, for: .normal)
    b.tintColor = .label
    b.backgroundColor = .clear          // ← 薄いグレーの丸を消す
    b.layer.cornerRadius = 0            // 念のため
    b.contentEdgeInsets = .zero
    b.translatesAutoresizingMaskIntoConstraints = false
    b.addTarget(target, action: action, for: .touchUpInside)

    NSLayoutConstraint.activate([
        b.widthAnchor.constraint(equalToConstant: 34),
        b.heightAnchor.constraint(equalToConstant: 34)
    ])
    return b
}
