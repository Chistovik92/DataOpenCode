# OpenCode Port v2.0.0

Инструмент безопасного аддитивного переноса провайдеров, моделей, API-ключей, выбранных переменных окружения и диалогов между OpenCode V1/V2 на разных Windows-компьютерах. Собирает данные в zip на машине A и разворачивает на машине B, не удаляя и не перезаписывая существующие локальные настройки, файлы и записи с совпадающими ID.

## Что нового в v2.0.0

- **Перенос диалогов** во всех четырёх направлениях: V1→V1, V1→V2, V2→V1, V2→V2 (через штатные CLI-команды OpenCode).
- **Конвертеры V1↔V2** для несовместимых схем JSON; исходный transfer JSON сохраняется в metadata импортированной сессии для восстановления исходных данных.
- **Аддитивное слияние** конфигурации: поддерживаются `provider` и `providers`; локальные конфликтующие значения и настройки, не связанные с провайдерами, сохраняются.
- Существующие session ID пропускаются; диалоги с совпадающими ID не объединяются и не перезаписываются. Дочерние диалоги импортируются после родительских.
- **Безопасность**: защита ZIP (path traversal, лимиты размера/числа элементов), отклонение повреждённых config/auth/env/session JSON до изменения конфигурации, скрытие секретов и stderr CLI, env только в область User, резервные копии с GUID.
- Поддержка Unicode при экспорте диалогов, `--standalone` для V2 CLI 2.3.2 и объектная пагинация `cursor.next`.

## Проверка

- 17 автоматических изолированных тестов (`python -m unittest discover -s tests -v`) — OK.
- Реальный изолированный тест на OpenCode 2.3.2: V1 JSON импортирован в V2 и экспортирован обратно, `quick_check=ok`.

## Быстрый старт

```bat
:: Компьютер A — экспорт
opencode-port.cmd export
opencode-port.cmd export -Secrets All -Env AISTAR_API_KEY

:: Компьютер B — импорт (OpenCode Desktop закрыт)
opencode-port.cmd import -Zip opencode-port-....zip
opencode-port.cmd import -Zip opencode-port-....zip -SetEnv -OverwriteEnv
opencode-port.cmd import -Zip opencode-port-....zip -DryRun
```

## Установка

1. Скачать `opencode-port.ps1` и `opencode-port.cmd` из ассетов релиза в одну папку.
2. Запустить `opencode-port.cmd` (или `opencode-port.ps1` из PowerShell).

## Совместимость

- OpenCode V1 (1.2.27) и V2 (2.3.2).
- Windows PowerShell 5.1+, Windows 10/11.

## Важно

- Архив с `-Secrets Auth/All` содержит API-ключ в открытом виде — передавайте по защищённому каналу.
- Перед реальным импортом закройте OpenCode Desktop и выполните `-DryRun`.
- Полный план развития и оставшиеся задачи — в `DEVELOPMENT_PLAN.md`.

**Full Changelog**: https://github.com/Chistovik92/DataOpenCode/commits/v2.0.0
