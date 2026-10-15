import SwiftUI
import AudioToolbox

struct CalculatorView: View {
    @StateObject private var vm = CalculatorViewModel()
    @StateObject private var conversion = ConversionModel()
    var onUnlock: () -> Void
    var onAccess: () -> Void
    @State private var showHistory = false
    @State private var scientific = false
    @State private var converting = false
    @State private var selectingSource: Bool?
    private let buttons = [["⌫", "CLEAR", "%", "÷"], ["7", "8", "9", "×"],
                           ["4", "5", "6", "−"], ["1", "2", "3", "+"], ["+/−", "0", ",", "="]]
    private var science: [[String]] {
        [["(", ")", "mc", "m+", "m−", "mr"],
         ["2nd", "x²", "x³", "xʸ", vm.second ? "2ˣ" : "eˣ", "10ˣ"],
         ["1/x", "²√x", "³√x", "ʸ√x", "ln", vm.second ? "log₂" : "log₁₀"],
         ["x!", vm.second ? "sin⁻¹" : "sin", vm.second ? "cos⁻¹" : "cos", vm.second ? "tan⁻¹" : "tan", "e", "EE"],
         ["Rand", vm.second ? "sinh⁻¹" : "sinh", vm.second ? "cosh⁻¹" : "cosh", vm.second ? "tanh⁻¹" : "tanh", "π", vm.radians ? "Rad" : "Deg"]]
    }
    var body: some View {
        GeometryReader { geometry in
            let inset: CGFloat = 16
            let gap: CGFloat = scientific ? 7 : 9
            let width = (geometry.size.width - inset * 2 - gap * 3) / 4
            let heightBudget = (geometry.size.height - 54 - (converting ? 175 : 110) - 30)
            let keyHeight = scientific ? max(28, min(width * 0.50, (heightBudget - gap * 9) / 10))
                : min(width, (heightBudget - gap * 4) / 5)
            VStack(spacing: 0) {
                toolbar.frame(height: 48).padding(.horizontal, inset)
                Spacer(minLength: 6)
                if converting {
                    conversionDisplay(size: min(58, width * 0.70))
                        .padding(.horizontal, inset + 3).padding(.bottom, 12)
                } else {
                    numberDisplay(size: scientific ? min(46, width * 0.54) : min(68, width * 0.80))
                        .padding(.horizontal, inset).padding(.bottom, scientific ? 12 : 7)
                }
                VStack(spacing: gap) {
                    if scientific { scienceGrid(width: geometry.size.width - inset * 2, height: keyHeight, gap: gap) }
                    ForEach(buttons.indices, id: \.self) { row in
                        HStack(spacing: gap) {
                            ForEach(buttons[row], id: \.self) { symbol in
                                CalculatorButton(title: symbol == "CLEAR" ? vm.clearButtonTitle : symbol,
                                    size: width, height: keyHeight, isSelected: vm.activeOperator == symbol, action: vm.tap)
                            }
                        }
                    }
                }
                .padding(.horizontal, inset).padding(.bottom, 28)
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Color.black.ignoresSafeArea()).preferredColorScheme(.dark)
        .onAppear {
            #if DEBUG && targetEnvironment(simulator)
            let args = ProcessInfo.processInfo.arguments
            if args.contains("--preview-scientific") { scientific = true }
            if args.contains("--preview-conversion") {
                converting = true; conversion.to = "EUR"
                for digit in ["7", "9", "9"] { vm.tap(digit) }
            }
            if args.contains("--preview-units") {
                converting = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { selectingSource = true }
            }
            if args.contains("--preview-example") {
                for key in ["1", "1", ",", "7", "5", "−", "8", "×", "0", ",", "5", "="] { vm.tap(key) }
            }
            #endif
        }
        .onChange(of: vm.shouldUnlock) { value in
            if value { vm.shouldUnlock = false; onUnlock() }
        }
        .onChange(of: converting) { value in
            vm.allowsVaultEntry = !value
        }
        .sheet(isPresented: $showHistory) {
            HistoryView(history: $vm.history, onSelect: vm.useHistory)
        }
        .sheet(isPresented: Binding(get: { selectingSource != nil }, set: { if !$0 { selectingSource = nil } })) {
            ConversionPicker(model: conversion, source: selectingSource == true)
        }
    }
    private func numberDisplay(size: CGFloat) -> some View {
        VStack(alignment: .trailing, spacing: 3) {
            if !vm.expression.isEmpty {
                Text(vm.expression).font(.system(size: scientific ? 19 : 26)).foregroundStyle(.white.opacity(0.5))
                    .lineLimit(1).minimumScaleFactor(0.5)
            }
            Text(vm.display).font(.system(size: size, weight: .regular, design: .default))
                .foregroundStyle(.white).lineLimit(1).minimumScaleFactor(0.3)
                .modifier(CalculatorNumberTransition())
                .accessibilityIdentifier("calculator.display")
                .onTapGesture(count: 2) { UIPasteboard.general.string = vm.display }
                .onLongPressGesture(minimumDuration: 3, perform: onAccess)
        }.frame(maxWidth: .infinity, minHeight: 90, alignment: .bottomTrailing)
    }
    private func conversionDisplay(size: CGFloat) -> some View {
        VStack(spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Spacer(minLength: 0)
                Text(vm.display).font(.system(size: size)).lineLimit(1).minimumScaleFactor(0.3)
                unitButton(conversion.from, source: true)
            }
            HStack {
                Button { conversion.swap() } label: { Image(systemName: "arrow.up.arrow.down") }.tint(.orange)
                    .accessibilityLabel("Поменять единицы местами")
                Rectangle().fill(.white.opacity(0.12)).frame(height: 0.5)
            }.frame(height: 18)
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Spacer(minLength: 0)
                Text(vm.numericValue.flatMap(conversion.result).map(formatConversion) ?? (vm.display == "0" ? "0" : "—"))
                    .font(.system(size: size)).foregroundStyle(.gray).lineLimit(1).minimumScaleFactor(0.3)
                    .accessibilityIdentifier("calculator.converted")
                unitButton(conversion.to, source: false)
            }
        }.task { if conversion.category == .currency { await conversion.reload() } }
    }
    private func formatConversion(_ value: Double) -> String {
        guard conversion.category == .currency else { return CalculatorViewModel.format(value) }
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.currencyCode = conversion.to
        formatter.currencySymbol = ""
        formatter.locale = Locale(identifier: "ru_RU")
        return formatter.string(from: NSNumber(value: value))?.trimmingCharacters(in: .whitespaces)
            ?? CalculatorViewModel.format(value)
    }
    private func unitButton(_ title: String, source: Bool) -> some View {
        Button { selectingSource = source } label: {
            HStack(spacing: 4) { Text(title).fontWeight(.semibold); Image(systemName: "chevron.up.chevron.down").font(.system(size: 11, weight: .bold)) }
                .font(.system(size: 18)).foregroundStyle(.gray)
        }.accessibilityLabel(source ? "Исходная единица" : "Результирующая единица")
    }
    private func scienceGrid(width: CGFloat, height: CGFloat, gap: CGFloat) -> some View {
        VStack(spacing: gap) {
            ForEach(science.indices, id: \.self) { row in
                HStack(spacing: gap) {
                    ForEach(science[row], id: \.self) { symbol in
                        Button { vm.tap(symbol) } label: {
                            Text(symbol).font(.system(size: min(17, height * 0.38), weight: .regular))
                                .minimumScaleFactor(0.65).lineLimit(1)
                                .frame(width: (width - gap * 5) / 6, height: height)
                                .foregroundStyle(symbol == "2nd" && vm.second ? .black : .white)
                                .background(symbol == "2nd" && vm.second ? Color.white : Color(white: 0.13), in: Capsule())
                        }.buttonStyle(CalculatorKeyPressStyle()).accessibilityIdentifier("calculator.science." + symbol)
                    }
                }
            }
        }
    }
    private var toolbar: some View {
        HStack {
            Button { showHistory = true } label: {
                Image(systemName: "clock").font(.system(size: 22, weight: .medium))
                    .frame(width: 44, height: 44)
            }.buttonStyle(.plain).modifier(CalculatorTopSurface()).accessibilityLabel("История")
            Spacer()
            Menu {
                Picker("Режим", selection: $scientific) {
                    Label("Стандартный", systemImage: "plus.forwardslash.minus").tag(false)
                    Label("Научный", systemImage: "function").tag(true)
                }
                Divider()
                Toggle(isOn: $converting) { Label("Конвертация", systemImage: "arrow.left.arrow.right") }
            } label: {
                CalculatorGlyph().frame(width: 17, height: 23).frame(width: 44, height: 44)
            }.buttonStyle(.plain).modifier(CalculatorTopSurface())
                .accessibilityLabel("Режим калькулятора").accessibilityIdentifier("calculator.menu")
        }.foregroundStyle(.white)
    }
}

