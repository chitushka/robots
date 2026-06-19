# Торговый робот для QUIK на чистом QLua

## Назначение проекта

Цель проекта — разработать торгового робота для терминала QUIK на чистом QLua.

Робот должен реализовывать несколько базовых торговых стратегий для российских акций:

1. EMA Crossover — пересечение скользящих средних.
2. Donchian Channel Breakout — пробой максимума/минимума за период.
3. Donchian + Volume Filter — пробой диапазона с подтверждением объёмом.
4. RSI Mean Reversion — возврат к среднему через RSI.
5. EMA Trend Filter + RSI — торговля RSI только по направлению старшего тренда.
6. ATR Stop / ATR Trailing Stop — сопровождение позиции через волатильность.

Первая версия робота должна быть безопасной: по умолчанию работает в режиме сигналов или paper trading. Реальная отправка заявок включается только явно через параметр конфигурации.

---

QUIK использует встроенный интерпретатор QLua. Реализация должна быть ориентирована на QLua API терминала QUIK.

В проекте используются стандартные функции QLua:

- `getParamEx()` — получение параметров инструмента из таблицы текущих торгов.
- `CreateDataSource()` — получение свечных данных.
- `sendTransaction()` — отправка транзакций в торговую систему.
- `getItem()` и `getNumberOf()` — чтение таблиц QUIK.
- `getQuoteLevel2()` — чтение стакана заявок.
- `message()` — вывод сообщений в терминал.
- `sleep()` — паузы в основном цикле.
- `OnStop()` — обработчик остановки скрипта.

---


## Общая архитектура

Робот должен быть разделён на логические модули.

```text
quik_robot/
├── main.lua
├── config.lua
├── market_data.lua
├── indicators.lua
├── strategies.lua
├── risk.lua
├── orders.lua
├── portfolio.lua
├── logger.lua
├── state.lua
├── utils.lua
├── reports.lua
└── README.md
```

---

## Принцип работы

Робот работает в цикле:

```text
1. Загрузить конфигурацию.
2. Инициализировать инструменты.
3. Создать источники свечных данных.
4. Проверить подключение к QUIK.
5. На каждой новой свече:
   1. Обновить рыночные данные.
   2. Рассчитать индикаторы.
   3. Получить сигналы стратегий.
   4. Пропустить сигналы через risk manager.
   5. В режиме SIGNALS_ONLY вывести сигнал.
   6. В режиме PAPER_TRADING симулировать сделку.
   7. В режиме LIVE отправить заявку через sendTransaction().
   8. Записать событие в лог.
```

---

## Режимы работы

Робот обязан поддерживать три режима.

### 1. SIGNALS_ONLY

Робот только рассчитывает сигналы и пишет их в лог. Заявки не отправляются. Используется для первой проверки логики.

### 2. PAPER_TRADING

Робот симулирует сделки внутри Lua.

Он учитывает:

- цену входа;
- цену выхода;
- объём;
- комиссию;
- условное проскальзывание;
- текущий виртуальный PnL;
- открытую виртуальную позицию.

### 3. LIVE

Робот отправляет реальные заявки в QUIK через `sendTransaction()`. Для включения LIVE нужно явно указать:

```lua
TRADING_MODE = "LIVE"
ALLOW_REAL_ORDERS = true
```

---

## Конфигурация

Файл `config.lua` содержит:

```lua
Config = {
    trading_mode = "SIGNALS_ONLY",

    account = "L01-XXXXXX",
    client_code = "XXXX",
    firm_id = "",

    instruments = {
        {
            name = "SBER",
            class_code = "TQBR",
            sec_code = "SBER",
            enabled = true,
            lot_size = 10,
            max_position_lots = 1
        },
        {
            name = "GAZP",
            class_code = "TQBR",
            sec_code = "GAZP",
            enabled = false,
            lot_size = 10,
            max_position_lots = 1
        }
    },

    timeframe = INTERVAL_M15,

    cycle_sleep_ms = 1000,

    strategies = {
        ema_cross = {
            enabled = true,
            fast_period = 20,
            slow_period = 50
        },

        donchian = {
            enabled = true,
            entry_period = 20,
            exit_period = 10
        },

        donchian_volume = {
            enabled = true,
            entry_period = 20,
            volume_period = 20,
            volume_multiplier = 1.5
        },

        rsi_mean_reversion = {
            enabled = true,
            period = 14,
            buy_level = 25,
            exit_level = 50
        },

        ema_rsi = {
            enabled = true,
            ema_fast = 50,
            ema_slow = 200,
            rsi_period = 14,
            rsi_buy_level = 50
        }
    },

    risk = {
        max_order_lots = 1,
        max_position_lots = 1,
        max_trades_per_day = 3,
        max_daily_loss_rub = 500,
        max_signal_age_sec = 60,
        allow_short = false
    },

    execution = {
        order_type = "L",
        price_offset_steps = 1,
        slippage_percent = 0.05
    },

    logging = {
        enabled = true,
        file = "robot.log",
        csv_trades = "trades.csv",
        csv_signals = "signals.csv"
    }
}
```

