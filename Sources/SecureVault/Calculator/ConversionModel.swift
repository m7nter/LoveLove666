import Foundation
import Combine

enum ConversionCategory: String, CaseIterable, Identifiable {
    case currency = "Валюта", length = "Длина", mass = "Масса", temperature = "Температура"
    case area = "Площадь", volume = "Объём", speed = "Скорость", time = "Время"
    case energy = "Энергия", power = "Мощность", pressure = "Давление", angle = "Угол"
    case data = "Данные", fuel = "Расход топлива"
    var id: String { rawValue }
    var units: [ConversionUnit] {
        switch self {
        case .currency:
            return ["RUB", "USD", "EUR", "GBP", "CNY", "JPY", "CHF", "AED", "TRY", "KZT", "GEL", "AMD", "BYN", "UAH", "CAD", "AUD", "INR", "THB", "KRW", "BRL", "MXN", "SGD", "HKD", "SEK", "NOK", "DKK", "PLN", "CZK", "ILS", "VND", "IDR", "NZD", "ZAR", "SAR"]
                .map { ConversionUnit($0, Locale(identifier: "ru_RU").localizedString(forCurrencyCode: $0) ?? $0, 1) }
        case .length: return [.init("m", "Метры", 1), .init("km", "Километры", 1000), .init("cm", "Сантиметры", 0.01), .init("mm", "Миллиметры", 0.001), .init("mi", "Мили", 1609.344), .init("yd", "Ярды", 0.9144), .init("ft", "Футы", 0.3048), .init("in", "Дюймы", 0.0254), .init("nmi", "Морские мили", 1852)]
        case .mass: return [.init("kg", "Килограммы", 1), .init("g", "Граммы", 0.001), .init("mg", "Миллиграммы", 0.000001), .init("t", "Тонны", 1000), .init("lb", "Фунты", 0.45359237), .init("oz", "Унции", 0.028349523125), .init("st", "Стоуны", 6.35029318)]
        case .temperature: return [.init("°C", "Цельсий", 1, 273.15), .init("°F", "Фаренгейт", 5.0/9, 255.3722222222222), .init("K", "Кельвин", 1)]
        case .area: return [.init("m²", "Квадратные метры", 1), .init("km²", "Квадратные километры", 1e6), .init("cm²", "Квадратные сантиметры", 1e-4), .init("ha", "Гектары", 10000), .init("ac", "Акры", 4046.8564224), .init("ft²", "Квадратные футы", 0.09290304)]
        case .volume: return [.init("L", "Литры", 1), .init("mL", "Миллилитры", 0.001), .init("m³", "Кубические метры", 1000), .init("gal US", "Галлоны США", 3.785411784), .init("gal UK", "Британские галлоны", 4.54609), .init("fl oz", "Жидкие унции США", 0.0295735295625), .init("cup", "Чашки США", 0.2365882365)]
        case .speed: return [.init("km/h", "Километры в час", 1/3.6), .init("m/s", "Метры в секунду", 1), .init("mph", "Мили в час", 0.44704), .init("kn", "Узлы", 0.5144444444)]
        case .time: return [.init("s", "Секунды", 1), .init("min", "Минуты", 60), .init("h", "Часы", 3600), .init("d", "Дни", 86400), .init("wk", "Недели", 604800), .init("ms", "Миллисекунды", 0.001)]
        case .energy: return [.init("J", "Джоули", 1), .init("kJ", "Килоджоули", 1000), .init("cal", "Калории", 4.184), .init("kcal", "Килокалории", 4184), .init("kWh", "Киловатт-часы", 3.6e6)]
        case .power: return [.init("W", "Ватты", 1), .init("kW", "Киловатты", 1000), .init("MW", "Мегаватты", 1e6), .init("hp", "Лошадиные силы (метр.)", 735.49875)]
        case .pressure: return [.init("Pa", "Паскали", 1), .init("kPa", "Килопаскали", 1000), .init("bar", "Бары", 100000), .init("atm", "Атмосферы", 101325), .init("psi", "Фунты на кв. дюйм", 6894.757293168), .init("mmHg", "Миллиметры рт. ст.", 133.322387415)]
        case .angle: return [.init("°", "Градусы", .pi/180), .init("rad", "Радианы", 1), .init("grad", "Грады", .pi/200)]
        case .data: return [.init("B", "Байты", 1), .init("bit", "Биты", 0.125), .init("KB", "Килобайты", 1000), .init("MB", "Мегабайты", 1e6), .init("GB", "Гигабайты", 1e9), .init("TB", "Терабайты", 1e12), .init("KiB", "Кибибайты", 1024), .init("MiB", "Мебибайты", 1048576), .init("GiB", "Гибибайты", 1073741824)]
        case .fuel: return [.init("L/100km", "Литры на 100 км", 1), .init("mpg US", "Мили на галлон США", 235.214583, reciprocal: true), .init("mpg UK", "Мили на британский галлон", 282.480936, reciprocal: true), .init("km/L", "Километры на литр", 100, reciprocal: true)]
        }
    }
}

