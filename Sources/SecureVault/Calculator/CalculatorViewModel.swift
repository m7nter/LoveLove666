import Foundation
import Combine

class CalculatorViewModel: ObservableObject {
    @Published var display: String = "0"
    @Published var expression: String = ""
    @Published var shouldUnlock: Bool = false
    @Published var history: [String] = []

    private var currentInput: String = ""
    private var storedValue: Double = 0
    private var currentOperator: String? = nil
    private var shouldResetDisplay = false
    private var lastOperator: String? = nil
    private var lastOperand: Double = 0
    private var pinInput = ""
    private var pinEntryInvalid = false
    private let pinAttemptsKey = "vaultPinAttempts"
    private let pinCooldownKey = "vaultPinCooldownUntil"
    private let formatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.groupingSeparator = " "
        formatter.decimalSeparator = ","
        formatter.maximumFractionDigits = 6
        formatter.groupingSize = 3
        return formatter
    }()

    var clearButtonTitle: String {
        currentInput.isEmpty && display == "0" ? "AC" : "C"
    }

    var activeOperator: String? {
        shouldResetDisplay ? currentOperator : nil
    }

    func tap(_ symbol: String) {
        switch symbol {
        case "0"..."9":
            handleDigit(symbol)
        case ",", ".":
            handleDigit(".")
        case "+", "−", "×", "÷":
            handleOperator(symbol)
        case "=":
            handleEquals()
        case "AC":
            reset()
        case "C":
            clearCurrent()
        case "⌫":
            handleBackspace()
        case "+/−":
            toggleSign()
        case "%":
            handlePercent()
        default:
            break
        }
    }

    private func clearCurrent() {
        currentInput = ""
        pinInput = ""
        pinEntryInvalid = false
        display = "0"
    }

    private func formatted(_ value: Double) -> String {
        return formatter.string(from: NSNumber(value: value)) ?? formatResult(value)
    }

    private func handleDigit(_ d: String) {
        if d == "." && currentInput.contains(".") { return }
        var digitAccepted = true
        if shouldResetDisplay {
            if currentOperator == nil { lastOperator = nil; lastOperand = 0 }
            currentInput = d == "." ? "0." : d
            pinInput = ""
            pinEntryInvalid = currentOperator != nil
            shouldResetDisplay = false
        } else {
            if currentInput == "0" && d != "." {
                currentInput = d
            } else {
                if currentInput.count < 9 { currentInput += d }
                else { digitAccepted = false }
            }
        }
        if d == "." {
            pinInput = ""
            pinEntryInvalid = true
        } else if digitAccepted && currentOperator == nil && !pinEntryInvalid {
            if pinInput.count < 8 { pinInput += d }
            else {
                pinInput = ""
                pinEntryInvalid = true
            }
        }
        if let val = Double(currentInput) {
            display = formatted(val) + (currentInput.hasSuffix(".") ? "," : "")
        } else {
            display = currentInput.replacingOccurrences(of: ".", with: ",")
        }
    }

    private func handleBackspace() {
        if !currentInput.isEmpty {
            currentInput.removeLast()
            if !pinInput.isEmpty { pinInput.removeLast() }
            if currentInput.isEmpty || currentInput == "-" { currentInput = "0" }
            if let val = Double(currentInput) {
                display = formatted(val)
            } else {
                display = currentInput.replacingOccurrences(of: ".", with: ",")
            }
        }
    }

    private func handleOperator(_ op: String) {
        pinInput = ""
        pinEntryInvalid = true
        if !currentInput.isEmpty {
            storedValue = Double(currentInput) ?? 0
        }
        expression = "\(formatted(storedValue))  \(op)"
        currentOperator = op
        shouldResetDisplay = true
        currentInput = ""
    }

    private func handleEquals() {
        let directEntry = currentOperator == nil && lastOperator == nil && !currentInput.isEmpty
        if directEntry && !pinEntryInvalid, (try? VaultGate.shared.withAccess { true }) == true {
            let store = SettingsStore.shared
            if canTryCode && store.kamikazeCodeEnabled && !store.kamikazeCode.isEmpty
                && store.kamikazeCode != store.mainCode && pinInput == store.kamikazeCode {
                VaultLifecycle.shared.erase(.photos)
                reset()
                return
            }

            if canTryCode && !store.mainCode.isEmpty && pinInput == store.mainCode {
                UserDefaults.standard.removeObject(forKey: pinAttemptsKey)
                UserDefaults.standard.removeObject(forKey: pinCooldownKey)
                shouldUnlock = true
                reset()
                return
            }
            if (4...8).contains(pinInput.count) && pinInput.allSatisfy(\.isNumber) {
                recordFailedCode()
            }
            pinInput = ""
            pinEntryInvalid = true
        }

        guard let op = currentOperator,
              let rhs = Double(currentInput) else {
            // Повторное нажатие "=" — повторяем последнюю операцию
            if let op = lastOperator {
                let rhs = lastOperand
                let result: Double
                switch op {
                case "+": result = storedValue + rhs
                case "−": result = storedValue - rhs
                case "×": result = storedValue * rhs
                case "÷": result = rhs != 0 ? storedValue / rhs : 0
                default: return
                }

                let entry = "\(formatted(storedValue))  \(op)  \(formatted(rhs)) = \(formatted(result))"
                history.append(entry)
                expression = "\(formatted(storedValue))  \(op)  \(formatted(rhs))"

                storedValue = result
                currentInput = formatResult(result)
                display = formatted(result)
                shouldResetDisplay = true
            }
            return
        }

        lastOperator = op
        lastOperand = rhs

        let result: Double
        switch op {
        case "+": result = storedValue + rhs
        case "−": result = storedValue - rhs
        case "×": result = storedValue * rhs
        case "÷": result = rhs != 0 ? storedValue / rhs : 0
        default: return
        }

        let entry = "\(formatted(storedValue))  \(op)  \(formatted(rhs)) = \(formatted(result))"
        history.append(entry)
        expression = "\(formatted(storedValue))  \(op)  \(formatted(rhs))"

        storedValue = result
        currentInput = formatResult(result)
        display = formatted(result)
        currentOperator = nil
        shouldResetDisplay = true
    }

    private func formatResult(_ v: Double) -> String {
        if v.truncatingRemainder(dividingBy: 1) == 0 && abs(v) < 1e9 {
            return String(Int(v))
        }
        return String(format: "%.6g", v)
    }

    private func reset() {
        display = "0"
        expression = ""
        currentInput = ""
        storedValue = 0
        currentOperator = nil
        shouldResetDisplay = false
        lastOperator = nil
        lastOperand = 0
        pinInput = ""
        pinEntryInvalid = false
    }

    private func toggleSign() {
        pinInput = ""
        pinEntryInvalid = true
        if let v = Double(currentInput) {
            let toggled = -v
            currentInput = formatResult(toggled)
            display = formatted(toggled)
        }
    }

    private func handlePercent() {
        pinInput = ""
        pinEntryInvalid = true
        guard let v = Double(currentInput) else { return }
        let pct: Double
        if let op = currentOperator, (op == "+" || op == "−") {
            // Процент от первого числа (как в стандартном калькуляторе)
            pct = storedValue * (v / 100)
        } else {
            pct = v / 100
        }
        currentInput = formatResult(pct)
        display = formatted(pct)
    }

    private var canTryCode: Bool {
        Date().timeIntervalSince1970 >= UserDefaults.standard.double(forKey: pinCooldownKey)
    }

    private func recordFailedCode() {
        let now = Date().timeIntervalSince1970
        guard canTryCode else { return }
        var attempts = (UserDefaults.standard.array(forKey: pinAttemptsKey) as? [TimeInterval] ?? [])
            .filter { now - $0 < 60 }
        attempts.append(now)
        if attempts.count >= 6 {
            UserDefaults.standard.set(now + 60, forKey: pinCooldownKey)
            UserDefaults.standard.removeObject(forKey: pinAttemptsKey)
        } else {
            UserDefaults.standard.set(attempts, forKey: pinAttemptsKey)
        }
    }
}
