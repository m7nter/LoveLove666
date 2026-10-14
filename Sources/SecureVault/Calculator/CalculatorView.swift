import SwiftUI

struct CalculatorView: View {
    @StateObject private var vm = CalculatorViewModel()
    var onUnlock: () -> Void
    @State private var showHistory = false
    @ObservedObject private var lifecycle = VaultLifecycle.shared
    @State private var showRecovery = false

    private let buttons: [[String]] = [
        ["⌫", "CLEAR", "%", "÷"],
        ["7", "8", "9", "×"],
        ["4", "5", "6", "−"],
        ["1", "2", "3", "+"],
        ["+/−", "0", ",", "="]
    ]

    var body: some View {
        GeometryReader { geometry in
            let gap: CGFloat = 11
            let sideInset: CGFloat = 18
            let widthForKey = (geometry.size.width - sideInset * 2 - gap * 3) / 4
            let heightForKey = (geometry.size.height - 54 - 112 - 20 - gap * 4) / 5
            let keySize = max(42, min(widthForKey, heightForKey))

            VStack(spacing: 0) {
                toolbar
                    .frame(height: 54)
                    .padding(.horizontal, sideInset + 2)

                Spacer(minLength: 12)

                VStack(alignment: .trailing, spacing: 3) {
                    if !vm.expression.isEmpty {
                        Text(vm.expression)
                            .font(.system(size: 21, weight: .regular))
                            .foregroundStyle(.white.opacity(0.50))
                            .lineLimit(1)
                            .minimumScaleFactor(0.6)
                            .frame(maxWidth: .infinity, alignment: .trailing)
                    }

                    Text(vm.display)
                        .font(.system(size: min(82, max(48, keySize * 0.96)), weight: .light))
                        .monospacedDigit()
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .minimumScaleFactor(0.34)
                        .modifier(CalculatorNumberTransition())
                }
                .frame(maxWidth: .infinity, minHeight: 96, alignment: .bottomTrailing)
                .padding(.horizontal, sideInset + 3)
                .padding(.bottom, 20)

                VStack(spacing: gap) {
                    ForEach(buttons.indices, id: \.self) { rowIndex in
                        HStack(spacing: gap) {
                            ForEach(buttons[rowIndex], id: \.self) { symbol in
                                CalculatorButton(
                                    title: symbol == "CLEAR" ? vm.clearButtonTitle : symbol,
                                    size: keySize,
                                    isSelected: vm.activeOperator == symbol,
                                    action: vm.tap
                                )
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Color.black.ignoresSafeArea())
        .preferredColorScheme(.dark)
        .onChange(of: vm.shouldUnlock) { value in
            if value {
                vm.shouldUnlock = false
                onUnlock()
            }
        }
        .sheet(isPresented: $showHistory) {
            HistoryView(history: vm.history)
        }
        .alert("Создать пустое хранилище?", isPresented: $showRecovery) {
            Button("Создать заново", role: .destructive) { lifecycle.erase(.reset) }
            Button("Отмена", role: .cancel) {}
        } message: {
            Text("Оставшиеся данные приложения, пароли и ключ шифрования будут удалены. После очистки задайте новый личный код. Старые фотографии и заметки не восстановятся.")
        }
        .overlay(alignment: .top) {
            if lifecycle.isErasing {
                ProgressView("Удаление данных…")
                    .padding().background(Color.black).foregroundColor(.white)
            } else if let error = lifecycle.lastError {
                VStack(spacing: 8) {
                    Text(error).font(.caption)
                    if lifecycle.canRetry { Button("Повторить удаление") { lifecycle.retry() } }
                }
                .padding().background(Color.black).foregroundColor(.white)
            }
        }
    }

    private var toolbar: some View {
        HStack {
            Button {
                showHistory = true
            } label: {
                Image(systemName: "list.bullet")
                    .font(.system(size: 20, weight: .medium))
                    .frame(width: 44, height: 44)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .modifier(CalculatorTopSurface())
            .accessibilityLabel("История")

            Spacer()

            Menu {
                Button {} label: {
                    Label("Основной", systemImage: "checkmark")
                }
                .disabled(true)
                Button {
                    showHistory = true
                } label: {
                    Label("История", systemImage: "list.bullet")
                }
                if lifecycle.blocksUI {
                    Button("Создать пустое хранилище") { showRecovery = true }
                        .disabled(lifecycle.isErasing)
                }
            } label: {
                Image(systemName: "calculator")
                    .font(.system(size: 20, weight: .medium))
                    .frame(width: 44, height: 44)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .modifier(CalculatorTopSurface())
            .accessibilityLabel("Режим калькулятора")
        }
        .foregroundColor(.white)
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
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.72 : 1)
            .animation(.easeOut(duration: 0.10), value: configuration.isPressed)
    }
}

struct CalculatorButton: View {
    let title: String
    let size: CGFloat
    let isSelected: Bool
    let action: (String) -> Void

    private var isOperator: Bool {
        ["÷", "×", "−", "+", "="].contains(title)
    }

    private var backgroundColor: Color {
        if isSelected { return .white }
        if isOperator { return Color(red: 1, green: 0.62, blue: 0.04) }
        if ["⌫", "AC", "C", "%", "+/−"].contains(title) {
            return Color(red: 0.65, green: 0.65, blue: 0.65)
        }
        return Color(red: 0.20, green: 0.20, blue: 0.20)
    }

    private var textColor: Color {
        if isSelected { return Color(red: 1, green: 0.62, blue: 0.04) }
        return ["⌫", "AC", "C", "%", "+/−"].contains(title) ? .black : .white
    }

    private var label: some View {
        Group {
            if title == "⌫" {
                Image(systemName: "delete.left")
                    .font(.system(size: size * 0.31, weight: .regular))
            } else {
                Text(title == "+/−" ? "±" : title)
                    .font(.system(
                        size: size * (title == "AC" || title == "C" ? 0.33 : 0.43),
                        weight: title == "=" ? .medium : .regular
                    ))
                    .minimumScaleFactor(0.65)
                    .lineLimit(1)
            }
        }
        .foregroundColor(textColor)
    }

    @ViewBuilder private var keyFace: some View {
        let content = label.frame(width: size, height: size)
        #if compiler(>=6.2)
        if #available(iOS 26.0, *) {
            content.glassEffect(.regular.tint(backgroundColor).interactive(), in: Circle())
        } else {
            content.background(backgroundColor, in: Circle())
        }
        #else
        content.background(backgroundColor, in: Circle())
        #endif
    }

    var body: some View {
        Button {
            action(title)
        } label: {
            keyFace
                .contentShape(Circle())
        }
        .buttonStyle(CalculatorKeyPressStyle())
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
    let history: [String]
    @Environment(\.dismiss) var dismiss

    var body: some View {
        NavigationStack {
            List {
                if history.isEmpty {
                    Text("История пуста")
                        .foregroundColor(.secondary)
                } else {
                    ForEach(history.indices.reversed(), id: \.self) { index in
                        Text(history[index])
                            .font(.system(size: 16, design: .monospaced))
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(Color.black)
            .navigationTitle("История")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Готово") { dismiss() }
                        .foregroundColor(.orange)
                }
            }
        }
        .preferredColorScheme(.dark)
    }
}
