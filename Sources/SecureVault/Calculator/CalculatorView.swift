import SwiftUI

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
                toolbar.frame(height: 54).padding(.horizontal, inset)
                Spacer(minLength: 6)
                if converting {
                    conversionDisplay(size: min(58, width * 0.70))
                        .padding(.horizontal, inset + 3).padding(.bottom, 12)
                } else {
                    numberDisplay(size: min(68, width * 0.78))
                        .padding(.horizontal, inset + 3).padding(.bottom, 18)
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
                .padding(.horizontal, inset).padding(.bottom, 14)
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
            #endif
        }
        .onChange(of: vm.shouldUnlock) { value in
            if value { vm.shouldUnlock = false; onUnlock() }
        }
        .onChange(of: converting) { value in vm.allowsVaultEntry = !value }
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
                Text(vm.expression).font(.system(size: 21)).foregroundStyle(.white.opacity(0.5))
                    .lineLimit(1).minimumScaleFactor(0.5)
            }
            Text(vm.display).font(.system(size: size, weight: .regular, design: .default))
                .foregroundStyle(.white).lineLimit(1).minimumScaleFactor(0.3)
                .modifier(CalculatorNumberTransition())
                .accessibilityIdentifier("calculator.display")
                .contextMenu { Button("Скопировать") { UIPasteboard.general.string = vm.display } }
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
                Text(vm.numericValue.flatMap(conversion.result).map(CalculatorViewModel.format) ?? (vm.display == "0" ? "0" : "—"))
                    .font(.system(size: size)).foregroundStyle(.gray).lineLimit(1).minimumScaleFactor(0.3)
                    .accessibilityIdentifier("calculator.converted")
                unitButton(conversion.to, source: false)
            }
            HStack {
                Text(conversion.status).font(.system(size: 10)).foregroundStyle(.gray).lineLimit(2)
                Spacer(minLength: 0)
                if conversion.category == .currency {
                    Button { Task { await conversion.reload() } } label: { Image(systemName: "arrow.clockwise") }
                        .font(.caption).tint(.orange).disabled(conversion.loading).accessibilityLabel("Обновить курс")
                }
            }.padding(.top, 3)
        }.task { if conversion.category == .currency { await conversion.reload() } }
    }
    private func unitButton(_ title: String, source: Bool) -> some View {
        Button { selectingSource = source } label: {
            HStack(spacing: 2) { Text(title); Image(systemName: "chevron.up.chevron.down").font(.system(size: 8)) }
                .font(.system(size: 13)).foregroundStyle(.gray)
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
                Button { scientific = false } label: { Label("Основной", systemImage: scientific ? "circle" : "checkmark") }
                Button { scientific = true } label: { Label("Научный", systemImage: scientific ? "checkmark" : "circle") }
                Toggle("Конвертация", isOn: $converting)
                Button("История") { showHistory = true }
                Divider()
                Button("Хранилище", action: onAccess)
                Text("Калькулятор 1.1.0 (3)")
            } label: {
                CalculatorGlyph().frame(width: 19, height: 25).frame(width: 44, height: 44)
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
    var body: some View {
        NavigationStack {
            List {
                Section {
                    Picker("Категория", selection: Binding(get: { model.category }, set: { model.select($0) })) {
                        ForEach(ConversionCategory.allCases) { Text($0.rawValue).tag($0) }
                    }
                }
                ForEach(model.units.filter { search.isEmpty || $0.name.localizedCaseInsensitiveContains(search) || $0.id.localizedCaseInsensitiveContains(search) }) { unit in
                    Button {
                        if source { model.from = unit.id } else { model.to = unit.id }
                        dismiss()
                    } label: {
                        HStack {
                            Text(unit.name); Spacer(); Text(unit.id).foregroundStyle(.secondary)
                            if unit.id == (source ? model.from : model.to) { Image(systemName: "checkmark").foregroundStyle(.orange) }
                        }
                    }.foregroundStyle(.white)
                }
            }.searchable(text: $search, prompt: "Валюта или единица")
                .navigationTitle(source ? "Из" : "В").navigationBarTitleDisplayMode(.inline)
                .toolbar { Button("Готово") { dismiss() } }
                .onChange(of: model.category) { value in if value == .currency { Task { await model.reload() } } }
        }.preferredColorScheme(.dark).tint(.orange)
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
        VStack(spacing: 3) {
            RoundedRectangle(cornerRadius: 1.5).fill(.black).frame(height: 6)
            ForEach(0..<3) { _ in
                HStack(spacing: 2) {
                    ForEach(0..<3) { _ in Circle().fill(.black) }
                }
            }
        }
        .padding(3)
        .background(.white, in: RoundedRectangle(cornerRadius: 3.5))
    }
}

private struct CalculatorTopSurface: ViewModifier {
    func body(content: Content) -> some View {
        content.background(Color(white: 0.07), in: Circle())
            .overlay(Circle().strokeBorder(.white.opacity(0.12), lineWidth: 0.8))
    }
}

private struct CalculatorKeyPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.72 : 1)
            .animation(.easeOut(duration: 0.10), value: configuration.isPressed)
    }
}

struct CalculatorButton: View {
    let title: String
    let size: CGFloat
    var height: CGFloat? = nil
    let isSelected: Bool
    let action: (String) -> Void

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

    private var keyFace: some View {
        label.frame(width: size, height: height ?? size)
            .background(backgroundColor, in: Capsule())
            .overlay(Capsule().strokeBorder(
                LinearGradient(colors: [.white.opacity(0.22), .white.opacity(0.05), .white.opacity(0.14)],
                               startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 0.7))
    }

    var body: some View {
        Button {
            action(title)
        } label: {
            keyFace
                .contentShape(Capsule())
        }
        .buttonStyle(CalculatorKeyPressStyle())
        .accessibilityIdentifier("calculator.key." + title)
        .accessibilityLabel(title == "+/−" ? "Сменить знак" : title == "⌫" ? "Удалить цифру" : title)
        .simultaneousGesture(
            LongPressGesture(minimumDuration: 0.5)
                .onEnded { _ in
                    if title == "⌫" || title == "C" { action("AC") }
                }
        )
    }
}

struct HistoryView: View {
    @Binding var history: [String]
    var onSelect: (String) -> Void
    @Environment(\.dismiss) var dismiss

    var body: some View {
        NavigationStack {
            List {
                if history.isEmpty {
                    Text("История пуста")
                        .foregroundColor(.secondary)
                } else {
                    ForEach(history.indices.reversed(), id: \.self) { index in
                        Button { onSelect(history[index]); dismiss() } label: {
                            Text(history[index]).font(.system(size: 20)).foregroundStyle(.white)
                                .frame(maxWidth: .infinity, alignment: .trailing)
                        }
                        .contextMenu { Button("Скопировать") { UIPasteboard.general.string = history[index] } }
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(Color.black)
            .navigationTitle("История")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Очистить", role: .destructive) { history.removeAll() }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Готово") { dismiss() }
                        .foregroundColor(.orange)
                }
            }
        }
        .preferredColorScheme(.dark)
    }
}

