import Foundation
import ATVKit

/// Types into a TV text field by steering the TV's own on-screen keyboard:
/// arrow keys to the letter, then OK.
///
/// The fallback for TVs that drop typed text from remotes. A Xiaomi
/// MiTV-MOOR2 (Android 11, remote service 7.00) ignores both ime batch edits
/// and letter keycodes, yet accepts arrows, OK and Delete — and reports the
/// field's contents after every change. That report is what makes this
/// dependable: each press is checked against it, so a missed or misplaced
/// press is noticed, erased and retried instead of compounding.
///
/// Layout of the standard Android TV keyboard, mapped on that TV. Rows wrap
/// left/right; Up from the top row lands on the bottom row (Space when
/// starting from the second column); Down from the bottom row leaves the
/// keyboard for the Search button, so it is never pressed.
@MainActor
final class KeyboardDriver {

    struct Key: Equatable {
        var row: Int
        var col: Int
    }

    private enum Position: Equatable {
        case unknown
        case key(Key)
        /// On the bottom row's Space bar; Up from there lands somewhere on
        /// the third row, column unknown.
        case space
    }

    private static let columns = 10
    private static let rows: [[Character]] = [
        Array("qwertyuiop"),
        Array("asdfghjkl,"),
        Array("\u{21E7}zxcvbnm.\u{232B}"),     // Shift … Backspace
    ]
    private static let shift = Key(row: 2, col: 0)
    /// Up from here reaches Space.
    private static let spaceApproach = Key(row: 0, col: 1)
    /// Where Up from Space is assumed to land; the next press confirms it.
    private static let belowSpaceGuess = Key(row: 2, col: 4)

    private var position: Position = .unknown

    /// Characters the keyboard can produce from its letter page.
    static func canType(_ c: Character) -> Bool {
        if c == " " || c == "," || c == "." { return true }
        return c.isLetter && key(for: Character(c.lowercased())) != nil
    }

    /// Call when something else may have moved the highlight — the user
    /// pressing arrows, or the field closing.
    func forgetPosition() {
        position = .unknown
    }

    enum Failure: Error {
        case noField
        case lost
    }

    /// Edits the TV field until it reads `target()`, which is re-read every
    /// step so typing that continues meanwhile is picked up.
    func sync(_ remote: RemoteSession, to target: @MainActor () -> String) async throws {
        var budget = 0
        while true {
            let goal = target().filter(Self.canType)
            guard let current = await remote.deviceState.fieldValue else { throw Failure.noField }
            if Self.matches(current, goal) { return }

            budget += 1
            // Generous: a short word costs a handful of steps, a correction a few more.
            guard budget < goal.count * 4 + 20 else { throw Failure.lost }

            let shared = Self.sharedPrefix(current, goal)
            if current.count > shared {
                // Delete is a plain keycode this TV accepts; it erases before
                // the caret, which stays at the end because only we type here.
                try await press(.backspace, on: remote, expectChange: true)
                continue
            }
            let next = goal[goal.index(goal.startIndex, offsetBy: shared)]
            try await type(next, on: remote, after: current)
        }
    }

    // MARK: - One character

    private func type(_ c: Character, on remote: RemoteSession, after current: String) async throws {
        if position == .unknown {
            try await locate(on: remote)
            return      // locating typed a character; the caller re-diffs
        }

        if c == " " {
            try await move(to: Self.spaceApproach, on: remote)
            try await remote.send(.up)
            position = .space
            try await press(.select, on: remote, expectChange: true)
            return
        }

        let lower = Character(c.lowercased())
        guard let target = Self.key(for: lower) else { return }
        if c.isUppercase {
            try await move(to: Self.shift, on: remote)
            try await remote.send(.select)      // one-shot shift; no field change
            try await pause()
        }
        try await move(to: target, on: remote)
        let typed = try await pressAndRead(on: remote, before: current)
        position = typed.flatMap { Self.key(for: Character($0.lowercased())) }.map(Position.key) ?? .unknown
    }

    /// Finds the highlight by pressing OK and seeing what it typed. The stray
    /// character is erased by the next sync step.
    private func locate(on remote: RemoteSession) async throws {
        for _ in 0..<3 {
            let before = await remote.deviceState.fieldValue ?? ""
            if let typed = try await pressAndRead(on: remote, before: before),
               let key = Self.key(for: Character(typed.lowercased())) {
                position = .key(key)
                return
            }
            // Not a letter key (Shift, a mode key…): step right and retry.
            try await remote.send(.right)
            try await pause()
        }
        throw Failure.lost
    }

    // MARK: - Moving

    private func move(to target: Key, on remote: RemoteSession) async throws {
        var from: Key
        switch position {
        case .key(let key):
            from = key
        case .space:
            try await remote.send(.up)
            try await pause()
            from = Self.belowSpaceGuess
        case .unknown:
            throw Failure.lost
        }

        // Rows 0–2 only: never Up from the top row or Down from the third.
        while from.row < target.row { try await remote.send(.down); from.row += 1; try await pause() }
        while from.row > target.row { try await remote.send(.up); from.row -= 1; try await pause() }

        let right = (target.col - from.col + Self.columns) % Self.columns
        if right <= Self.columns / 2 {
            for _ in 0..<right { try await remote.send(.right); try await pause() }
        } else {
            for _ in 0..<(Self.columns - right) { try await remote.send(.left); try await pause() }
        }
        position = .key(target)
    }

    // MARK: - Pressing

    /// Presses OK and returns the character it appended, if any.
    private func pressAndRead(on remote: RemoteSession, before: String) async throws -> String? {
        let revision = await remote.deviceState.fieldRevision
        try await remote.send(.select)
        guard let after = await waitForReport(on: remote, after: revision),
              after.count == before.count + 1 else { return nil }
        return String(after.last!)
    }

    private func press(_ command: RemoteCommand, on remote: RemoteSession, expectChange: Bool) async throws {
        let revision = await remote.deviceState.fieldRevision
        try await remote.send(command)
        if expectChange { _ = await waitForReport(on: remote, after: revision) }
    }

    /// Waits for the TV's next report of the field. Nil on timeout.
    private func waitForReport(on remote: RemoteSession, after revision: Int) async -> String? {
        for _ in 0..<32 {      // ~800 ms
            let state = await remote.deviceState
            if state.fieldRevision != revision { return state.fieldValue }
            try? await Task.sleep(nanoseconds: 25_000_000)
        }
        return nil
    }

    /// Gap between arrow presses, so the TV's focus animation keeps up.
    private func pause() async throws {
        try await Task.sleep(nanoseconds: 55_000_000)
    }

    // MARK: - Text helpers

    private static func key(for c: Character) -> Key? {
        for (row, keys) in rows.enumerated() {
            if let col = keys.firstIndex(of: c) { return Key(row: row, col: col) }
        }
        return nil
    }

    /// The TV may capitalise on its own (start of a sentence), so a capital
    /// where a lowercase letter was asked for still counts as a match —
    /// otherwise it would be erased and retyped forever.
    private static func same(_ got: Character, _ wanted: Character) -> Bool {
        got == wanted || (wanted.isLowercase && got.lowercased() == String(wanted))
    }

    private static func sharedPrefix(_ a: String, _ b: String) -> Int {
        zip(a, b).prefix { same($0, $1) }.count
    }

    private static func matches(_ a: String, _ b: String) -> Bool {
        a.count == b.count && sharedPrefix(a, b) == a.count
    }
}
