import XCTest
@testable import SecureVault

final class CalculatorTests: XCTestCase {
    private func calculate(_ keys: [String]) -> CalculatorViewModel {
        let vm = CalculatorViewModel(); vm.allowsVaultEntry = false
        for key in keys { vm.tap(key) }
        return vm
    }
    func testPrecedenceAndParentheses() {
        XCTAssertEqual(calculate(["2", "+", "3", "×", "4", "="]).numericValue, 14)
        XCTAssertEqual(calculate(["(", "2", "+", "3", ")", "×", "4", "="]).numericValue, 20)
    }
    func testLongChainAndRepeatedEquals() {
        XCTAssertEqual(calculate(["8", "+", "2", "−", "3", "="]).numericValue, 7)
        XCTAssertEqual(calculate(["2", "+", "3", "=", "=", "="]).numericValue, 11)
    }
    func testPercentOfLeftOperand() {
        XCTAssertEqual(calculate(["2", "0", "0", "+", "1", "0", "%", "="]).numericValue, 220)
        XCTAssertEqual(calculate(["2", "0", "0", "×", "1", "0", "%", "="]).numericValue, 20)
    }
    func testDivisionByZeroIsUndefinedAndInvalidRootShowsError() {
        XCTAssertEqual(calculate(["2", "0", "2", "6", "÷", "0", "="]).display, "Не определено")
        XCTAssertEqual(calculate(["0", "÷", "0", "="]).display, "Не определено")
        XCTAssertEqual(calculate(["0", "1/x"]).display, "Не определено")
        XCTAssertEqual(calculate(["1", "÷", "(", "2", "−", "2", ")", "="]).display, "Не определено")
        XCTAssertEqual(calculate(["9", "+/−", "²√x"]).display, "Ошибка")
        XCTAssertEqual(calculate(["4", "÷", "0", "=", "7"]).numericValue, 7)
    }
    func testDegreesRadiansAndInverseTrig() throws {
        XCTAssertEqual(try XCTUnwrap(calculate(["3", "0", "sin"]).numericValue), 0.5, accuracy: 1e-12)
        XCTAssertEqual(try XCTUnwrap(calculate(["0", ",", "5", "sin⁻¹"]).numericValue), 30, accuracy: 1e-10)
        XCTAssertEqual(try CalculationEngine.unary("sin", value: .pi / 2, radians: true), 1, accuracy: 1e-12)
    }
    func testFactorialPowerRootsLogAndExponent() throws {
        XCTAssertEqual(calculate(["7", "x!", "÷", "2", "−", "(", "2", "xʸ", "2", "×", "1", "3", "6", ")", "="]).numericValue, 1976)
        XCTAssertEqual(calculate(["2", "xʸ", "1", "0", "="]).numericValue, 1024)
        XCTAssertEqual(try XCTUnwrap(calculate(["2", "7", "ʸ√x", "3", "="]).numericValue), 3, accuracy: 1e-12)
        XCTAssertEqual(calculate(["1", "0", "0", "log₁₀"]).numericValue, 2)
        XCTAssertEqual(calculate(["2", "EE", "3", "="]).numericValue, 2000)
    }
    func testMemoryAndClearEntry() {
        XCTAssertEqual(calculate(["8", "m+", "AC", "2", "m−", "mr"]).numericValue, 6)
        XCTAssertEqual(calculate(["8", "+", "9", "C", "2", "="]).numericValue, 10)
        XCTAssertEqual(calculate(["(", "2", "+", "3", ")", "m+", "×", "2", "="]).numericValue, 10)
    }
    func testTemperatureAndReverseConversion() throws {
        let units = ConversionCategory.temperature.units
        XCTAssertEqual(try XCTUnwrap(ConversionUnit.convert(0, from: units[0], to: units[1])), 32, accuracy: 1e-10)
        XCTAssertEqual(try XCTUnwrap(ConversionUnit.convert(212, from: units[1], to: units[0])), 100, accuracy: 1e-10)
    }
    func testLengthAndFuelAndBinaryData() throws {
        let length = ConversionCategory.length.units
        XCTAssertEqual(ConversionUnit.convert(1, from: length[4], to: length[0]), 1609.344)
        let fuel = ConversionCategory.fuel.units
        XCTAssertEqual(try XCTUnwrap(ConversionUnit.convert(10, from: fuel[0], to: fuel[1])), 23.5214583, accuracy: 1e-7)
        XCTAssertNil(ConversionUnit.convert(0, from: fuel[0], to: fuel[1]))
        let data = ConversionCategory.data.units
        XCTAssertEqual(ConversionUnit.convert(1, from: data[8], to: data[0]), 1073741824)
    }
    func testCrossCurrencyRatesMissingRateAndDates() throws {
        let json = Data("""
        [{"date":"2026-10-13","base":"USD","quote":"EUR","rate":0.8},
         {"date":"2026-10-14","base":"USD","quote":"RUB","rate":80}]
        """.utf8)
        let book = ExchangeRateBook(rates: try JSONDecoder().decode([ExchangeRate].self, from: json))
        XCTAssertEqual(book.convert(10, from: "EUR", to: "RUB"), 1000)
        XCTAssertEqual(book.convert(80, from: "RUB", to: "USD"), 1)
        XCTAssertNil(book.convert(10, from: "EUR", to: "INVALID"))
        XCTAssertEqual(book.date(from: "EUR", to: "RUB"), "2026-10-13")
    }
    func testInvalidCurrencyRatesAreRejected() {
        let book = ExchangeRateBook(rates: [.init(date: "2026-10-14", base: "USD", quote: "EUR", rate: 0)])
        XCTAssertNil(book.convert(1, from: "EUR", to: "USD"))
        XCTAssertEqual(book.convert(10, from: "EUR", to: "EUR"), 10)
    }
}
