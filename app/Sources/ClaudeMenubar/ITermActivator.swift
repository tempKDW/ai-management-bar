import Foundation

enum ITermActivator {
    /// Activates the iTerm2 tab whose session matches the given identifier.
    ///
    /// Accepts either:
    /// - the raw `ITERM_SESSION_ID` env var (e.g. `"w0t4p0:B466...A8E9"`), or
    /// - the bare UUID returned by AppleScript's `unique id of session`.
    ///
    /// We always strip a leading `wNtNpN:` prefix before comparison because
    /// `ITERM_SESSION_ID` includes the window/tab/pane index but `unique id` does not.
    ///
    /// Returns nil on success, an error message string otherwise.
    @discardableResult
    static func activate(sessionUniqueID: String) -> String? {
        let uuid: String = {
            if let colon = sessionUniqueID.lastIndex(of: ":") {
                return String(sessionUniqueID[sessionUniqueID.index(after: colon)...])
            }
            return sessionUniqueID
        }()
        let escaped = uuid.replacingOccurrences(of: "\\", with: "\\\\")
                          .replacingOccurrences(of: "\"", with: "\\\"")
        let script = """
        tell application "iTerm2"
            activate
            repeat with w in windows
                repeat with t in tabs of w
                    repeat with s in sessions of t
                        if unique id of s is "\(escaped)" then
                            select w
                            tell w to select t
                            tell t to select s
                            return "ok"
                        end if
                    end repeat
                end repeat
            end repeat
            return "not-found"
        end tell
        """

        var errInfo: NSDictionary?
        guard let apple = NSAppleScript(source: script) else {
            return "failed to compile AppleScript"
        }
        let result = apple.executeAndReturnError(&errInfo)
        if let info = errInfo {
            return "AppleScript error: \(info)"
        }
        if result.stringValue == "not-found" {
            return "session not found in any iTerm2 window"
        }
        return nil
    }
}
