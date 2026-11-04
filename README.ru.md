# wslbin

[![CI](https://github.com/quatrebi/wslbin/actions/workflows/ci.yml/badge.svg)](https://github.com/quatrebi/wslbin/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
![Platform: Windows 10 and 11, WSL 2](https://img.shields.io/badge/platform-Windows%2010%2F11%20%2B%20WSL%202-0078D6)
[![Support on Ko-fi](https://img.shields.io/badge/Ko--fi-support%20wslbin-ff7a45?logo=ko-fi&logoColor=white)](https://ko-fi.com/Y7H12A1AMH)

**Linux-утилиты из WSL как обычные программы Windows.**

`rsync`, `make`, `dig`, `nc`, `man`, полноэкранные программы вроде `redis-tui`: запускайте их из PowerShell,
cmd, терминала IDE или из любой программы. Пути Windows, шаблоны, конвейеры, цвета, `Ctrl+C` и коды выхода
работают так, как вы ждёте.

[English](README.md) · [Установка](#установка) · [Использование](#использование) · [Автодополнение](#автодополнение) · [Для ИИ-агентов](#для-ии-агентов) · [Документация](#документация)

## Пример

```powershell
make build
rsync -av C:\proj\dist\ host:/srv/app/
rsync -av *.log host:/srv/logs/
dig example.com
```

`--wslbin-explain` печатает, что запустится в WSL, и ничего не запускает:

```text
PS> rsync --wslbin-explain -av C:\proj\dist\ host:/srv/app/
rsync -av /mnt/c/proj/dist/ host:/srv/app/
PS> rsync --wslbin-explain -av *.log C:\backup\
rsync -av *.log /mnt/c/backup/
```

## Что получаете

- **Один маленький `.exe`.** Каждая утилита - копия `wslbin.exe` с её именем (`rsync.exe`, `make.exe`, ...).
  В Windows больше ничего ставить не нужно: ни .NET, ни рантайма.
- **Пути работают.** `C:\proj\dist\` становится `/mnt/c/proj/dist/`; bash раскрывает `*.log` по правилам Linux.
- **Безопасно по умолчанию.** Набранным аргументом нельзя выполнить вторую команду (`--wslbin-sh` и
  `wslbin -c` - для случаев, когда текст должен разобрать Linux).
- **Без посредника.** Ввод и вывод не перехватываются: работают конвейеры, цвета и полноэкранные программы, а
  код выхода утилиты - это и ваш код выхода (125 значит, что сбой в wslbin или в `wsl.exe`).

> **Состояние.** Всё работает и покрыто тестами, но релиза ещё нет, а сайт (GitHub Pages) не опубликован,
> поэтому команда установки ниже заработает после первого релиза и первого деплоя Pages. До тех пор соберите
> программу из исходников: см. [Сборка и запуск из исходников](CONTRIBUTING.md#build-and-use-from-source)
> (файл на английском).

## Установка

Нужны Windows 10 22H2 или Windows 11 (x64) и WSL 2 с дистрибутивом. Установщик работает в Windows
PowerShell 5.1 и в PowerShell 7.

```powershell
irm https://quatrebi.github.io/wslbin/install.ps1 | iex
```

- Команда скачивает последний релиз, проверяет его и запускает установщик из него.
- По умолчанию wslbin ставится в `%LOCALAPPDATA%\Programs\wslbin` и в PATH пользователя, без прав
  администратора. В консоли команда спросит то, что не задано: для кого ставить и подключать ли
  автодополнение.
- Параметры (для всех пользователей, обёртки, автодополнение, тихий режим) передаёт блок скрипта:

```powershell
& ([scriptblock]::Create((irm https://quatrebi.github.io/wslbin/install.ps1))) -Scope AllUsers -Link make,rsync -Completion pwsh -Quiet
```

Дальше:

```powershell
wslbin --doctor            # проверка WSL, bash, дополнения, PATH, обёрток, wslbin.ini
wslbin --link make rsync   # ещё обёртки; предложит поставить недостающую утилиту через apt
wslbin --list              # обёртки и что с ними не так
```

Все параметры, что доказывают проверки, обновление, удаление и установка без сети:
[INSTALL.ru.md](INSTALL.ru.md).

## Использование

| Что нужно | Что набрать |
| --- | --- |
| утилита, как обычно | `make build`, `rsync -av C:\x\ host:/srv/` |
| утилита без обёртки | `wslbin htop` |
| переменные Linux и `$(...)` | `make --wslbin-sh 'OUT=$HOME/out' 'TAG=$(git rev-parse --short HEAD)'` |
| аргументы ровно как набраны | `grep --wslbin-raw 'a*' file.txt` |
| что запустится, не запуская | `rsync --wslbin-explain -av *.log C:\backup\` |
| конвейер внутри Linux | `wslbin -c "ls *.log \| wc -l"` |

Опции `--wslbin-raw`, `--wslbin-sh` и `--wslbin-explain` пишутся сразу после имени утилиты и только там;
всё, что дальше, принадлежит утилите. По умолчанию:

- Пути Windows становятся путями Linux. Относительный путь с обратными косыми переводится, только если такой
  файл или папка есть в текущей папке (`wslbin --help paths`).
- bash раскрывает `*`, `?`, `[...]` и ведущую `~`; всё остальное (`$`, `;`, `|`, `&`, кавычки, скобки,
  пробелы) доходит до утилиты буквально.
- PowerShell и cmd снимают кавычки до запуска wslbin, поэтому `grep 'a*' f` доходит как `a*`: для такого -
  `--wslbin-raw`.

Справка встроена в программу, на английском и русском: `wslbin --help`, а также `wslbin --help` с `modes`,
`paths`, `globs`, `env`, `completion`, `config` или `troubleshooting`. Настройки (`distro`, `raw`, `sh`,
`pass_env`, `path`, `args.<утилита>`, `lang`) лежат в `wslbin.ini` рядом с `wslbin.exe`:
`wslbin --help config`.

## Автодополнение

Варианты берутся из bash-completion в WSL, поэтому `rsync --<Tab>`, `make <Tab>` или `man <Tab>` дают то же,
что в Linux, а пути Windows работают в обе стороны (`C:\Prog` становится `C:\Program Files\`). Нужен пакет
`bash-completion` в WSL (`wslbin --doctor` его проверяет).

В PowerShell эту строку кладут в профиль; в cmd - `wslbin --init clink` (нужен
[Clink](https://chrisant996.github.io/clink/)). Установщик с `-Completion pwsh,clink` делает и то, и другое.

```powershell
wslbin --init pwsh | Invoke-Expression
```

Строка для PowerShell ещё и убирает псевдонимы, которые закрыли бы обёртку (`ls`, `cat`, `rm`, ...), на весь
сеанс и для всех скриптов в нём: делайте обёртки только для тех имён, которые должны означать Linux-утилиту.

## Для ИИ-агентов

`wslbin --ai-context` печатает, как агенту вызывать Linux-утилиты на этой машине (тот же текст, что в
[`llms.txt`](llms.txt)). `wslbin --install-ai-context` добавляет короткий помеченный блок в инструкции
Claude Code (`CLAUDE.md` и навык) и Codex (`AGENTS.md`); `--remove` убирает его. Агентам, которые
разрабатывают сам wslbin: начните с [CONTRIBUTING.md](CONTRIBUTING.md).

## Документация

- [INSTALL.ru.md](INSTALL.ru.md): установщик подробно (параметры, область установки, проверки, обновление, удаление, установка без сети).
- [`docs/ru`](docs/ru): тексты справки программы (`wslbin --help`).
- [CONTRIBUTING.md](CONTRIBUTING.md): сборка из исходников, тесты, версии, устройство репозитория (на английском).

## Лицензия

[MIT](LICENSE), Copyright (c) 2026 Dmitriy Khudnitskiy.