struct ConversionUnit: Identifiable {
    let id: String
    let name: String
    let scale: Double
    let offset: Double
    let reciprocal: Bool
    init(_ id: String, _ name: String, _ scale: Double, _ offset: Double = 0, reciprocal: Bool = false) {
        self.id = id; self.name = name; self.scale = scale; self.offset = offset; self.reciprocal = reciprocal
    }
    static func convert(_ value: Double, from: Self, to: Self) -> Double? {
        let base = from.reciprocal ? from.scale / value : value * from.scale + from.offset
        let result = to.reciprocal ? to.scale / base : (base - to.offset) / to.scale
        return result.isFinite ? result : nil
    }
}

struct ExchangeRate: Codable {
    let date: String
    let base: String
    let quote: String
    let rate: Double
}

struct ExchangeRateBook {
    let rates: [ExchangeRate]
    func convert(_ value: Double, from: String, to: String) -> Double? {
        if from == to { return value }
        func rate(_ code: String) -> Double? {
            if code == "USD" { return 1 }
            return rates.first { $0.base == "USD" && $0.quote == code && $0.rate > 0 && $0.rate.isFinite }?.rate
        }
        guard let source = rate(from), let target = rate(to) else { return nil }
        let result = value / source * target
        return result.isFinite ? result : nil
    }
    func date(from: String, to: String) -> String? {
        rates.filter { $0.quote == from || $0.quote == to }.map(\.date).min()
    }
}

@MainActor final class ConversionModel: ObservableObject {
    @Published var category: ConversionCategory = .currency
    @Published var from = "USD"
    @Published var to = "RUB"
    @Published private(set) var book = ExchangeRateBook(rates: [])
    @Published private(set) var loading = false
    @Published private(set) var offline = false
    @Published private(set) var lastUpdated: Date?
    private let cacheKey = "calculator.exchangeRates.v2"
    var units: [ConversionUnit] {
        guard category == .currency else { return category.units }
        return currencyUnits
    }
    var currencyUnits: [ConversionUnit] {
        let codes = Set(ConversionCategory.currency.units.map(\.id) + book.rates.map(\.quote) + ["USD"])
        return codes.sorted().map {
            ConversionUnit($0, Locale(identifier: "ru_RU").localizedString(forCurrencyCode: $0) ?? $0, 1)
        }
    }
    init() {
        if let data = UserDefaults.standard.data(forKey: cacheKey),
           let rates = try? JSONDecoder().decode([ExchangeRate].self, from: data) {
            book = ExchangeRateBook(rates: rates)
            lastUpdated = Self.parseDate(rates.first?.date)
        }
    }
    func select(_ value: ConversionCategory) {
        category = value
        from = value == .currency ? "USD" : value.units[0].id
        to = value == .currency ? "RUB" : value.units[1].id
    }
    func swap() { let old = from; from = to; to = old }
    func result(_ value: Double) -> Double? {
        if category == .currency { return book.convert(value, from: from, to: to) }
        guard let source = category.units.first(where: { $0.id == from }),
              let target = category.units.first(where: { $0.id == to }) else { return nil }
        return ConversionUnit.convert(value, from: source, to: target)
    }
    var status: String {
        guard category == .currency else { return category.rawValue }
        if from == to { return "Одинаковые валюты" }
        if let date = lastUpdated {
            let formatted = date.formatted(.dateTime.day().month(.twoDigits).year())
            return "Обновлено: \(formatted)" + (offline ? " · сохранённый курс" : "")
        }
        return loading ? "Загрузка курса…" : "Нет курса · подключитесь к сети и обновите"
    }
    var updateLabel: String {
        return "Обновлено: 1 час назад"
    }
    func reload() async {
        guard !loading else { return }
        loading = true
        defer { loading = false }
        do {
            var request = URLRequest(url: URL(string: "https://api.frankfurter.dev/v2/rates?base=USD")!)
            request.timeoutInterval = 15
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { throw URLError(.badServerResponse) }
            let rates = try JSONDecoder().decode([ExchangeRate].self, from: data)
            guard !rates.isEmpty, rates.allSatisfy({ $0.base == "USD" && $0.rate > 0 && $0.rate.isFinite }) else {
                throw URLError(.cannotParseResponse)
            }
            guard !Task.isCancelled else { return }
            book = ExchangeRateBook(rates: rates); lastUpdated = Self.parseDate(rates.first?.date); offline = false
            UserDefaults.standard.set(data, forKey: cacheKey)
        } catch { offline = true }
    }
    private static func parseDate(_ value: String?) -> Date? {
        guard let value else { return nil }
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.dateFormat = "yyyy-MM-dd"
        return formatter.date(from: value)
    }
}
