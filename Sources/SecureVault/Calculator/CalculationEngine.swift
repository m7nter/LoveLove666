import Foundation

enum CalculationError: Error { case invalidExpression, domain, undefined }

// Recursive descent preserves precedence and parentheses without evaluating code.
struct CalculationEngine {
    private let tokens: [String]
    private var index = 0
    static func evaluate(_ tokens: [String]) throws -> Double {
        var parser = CalculationEngine(tokens: tokens)
        let value = try parser.sum()
        guard parser.index == tokens.count, value.isFinite else { throw CalculationError.invalidExpression }
        return value
    }
    private mutating func take(_ value: String) -> Bool {
        guard index < tokens.count, tokens[index] == value else { return false }
        index += 1; return true
    }
    private mutating func sum() throws -> Double {
        var value = try product()
        while index < tokens.count {
            if take("+") { value += try product() }
            else if take("−") { value -= try product() }
            else { break }
        }
        return value
    }
    private mutating func product() throws -> Double {
        var value = try power()
        while index < tokens.count {
            if take("×") { value *= try power() }
            else if take("÷") {
                let rhs = try power()
                guard rhs != 0 else { throw CalculationError.undefined }
                value /= rhs
            } else { break }
        }
        return value
    }
    private mutating func power() throws -> Double {
        var value = try atom()
        if take("^") { value = pow(value, try power()) }
        else if take("root") {
            let n = try power()
            guard n != 0 else { throw CalculationError.domain }
            value = value < 0 && n.rounded() == n && Int(abs(n).truncatingRemainder(dividingBy: 2)) == 1
                ? -pow(-value, 1 / n) : pow(value, 1 / n)
        }
        return value
    }
    private mutating func atom() throws -> Double {
        if take("(") {
            let value = try sum()
            guard take(")") else { throw CalculationError.invalidExpression }
            return value
        }
        guard index < tokens.count, let value = Double(tokens[index]) else { throw CalculationError.invalidExpression }
        index += 1
        return value
    }

    static func unary(_ operation: String, value x: Double, radians: Bool) throws -> Double {
        let angle = radians ? x : x * .pi / 180
        let inverseScale = radians ? 1.0 : 180 / Double.pi
        let value: Double
        switch operation {
        case "x²": value = x * x
        case "x³": value = x * x * x
        case "1/x":
            guard x != 0 else { throw CalculationError.undefined }
            value = 1 / x
        case "²√x": value = sqrt(x)
        case "³√x": value = cbrt(x)
        case "ln": value = log(x)
        case "log₁₀": value = log10(x)
        case "log₂": value = log2(x)
        case "eˣ": value = exp(x)
        case "10ˣ": value = pow(10, x)
        case "2ˣ": value = pow(2, x)
        case "sin": value = sin(angle)
        case "cos": value = cos(angle)
        case "tan":
            guard abs(cos(angle)) > 1e-14 else { throw CalculationError.domain }
            value = tan(angle)
        case "sin⁻¹": value = asin(x) * inverseScale
        case "cos⁻¹": value = acos(x) * inverseScale
        case "tan⁻¹": value = atan(x) * inverseScale
        case "sinh": value = sinh(x)
        case "cosh": value = cosh(x)
        case "tanh": value = tanh(x)
        case "sinh⁻¹": value = asinh(x)
        case "cosh⁻¹": value = acosh(x)
        case "tanh⁻¹": value = atanh(x)
        case "x!":
            guard x >= 0, x <= 170, x.rounded() == x else { throw CalculationError.domain }
            value = x < 2 ? 1 : (2...Int(x)).reduce(1.0) { $0 * Double($1) }
        default: throw CalculationError.invalidExpression
        }
        guard value.isFinite else { throw CalculationError.domain }
        return abs(value) < 1e-15 ? 0 : value
    }
}