struct ConversionPicker: View {
    @ObservedObject var model: ConversionModel
    let source: Bool
    @Environment(\.dismiss) private var dismiss
    @State private var search = ""
    private var selectedID: String { source ? model.from : model.to }
    private var categories: [ConversionCategory] {
        [.angle, .area, .currency, .data, .energy, .fuel, .length,
         .power, .pressure, .speed, .temperature, .time, .volume, .mass]
    }
    private var rows: [ConversionChoice] {
        let choices: [ConversionCategory] = search.isEmpty ? [model.category] : categories
        let all: [ConversionChoice] = choices.flatMap { (category: ConversionCategory) -> [ConversionChoice] in
            let units: [ConversionUnit] = category == .currency ? model.currencyUnits : category.units
            return units.map { unit in ConversionChoice(category: category, unit: unit) }
        }
        return all.filter { search.isEmpty || $0.unit.name.localizedCaseInsensitiveContains(search) || $0.unit.id.localizedCaseInsensitiveContains(search) }
            .sorted { $0.unit.name.localizedStandardCompare($1.unit.name) == .orderedAscending }
    }
    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                Text("Единицы").font(.headline.bold())
                HStack {
                    Spacer()
                    Button { dismiss() } label: {
                        Image(systemName: "checkmark").font(.system(size: 23, weight: .bold))
                            .foregroundStyle(.white).frame(width: 44, height: 44)
                            .background(Color.orange, in: Circle())
                    }.accessibilityLabel("Готово")
                }
            }.padding(.horizontal, 16).padding(.top, 16).padding(.bottom, 12)
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 2) {
                        ForEach(categories) { category in
                            Button {
                                model.select(category)
                                withAnimation { proxy.scrollTo(category.id, anchor: .center) }
                            } label: {
                                Text(category.rawValue).font(.system(size: 14, weight: .bold))
                                    .foregroundStyle(category == model.category ? .white : .orange)
                                    .padding(.horizontal, 12).padding(.vertical, 7)
                                    .background(category == model.category ? Color.orange : .clear, in: Capsule())
                            }.id(category.id)
                        }
                    }.padding(.horizontal, 12)
                }.onAppear { proxy.scrollTo(model.category.id, anchor: .center) }
            }.padding(.bottom, 10)
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(rows) { choice in
                            let selected = choice.category == model.category && choice.unit.id == selectedID
                            ConversionRow(choice: choice, selected: selected) {
                                if choice.category != model.category { model.select(choice.category) }
                                if source { model.from = choice.unit.id } else { model.to = choice.unit.id }
                                dismiss()
                            }.id(choice.id)
                                .accessibilityIdentifier("conversion.unit." + choice.unit.id)
                            Divider().padding(.leading, 28)
                        }
                    }.padding(.horizontal, 14)
                }
                .onAppear { proxy.scrollTo(model.category.id + ":" + selectedID, anchor: .top) }
                .onChange(of: model.currencyUnits.count) { _ in
                    if search.isEmpty { proxy.scrollTo(model.category.id + ":" + selectedID, anchor: .top) }
                }
            }
            if model.category == .currency {
                HStack(alignment: .firstTextBaseline) {
                    Text("yahoo!finance").font(.system(size: 19, weight: .bold, design: .rounded)).foregroundStyle(.white.opacity(0.82))
                    Spacer()
                    Text(model.updateLabel).font(.system(size: 15)).foregroundStyle(.secondary)
                }.padding(.horizontal, 28).padding(.top, 8)
            }
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.white)
                TextField("Поиск по всем единицам", text: $search)
                    .font(.system(size: 17)).autocorrectionDisabled()
                    .accessibilityIdentifier("conversion.search")
                if !search.isEmpty {
                    Button { search = "" } label: { Image(systemName: "xmark.circle.fill") }
                        .foregroundStyle(.secondary).accessibilityLabel("Очистить поиск")
                }
            }.padding(.horizontal, 16).frame(height: 48)
                .background(.thinMaterial, in: Capsule())
                .overlay(Capsule().strokeBorder(.white.opacity(0.16), lineWidth: 0.7))
                .padding(.horizontal, 28).padding(.top, 12).padding(.bottom, 18)
        }.background(Color(white: 0.13)).foregroundStyle(.white)
            .preferredColorScheme(.dark).tint(.orange)
            .presentationDetents([.large]).presentationDragIndicator(.hidden)
            .onChange(of: model.category) { value in if value == .currency { Task { await model.reload() } } }
    }
}