---

## Модуль `market_data.lua`

Модуль отвечает за получение рыночных данных из QUIK.

```lua
MarketData.get_param_number(class_code, sec_code, param_name)
MarketData.get_last_price(class_code, sec_code)
MarketData.get_best_bid_ask(class_code, sec_code)
MarketData.get_order_book(class_code, sec_code)
MarketData.create_datasource(class_code, sec_code, interval)
MarketData.get_candles(ds, limit)
MarketData.is_new_candle(ds, last_size)
```

Функция `get_param_number()`:

1. Вызывает `getParamEx(class_code, sec_code, param_name)`.
2. Проверяет `result`.
3. Преобразовывает `param_value` в число.
4. Возвращает `nil, error`, если данные недоступны.

Пример логики:

```lua
function MarketData.get_param_number(class_code, sec_code, param_name)
    local p = getParamEx(class_code, sec_code, param_name)

    if p == nil then
        return nil, "getParamEx returned nil"
    end

    if p.result ~= "1" then
        return nil, "param not found: " .. tostring(param_name)
    end

    local value = tonumber(p.param_value)

    if value == nil then
        return nil, "param is not number: " .. tostring(p.param_value)
    end

    return value, nil
end
```

---

## Модуль `indicators.lua`

Модуль рассчитывает технические индикаторы по свечам.

### Индикаторы

Реализовает:

```lua
Indicators.sma(values, period)
Indicators.ema(values, period)
Indicators.rsi(values, period)
Indicators.atr(candles, period)
Indicators.highest_high(candles, period, offset)
Indicators.lowest_low(candles, period, offset)
Indicators.average_volume(candles, period)
```

---

## Индикатор SMA

### Логика

SMA — простое среднее значение за период.

```text
SMA = сумма закрытий за N свечей / N
```

### Использование

SMA можно использовать как:

- фильтр тренда;
- уровень возврата к среднему;
- основу для сравнения с EMA.

---

## Индикатор EMA

### Логика

EMA сильнее учитывает последние цены.

Формула:

```text
alpha = 2 / (period + 1)
EMA = Close * alpha + PreviousEMA * (1 - alpha)
```

### Использование

EMA используется в стратегиях:

- EMA20/EMA50;
- EMA50/EMA200;
- трендовый фильтр.

---

## Индикатор RSI

### Логика

RSI показывает соотношение среднего роста и среднего падения за период.

Стандартный период — 14.

Интерпретация:

```text
RSI < 30  — перепроданность
RSI > 70  — перекупленность
RSI > 50  — умеренная сила покупателей
RSI < 50  — умеренная сила продавцов
```

### Использование

Для российских акций RSI разумнее использовать осторожно:

- не покупать только потому, что RSI низкий;
- добавлять фильтр тренда;
- ограничивать убыток;
- не усредняться без строгих правил.

---

## Индикатор ATR

### Логика

ATR измеряет средний истинный диапазон свечи.

True Range:

```text
TR = max(
    High - Low,
    abs(High - PreviousClose),
    abs(Low - PreviousClose)
)
```

### Использование

ATR применяется для:

- стопа;
- трейлинг-стопа;
- фильтра волатильности;
- расчёта размера позиции.

---

## Модуль `strategies.lua`

Каждая стратегия возвращает сигнал в едином формате:

```lua
signal = {
    strategy = "ema_cross",
    action = "BUY", -- BUY, SELL, EXIT, HOLD
    class_code = "TQBR",
    sec_code = "SBER",
    reason = "EMA20 crossed EMA50 up",
    price = 315.20,
    lots = 1,
    timestamp = os.time()
}
```

Если сигнала нет:

```lua
action = "HOLD"
```

---

## Стратегия EMA Crossover

Покупать, когда быстрая EMA пересекает медленную EMA снизу вверх.

Выходить, когда быстрая EMA пересекает медленную EMA сверху вниз.

### Параметры

```lua
fast_period = 20
slow_period = 50
```

### Логика входа

