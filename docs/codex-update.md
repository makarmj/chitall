# Промпт для Codex на Маке: обновить Chitall и поставить на iPhone

Вставьте текст ниже в Codex, запущенный **локально на Маке** (Codex CLI или приложение Codex в локальном режиме), когда iPhone подключён кабелем и разблокирован. Облачная среда Codex не подходит: там Linux без Xcode.

```text
Работай только локально на этом Mac, не в облачной среде. Если у тебя нет доступа к локальной файловой системе Mac, к xcodebuild или к подключённому iPhone — остановись и скажи об этом.

Задача: обновить проект Chitall из GitHub и установить новую сборку на подключённый iPhone. Код приложения не меняй, ничего не коммить и не пушь.

1. Найди локальную копию репозитория https://github.com/makarmj/chitall (в ней есть Chitall.xcodeproj; проверь `git remote -v`). Если копии нет — склонируй в ~/Documents/chitall.
2. Покажи `git status` и `git log -1 --oneline`.
3. Сохрани локальные изменения (это настройки подписи в Chitall.xcodeproj/project.pbxproj: DEVELOPMENT_TEAM и PRODUCT_BUNDLE_IDENTIFIER): `git stash push -m "local signing"`, если есть что сохранять.
4. `git pull --ff-only origin main`, затем `git stash pop`. Если в project.pbxproj конфликт — возьми версию из GitHub и заново впиши в неё прежние локальные значения DEVELOPMENT_TEAM и PRODUCT_BUNDLE_IDENTIFIER у таргетов Chitall и ChitallTests. Bundle Identifier приложения не меняй: с новым идентификатором iPhone поставит отдельное приложение, и книги с выделениями останутся в старом.
5. Покажи `git log -1 --oneline` после обновления.
6. Проверь `xcodebuild -version` и найди iPhone: `xcrun devicectl list devices`. Возьми его Identifier из этого списка (он нужен для devicectl).
7. Собери для устройств:
   xcodebuild -project Chitall.xcodeproj -scheme Chitall -configuration Debug -destination "generic/platform=iOS" -derivedDataPath build/DerivedData -allowProvisioningUpdates build
8. Установи и запусти:
   xcrun devicectl device install app --device <ID iPhone> build/DerivedData/Build/Products/Debug-iphoneos/Chitall.app
   xcrun devicectl device process launch --device <ID iPhone> <Bundle Identifier приложения>
   Приложение с телефона не удаляй: вместе с ним удалятся книги и выделения. Установка идёт поверх.
9. Если на любом шаге ошибка — не пытайся чинить исходный код. Пришли полный текст ошибки. Типичные случаи: телефон заблокирован (попроси разблокировать), «Untrusted Developer» (Настройки → Основные → VPN и управление устройством → Доверять), не выбрана команда подписи (Xcode → Settings → Accounts).
10. В конце коротко отчитайся: какой коммит установлен, прошла ли сборка, установлено ли приложение.
```

Если что-то не получилось, пришлите отчёт Codex в чат проекта — по тексту ошибки будет видно, что поправить.
