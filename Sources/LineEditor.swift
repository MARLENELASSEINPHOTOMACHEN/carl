import Foundation

// MARK: - Terminal Width

func getTerminalWidth() -> Int {
    var ws = winsize()
    if ioctl(STDOUT_FILENO, TIOCGWINSZ, &ws) == 0 && ws.ws_col > 0 {
        return Int(ws.ws_col)
    }
    return 80  // fallback
}

// MARK: - Visual Width

func visualWidth(_ str: String) -> Int {
    // Calculate terminal column width: ASCII = 1, wide chars (CJK, emoji) = 2, others = 1
    var width = 0
    for scalar in str.unicodeScalars {
        if scalar.isASCII {
            width += 1
        } else if scalar.value >= 0x1100 {
            // Wide characters: CJK, emoji, etc.
            width += 2
        } else {
            width += 1
        }
    }
    return width
}

// MARK: - Editable Prompt

func editablePrompt(prefill: String, prompt: String) -> String? {
    guard isatty(STDIN_FILENO) != 0 else {
        return prefill
    }

    // Save original terminal settings
    var originalTermios = termios()
    tcgetattr(STDIN_FILENO, &originalTermios)

    // Set up raw mode
    var raw = originalTermios
    raw.c_lflag &= ~UInt(ICANON | ECHO)
    raw.c_cc.16 = 1  // VMIN
    raw.c_cc.17 = 0  // VTIME
    tcsetattr(STDIN_FILENO, TCSAFLUSH, &raw)

    // Restore terminal on exit
    defer {
        tcsetattr(STDIN_FILENO, TCSAFLUSH, &originalTermios)
    }

    var buffer = Array(prefill)  // Array of Characters for proper Unicode handling
    var cursorPos = buffer.count
    let promptWidth = visualWidth(prompt)

    // Save cursor position at start
    fputs("\u{1B}7", stdout)  // DECSC - save cursor

    func textWidth(_ chars: ArraySlice<Character>) -> Int {
        return visualWidth(String(chars))
    }

    func redraw() {
        let termWidth = getTerminalWidth()
        let text = String(buffer)

        // Restore to saved position and clear to end of screen
        fputs("\u{1B}8\u{1B}[J\(prompt)\(text)", stdout)

        // Position cursor correctly using visual widths
        let cursorOffset = buffer.count - cursorPos
        if cursorOffset > 0 {
            let cursorVisualPos = promptWidth + textWidth(buffer[0..<cursorPos])
            let endVisualPos = promptWidth + textWidth(buffer[...])
            let targetLine = cursorVisualPos / termWidth
            let endLine = endVisualPos / termWidth
            let targetCol = cursorVisualPos % termWidth

            // Move up if needed
            let linesToMoveUp = endLine - targetLine
            if linesToMoveUp > 0 {
                fputs("\u{1B}[\(linesToMoveUp)A", stdout)
            }

            // Move to correct column
            fputs("\r", stdout)
            if targetCol > 0 {
                fputs("\u{1B}[\(targetCol)C", stdout)
            }
        }

        fflush(stdout)
    }

    redraw()

    while true {
        var c: UInt8 = 0
        let bytesRead = read(STDIN_FILENO, &c, 1)

        guard bytesRead == 1 else { continue }

        switch c {
        case 3:  // Ctrl+C
            fputs("\n", stdout)
            fflush(stdout)
            return nil

        case 13, 10:  // Enter
            // Move to end and newline
            let termWidth = getTerminalWidth()
            let cursorVisualPos = promptWidth + textWidth(buffer[0..<cursorPos])
            let endVisualPos = promptWidth + textWidth(buffer[...])
            let linesToEnd = (endVisualPos / termWidth) - (cursorVisualPos / termWidth)
            if linesToEnd > 0 {
                fputs("\u{1B}[\(linesToEnd)B", stdout)
            }
            fputs("\n", stdout)
            fflush(stdout)
            let result = String(buffer)
            return result.isEmpty ? nil : result

        case 127, 8:  // Backspace / Delete
            if cursorPos > 0 {
                buffer.remove(at: cursorPos - 1)
                cursorPos -= 1
                redraw()
            }

        case 27:  // Escape sequence (arrow keys)
            var seq: [UInt8] = [0, 0]
            if read(STDIN_FILENO, &seq[0], 1) == 1 && read(STDIN_FILENO, &seq[1], 1) == 1 {
                if seq[0] == 91 {  // [
                    switch seq[1] {
                    case 68:  // Left arrow
                        if cursorPos > 0 {
                            cursorPos -= 1
                            redraw()
                        }
                    case 67:  // Right arrow
                        if cursorPos < buffer.count {
                            cursorPos += 1
                            redraw()
                        }
                    case 72:  // Home
                        cursorPos = 0
                        redraw()
                    case 70:  // End
                        cursorPos = buffer.count
                        redraw()
                    default:
                        break
                    }
                }
            }

        case 1:  // Ctrl+A (Home)
            cursorPos = 0
            redraw()

        case 5:  // Ctrl+E (End)
            cursorPos = buffer.count
            redraw()

        case 21:  // Ctrl+U (Clear line)
            buffer.removeAll()
            cursorPos = 0
            redraw()

        case 32...126:  // Printable ASCII
            buffer.insert(Character(UnicodeScalar(c)), at: cursorPos)
            cursorPos += 1
            redraw()

        default:
            // Handle multi-byte UTF-8 characters
            if c >= 0xC0 && c < 0xF8 {
                var bytes = [c]
                let bytesNeeded: Int
                if c < 0xE0 { bytesNeeded = 2 }
                else if c < 0xF0 { bytesNeeded = 3 }
                else { bytesNeeded = 4 }

                for _ in 1..<bytesNeeded {
                    var cont: UInt8 = 0
                    if read(STDIN_FILENO, &cont, 1) == 1 {
                        bytes.append(cont)
                    }
                }

                if let str = String(bytes: bytes, encoding: .utf8), let char = str.first {
                    buffer.insert(char, at: cursorPos)
                    cursorPos += 1
                    redraw()
                }
            }
        }
    }
}
