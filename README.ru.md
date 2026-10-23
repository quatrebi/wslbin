# wslbin

[![CI](https://github.com/quatrebi/wslbin/actions/workflows/ci.yml/badge.svg)](https://github.com/quatrebi/wslbin/actions/workflows/ci.yml)
[![Release](https://img.shields.io/github/v/release/quatrebi/wslbin?include_prereleases)](https://github.com/quatrebi/wslbin/releases)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
![Platform: Windows 10 and 11, WSL 2](https://img.shields.io/badge/platform-Windows%2010%2F11%20%2B%20WSL%202-0078D6)
![No dependencies](https://img.shields.io/badge/dependencies-none-brightgreen)

[English](README.md)

Linux-утилиты из WSL как обычные программы Windows. `rsync`, `make`, `dig`, `nc`, `man`, полноэкранные
программы вроде `redis-tui`: запускайте их из PowerShell, cmd, терминала IDE или из любой программы,
а пути Windows, шаблоны, конвейеры, цвета, `Ctrl+C` и коды выхода работают так, как вы ждёте.

```powershell
make build
rsync -av C:\proj\dist\ host:/srv/app/
rsync -av *.log host:/srv/logs/
dig example.com
```

Каждая утилита - копия одного маленького `wslbin.exe` с её именем (`rsync.exe`, `make.exe`, ...). Он
превращает `C:\proj\dist\` в `/mnt/c/proj/dist/`, отдаёт bash раскрыть `*.log` по правилам Linux,
экранирует всё остальное, запускает утилиту в WSL и возвращает её код выхода. Ввод и вывод не
перехватываются, поэтому работают конвейеры и полноэкранные программы.

> **Состояние.** Всё работает и покрыто тестами, но релиза ещё нет: до первого устанавливайте из
> копии исходников.

## Установка

Нужны Windows 10 22H2 или Windows 11 с WSL 2 и дистрибутивом. Программа - один самодостаточный файл,
больше ей ничего не нужно. Пока релиза нет, `install.ps1` собирает её из копии исходников, а для этого
нужны [.NET SDK 10](https://dotnet.microsoft.com/download) и инструменты сборки C++ из Visual Studio
(набор "Разработка классических приложений на C++").

```powershell
# из копии исходников:
powershell -NoProfile -ExecutionPolicy Bypass -File .\install.ps1 -Source . -Link make,rsync,dig -Completion pwsh,clink

# из релиза (install.ps1 и SHA256SUMS.txt лежат на странице релиза; хеш - у wslbin-<тег>-source.zip;
# -Repository равен quatrebi/wslbin, если не указать другой):
powershell -NoProfile -ExecutionPolicy Bypass -File .\install.ps1 -Version v<версия> -Sha256 <хеш> -Link make,rsync,dig
```

Windows по умолчанию не запускает скрипты, а скачанный `install.ps1` помечает как полученный из
интернета: `-ExecutionPolicy Bypass` разрешает этот один запуск и больше ничего не меняет.

`-Scope AllUsers` (по умолчанию пробуется первым) ставит wslbin в `C:\Program Files\wslbin`, в PATH
машины, и просит права администратора (UAC). Копия с правами ставит только саму программу: `-Link` и
`-Completion` делаются потом от вашего имени, в вашем WSL и ваших профилях (поэтому `-Link` ещё раз
попросит права, чтобы записать обёртки). `-Scope CurrentUser` (запасной вариант, если в правах
отказали) - `%LOCALAPPDATA%\Programs\wslbin` и PATH пользователя. `-Completion` подключает
автодополнение в PowerShell (обе редакции) и Clink. `-Uninstall` убирает всё, в том числе блок для
ИИ-агентов (ваш `wslbin.ini` остаётся). Остальное - `Get-Help .\install.ps1 -Full`.

Дальше:

```powershell
wslbin --doctor            # проверка WSL, bash, дополнения, PATH, обёрток, wslbin.ini
wslbin --link make rsync   # ещё обёртки; предложит поставить недостающую утилиту через apt
wslbin --list              # обёртки и что с ними не так
```

## Использование

| Что нужно | Что набрать |
| --- | --- |
| утилита, как обычно | `make build`, `rsync -av C:\x\ host:/srv/` |
| утилита без обёртки | `wslbin htop` |
| переменные Linux и `$(...)` | `make --wslbin-sh 'OUT=$HOME/out' 'TAG=$(git rev-parse --short HEAD)'` |
| аргументы ровно как набраны | `grep --wslbin-raw 'a*' file.txt` |
| что запустится, не запуская | `rsync --wslbin-explain -av *.log C:\backup\` |
| конвейер внутри Linux | `wslbin -c "ls *.log \| wc -l"` |

По умолчанию пути Windows становятся путями Linux, bash раскрывает `*`, `?`, `[...]` и ведущую `~`, а
всё остальное (`$`, `;`, `|`, `&`, кавычки, скобки, пробелы) доходит до утилиты буквально. Набранным
аргументом нельзя выполнить вторую команду. Относительный путь с обратными косыми (`.\file`, `src\a.c`,
то, что пишет Tab-дополнение) переводится, если такой файл или папка есть в текущей папке, и остаётся
как набран, если нет (`.\d+` остаётся регулярным выражением). PowerShell и cmd снимают кавычки до
запуска wslbin, поэтому `grep 'a*' f` доходит как `a*`: для такого - `--wslbin-raw`.

Справка встроена в программу, на английском и русском: `wslbin --help`, а также `wslbin --help` с
`modes`, `paths`, `globs`, `env`, `completion`, `config` или `troubleshooting`. Те же тексты - в
[`docs/ru`](docs/ru). Настройки (`distro`, `raw`, `sh`, `pass_env`, `path`, `args.<утилита>`, `lang`)
лежат в `wslbin.ini` рядом с `wslbin.exe`: `wslbin --help config`.

## Автодополнение

Варианты берутся из bash-completion в WSL, поэтому `rsync --<Tab>`, `make <Tab>` или `man <Tab>` дают то
же, что в Linux, а пути Windows работают в обе стороны (`C:\Prog` становится `C:\Program Files\`).
В PowerShell строку `wslbin --init pwsh | Invoke-Expression` кладут в профиль; в cmd - `wslbin --init clink`
(нужен [Clink](https://chrisant996.github.io/clink/)). `install.ps1 -Completion pwsh,clink` делает и то,
и другое. Строка для PowerShell ещё и убирает псевдонимы, которые закрыли бы обёртку (`ls`, `cat`,
`rm`, ...), на весь сеанс и для всех скриптов в нём: делайте обёртки только для тех имён, которые
должны означать Linux-утилиту.

## Для ИИ-агентов

`wslbin --ai-context` печатает, как агенту вызывать Linux-утилиты на этой машине (тот же текст, что в
[`llms.txt`](llms.txt)). `wslbin --install-ai-context` добавляет короткий помеченный блок в инструкции
Claude Code (`CLAUDE.md` и навык) и Codex (`AGENTS.md`); `--remove` убирает его. Агентам, которые
разрабатывают сам wslbin: читайте [`AGENTS.md`](AGENTS.md).

## Сборка и участие в разработке

Нужны [.NET SDK 10](https://dotnet.microsoft.com/download), инструменты сборки C++ из Visual Studio
(набор "Разработка классических приложений на C++") и доступ к nuget.org, пока пакетов NuGet компилятора
AOT и рантайма нет в кэше (первая сборка и обновление SDK). Программа публикуется как Native AOT: один
самодостаточный `.exe`, который копирует каждая обёртка.

```powershell
.\build.ps1                                        # bin\wslbin.exe, с версией этой копии
.\get-version.ps1                                  # эта версия, в формате SemVer 2.0
Invoke-Pester .\tests                              # всё (нужен WSL; тестам Clink нужен Clink)
Invoke-Pester .\tests -ExcludeTagFilter WSL        # то, что не требует ни того, ни другого (это запускает CI)
```

Программа - C# на .NET 10 в [`src/`](src), по файлу на каждую область; в [`src/wslbin.cs`](src/wslbin.cs)
точка входа и карта остальных. Тесты - Pester 5 в PowerShell 7.
В [`DECISIONS.md`](DECISIONS.md) собраны все принятые решения и то, что выяснилось по дороге; агентам,
которые работают над wslbin, нужен [`AGENTS.md`](AGENTS.md).

Версии автоматические (SemVer 2.0). `MAJOR.MINOR` - это `VersionPrefix` в
[`wslbin.csproj`](wslbin.csproj): единственное, что в pull request меняют руками, и его не понижают.
`PATCH` - число коммитов с тех пор, как это значение появилось, а остальное говорит, откуда сборка:
`0.1.4-develop.42+33c8830` - это 42-й запуск CI, на `develop`, на этом коммите; у релиза суффикса нет.
У сборок разных веток версии никогда не совпадают, а `wslbin --version` её печатает.

```
src/               программа
wslbin.csproj      проект: MAJOR.MINOR версии, что вшивается в .exe
data/              утилиты, у которых есть своя версия для Windows (вшивается в .exe)
wsl/complete.sh    помощник автодополнения, работает в WSL
shell/             код для PowerShell и Clink, который заполняет "wslbin --init"
docs/en  docs/ru   тексты справки (вшиваются в .exe)
install.ps1        установщик и удаление
build.ps1          сборка (dotnet publish, Native AOT)
get-version.ps1    версия сборки; её функции - в Wslbin.Version.psm1
tests/             тесты Pester
.github/workflows/ CI и релиз
LICENSE            MIT
```

## Лицензия

[MIT](LICENSE), Copyright (c) 2026 Dmitriy Khudnitskiy.