private struct ConversionChoice: Identifiable {
    let category: ConversionCategory
    let unit: ConversionUnit
    var id: String { category.id + ":" + unit.id }
}

private struct ConversionRow: View {
    let choice: ConversionChoice
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(alignment: .center, spacing: 8) {
                Image(systemName: "checkmark").font(.system(size: 17, weight: .semibold))
                    .frame(width: 20).opacity(selected ? 1 : 0)
                VStack(alignment: .leading, spacing: 1) {
                    Text(choice.unit.name).font(.system(size: 17, weight: .medium))
                    Text(choice.unit.id).font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(selected ? .orange : .secondary)
                }
                Spacer(minLength: 0)
            }
            .foregroundStyle(selected ? .orange : .white)
            .frame(maxWidth: .infinity, minHeight: 67, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// Match the system's rounded material on the navigation controls.
private struct CalculatorNumberTransition: ViewModifier {
    @ViewBuilder func body(content: Content) -> some View {
        if #available(iOS 17.0, *) {
            content.contentTransition(.numericText())
        } else {
            content
        }
    }
}

// Draw the toolbar glyph ourselves; unavailable SF Symbols render as an empty button.
private struct CalculatorGlyph: View {
    var body: some View {
        VStack(spacing: 2) {
            RoundedRectangle(cornerRadius: 1).fill(.black).frame(height: 6)
            ForEach(0..<3) { _ in
                HStack(spacing: 2) {
                    ForEach(0..<3) { _ in Circle().fill(.black) }
                }
            }
        }
        .padding(2.4)
        .background(.white, in: RoundedRectangle(cornerRadius: 3))
    }
}

private struct CalculatorTopSurface: ViewModifier {
    @ViewBuilder func body(content: Content) -> some View {
        #if compiler(>=6.2)
        if #available(iOS 26.0, *) {
            content.glassEffect(.regular.interactive(), in: Circle())
        } else {
            content.background(.ultraThinMaterial, in: Circle())
        }
        #else
        content.background(.ultraThinMaterial, in: Circle())
        #endif
    }
}

