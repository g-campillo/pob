import AppKit

/// Native sign-in fields, which macOS may offer to fill from Apple Passwords.
/// Stage 1 uses this to find out whether AutoFill works here at all.
final class SignInPopover: NSViewController {
    let usernameField = NSTextField()
    let passwordField = NSSecureTextField()

    private let host: String
    private let onFill: (String, String) -> Void

    init(host: String, onFill: @escaping (String, String) -> Void) {
        self.host = host
        self.onFill = onFill
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func loadView() {
        usernameField.contentType = .username
        usernameField.placeholderString = "Email or username"
        passwordField.contentType = .password
        passwordField.placeholderString = "Password"
        for field in [usernameField, passwordField] {
            field.widthAnchor.constraint(equalToConstant: 240).isActive = true
        }

        let title = NSTextField(labelWithString: "Sign in to \(host)")
        title.font = .boldSystemFont(ofSize: NSFont.systemFontSize)
        let button = NSButton(title: "Fill", target: self, action: #selector(fillPressed))
        button.keyEquivalent = "\r"

        let stack = NSStackView(views: [title, usernameField, passwordField, button])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 14, left: 14, bottom: 14, right: 14)
        view = stack
    }

    @objc private func fillPressed() {
        let username = usernameField.stringValue
        let password = passwordField.stringValue
        usernameField.stringValue = ""
        passwordField.stringValue = ""
        onFill(username, password)
    }
}
