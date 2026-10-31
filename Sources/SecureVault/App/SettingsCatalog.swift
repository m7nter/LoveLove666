import Foundation

enum SettingsCategory: String, CaseIterable, Identifiable, Hashable {
    case location, camera, events, appearance, export, security, actionButton
    var id: String { rawValue }
    var title: String {
        switch self {
        case .location: return "GPS, карты и OSM"
        case .camera: return "Съёмка"
        case .events: return "События и папки"
        case .appearance: return "Оформление фото"
        case .export: return "Выгрузка"
        case .security: return "Безопасность"
        case .actionButton: return "Action Button"
        }
    }
    var detail: String {
        switch self {
        case .location: return "Запретные зоны, офлайн-карты и точность GPS"
        case .camera: return "Кнопки громкости, прицел и чёрный экран"
        case .events: return "Кадры, расстояние между событиями и нумерация"
        case .appearance: return "Фото в углу снимка и цвет пометок"
        case .export: return "Файлы, ZIP, координаты и заметки"
        case .security: return "Пароли, автоблокировка и защитное удаление"
        case .actionButton: return "Запуск камеры и команды боковой кнопки"
        }
    }
    var icon: String {
        switch self {
        case .location: return "map.fill"
        case .camera: return "camera.fill"
        case .events: return "rectangle.stack.fill"
        case .appearance: return "paintbrush.fill"
        case .export: return "square.and.arrow.up.fill"
        case .security: return "lock.shield.fill"
        case .actionButton: return "bolt.fill"
        }
    }
}

enum SettingsItem: String, Hashable {
    case guide, restrictedPlaces, offlineMaps, continuousGPS, gpsAccuracy, mapPins
    case volumeCapture, crosshair, blackScreen
    case eventPhotos, eventDistance, folders, numbering
    case avatar, annotation
    case exportFormat, exportCoordinates, exportNote, archiveMetadata
    case locking, mainPIN, vaultPIN, emergencyPIN, bruteForce, inactivity, actionButton
}

enum SettingsDestination: Hashable {
    case category(SettingsCategory, focus: SettingsItem?)
    case restrictedPlaces, offlineMaps
}

struct SettingsSearchEntry: Identifiable {
    let id: SettingsItem
    let category: SettingsCategory?
    let title: String
    let detail: String
    let keywords: String

    init(_ id: SettingsItem, _ category: SettingsCategory?, _ title: String, _ detail: String, _ keywords: String) {
        self.id = id; self.category = category; self.title = title; self.detail = detail; self.keywords = keywords
    }

    var destination: SettingsDestination? {
        switch id {
        case .restrictedPlaces: return .restrictedPlaces
        case .offlineMaps: return .offlineMaps
        default: return category.map { .category($0, focus: id) }
        }
    }
}