private struct CalculatorKeyPressStyle: ButtonStyle {
    var soundID: SystemSoundID = 1123
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .overlay(Capsule().fill(.white.opacity(configuration.isPressed ? 0.30 : 0)))
            .scaleEffect(configuration.isPressed ? 1.065 : 1)
            .animation(.spring(response: 0.22, dampingFraction: 0.65), value: configuration.isPressed)
            .onChange(of: configuration.isPressed) { pressed in
                if pressed { AudioServicesPlaySystemSound(soundID) }
            }
    }
}

struct CalculatorButton: View {
    let title: String
    let size: CGFloat
    var height: CGFloat? = nil
    let isSelected: Bool
    let action: (String) -> Void
    private var clickSound: SystemSoundID {
        if title == "⌫" { return 1155 }
        return ["AC", "C", "+/−", "%"].contains(title) ? 1156 : 1123
    }

    private var isOperator: Bool {
        ["÷", "×", "−", "+", "="].contains(title)
    }

    private var backgroundColor: Color {
        if isSelected { return .white }
        if isOperator { return Color(red: 1, green: 0.60, blue: 0) }
        if ["⌫", "AC", "C", "%"].contains(title) {
            return Color(white: 0.36)
        }
        return Color(red: 0.20, green: 0.20, blue: 0.20)
    }

    private var textColor: Color {
        if isSelected { return Color(red: 1, green: 0.60, blue: 0) }
        return .white
    }

    private var symbolName: String? {
        switch title {
        case "⌫": return "delete.left"
        case "+/−": return "plus.forwardslash.minus"
        case "÷": return "divide"
        case "×": return "multiply"
        case "−": return "minus"
        case "+": return "plus"
        case "=": return "equal"
        case "%": return "percent"
        default: return nil
        }
    }