```text
Предыдущая EMA20 <= предыдущая EMA50
Текущая EMA20 > текущая EMA50
=> BUY
```

### Логика выхода

```text
Предыдущая EMA20 >= предыдущая EMA50
Текущая EMA20 < текущая EMA50
=> EXIT
```

Стратегия пытается поймать переход из бокового/нисходящего режима в восходящий тренд.

Во флэте будет много ложных сигналов.

---

## Стратегия Donchian Channel

Покупать пробой максимума за период.

Выходить при пробое минимума за более короткий период.

### Параметры

```lua
entry_period = 20
exit_period = 10
```

### Логика входа

```text
Close текущей свечи > максимум High за предыдущие 20 свечей
=> BUY
```

### Логика выхода

```text
Close текущей свечи < минимум Low за предыдущие 10 свечей
=> EXIT
```

Сильные акции часто продолжают движение после обновления максимумов.

На ложных пробоях стратегия входит поздно и быстро получает убыток.

---

## Стратегия Donchian + Volume Filter

Покупать пробой только если он подтверждён повышенным объёмом.

### Параметры

```lua
entry_period = 20
volume_period = 20
volume_multiplier = 1.5
```

### Логика входа

```text
Close > High20
Volume > AverageVolume20 * 1.5
=> BUY
```

### Логика выхода

Использовать одну из логик:

```text
1. Close < Low10
2. Close < EMA20
3. ATR trailing stop
```

Для первой версии использовать:

```text
Close < Low10
```

Объёмный пробой чаще означает участие крупного капитала, а не случайный ценовой выброс.

---

## Стратегия RSI Mean Reversion

Покупать после сильной локальной перепроданности.

### Параметры

```lua
period = 14
buy_level = 25
exit_level = 50
```

### Логика входа

```text
RSI14 < 25
=> BUY
```

### Логика выхода

```text
RSI14 > 50
=> EXIT
```

На боковом рынке российские ликвидные акции часто делают возвраты после эмоциональных продаж.

Во время сильного падения RSI может оставаться низким долго, а цена продолжит падать.

Запрещено усреднение без отдельного режима и отдельного risk manager.

---

## Стратегия EMA Trend Filter + RSI

Использовать RSI только когда старший тренд положительный.

### Параметры

```lua
ema_fast = 50
ema_slow = 200
rsi_period = 14
rsi_buy_level = 40
rsi_exit_level = 60
```

### Логика входа

```text
EMA50 > EMA200
RSI14 < 40
=> BUY
```

### Логика выхода

```text
RSI14 > 60
или
EMA50 < EMA200
=> EXIT
```

Стратегия покупает откаты, но только в рамках восходящего тренда.

---

## ATR Stop

Стоп зависит от текущей волатильности инструмента.

### Логика

После входа:

```text
stop_price = entry_price - ATR14 * 2
```

Для long-позиции:

```text
если Close < stop_price => EXIT
```

### Trailing stop

```text
new_stop = Close - ATR14 * 2
если new_stop > current_stop:
    current_stop = new_stop
```

Стоп можно только повышать, но нельзя понижать.

---

## Модуль `risk.lua`

Risk manager должен быть обязательным фильтром между стратегией и отправкой заявки.

Стратегия не имеет права сама отправлять заявки.

### Проверки

Перед любой заявкой проверить:

```text
1. Торговый режим разрешает заявку.
2. Инструмент включён в конфигурации.
3. Размер заявки <= max_order_lots.
4. Итоговая позиция <= max_position_lots.
5. Количество сделок за день <= max_trades_per_day.
6. Дневной убыток <= max_daily_loss_rub.
7. Нет файла STOP.
8. Есть подключение к серверу QUIK.
9. Цена не равна nil.
10. Сигнал не устарел.
```

### Файл аварийной остановки

Если рядом со скриптом существует файл:

```text
STOP
```

робот должен:

- перестать открывать новые позиции;
- разрешить только закрытие позиции;
- записать событие в лог.

---

## Модуль `orders.lua`

Модуль отвечает за реальные и виртуальные заявки.

### Функции

```lua
Orders.send_limit_order(signal)
Orders.close_position(signal)
Orders.paper_execute(signal)
Orders.build_transaction(signal)
Orders.next_trans_id()
```

### Транзакция QUIK

Пример структуры:

```lua
transaction = {
    TRANS_ID = tostring(Orders.next_trans_id()),
    ACTION = "NEW_ORDER",
    CLASSCODE = signal.class_code,
    SECCODE = signal.sec_code,
    ACCOUNT = Config.account,
    CLIENT_CODE = Config.client_code,
    OPERATION = "B",
    PRICE = tostring(signal.price),
    QUANTITY = tostring(signal.lots),
    TYPE = "L"
}
```

