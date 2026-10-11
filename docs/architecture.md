# Архитектура

```
 Files picker / «Открыть в»            ┌──────────────────── ChitallCore (Swift package) ────────────────────┐
          │                            │                                                                     │
          ▼                            │  BookImporter ── ZipArchive (.fb2.zip)                              │
 BookImportService ──── bytes ────────▶│      │                                                              │
   (security scope,                    │      ▼                                                              │
    NSFileCoordinator)                 │  XMLTextDecoder (кодировка → UTF-8) → XMLTreeReader (XMLParser)     │
          │                            │      │                                                              │
          │                            │      ▼                                                              │
          │      ReadableBook ◀────────│  FB2Parser: главы, блоки {path, канонический текст, стили}, сноски  │
          │      fingerprint           │                                                                     │
          ▼                            │  ChapterText: текст главы + карта UTF-16 ↔ (блок, кодовая точка)     │
 SwiftData: StoredBook                 │  LocatorService: выделение → Locator v1 → выделение (переякоривание) │
 Application Support/Chitall/Books     │  MaterialFilter, MarkdownExporter, JSONExporter                     │
          │                            └─────────────────────────────────────────────────────────────────────┘
          ▼
 ReaderModel ── ChapterText ── ChapterRenderer ── NSAttributedString ── BookTextView (UITextView, TextKit 1)
     │                                                                        │
     │◀──── NSRange выделения / тап по подсветке / ссылка-сноска ─────────────┘
     ▼
 SwiftData: Highlight {locatorJSON, text, note, tags, color, provenance}
     │
     ▼
 MaterialsView (поиск, фильтры) ── MaterialExport ── Markdown + JSON ── ShareLink
```

## Инварианты

1. **Текст на экране = `ChapterText.string`.** Рендер только добавляет атрибуты (шрифты, абзацы, ссылки, вложения на месте U+FFFC), поэтому любое `NSRange` из `UITextView` точно переводится в позицию блока. Проверяется тестом `testRenderingKeepsTheCharacterMapExact`.
2. **Locator ссылается на исходный файл, а не на экран.** Путь элемента и смещение в каноническом тексте не зависят от шрифта, темы, ширины экрана и кодировки файла.
3. **Выделение самодостаточно.** У него есть цитата, название книги и главы, автор, locator и даты; оно не требует книги в библиотеке и экспортируется без неё.
4. **Ядро не знает про iOS.** `ChitallCore` собирается и тестируется на Windows/Linux/macOS; всё, что зависит от UIKit/SwiftUI/SwiftData, — в приложении.

## Где что лежит

| Путь | Содержимое |
|---|---|
| `ChitallCore/Sources/ChitallCore/FB2` | Кодировки, XML-дерево, разбор FB2, импорт, ошибки |
| `ChitallCore/Sources/ChitallCore/Reading` | `ReadableBook`, канонизация текста, `ChapterText` |
| `ChitallCore/Sources/ChitallCore/Locator` | `Locator` v1, создание и разрешение |
| `ChitallCore/Sources/ChitallCore/Export` | Цвета, теги, фильтр, Markdown/JSON |
| `ChitallCore/Sources/ChitallCore/Support` | SHA-256, ZIP, смещения Unicode |
| `Chitall/App` | Точка входа, координатор, корневой `TabView` |
| `Chitall/Models` | SwiftData-схема v1 без связей |
| `Chitall/Services` | Файлы книг, импорт, удаление, запись экспорта |
| `Chitall/Reader` | `ReaderModel`, рендер главы, `UITextView`, листы оглавления и оформления |
| `Chitall/Highlights` | Редактор выделения, теги |
| `Chitall/Library`, `Chitall/Materials`, `Chitall/Settings` | Экраны |
| `Config/Info.plist` | Тип FB2, «Открыть в», шифрование |
| `tools/` | Тесты ядра на Windows, проверка проекта, генераторы фикстур и иконки |