/// Search is local, read-only and independent of the saved setting values.
enum SettingsCatalog {
    static let entries: [SettingsSearchEntry] = [
        .init(.guide, nil, "Руководство по использованию", "Описание функций и сценариев работы", "помощь инструкция обучение возможности как пользоваться"),
        .init(.restrictedPlaces, .location, "Контроль территорий OSM", "Типы мест, радиусы и режим проверки", "запретные зоны школа детсад садик площадка полиция мвд фсб онлайн офлайн автоматически расстояние погрешность openstreetmap overpass"),
        .init(.offlineMaps, .location, "Офлайн-карты и зоны", "Загрузка региона и состояние данных", "скачать загрузить область регион без интернета загрузка прогресс ячейки база osm карта запретные места"),
        .init(.continuousGPS, .location, "GPS без ожидания", "Геолокация в калькуляторе и фоне", "gps гпс всегда поддерживать активным калибровка координаты фон точная геопозиция"),
        .init(.gpsAccuracy, .location, "Точность GPS", "Допустимая погрешность при съёмке", "gps гпс координаты метры точность сигнал спутники защита погрешности максимальная погрешность"),
        .init(.mapPins, .location, "Метки фотографий на карте", "Группировка близких снимков", "карта метки кружки объединять близкие группировка кластеры cluster"),
        .init(.volumeCapture, .camera, "Снимать кнопками громкости", "Спуск затвора боковыми клавишами", "громкость volume кнопка камера съёмка съемка затвор"),
        .init(.crosshair, .camera, "Прицел", "Видимость, цвет и впечатывание перекрестия", "перекрестие крестик центр фото цвет показывать"),
        .init(.blackScreen, .camera, "Чёрный экран", "Два касания тремя пальцами в камере", "черный скрыть экран жест тройное касание пальцы два касания тремя пальцами три пальца"),
        .init(.eventPhotos, .events, "Фото на событие", "Количество кадров в серии", "события серия один два 1 2 20 фото снимки кадров альбом количество фотографий"),
        .init(.eventDistance, .events, "Дистанция между событиями", "Минимальное расстояние до нового события", "30 30м метры между фото снимками расстояние дистанция gps последнее событие минимально допустимая"),
        .init(.folders, .events, "Папки режимов", "Распределение снимков по рабочим папкам", "папка режим категории добавить 0.5 1 2 текущий новый распределять новые фото по режимам"),
        .init(.numbering, .events, "Нумерация", "Номера за день и общий счётчик", "номер фото снимки счетчик счётчик имена файлы"),
        .init(.avatar, .appearance, "Фото в углу снимка", "Выбрать или удалить дополнительную картинку", "аватар аватарка логотип фото на фото фото на снимках картинка справа снизу правый нижний угол"),
        .init(.annotation, .appearance, "Цвет пометок", "Цвет стрелок, овалов и текста", "цвет текст надпись стрелка овал пометки редактор"),
        .init(.exportFormat, .export, "Способ выгрузки", "ZIP-архив или отдельные фотографии", "экспорт отправить поделиться telegram телеграм share sheet архив файлы"),
        .init(.exportCoordinates, .export, "Координаты сообщением", "Дата и координаты первого кадра события", "координаты подпись сообщение выгрузка дата telegram телеграм 6 знаков скопировать снимками"),
        .init(.exportNote, .export, "Заметка на выгружаемом фото", "Впечатывание заметки при экспорте", "заметка подпись текст фото экспорт выгрузка впечатывать заметку"),
        .init(.archiveMetadata, .export, "Метаданные ZIP-архива", "Только координаты или выбранные поля", "метаданные метаданных zip архив только координаты дата папка номер события нумерация ссылки заметки metadata " + ArchiveMetadataOptions.fields.map { $0.0 }.joined(separator: " ")),
        .init(.locking, .security, "Автоблокировка", "Сворачивание приложения и таймер блокировки", "заблокировать выход фон свернуть минут таймаут время блокировка"),
        .init(.mainPIN, .security, "Основной пароль", "Код входа с калькулятора", "pin пин код пароль изменить сменить основной калькулятор"),
        .init(.vaultPIN, .security, "Дополнительный пароль", "Защита папок, карты меток и дневника", "пароль хранилища код галерея папки карта дневник заметки дополнительный"),
        .init(.emergencyPIN, .security, "Пароль-камикадзе", "Удаление фотографий специальным кодом", "камикадзе экстренный код пароль уничтожение удалить фото"),
        .init(.bruteForce, .security, "Защита от перебора пароля", "Удаление после неверных попыток", "ошибочный неправильный неверный пароль попытки 3 5 10 20 перебор стирание блокировка"),
        .init(.inactivity, .security, "Автоматическое уничтожение", "Удаление при долгой неактивности", "dead man switch deadman таймер неактивность самоуничтожение 24 48 72 часов 7 дней время"),
        .init(.actionButton, .actionButton, "Действие Action Button", "Камера, удаление или блокировка входа", "кнопка действия боковая shortcut команды url камера сброс сбросить полный стереть уничтожить данные вход заблокировать " + ActionButtonMode.allCases.map { $0.title }.joined(separator: " "))
    ]

    private static let stopWords: Set<String> = ["и", "в", "во", "на", "от", "по", "за", "к", "с", "со", "из", "при", "для", "до"]

    static func search(_ query: String) -> [SettingsSearchEntry] {
        let tokens = normalize(query).components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty && !stopWords.contains($0) }
        guard !tokens.isEmpty else { return [] }
        return entries.filter { entry in
            let text = normalize([entry.title, entry.detail, entry.keywords, entry.category?.title ?? ""].joined(separator: " "))
            return tokens.allSatisfy { text.contains($0) }
        }
    }

    private static func normalize(_ value: String) -> String {
        value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "ru_RU"))
            .lowercased().replacingOccurrences(of: "ё", with: "е")
    }
}
