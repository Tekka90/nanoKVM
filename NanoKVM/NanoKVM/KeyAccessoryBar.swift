#if os(iOS)
import UIKit

/// Row of keys above the system keyboard: hide, Esc, Tab, sticky Ctrl/Alt/Win, arrows, navigation, F-keys.
final class KeyAccessoryBar: UIView {
    var onKey: ((UInt8) -> Void)?
    var onModifier: ((UInt8) -> Bool)?
    var onHide: (() -> Void)?
    private var modifierButtons: [UInt8: UIButton] = [:]

    var target = KeyboardTarget.windows { didSet { if target != oldValue { rebuild() } } }
    private let stack = UIStackView()

    override init(frame: CGRect) {
        super.init(frame: CGRect(x: 0, y: 0, width: 0, height: 44))
        autoresizingMask = .flexibleWidth
        let blur = UIVisualEffectView(effect: UIBlurEffect(style: .systemChromeMaterial))
        blur.frame = bounds
        blur.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        addSubview(blur)

        let hide = button("keyboard.chevron.compact.down", symbol: true)
        hide.addAction(UIAction { [weak self] _ in self?.onHide?() }, for: .touchUpInside)
        hide.translatesAutoresizingMaskIntoConstraints = false
        addSubview(hide)

        let scroll = UIScrollView()
        scroll.showsHorizontalScrollIndicator = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scroll)
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false
        scroll.addSubview(stack)

        rebuild()

        NSLayoutConstraint.activate([
            hide.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            hide.centerYAnchor.constraint(equalTo: centerYAnchor),
            scroll.leadingAnchor.constraint(equalTo: hide.trailingAnchor, constant: 6),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.topAnchor.constraint(equalTo: topAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor, constant: -6),
            stack.centerYAnchor.constraint(equalTo: scroll.frameLayoutGuide.centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    private func rebuild() {
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        modifierButtons = [:]
        for (title, usage) in [("Ctrl", UInt8(0xE0)), (target.altTitle, 0xE2), (target.guiTitle, 0xE3)] {
            let b = button(title)
            b.addAction(UIAction { [weak self] _ in
                guard let self else { return }
                self.setArmed(self.onModifier?(usage) ?? false, usage)
            }, for: .touchUpInside)
            modifierButtons[usage] = b
            stack.addArrangedSubview(b)
        }
        for (title, usage) in target.barKeys {
            let b = button(title)
            b.addAction(UIAction { [weak self] _ in self?.onKey?(usage); self?.clearArmed() }, for: .touchUpInside)
            stack.addArrangedSubview(b)
        }
    }

    private func button(_ title: String, symbol: Bool = false) -> UIButton {
        var c = UIButton.Configuration.gray()
        c.cornerStyle = .medium
        c.contentInsets = NSDirectionalEdgeInsets(top: 6, leading: 10, bottom: 6, trailing: 10)
        if symbol { c.image = UIImage(systemName: title) } else { c.title = title }
        return UIButton(configuration: c)
    }

    func setArmed(_ on: Bool, _ usage: UInt8) {
        guard let b = modifierButtons[usage] else { return }
        b.configuration = {
            var c = on ? UIButton.Configuration.filled() : UIButton.Configuration.gray()
            c.cornerStyle = .medium
            c.contentInsets = NSDirectionalEdgeInsets(top: 6, leading: 10, bottom: 6, trailing: 10)
            c.title = b.configuration?.title
            return c
        }()
    }

    func clearArmed() { for usage in modifierButtons.keys { setArmed(false, usage) } }
}
#endif
