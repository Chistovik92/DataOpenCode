# OpenCode Port v1.0.0

Скрипт переноса **своего (кастомного) провайдера** OpenCode Desktop между компьютерами под Windows: собирает на компьютере A конфиг, ключи и переменные окружения в один zip-архив и разворачивает на компьютере B.

## Возможности

- **Экспорт**: `opencode.json` / `opencode.jsonc`, каталог `.opencode\` (агенты, команды, плагины), `auth.json` (ключи API), переменные окружения (`-Env`)
- **Импорт**: слияние с уже существующим конфигом — локальные настройки и провайдеры не теряются
- **Понимает JSONC**: комментарии `//` и `/* */`, висячие запятые
- **Безопасность**: резервные копии `*.bak` перед каждым изменением, режим `-Secrets None` без ключей, `-DryRun` для просмотра плана изменений
- **Проверки**: отказ при запущенном OpenCode Desktop, валидация архива (чужой/повреждённый zip отклоняется), понятные сообщения об ошибках
- **Интерактивное меню** через двойной клик `opencode-port.cmd`

## Быстрый старт

```bat
:: Компьютер A — экспорт (архив opencode-port-<ПК>-<дата>.zip)
opencode-port.cmd export

:: Компьютер B — импорт (OpenCode Desktop должен быть закрыт)
opencode-port.cmd import -Zip opencode-port-....zip
```

Подробности и полный список параметров — в [README](https://github.com/Chistovik92/DataOpenCode#readme).

## Установка

1. Скачать `opencode-port.ps1` и `opencode-port.cmd` из ассетов релиза в одну папку
2. Запустить `opencode-port.cmd` (или вызвать `opencode-port.ps1` из PowerShell)
3. Выбрать пункт 1 (экспорт) или 2 (импорт)

## Важно

- Архив с `-Secrets Auth/All` содержит **API-ключ в открытом виде** — передавайте по защищённому каналу
- Пути config/data учитывают `XDG_CONFIG_HOME`, `XDG_DATA_HOME`, `OPENCODE_CONFIG_DIR` — как сам sidecar OpenCode
- Сессии и история чатов не переносятся (намеренно)

## Совместимость

- OpenCode Desktop 1.19.x (протестировано на 1.19.0)
- Windows PowerShell 5.1+, Windows 10/11

**Full Changelog**: https://github.com/Chistovik92/DataOpenCode/commits/v1.0.0
