import SwiftUI

/// First launch: permissions and the "two switchers" warning.
struct OnboardingView: View {
    @Bindable var model: AppModel

    private var ready: Bool { model.accessibilityGranted && model.inputMonitoringGranted }

    var body: some View {
        let _ = model.revision
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 16) {
                AppIcon(size: 64)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Добро пожаловать в KeySwitch").font(.title2.bold())
                    Text("Пишите как обычно. Слова в неправильной раскладке исправятся сами.")
                        .font(.callout).foregroundStyle(.secondary)
                }
            }

            Card(padding: 0) {
                step(1, title: "Универсальный доступ",
                     detail: "Чтобы перепечатывать слово в правильной раскладке",
                     granted: model.accessibilityGranted, current: !model.accessibilityGranted) {
                    model.actions?.openAccessibility()
                }
                Divider()
                step(2, title: "Мониторинг ввода",
                     detail: "Чтобы видеть нажатые клавиши. Пароли macOS не показывает",
                     granted: model.inputMonitoringGranted, current: model.accessibilityGranted && !model.inputMonitoringGranted) {
                    model.actions?.openInputMonitoring()
                }
                Divider()
                conflictRow
            }

            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "lock").foregroundStyle(Theme.accent).accessibilityHidden(true)
                Text("Всё работает на этом Mac, без интернета: набранный текст никуда не отправляется. KeySwitch учится только на ваших исправлениях.")
                    .font(.caption).fixedSize(horizontal: false, vertical: true)
            }
            .padding(12)
            .background(Theme.accent.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))

            Spacer(minLength: 0)

            HStack {
                Toggle("Запускать при входе в систему", isOn: Binding(
                    get: { model.loginEnabled }, set: { model.actions?.setLogin($0) }))
                Spacer()
                Button("Готово") { model.actions?.finishOnboarding() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .tint(Theme.accent)
                    .disabled(!ready)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(28)
        .frame(width: 680, height: 560)
    }

    private func step(_ n: Int, title: String, detail: String, granted: Bool, current: Bool, open: @escaping () -> Void) -> some View {
        HStack(spacing: 14) {
            ZStack {
                if granted {
                    Circle().fill(Theme.success)
                    Image(systemName: "checkmark").font(.system(size: 13, weight: .bold)).foregroundStyle(Theme.onAccent)
                } else {
                    Circle().strokeBorder(current ? Theme.accent : Color.secondary.opacity(0.6), lineWidth: 2)
                    Text("\(n)").font(.system(size: 13, weight: .bold)).foregroundStyle(current ? Theme.accent : .secondary)
                }
            }
            .frame(width: 28, height: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 14, weight: .semibold))
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if granted {
                Text("Разрешено").font(.callout.weight(.semibold)).foregroundStyle(Theme.success)
            } else {
                Button("Открыть настройки", action: open).buttonStyle(.borderedProminent).tint(Theme.accent)
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 14)
        .accessibilityElement(children: .combine)
    }

    private var conflictRow: some View {
        HStack(spacing: 14) {
            Text("3").font(.system(size: 13, weight: .bold)).foregroundStyle(.secondary)
                .frame(width: 28, height: 28)
                .overlay(Circle().strokeBorder(Color.secondary.opacity(0.6), lineWidth: 2))
            VStack(alignment: .leading, spacing: 2) {
                Text("Выключите Punto Switcher / Caramba").font(.system(size: 14, weight: .semibold))
                Text("Две программы будут исправлять одно слово дважды").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if model.conflictingApps.isEmpty {
                Text("Не найдены").font(.callout.weight(.semibold)).foregroundStyle(Theme.success)
            } else {
                Text("Найдена \(model.conflictingApps.joined(separator: ", "))")
                    .font(.callout.weight(.semibold)).foregroundStyle(Theme.warning)
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 14)
        .accessibilityElement(children: .combine)
    }
}
