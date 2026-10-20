# Chitall

Личная iPhone-читалка для исследовательского чтения: импорт своей DRM-free книги EPUB или FB2, чтение, цветные выделения с мыслью и тегами, «Материалы» с поиском и фильтрами, экспорт в Markdown и JSON для работы с ИИ. Всё хранится на устройстве — без аккаунта, сети и аналитики.

- Цель и MVP — [PRODUCT_BRIEF.md](PRODUCT_BRIEF.md)
- Решения и альтернативы — [DECISIONS.md](DECISIONS.md)
- Статус и проверки — [PROGRESS.md](PROGRESS.md)
- Архитектура — [docs/architecture.md](docs/architecture.md), locator — [docs/locator.md](docs/locator.md), экспорт — [docs/export-format.md](docs/export-format.md)
- Проверка на Mac — [docs/macos-checklist.md](docs/macos-checklist.md)

## Структура

```
Chitall.xcodeproj   iOS 17+ проект (Xcode 16+, buildable folders)
Chitall/            приложение: SwiftUI + UITextView (TextKit 1) + SwiftData
ChitallTests/       тесты приложения (SwiftData, импорт, рендер, читалка)
ChitallCore/        Swift-пакет без UIKit: FB2, EPUB, модель книги, locator, экспорт + тесты
Config/Info.plist   типы файлов FB2 и EPUB, «Открыть в Chitall»
tools/              запуск тестов ядра на Windows, проверка проекта, генераторы
```

## Запуск

На Mac: открыть `Chitall.xcodeproj`, выбрать команду подписи, запустить на iPhone или симуляторе; `⌘U` — тесты приложения. Пошагово для своего iPhone — [docs/run-on-iphone.md](docs/run-on-iphone.md).

При каждом `git push` GitHub Actions собирает приложение на macOS, гоняет тесты ядра и приложения в симуляторе iPhone (`.github/workflows/build.yml`).

Тесты ядра без Xcode (macOS, Linux или Windows со Swift 6):

```bash
swift test --package-path ChitallCore
```

На Windows то же через скрипт, который сам находит свежеустановленный toolchain:

```bash
pwsh tools/test-core.ps1
```

Статическая проверка Xcode-проекта, plist-файлов, схемы и ресурсов:

```bash
python -I tools/check_project.py
```

## Книги

Chitall не скачивает книги и не обходит DRM. В репозитории только тексты, написанные специально для тестов (`ChitallCore/Tests/ChitallCoreTests/Fixtures`, `Chitall/Resources/SampleBooks`).