Для продажи:

```lua
OPERATION = "S"
```

### Правило

После вызова `sendTransaction()` обязательно проверить результат.

```lua
local result = sendTransaction(transaction)

if result ~= "" then
    Logger.error("Transaction rejected: " .. tostring(result))
else
    Logger.info("Transaction sent: " .. transaction.TRANS_ID)
end
```

---

## Модуль `portfolio.lua`

Модуль хранит состояние позиций робота.

Минимально:

```lua
Portfolio.positions = {
    SBER = {
        lots = 0,
        avg_price = 0,
        entry_time = nil,
        stop_price = nil,
        strategy = nil
    }
}
```

Допускается вести позиции внутри Lua-состояния, но перед LIVE-режимом желательно сверяться с таблицами QUIK.

---

## Модуль `logger.lua`

Логирование всех событий.

### Уровни

```text
INFO
WARN
ERROR
SIGNAL
ORDER
TRADE
RISK
```

### Формат строки

```text
2026-06-17 10:15:00;SIGNAL;SBER;ema_cross;BUY;315.20;1;EMA20 crossed EMA50 up
```

### Файлы

```text
robot.log
signals.csv
trades.csv
errors.log
```

---

## Модуль `state.lua`

Хранение состояния робота между итерациями.

```lua
State = {
    started_at = os.time(),
    last_candle_size = {},
    daily_trade_count = 0,
    daily_realized_pnl = 0,
    last_trans_id = 100000,
    paper_positions = {},
    live_positions = {},
    strategy_states = {}
}
```

---

## Главный цикл `main.lua`

```lua
is_run = true

function main()
    Logger.info("Robot started")

    init()

    while is_run do
        for _, instrument in ipairs(Config.instruments) do
            if instrument.enabled then
                process_instrument(instrument)
            end
        end

        sleep(Config.cycle_sleep_ms)
    end

    shutdown()
end

function OnStop()
    is_run = false
    Logger.warn("OnStop called")
end
```

---

## Функция `process_instrument`

```lua
function process_instrument(instrument)
    local ds = State.datasources[instrument.sec_code]

    if ds == nil then
        Logger.error("No datasource for " .. instrument.sec_code)
        return
    end

    local is_new = MarketData.is_new_candle(ds, State.last_candle_size[instrument.sec_code])

    if not is_new then
        return
    end

    local candles = MarketData.get_candles(ds, 250)

    if candles == nil or #candles < 210 then
        Logger.warn("Not enough candles for " .. instrument.sec_code)
        return
    end

    local signals = Strategies.evaluate_all(instrument, candles)

    for _, signal in ipairs(signals) do
        if signal.action ~= "HOLD" then
            handle_signal(signal)
        end
    end
end
```

---

## Функция `handle_signal`

```lua
function handle_signal(signal)
    Logger.signal(signal)

    local ok, reason = Risk.check(signal)

    if not ok then
        Logger.risk(signal, reason)
        return
    end

    if Config.trading_mode == "SIGNALS_ONLY" then
        message("SIGNAL: " .. signal.sec_code .. " " .. signal.action)
        return
    end

    if Config.trading_mode == "PAPER_TRADING" then
        Orders.paper_execute(signal)
        return
    end

    if Config.trading_mode == "LIVE" then
        Orders.send_limit_order(signal)
        return
    end

    Logger.error("Unknown trading mode: " .. tostring(Config.trading_mode))
end
```

---

## Приоритет стратегий:

```text
1. ATR Stop EXIT
2. Donchian EXIT
3. EMA Crossover EXIT
4. EMA + RSI EXIT
5. Donchian + Volume BUY
6. Donchian BUY
7. EMA Crossover BUY
8. RSI BUY
9. EMA + RSI BUY
```

---

## Отчётность

Робот должен писать CSV:

### `signals.csv`

```text
datetime;strategy;class_code;sec_code;action;price;lots;reason
```

### `trades.csv`

```text
datetime;mode;strategy;class_code;sec_code;action;price;lots;pnl;reason
```

### `risk.csv`

```text
datetime;class_code;sec_code;action;blocked;reason
```

---

## Разработка

Для разработки используем ликвидную акцию:

```text
SBER
class_code = TQBR
sec_code = SBER
```

Причина:

- высокая ликвидность;
- узкий спред;
- много сделок;
- удобно тестировать;
- легко наблюдать вручную.