    private var label: some View {
        Group {
            if let symbolName {
                Image(systemName: symbolName)
                    .font(.system(size: min(size * (title == "⌫" ? 0.40 : 0.43), (height ?? size) * 0.58), weight: .medium))
            } else {
                Text(title)
                    .font(.system(size: min(size * 0.43, (height ?? size) * 0.65), weight: .medium))
                    .minimumScaleFactor(0.65).lineLimit(1)
            }
        }.foregroundColor(textColor)
    }

    @ViewBuilder private var keyFace: some View {
        let content = label.frame(width: size, height: height ?? size)
        #if compiler(>=6.2)
        if #available(iOS 26.0, *) {
            content.glassEffect(.regular.tint(backgroundColor).interactive(), in: Capsule())
        } else {
            content.background(backgroundColor, in: Capsule())
        }
        #else
        content.background(backgroundColor, in: Capsule())
        #endif
    }

    var body: some View {
        Button {
            action(title)
        } label: {
            keyFace
                .contentShape(Capsule())
        }
        .buttonStyle(CalculatorKeyPressStyle(soundID: clickSound))
        .accessibilityIdentifier("calculator.key." + title)
        .accessibilityLabel(title == "+/−" ? "Сменить знак" : title == "⌫" ? "Удалить цифру" : title)
        .simultaneousGesture(
            title == "⌫" || title == "C" ? LongPressGesture(minimumDuration: 0.5)
                .onEnded { _ in
                    action("AC")
                }
            : nil
        )
    }
}

struct HistoryView: View {
    @Binding var history: [HistoryRecord]
    var onSelect: (HistoryRecord) -> Void
    @Environment(\.dismiss) var dismiss
    @State private var editing = false

    var body: some View {
        VStack(spacing: 0) {
            Capsule().fill(.white.opacity(0.45)).frame(width: 60, height: 5).padding(.top, 10).padding(.bottom, 14)
            HStack {
                Button(editing ? "Готово" : "Править") { editing.toggle() }
                    .font(.system(size: 18, weight: .semibold)).padding(.horizontal, 18).padding(.vertical, 10)
                    .background(.ultraThinMaterial, in: Capsule())
                Spacer()
                Button { dismiss() } label: { Image(systemName: "xmark").font(.system(size: 20, weight: .bold)).frame(width: 44, height: 44).background(.white.opacity(0.12), in: Circle()) }
            }.padding(.horizontal, 20).padding(.bottom, 12)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if history.isEmpty {
                        Text("История пуста").foregroundStyle(.secondary).frame(maxWidth: .infinity).padding(.top, 60)
                    } else {
                        ForEach(historySections.indices, id: \.self) { sectionIndex in
                            Text(historySections[sectionIndex].0)
                                .font(.system(size: 18, weight: .bold)).foregroundStyle(.secondary)
                                .padding(.horizontal, 20).padding(.top, 16).padding(.bottom, 8)
                            ForEach(historySections[sectionIndex].1.reversed()) { record in
                                Button { onSelect(record); dismiss() } label: {
                                    HStack(spacing: 10) {
                                        if editing { Image(systemName: "minus.circle.fill").foregroundStyle(.red) }
                                        VStack(alignment: .leading, spacing: 5) {
                                            Text(record.expression).font(.system(size: 17)).foregroundStyle(.secondary).lineLimit(1)
                                            Text(record.result).font(.system(size: 25, weight: .medium)).foregroundStyle(.white)
                                        }
                                        Spacer()
                                    }.padding(.horizontal, 20).padding(.vertical, 17)
                                }.buttonStyle(.plain)
                                Divider().overlay(.white.opacity(0.16)).padding(.horizontal, 20)
                            }
                        }
                    }
                }
            }
        }
        .background(.ultraThinMaterial)
        .preferredColorScheme(.dark)
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.hidden)
    }

    private var historySections: [(String, [HistoryRecord])] {
        let calendar = Calendar.current
        let grouped = Dictionary(grouping: history) { record -> Date in
            calendar.startOfDay(for: record.date)
        }
        return grouped.keys.sorted(by: >).map { day in
            let title: String
            if calendar.isDateInToday(day) { title = "Сегодня" }
            else if calendar.isDateInYesterday(day) { title = "Вчера" }
            else { title = day.formatted(.dateTime.day().month(.wide).year()) }
            return (title, grouped[day] ?? [])
        }
    }
}
