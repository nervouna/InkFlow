import UIKit

final class HostViewController: UIViewController {
    override func viewDidLoad() {
        super.viewDidLoad()
        title = "InkFlow"
        view.backgroundColor = .systemBackground

        let titleLabel = UILabel()
        titleLabel.font = .preferredFont(forTextStyle: .title1)
        titleLabel.text = "InkFlow 中文输入法"
        titleLabel.textAlignment = .center

        let instructions = UILabel()
        instructions.font = .preferredFont(forTextStyle: .body)
        instructions.numberOfLines = 0
        instructions.textAlignment = .center
        instructions.text = "请在“设置 > 通用 > 键盘 > 键盘”中添加 InkFlow。输入法完全离线，不请求完全访问权限。"

        let stack = UIStackView(arrangedSubviews: [titleLabel, instructions])
        stack.axis = .vertical
        stack.spacing = 16
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: view.layoutMarginsGuide.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: view.layoutMarginsGuide.trailingAnchor),
            stack.centerYAnchor.constraint(equalTo: view.centerYAnchor),
        ])
    }
}
