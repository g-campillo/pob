import WebKit

/// Puts a username and password into the page. Values go in as arguments from an isolated
/// content world, so they're never pasted into script text or visible to the page's own scripts.
enum LoginFiller {
    private static let script = """
    const inputs = [...document.querySelectorAll('input')];
    const passwordIndex = inputs.findIndex(input => input.type === 'password');
    if (passwordIndex < 0) return false;
    const username = inputs.slice(0, passwordIndex).reverse()
        .find(input => ['text', 'email', 'tel'].includes(input.type));
    const fill = (input, value) => {
        input.value = value;
        input.dispatchEvent(new Event('input', { bubbles: true }));
        input.dispatchEvent(new Event('change', { bubbles: true }));
    };
    if (username) fill(username, user);
    fill(inputs[passwordIndex], pass);
    return true;
    """

    static func fill(_ webView: WKWebView, username: String, password: String) async throws -> Bool {
        let configuration = WKContentWorld.Configuration()
        configuration.autofillScriptingEnabled = true
        let result = try await webView.callAsyncJavaScript(
            script,
            arguments: ["user": username, "pass": password],
            in: nil,
            contentWorld: WKContentWorld(configuration: configuration)
        )
        return result as? Bool ?? false
    }
}
