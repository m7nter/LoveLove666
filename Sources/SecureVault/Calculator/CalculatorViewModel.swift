import Foundation
import Combine

struct HistoryRecord: Identifiable, Codable, Equatable {
    let id: UUID
    let expression: String
    let result: String
    let date: Date
    var text: String { "\(expression) = \(result)" }
}

final class CalculatorViewModel: ObservableObject {
    @Published var display = "0"
    @Published var expression = ""
    @Published var shouldUnlock = false
    private(set) var pendingUnlockCode: String?
    @Published var history: [HistoryRecord] = CalculatorViewModel.loadHistory() {
        didSet {
            if let data = try? JSONEncoder().encode(history) {
                ProtectedPreferences.set(data, forKey: "calculator.history.v2")
            }
        }
    }
    @Published var radians = false
    @Published var second = false
    @Published var memory: Double = 0
    var allowsVaultEntry = true
    private var tokens: [String] = []
    private var input = ""
    private var replaceInput = false
    private var finished = false
    private var repeated: (String, Double)?
    private var pinInput = ""
    private var pinEligible = true
    private let operators = ["+", "−", "×", "÷", "^", "root"]
    private let pinAttemptsKey = "vaultPinAttempts"
    private let pinCooldownKey = "vaultPinCooldownUntil"
    var clearButtonTitle: String { finished || (input.isEmpty && tokens.isEmpty) ? "AC" : "C" }
    var activeOperator: String? { input.isEmpty && operators.contains(tokens.last ?? "") ? tokens.last : nil }
    var numericValue: Double? { Double(input) ?? (try? CalculationEngine.evaluate(tokens)) }

    static func format(_ value: Double) -> String {
        guard value.isFinite else { return "Ошибка" }
        if value != 0 && (abs(value) >= 1e12 || abs(value) < 1e-7) {
            return String(format: "%.9g", value).replacingOccurrences(of: ".", with: ",")
        }
        let f = NumberFormatter()
        f.numberStyle = .decimal; f.groupingSeparator = " "; f.decimalSeparator = ","
        f.maximumFractionDigits = 10; f.maximumSignificantDigits = 12; f.usesSignificantDigits = true
        return f.string(from: NSNumber(value: value)) ?? String(value)
    }

