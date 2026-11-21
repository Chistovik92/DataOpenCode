# OpenCode Port

> Безопасный аддитивный перенос провайдеров, моделей, API-ключей и диалогов OpenCode между Windows-компьютерами.

`opencode-port` собирает на компьютере A конфигурацию провайдеров, ключи API, выбранные
переменные окружения и диалоги в один zip-архив и разворачивает его на компьютере B.
Инструмент работает **аддитивно**: не удаляет и не перезаписывает существующие локальные
настройки, файлы и записи с совпадающими ID.

Поддерживаются все направления переноса диалогов: **V1 → V1**, **V1 → V2**, **V2 → V1**,
**V2 → V2**.

## Возможности

- **Экспорт** конфигурации (`opencode.json` / `opencode.jsonc`), каталога `.opencode`,
  файла ключей `auth.json`, выбранных переменных окружения и диалогов (сессий).
- **Аддитивный импорт** — локальные конфликтующие значения и настройки, не связанные
  с провайдерами, сохраняются; поддерживаются оба написания `provider` и `providers`.
- **Перенос диалогов** через штатные CLI-команды OpenCode с конвертацией JSON между V1 и V2.
- **Сохранение данных** — существующие session ID пропускаются; исходный transfer JSON
  хранится в metadata импортированной сессии.
- **Безопасность** — защита ZIP (path traversal, лимиты размера и числа элементов),
  отклонение повреждённых JSON до изменения конфигурации, скрытие секретов и stderr CLI,
  резервные копии перед каждым изменением.

## Быстрый старт

Скачайте [`opencode-port.ps1`](opencode-port.ps1) и [`opencode-port.cmd`](opencode-port.cmd)
из [релиза](https://github.com/Chistovik92/DataOpenCode/releases) в одну папку.

```bat
:: Компьютер A — экспорт (архив opencode-port-<ПК>-<дата>.zip)
opencode-port.cmd export
opencode-port.cmd export -Secrets All -Env AISTAR_API_KEY

:: Компьютер B — импорт (OpenCode Desktop должен быть закрыт)
opencode-port.cmd import -Zip opencode-port-....zip
opencode-port.cmd import -Zip opencode-port-....zip -SetEnv -OverwriteEnv
opencode-port.cmd import -Zip opencode-port-....zip -DryRun
```

Двойной клик по `opencode-port.cmd` открывает интерактивное меню.

Подробное описание параметров, порядка работы импорта и устранения неполадок — в
[`README-opencode-port.md`](README-opencode-port.md).

## Требования

- OpenCode V1 (1.2.x) или V2 (2.3.x).
- Windows PowerShell 5.1+, Windows 10/11.
- Для переноса диалогов — доступный `opencode` CLI (или путь через `OPENCODE_PORT_CLI`).

## Разработка

```bat
:: изолированные тесты (синтетические данные, подменённый CLI)
python -m unittest discover -s tests -v
```

Тесты не используют реальные секреты и диалоги. Перед реальным импортом закройте
OpenCode Desktop и выполните `-DryRun`.

## Безопасность

Архив с `-Secrets Auth/All` содержит действующий API-ключ в открытом виде.
Передавайте его по защищённому каналу и удаляйте после импорта. Для переноса без ключей
используйте `-Secrets None` и введите ключ на машине B вручную.

## Документация

- [`README-opencode-port.md`](README-opencode-port.md) — полная документация инструмента.
- [`CHANGELOG.md`](CHANGELOG.md) — история изменений.
- [`DEVELOPMENT_PLAN.md`](DEVELOPMENT_PLAN.md) — статус и план развития.

## Лицензия

[MIT](LICENSE)
