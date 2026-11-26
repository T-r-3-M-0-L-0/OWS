# Zapret2: работа с профилями и тактиками

Руководство по профилям Zapret2 на OpenWrt и Windows. Примеры Windows
относятся к отдельной сборке с `winws2` и её вспомогательным скриптам.

---

## 1. Модель работы

zapret2 — не прокси и не VPN. Движок перехватывает пакеты и изменяет их так,
чтобы DPI провайдера и конечный сервер по-разному собирали поток.

```
клиент → перехват WinDivert/NFQUEUE → профиль → Lua-действия → DPI → сервер
```

- **Профиль** — фильтры портов/L7/hostlist/ipset, условия payload и цепочка
  `--lua-desync`.
- Срабатывает **первый подходящий профиль**. Узкие профили размещаются выше
  общих.
- **Тактика** — Lua-функция (`fake`, `multisplit`, `multidisorder`, `syndata`
  и др.) с аргументами.
- Глобальные `--lua-init` и `--blob` задаются до первого профиля. Первый профиль
  пишется **без `--new`**; `--new` нужен только между профилями.

Основные фильтры:

| Фильтр | Назначение |
|---|---|
| `--filter-tcp=80,443` / `--filter-udp=443` | Порты |
| `--filter-l7=tls,http,quic,discord,stun` | L7-протокол |
| `--hostlist=<file>` / `--hostlist-domains=a.com,b.com` | Домены |
| `--hostlist-exclude=<file>` | Исключения доменов |
| `--ipset=<file>` / `--ipset-exclude=<file>` | IP/CIDR и исключения |
| `--payload=tls_client_hello,http_req,quic_initial` | Тип payload |
| `--out-range=-d10` / `--out-range=-n2` | Ограничение числа срабатываний |

В hostlist одна строка означает домен и его поддомены. Начиная с v1.0.7 префикс
`!домен` задаёт локальное исключение. Один и тот же файл одного типа нельзя
указывать повторно в одном профиле.

---

## 2. Команды и каталоги

### Windows

Запускайте команды из каталога установленной сборки Windows.

| Действие | Команда |
|---|---|
| Главное меню | `service.bat` или `service.ps1` |
| Статус службы | `sc.exe query zapret2` |
| Стоп/старт | `sc.exe stop zapret2` / `sc.exe start zapret2` |
| Проверка процесса | `tasklist /FI "IMAGENAME eq winws2.exe"` |
| Debug-сессия | `python ztool.py debug Custom.bat` |
| Конвертация в @config | `python ztool.py config Custom.bat` |
| Пробы доменов | `python ztool.py watch --once` |
| Анализ WinDivert-фильтра | `python ztool.py wfcheck Custom.bat` |
| Гигиена списков | `python ztool.py hostlists stats` |
| Диагностический ZIP | `python ztool.py diag` |
| Подбор тактики | `python blockcheck.py <домен> [--quick] [--proto tls|http|quic]` |
| TCP timestamps для TS-фейков | `netsh interface tcp set global timestamps=enabled` |

`blockcheck.py` останавливает службу на время теста и восстанавливает её в
`finally`. Не запускайте параллельно второй обычный `winws2`: WinDivert у них
общий. Не убивайте `winws2.exe` через `taskkill`/`Stop-Process`; используйте
`sc stop zapret2` или корректный CTRL_BREAK.