    func tap(_ symbol: String) {
        if symbol.count == 1, "0123456789".contains(symbol) { digit(symbol); return }
        switch symbol {
        case ",", ".": digit(".")
        case "AC": reset()
        case "C":
            if input.isEmpty { reset() }
            else { input = ""; display = "0"; pinInput = ""; pinEligible = tokens.isEmpty; replaceInput = false }
        case "⌫":
            if !input.isEmpty {
                input.removeLast()
                if !pinInput.isEmpty { pinInput.removeLast() }
                display = input.isEmpty ? "0" : Self.format(Double(input) ?? 0)
                replaceInput = false
            }
        case "=": equals()
        case "+", "−", "×", "÷", "xʸ", "ʸ√x", "EE":
            let op = symbol == "xʸ" ? "^" : symbol == "ʸ√x" ? "root" : symbol
            invalidatePIN(); finished = false; repeated = nil
            commitInput()
            if tokens.isEmpty { tokens = ["0"] }
            if operators.contains(tokens.last ?? "") { tokens.removeLast() }
            if symbol == "EE" { tokens += ["×", "10", "^"] }
            else { tokens.append(op) }
            expression = readable(tokens)
        case "(":
            if finished { reset() }
            invalidatePIN(); commitInput()
            if let last = tokens.last, last == ")" || Double(last) != nil { tokens.append("×") }
            tokens.append("("); expression = readable(tokens)
        case ")":
            invalidatePIN(); commitInput()
            let balance = tokens.filter { $0 == "(" }.count - tokens.filter { $0 == ")" }.count
            if balance > 0, let last = tokens.last, !operators.contains(last), last != "(" {
                tokens.append(")"); expression = readable(tokens)
                if let result = try? CalculationEngine.evaluate(tokens) { display = Self.format(result) }
            }
        case "+/−": transform { -$0 }
        case "%":
            invalidatePIN()
            let x = operand()
            var result = x / 100
            if let op = tokens.last, op == "+" || op == "−",
               let base = try? CalculationEngine.evaluate(Array(tokens.dropLast())) { result *= base }
            setValue(result)
        case "2nd": second.toggle(); invalidatePIN()
        case "Rad", "Deg": radians.toggle(); invalidatePIN()
        case "mc": memory = 0; invalidatePIN()
        case "m+": memory += operand(consumingGroup: false); invalidatePIN()
        case "m−": memory -= operand(consumingGroup: false); invalidatePIN()
        case "mr": _ = operand(); setValue(memory); invalidatePIN()
        case "π": constant(.pi)
        case "e": constant(M_E)
        case "Rand": constant(Double.random(in: 0..<1))
        default:
            invalidatePIN()
            let x = operand()
            do {
                let result = try CalculationEngine.unary(symbol, value: x, radians: radians)
                expression = "\(symbol)(\(Self.format(x)))"
                setValue(result)
            } catch { showError(error) }
        }
    }
    private func digit(_ digit: String) {
        if finished { reset() }
        if replaceInput { input = ""; replaceInput = false; pinInput = "" }
        if tokens.last == ")" { tokens.append("×"); invalidatePIN() }
        if digit == "." {
            guard !input.contains("."), !input.contains("e") else { return }
            invalidatePIN()
            if input.isEmpty { input = "0" }
        }
        guard input.filter({ $0.isNumber }).count < 16 else { return }
        if input == "0" && digit != "." { input = digit } else { input += digit }
        if pinEligible && tokens.isEmpty { pinInput += digit }
        display = Self.format(Double(input) ?? 0)
        if input.hasSuffix(".") { display += "," }
        if let dot = input.firstIndex(of: "."), input.hasSuffix("0") {
            display = Self.format(Double(input[..<dot]) ?? 0) + "," + input[input.index(after: dot)...]
        }
    }
    private func commitInput() {
        if !input.isEmpty { tokens.append(input); input = "" }
        replaceInput = false
    }
    private func invalidatePIN() { pinEligible = false; pinInput = "" }
    private func operand(consumingGroup: Bool = true) -> Double {
        if let value = Double(input) { return value }
        if tokens.last == ")" {
            var depth = 0
            for i in tokens.indices.reversed() {
                if tokens[i] == ")" { depth += 1 }
                if tokens[i] == "(" { depth -= 1 }
                if depth == 0 {
                    let group = Array(tokens[i...])
                    if let value = try? CalculationEngine.evaluate(group) {
                        if consumingGroup { tokens.removeSubrange(i...) }
                        return value
                    }
                    break
                }
            }
        }
        return 0
    }
    private func setValue(_ value: Double) {
        guard value.isFinite else { showError(); return }
        input = String(value); display = Self.format(value)
        replaceInput = true; finished = false
    }
    private func transform(_ action: (Double) -> Double) { invalidatePIN(); setValue(action(operand())) }
    private func constant(_ value: Double) {
        if finished { reset() }
        invalidatePIN(); setValue(value)
    }
    private func equals() {
        if allowsVaultEntry && pinEligible && tokens.isEmpty && !pinInput.isEmpty,
           (try? VaultGate.shared.withAccess { true }) == true {
            let store = SettingsStore.shared
            if canTryCode && store.kamikazeCodeEnabled && !store.kamikazeCode.isEmpty
                && store.kamikazeCode != store.mainCode && pinInput == store.kamikazeCode {
                VaultLifecycle.shared.erase(.photos); reset(); return
            }
            if canTryCode && !store.mainCode.isEmpty && store.mainCode != "2026" && pinInput == store.mainCode {
                try? KeychainCodeStore.delete("vaultPinAttempts")
                try? KeychainCodeStore.delete("vaultPinCooldownUntil")
                UserDefaults.standard.removeObject(forKey: pinAttemptsKey)
                UserDefaults.standard.removeObject(forKey: pinCooldownKey)
                pendingUnlockCode = pinInput; shouldUnlock = true; reset(); return
            }
            if (4...8).contains(pinInput.count) { recordFailedCode() }
        }
        invalidatePIN()
        if finished, let repeated, let value = Double(input) {
            tokens = [String(value), repeated.0, String(repeated.1)]; input = ""
        } else { commitInput() }
        if tokens.isEmpty { return }
        // Complete an omitted RHS (5 + = -> 10), but not an incomplete parenthesis.
        if let last = tokens.last, operators.contains(last), tokens.count >= 2 {
            tokens.append(tokens[tokens.count - 2])
        }
        do {
            let result = try CalculationEngine.evaluate(tokens)
            let formula = readable(tokens)
            if !finished, tokens.count >= 3, let rhs = Double(tokens.last!), operators.contains(tokens[tokens.count - 2]) {
                repeated = (tokens[tokens.count - 2], rhs)
            }
            if tokens.count > 1 {
                history.append(HistoryRecord(id: UUID(), expression: formula,
                                             result: Self.format(result), date: Date()))
                if history.count > 100 { history.removeFirst() }
            }
            expression = formula
            tokens = []; input = String(result); display = Self.format(result)
            finished = true; replaceInput = true
        } catch { showError(error) }
    }
    func consumeUnlockCode() -> String? {
        defer { pendingUnlockCode = nil }
        return pendingUnlockCode
    }
    func useHistory(_ entry: HistoryRecord) {
        let result = entry.result
        guard
              let value = Double(result.replacingOccurrences(of: " ", with: "").replacingOccurrences(of: ",", with: ".")) else { return }
        reset(); invalidatePIN(); setValue(value)
    }

    private static func loadHistory() -> [HistoryRecord] {
        if let data = ProtectedPreferences.data(forKey: "calculator.history.v2"),
           let records = try? JSONDecoder().decode([HistoryRecord].self, from: data) {
            return records
        }
        let legacy = UserDefaults.standard.stringArray(forKey: "calculator.history") ?? []
        let records: [HistoryRecord] = legacy.compactMap { value -> HistoryRecord? in
            let parts = value.components(separatedBy: " = ")
            guard parts.count >= 2 else { return nil }
            return HistoryRecord(id: UUID(), expression: parts.dropLast().joined(separator: " = "),
                                 result: parts.last!, date: Date())
        }
        if !records.isEmpty, let data = try? JSONEncoder().encode(records) {
            ProtectedPreferences.set(data, forKey: "calculator.history.v2")
            UserDefaults.standard.removeObject(forKey: "calculator.history")
        }
        return records
    }
    private func readable(_ values: [String]) -> String {
        values.map { Double($0).map(Self.format) ?? ($0 == "root" ? "ʸ√" : $0) }.joined()
    }
    private func showError(_ error: Error? = nil) {
        if case CalculationError.undefined? = error as? CalculationError { display = "Не определено" }
        else { display = "Ошибка" }
        input = ""; tokens = []; finished = true; repeated = nil
        invalidatePIN()
    }
    private func reset() {
        display = "0"; expression = ""; tokens = []; input = ""
        finished = false; replaceInput = false; repeated = nil; pinInput = ""; pinEligible = true
    }
    private var cooldownUntil: TimeInterval {
        let stored = Double(KeychainCodeStore.read("vaultPinCooldownUntil")) ?? 0
        return stored > 0 ? stored : UserDefaults.standard.double(forKey: pinCooldownKey)
    }
    private var canTryCode: Bool { Date().timeIntervalSince1970 >= cooldownUntil }
    private func failedAttempts() -> [TimeInterval] {
        let raw = KeychainCodeStore.read("vaultPinAttempts")
        if let data = raw.data(using: .utf8), let values = try? JSONDecoder().decode([TimeInterval].self, from: data) {
            return values
        }
        return (UserDefaults.standard.array(forKey: pinAttemptsKey) as? [TimeInterval]) ?? []
    }
    private func saveFailedAttempts(_ attempts: [TimeInterval]) {
        guard let data = try? JSONEncoder().encode(attempts), let value = String(data: data, encoding: .utf8) else { return }
        try? KeychainCodeStore.write(value, for: "vaultPinAttempts")
        UserDefaults.standard.removeObject(forKey: pinAttemptsKey)
    }
    private func recordFailedCode() {
        let now = Date().timeIntervalSince1970
        guard canTryCode else { return }
        var attempts = failedAttempts().filter { now - $0 < 60 }
        attempts.append(now)
        if attempts.count >= 6 {
            try? KeychainCodeStore.write(String(now + 60), for: "vaultPinCooldownUntil")
            try? KeychainCodeStore.delete("vaultPinAttempts")
            UserDefaults.standard.removeObject(forKey: pinCooldownKey)
            UserDefaults.standard.removeObject(forKey: pinAttemptsKey)
        } else { saveFailedAttempts(attempts) }
    }
}