| Путь | Содержимое |
|---|---|
| `bin\` | `winws2.exe`, WinDivert и бинарные fake-blobs |
| `profiles\` | Модульные профили; `00_base.conf` — глобальный блок |
| `lists\` | hostlist/ipset |
| `lua\` | `zapret-lib.lua`, `zapret-antidpi.lua` и остальные библиотеки релиза |
| `logs\` | Журналы и диагностические архивы |
| `Custom.bat` | Собранная пользователем стратегия |
| `service.ps1`, `ztool.py`, `blockcheck.py` | Управление и диагностика |
| `tg-ws-proxy\` | Telegram WS-прокси |

### OpenWrt

| Действие | Команда |
|---|---|
| Применить UCI | `uci commit zapret2 && /etc/init.d/zapret2 restart` |
| Конфигурация | `uci show zapret2` |
| Журнал | `logread -e zapret2` |
| NFQUEUE | `nft list ruleset | grep -i nfq` |
| Проверка стратегий | Вкладка «Сравнение стратегий» / strategy-check |

| Путь | Содержимое |
|---|---|
| `/etc/config/zapret2` | UCI: секции `strategy`, `blob`, `list` |
| `/opt/zapret2/ipset/` | hostlist/ipset |
| `/opt/zapret2/lua/` | Lua-библиотеки |
| `/opt/zapret2/files/fake/` | Бинарные fake-blobs |
| `/opt/zapret2/config` | Сгенерированный конфиг; вручную не править |

Локальный `curl` с роутера проверяет базовую доступность, но не основной
transit-путь клиентов LAN. Для проверки desync используйте strategy-check.

---

## 3. Синтаксис профилей

Windows-профиль:

```bat
--filter-tcp=443 --filter-l7=tls --hostlist="%LISTS%list-google.txt" ^
--payload=tls_client_hello --out-range=-d10 ^
--lua-desync=fake:blob=tls_google:tcp_ts=-600000:repeats=6 ^
--lua-desync=fakedsplit:pattern=0x00:tcp_ts=-600000
```

В `profiles\*.conf` продолжения `^` не нужны; сборщик добавляет их и `--new`
сам. Пути задаются токенами `%BIN%`, `%LISTS%`, `%LUA%`.

Blob объявляется в `00_base.conf`:

```bat
--blob=tls_google:"%BIN%tls_clienthello_www_google_com.bin"
```

Производный SNI:

```bat
--lua-init="tls_ozon=tls_mod(tls_google,'sni=ozon.ru')"
```

Для zapret2 используются аргументы Lua, а не старые `--dpi-desync-*`. Основной
маппинг с zapret1 находится в `MIGRATION_ZAPRET2.md` и `PROFILES_GUIDE.md`.

---

## 4. Основные тактики

### fake

Отправляет поддельный payload до оригинального пакета:

```bat
--lua-desync=fake:blob=tls_ozon:tcp_seq=-10000:tcp_ack=-66000:repeats=8
```

- `blob` обязателен;
- `repeats` — число повторов;
- `ip_ttl` / `ip_autottl`, `tcp_ts`, `tcp_md5`, `tcp_seq`/`tcp_ack` — fooling;
- `tls_mod=rnd,dupsid,sni=ozon.ru` — модификация TLS-фейка;
- `optional` — пропустить действие при отсутствии blob.

Для `tcp_ts` на Windows-клиенте должны быть включены TCP timestamps.

### multisplit / multidisorder

```bat
--lua-desync=multisplit:pos=1,midsld
--lua-desync=multidisorder:pos=1,sniext+1,midsld
```

`multisplit` отправляет части по порядку, `multidisorder` — с нарушением
порядка. Перекрытие sequence задаётся так:

```bat
--lua-desync=multisplit:pos=1:seqovl=681:seqovl_pattern=tls_ozon
```

Позиции: `1`, `host`, `sld`, `midsld`, `endhost-1`, `sniext+1`, смещения
`+N`/`-N`. Маркера `sni` в установленной версии нет.

### fakedsplit / hostfakesplit

```bat
--lua-desync=fakedsplit:pattern=0x00:tcp_ts=-600000
--lua-desync=hostfakesplit:host=ozon.ru:tcp_ts=-600000:repeats=4
```

### syndata и obfs

`syndata` передаёт данные в SYN и применим не к каждому пути. `zapret-obfs.lua`
содержит обфускационные функции, включая `wgobfs`/UDP-over-ICMP сценарии; они
не используются в текущем `Custom.bat` и требуют отдельной настройки обоих
концов соединения там, где это предусмотрено функцией.

### Порядок подбора

1. Проверить DNS и TCP без обхода; незаблокированный домен в hostlist не
   добавлять.
2. `fake` с минимальным числом повторов.
3. `multisplit`, затем `multidisorder` с разными позициями.
4. Fooling и комбинации `fake` + split.
5. `seqovl` для реассемблирующего DPI.
6. Изменять один параметр за раз и проверять соседние сервисы.

Автоматизация: `python blockcheck.py <домен> --quick`; полный запуск добавляет
рефайнмент позиций, `seqovl`, повторов и fooling. Для HTTP/QUIC используйте
`--proto http` / `--proto quic`.

---

## 5. Fake-blobs

Встроенные имена в Lua: `fake_default_tls`, `fake_default_quic`,
`fake_default_http`. Файловые blobs объявляются через `--blob` на Windows и
через UCI `config blob` на OpenWrt.

Выбирайте blob по протоколу: TLS ClientHello для TLS, QUIC Initial для QUIC,
HTTP request для HTTP. Наличие файла недостаточно: имя должно быть
зарегистрировано, а путь должен существовать на целевой системе.

---

## 6. Домены, DNS и IP-списки

- Домены берите из реальных запросов: DevTools, `chrome://net-export`,
  журналы приложений.
- Достаточно базового домена, если нужны его поддомены; независимые зоны,
  например `googlevideo.com` и `ytimg.com`, добавляются отдельно.
- Для ipset используйте актуальные DoH-ответы и CIDR ASN, а не подменённые
  провайдерские ответы:

```sh
curl -s "https://1.1.1.1/dns-query?name=example.com&type=A" \
  -H "accept: application/dns-json"
```

- Провайдерский DNS и DoH можно сравнить через `nslookup` и такой JSON-запрос.
- Статический DNS-pinning требует регулярной проверки: смена IP или null-route
  не исправляются desync.

---

## 7. Антипаттерны

- Первый `--new` сразу после глобального блока — пустой catch-all.
- Общий профиль выше узкого — узкий никогда не сработает.
- Перехват всего UDP — поломка игр, голоса и служебных протоколов.
- Добавление незаблокированного домена — агрессивная тактика может его сломать.
- `tcp_ts` при выключенных TCP timestamps — TS-фейки не работают.
- Одновременный запуск zapret1 и zapret2 — конфликт WinDivert.
- Принудительное завершение `winws2.exe` — возможен клин WinDivert.
- Обновление `winws2.exe` без соответствующих Lua-файлов — несовместимость
  `NFQWS2_COMPAT_VER`.
