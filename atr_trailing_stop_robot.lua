--[[
atr_trailing_stop_robot.lua

Торговый робот для терминала QUIK на чистом QLua.
Стратегия: ATR Stop / ATR Trailing Stop — сопровождение позиции через волатильность.

Назначение:
1. Робот сопровождает long-позицию по российской акции.
2. После появления позиции рассчитывает ATR-стоп:
   initial_stop = entry_price - ATR(period) * atr_multiplier
3. Далее trailing stop подтягивается вверх:
   new_stop = close - ATR(period) * atr_multiplier
   если new_stop > current_stop, то current_stop = new_stop
4. Если Close <= current_stop, робот генерирует EXIT.
5. В первой версии робот НЕ открывает позицию сам, если manual_entry_enabled = false.
6. Для тестирования можно включить manual_entry_enabled = true, чтобы робот создал виртуальную/внутреннюю позицию сопровождения.

ВАЖНО:
1. По умолчанию робот работает в режиме SIGNALS_ONLY и НЕ отправляет реальные заявки.
2. LIVE-режим включается только если:
   Config.trading_mode = "LIVE"
   Config.allow_real_orders = true
3. Перед LIVE-запуском обязательно заполнить ACCOUNT, CLIENT_CODE и проверить параметры брокерского счёта.
4. Используйте сначала SIGNALS_ONLY, затем PAPER_TRADING, и только потом LIVE на минимальном объёме.
5. Скрипт предназначен для QLua в QUIK. Никаких require, внешних библиотек, БД и API не используется.

Файлы, которые создаёт робот:
- atr_trailing_stop_robot.log
- atr_trailing_stop_signals.csv
- atr_trailing_stop_trades.csv

Аварийная остановка:
- Если рядом с терминалом/рабочей директорией скрипта создать файл STOP,
  робот перестанет создавать ручную тестовую позицию.
  EXIT-сигналы по стопу разрешены.

Это учебно-инженерный шаблон, а не инвестиционная рекомендация.
Перед реальной торговлей код нужно тестировать на вашем QUIK, счёте и инструментах.
]]

----------------------------------------------------------------------
-- 1. CONFIG
----------------------------------------------------------------------

Config = {
    robot_name = "ATR_TRAILING_STOP_ROBOT",

    -- Режимы:
    -- SIGNALS_ONLY  — только сигналы, без сделок.
    -- PAPER_TRADING — виртуальные сделки внутри Lua.
    -- LIVE          — реальные заявки через sendTransaction().
    trading_mode = "SIGNALS_ONLY",

    -- Дополнительный предохранитель для LIVE.
    allow_real_orders = false,

    -- Инструмент по умолчанию: акция Сбербанка.
    class_code = "TQBR",
    sec_code = "SBER",

    -- Таймфрейм.
    -- Можно заменить на INTERVAL_M5, INTERVAL_M15, INTERVAL_H1, INTERVAL_D1 и т.д.
    interval = INTERVAL_M15,

    -- ATR Stop / Trailing Stop.
    atr_period = 14,
    atr_multiplier = 2.0,

    -- Режим сопровождения:
    -- true  — стоп подтягивается вверх.
    -- false — используется только начальный ATR-стоп.
    trailing_enabled = true,

    -- Ручная тестовая позиция.
    -- Если true, робот при запуске создаёт внутреннюю позицию сопровождения.
    -- Это удобно для SIGNALS_ONLY/PAPER_TRADING тестов.
    -- Для LIVE лучше выключить и доработать сверку реальной позиции через таблицы QUIK.
    manual_entry_enabled = true,
    manual_entry_price = 0, -- 0 означает взять последнюю цену Close из свечей.
    manual_entry_lots = 1,

    -- Минимальное количество свечей.
    min_candles = 80,
    candles_to_read = 250,

    -- Параметры заявки.
    lots = 1,
    order_type = "L", -- L = лимитная заявка. Для первой версии не использовать M.
    price_offset_steps = 1,

    -- Заполнить перед LIVE.
    account = "CHANGE_ME",
    client_code = "CHANGE_ME",

    -- Риск-лимиты.
    max_order_lots = 1,
    max_position_lots = 1,
    max_trades_per_day = 3,
    max_daily_loss_rub = 500,
    allow_short = false,

    -- Paper trading.
    paper_initial_cash = 100000,
    paper_commission_rate = 0.0005, -- 0.05%
    paper_slippage_rate = 0.0005,   -- 0.05%

    -- Цикл.
    cycle_sleep_ms = 1000,

    -- Логи.
    log_file = "atr_trailing_stop_robot.log",
    signals_file = "atr_trailing_stop_signals.csv",
    trades_file = "atr_trailing_stop_trades.csv",

    -- STOP-файл.
    stop_file = "STOP",

    -- Поведение.
    show_messages = true,
    close_datasource_on_stop = true
}

----------------------------------------------------------------------
-- 2. GLOBAL STATE
----------------------------------------------------------------------

State = {
    is_run = true,
    ds = nil,
    last_candle_size = 0,
    last_signal_candle = 0,
    last_action = "NONE",

    daily_trade_count = 0,
    daily_realized_pnl = 0,
    current_day = nil,

    trans_id = 600000,

    -- Позиция сопровождения. Используется во всех режимах как внутреннее состояние стратегии.
    position = {
        active = false,
        lots = 0,
        entry_price = 0,
        entry_time = nil,
        initial_stop = nil,
        trailing_stop = nil,
        highest_close = nil,
        last_atr = nil
    },

    paper = {
        cash = Config.paper_initial_cash,
        position_lots = 0,
        avg_price = 0,
        realized_pnl = 0,
        last_entry_strategy = nil
    },

    live = {
        position_lots = 0
    },

    started_at = os.time()
}

----------------------------------------------------------------------
-- 3. UTILS
----------------------------------------------------------------------

function now_string()
    local t = os.date("*t")
    return string.format(
        "%04d-%02d-%02d %02d:%02d:%02d",
        t.year, t.month, t.day, t.hour, t.min, t.sec
    )
end

function today_string()
    local t = os.date("*t")
    return string.format("%04d-%02d-%02d", t.year, t.month, t.day)
end

function bool_to_string(v)
    if v then
        return "true"
    end
    return "false"
end

function file_exists(path)
    local f = io.open(path, "r")
    if f ~= nil then
        f:close()
        return true
    end
    return false
end

function safe_tonumber(v)
    if v == nil then
        return nil
    end
    return tonumber(v)
end

function round_price(price, scale)
    if price == nil then
        return nil
    end

    local multiplier = 1
    for _ = 1, scale do
        multiplier = multiplier * 10
    end

    return math.floor(price * multiplier + 0.5) / multiplier
end

function emit_message(text)
    if Config.show_messages then
        message("[" .. Config.robot_name .. "] " .. tostring(text))
    end
end

----------------------------------------------------------------------
-- 4. LOGGER
----------------------------------------------------------------------

Logger = {}

function Logger.append(file_name, line)
    local f = io.open(file_name, "a")
    if f == nil then
        message("[" .. Config.robot_name .. "] Cannot open log file: " .. tostring(file_name))
        return
    end

    f:write(line .. "\n")
    f:close()
end

function Logger.log(level, text)
    local line = now_string() .. ";" .. tostring(level) .. ";" .. tostring(text)
    Logger.append(Config.log_file, line)
end

function Logger.info(text)
    Logger.log("INFO", text)
end

function Logger.warn(text)
    Logger.log("WARN", text)
end

function Logger.error(text)
    Logger.log("ERROR", text)
end

function Logger.signal(signal)
    local line = table.concat({
        now_string(),
        signal.strategy or "",
        signal.class_code or "",
        signal.sec_code or "",
        signal.action or "",
        tostring(signal.price or ""),
        tostring(signal.lots or ""),
        tostring(signal.atr or ""),
        tostring(signal.entry_price or ""),
        tostring(signal.initial_stop or ""),
        tostring(signal.trailing_stop or ""),
        tostring(signal.stop_price or ""),
        tostring(signal.highest_close or ""),
        signal.reason or ""
    }, ";")

    Logger.append(Config.signals_file, line)
    Logger.log("SIGNAL", line)
end

function Logger.trade(mode, strategy, action, price, lots, pnl, reason)
    local line = table.concat({
        now_string(),
        mode or "",
        strategy or "",
        Config.class_code,
        Config.sec_code,
        action or "",
        tostring(price or ""),
        tostring(lots or ""),
        tostring(pnl or ""),
        reason or ""
    }, ";")

    Logger.append(Config.trades_file, line)
    Logger.log("TRADE", line)
end

function Logger.init_files()
    if not file_exists(Config.signals_file) then
        Logger.append(
            Config.signals_file,
            "datetime;strategy;class_code;sec_code;action;price;lots;atr;entry_price;initial_stop;trailing_stop;stop_price;highest_close;reason"
        )
    end

    if not file_exists(Config.trades_file) then
        Logger.append(
            Config.trades_file,
            "datetime;mode;strategy;class_code;sec_code;action;price;lots;pnl;reason"
        )
    end
end

----------------------------------------------------------------------
-- 5. MARKET DATA
----------------------------------------------------------------------

MarketData = {}

function MarketData.get_param_number(class_code, sec_code, param_name)
    local p = getParamEx(class_code, sec_code, param_name)

    if p == nil then
        return nil, "getParamEx returned nil"
    end

    if p.result ~= "1" then
        return nil, "param not found: " .. tostring(param_name)
    end

    local value = safe_tonumber(p.param_value)

    if value == nil then
        return nil, "param value is not numeric: " .. tostring(p.param_value)
    end

    return value, nil
end

function MarketData.get_last_price()
    return MarketData.get_param_number(Config.class_code, Config.sec_code, "LAST")
end

function MarketData.get_best_bid_ask()
    local bid, err_bid = MarketData.get_param_number(Config.class_code, Config.sec_code, "BID")
    local offer, err_offer = MarketData.get_param_number(Config.class_code, Config.sec_code, "OFFER")

    if err_bid ~= nil then
        return nil, nil, "BID error: " .. err_bid
    end

    if err_offer ~= nil then
        return nil, nil, "OFFER error: " .. err_offer
    end

    return bid, offer, nil
end

function MarketData.get_security_info()
    local info = getSecurityInfo(Config.class_code, Config.sec_code)

    if info == nil then
        return nil, "getSecurityInfo returned nil"
    end

    return info, nil
end

function MarketData.create_datasource()
    local ds, err = CreateDataSource(Config.class_code, Config.sec_code, Config.interval)

    if ds == nil then
        return nil, "CreateDataSource failed: " .. tostring(err)
    end

    -- Дать QUIK время загрузить свечи.
    sleep(1000)

    return ds, nil
end

function MarketData.datasource_size()
    if State.ds == nil then
        return 0
    end

    local ok, size = pcall(function()
        return State.ds:Size()
    end)

    if not ok then
        return 0
    end

    return size or 0
end

function MarketData.is_new_candle()
    local size = MarketData.datasource_size()

    if size <= 0 then
        return false, size
    end

    if size > State.last_candle_size then
        return true, size
    end

    return false, size
end

function MarketData.get_candles(limit)
    local size = MarketData.datasource_size()

    if size <= 0 then
        return nil, "datasource is empty"
    end

    local from_index = size - limit + 1
    if from_index < 1 then
        from_index = 1
    end

    local candles = {}

    for i = from_index, size do
        local candle = {
            index = i,
            open = State.ds:O(i),
            high = State.ds:H(i),
            low = State.ds:L(i),
            close = State.ds:C(i),
            volume = State.ds:V(i),
            time = State.ds:T(i)
        }

        if candle.open ~= nil and candle.high ~= nil and candle.low ~= nil and candle.close ~= nil then
            table.insert(candles, candle)
        end
    end

    if #candles == 0 then
        return nil, "no valid candles"
    end

    return candles, nil
end

----------------------------------------------------------------------
-- 6. INDICATORS
----------------------------------------------------------------------

Indicators = {}

-- True Range для свечи i.
function Indicators.true_range(candles, i)
    if candles == nil or i == nil or i < 1 or i > #candles then
        return nil
    end

    local high = candles[i].high
    local low = candles[i].low

    if high == nil or low == nil then
        return nil
    end

    if i == 1 then
        return high - low
    end

    local prev_close = candles[i - 1].close

    if prev_close == nil then
        return nil
    end

    local range1 = high - low
    local range2 = math.abs(high - prev_close)
    local range3 = math.abs(low - prev_close)

    return math.max(range1, math.max(range2, range3))
end

-- ATR по методу Wilder.
-- Возвращает массив ATR.
function Indicators.atr_series(candles, period)
    local result = {}

    if candles == nil or #candles < period + 1 then
        return result
    end

    local tr_values = {}

    for i = 1, #candles do
        tr_values[i] = Indicators.true_range(candles, i)
    end

    local sum = 0

    -- Первый ATR считаем как SMA True Range за period свечей.
    -- Начинаем со 2-й свечи, потому что TR первой свечи не использует prev_close.
    local first_atr_index = period + 1

    for i = 2, first_atr_index do
        if tr_values[i] == nil then
            return result
        end
        sum = sum + tr_values[i]
    end

    result[first_atr_index] = sum / period

    for i = first_atr_index + 1, #candles do
        if tr_values[i] == nil or result[i - 1] == nil then
            return result
        end

        result[i] = ((result[i - 1] * (period - 1)) + tr_values[i]) / period
    end

    return result
end

----------------------------------------------------------------------
-- 7. STRATEGY: ATR STOP / ATR TRAILING STOP
----------------------------------------------------------------------

Strategy = {}

function Strategy.create_manual_position_if_needed(candles, atr_value)
    if State.position.active then
        return
    end

    if not Config.manual_entry_enabled then
        return
    end

    if Risk.is_stop_file_active() then
        Logger.warn("Manual entry is blocked by STOP file")
        return
    end

    if candles == nil or #candles == 0 or atr_value == nil then
        return
    end

    local close_price = candles[#candles].close
    local entry_price = Config.manual_entry_price

    if entry_price == nil or entry_price <= 0 then
        entry_price = close_price
    end

    local initial_stop = entry_price - atr_value * Config.atr_multiplier

    State.position.active = true
    State.position.lots = Config.manual_entry_lots
    State.position.entry_price = entry_price
    State.position.entry_time = os.time()
    State.position.initial_stop = initial_stop
    State.position.trailing_stop = initial_stop
    State.position.highest_close = close_price
    State.position.last_atr = atr_value

    -- Для PAPER_TRADING создаём виртуальную позицию.
    -- В SIGNALS_ONLY это просто внутренняя позиция сопровождения.
    if Config.trading_mode == "PAPER_TRADING" or Config.trading_mode == "SIGNALS_ONLY" then
        State.paper.position_lots = Config.manual_entry_lots
        State.paper.avg_price = entry_price
        State.paper.last_entry_strategy = "atr_trailing_stop_manual_entry"
    end

    Logger.trade(
        Config.trading_mode,
        "atr_trailing_stop",
        "MANUAL_ENTRY",
        entry_price,
        Config.manual_entry_lots,
        "",
        "Manual internal position created; initial_stop=" .. tostring(initial_stop)
    )

    emit_message(
        "Manual position created: price=" .. tostring(entry_price) ..
        " lots=" .. tostring(Config.manual_entry_lots) ..
        " initial_stop=" .. tostring(initial_stop)
    )
end

function Strategy.evaluate(candles)
    if candles == nil or #candles < Config.min_candles then
        return {
            strategy = "atr_trailing_stop",
            action = "HOLD",
            reason = "not enough candles"
        }
    end

    local atr = Indicators.atr_series(candles, Config.atr_period)
    local i = #candles
    local current_atr = atr[i]

    if current_atr == nil then
        return {
            strategy = "atr_trailing_stop",
            action = "HOLD",
            reason = "ATR is not ready"
        }
    end

    Strategy.create_manual_position_if_needed(candles, current_atr)

    local close_price = candles[i].close

    if not State.position.active then
        return {
            strategy = "atr_trailing_stop",
            action = "HOLD",
            class_code = Config.class_code,
            sec_code = Config.sec_code,
            price = close_price,
            lots = 0,
            atr = current_atr,
            reason = "no position to trail",
            candle_index = candles[#candles].index,
            timestamp = os.time()
        }
    end

    State.position.last_atr = current_atr

    if State.position.highest_close == nil or close_price > State.position.highest_close then
        State.position.highest_close = close_price
    end

    local proposed_stop = close_price - current_atr * Config.atr_multiplier

    if State.position.trailing_stop == nil then
        State.position.trailing_stop = State.position.entry_price - current_atr * Config.atr_multiplier
    end

    if Config.trailing_enabled then
        -- Стоп для long-позиции можно только повышать.
        if proposed_stop > State.position.trailing_stop then
            State.position.trailing_stop = proposed_stop
            Logger.info("Trailing stop updated: " .. tostring(State.position.trailing_stop))
        end
    end

    local stop_price = State.position.trailing_stop

    local action = "HOLD"
    local reason = "position is active; stop not reached"

    if close_price <= stop_price then
        action = "EXIT"
        reason = "ATR stop reached: close=" .. tostring(close_price) ..
                 " <= stop=" .. tostring(stop_price) ..
                 " ATR" .. tostring(Config.atr_period) ..
                 "=" .. tostring(current_atr) ..
                 " multiplier=" .. tostring(Config.atr_multiplier)
    end

    return {
        strategy = "atr_trailing_stop",
        action = action,
        class_code = Config.class_code,
        sec_code = Config.sec_code,
        price = close_price,
        lots = State.position.lots,
        reason = reason,
        atr = current_atr,
        entry_price = State.position.entry_price,
        initial_stop = State.position.initial_stop,
        trailing_stop = State.position.trailing_stop,
        stop_price = stop_price,
        highest_close = State.position.highest_close,
        candle_index = candles[#candles].index,
        timestamp = os.time()
    }
end

----------------------------------------------------------------------
-- 8. PORTFOLIO
----------------------------------------------------------------------

Portfolio = {}

function Portfolio.get_current_position_lots()
    if State.position.active then
        return State.position.lots
    end

    if Config.trading_mode == "PAPER_TRADING" or Config.trading_mode == "SIGNALS_ONLY" then
        return State.paper.position_lots
    end

    return State.live.position_lots
end

function Portfolio.has_position()
    return Portfolio.get_current_position_lots() > 0
end

function Portfolio.clear_position()
    State.position.active = false
    State.position.lots = 0
    State.position.entry_price = 0
    State.position.entry_time = nil
    State.position.initial_stop = nil
    State.position.trailing_stop = nil
    State.position.highest_close = nil
    State.position.last_atr = nil
end

----------------------------------------------------------------------
-- 9. RISK MANAGER
----------------------------------------------------------------------

Risk = {}

function Risk.reset_daily_if_needed()
    local d = today_string()

    if State.current_day == nil then
        State.current_day = d
        return
    end

    if State.current_day ~= d then
        State.current_day = d
        State.daily_trade_count = 0
        State.daily_realized_pnl = 0
        Logger.info("Daily counters reset")
    end
end

function Risk.is_stop_file_active()
    return file_exists(Config.stop_file)
end

function Risk.check_config_for_live()
    if Config.trading_mode ~= "LIVE" then
        return true, "not live mode"
    end

    if Config.allow_real_orders ~= true then
        return false, "LIVE is blocked: allow_real_orders is false"
    end

    if Config.account == nil or Config.account == "" or Config.account == "CHANGE_ME" then
        return false, "LIVE is blocked: account is not configured"
    end

    if Config.client_code == nil or Config.client_code == "" or Config.client_code == "CHANGE_ME" then
        return false, "LIVE is blocked: client_code is not configured"
    end

    return true, "live config ok"
end

function Risk.check(signal)
    Risk.reset_daily_if_needed()

    if signal == nil then
        return false, "nil signal"
    end

    if signal.action == "HOLD" then
        return false, "hold signal"
    end

    if signal.price == nil or signal.price <= 0 then
        return false, "invalid signal price"
    end

    if signal.lots == nil or signal.lots <= 0 then
        return false, "invalid lots"
    end

    if signal.lots > Config.max_order_lots then
        return false, "order lots exceeds max_order_lots"
    end

    if State.daily_trade_count >= Config.max_trades_per_day then
        return false, "max_trades_per_day exceeded"
    end

    if State.daily_realized_pnl <= -math.abs(Config.max_daily_loss_rub) then
        return false, "max_daily_loss_rub exceeded"
    end

    if Risk.is_stop_file_active() and signal.action == "BUY" then
        return false, "STOP file active: new entries are blocked"
    end

    local current_position = Portfolio.get_current_position_lots()

    if signal.action == "BUY" then
        return false, "ATR Stop robot does not open positions in this version"
    end

    if signal.action == "EXIT" then
        if current_position <= 0 then
            return false, "no position to exit"
        end
    end

    if signal.action ~= "EXIT" then
        return false, "unsupported action: " .. tostring(signal.action)
    end

    local ok_live, live_reason = Risk.check_config_for_live()

    if not ok_live then
        return false, live_reason
    end

    return true, "ok"
end

----------------------------------------------------------------------
-- 10. ORDERS
----------------------------------------------------------------------

Orders = {}

function Orders.next_trans_id()
    State.trans_id = State.trans_id + 1
    return State.trans_id
end

function Orders.get_execution_price(signal)
    local bid, offer, err = MarketData.get_best_bid_ask()

    if err ~= nil then
        Logger.warn("Cannot get BID/OFFER, using signal price: " .. err)
        return signal.price
    end

    local info, info_err = MarketData.get_security_info()
    local scale = 2
    local step = 0

    if info ~= nil then
        scale = tonumber(info.scale) or 2
        step = tonumber(info.min_price_step) or 0
    else
        Logger.warn("Cannot get security info: " .. tostring(info_err))
    end

    local price = signal.price

    if signal.action == "EXIT" then
        price = bid
        if step > 0 then
            price = price - step * Config.price_offset_steps
        end
    end

    return round_price(price, scale)
end

function Orders.paper_execute(signal)
    if signal.action ~= "EXIT" then
        Logger.warn("PAPER ignored unsupported action: " .. tostring(signal.action))
        return
    end

    if State.paper.position_lots <= 0 and not State.position.active then
        Logger.warn("PAPER EXIT ignored: no position")
        return
    end

    local price = signal.price
    local lots = signal.lots
    local slippage = price * Config.paper_slippage_rate
    local exec_price = price - slippage

    local entry = State.paper.avg_price
    if entry == nil or entry <= 0 then
        entry = State.position.entry_price
    end

    local pos_lots = lots
    if pos_lots == nil or pos_lots <= 0 then
        pos_lots = State.paper.position_lots
    end

    local gross_pnl = (exec_price - entry) * pos_lots
    local exit_commission = exec_price * pos_lots * Config.paper_commission_rate
    local pnl = gross_pnl - exit_commission

    State.paper.position_lots = 0
    State.paper.avg_price = 0
    State.paper.realized_pnl = State.paper.realized_pnl + pnl
    State.daily_realized_pnl = State.daily_realized_pnl + pnl
    State.daily_trade_count = State.daily_trade_count + 1

    Portfolio.clear_position()

    Logger.trade("PAPER", signal.strategy, "EXIT", exec_price, pos_lots, pnl, signal.reason)
    emit_message("PAPER EXIT " .. Config.sec_code .. " price=" .. tostring(exec_price) .. " pnl=" .. tostring(pnl))
end

function Orders.send_live_order(signal)
    local exec_price = Orders.get_execution_price(signal)

    if exec_price == nil then
        Logger.error("Cannot send order: execution price is nil")
        return false
    end

    if signal.action ~= "EXIT" then
        Logger.error("Unsupported live action: " .. tostring(signal.action))
        return false
    end

    local transaction = {
        ["TRANS_ID"] = tostring(Orders.next_trans_id()),
        ["ACTION"] = "NEW_ORDER",
        ["CLASSCODE"] = Config.class_code,
        ["SECCODE"] = Config.sec_code,
        ["ACCOUNT"] = Config.account,
        ["CLIENT_CODE"] = Config.client_code,
        ["OPERATION"] = "S",
        ["PRICE"] = tostring(exec_price),
        ["QUANTITY"] = tostring(signal.lots),
        ["TYPE"] = Config.order_type
    }

    local result = sendTransaction(transaction)

    if result ~= "" then
        Logger.error("sendTransaction error: " .. tostring(result))
        emit_message("LIVE order rejected: " .. tostring(result))
        return false
    end

    Logger.trade("LIVE", signal.strategy, "EXIT", exec_price, signal.lots, "", signal.reason)
    Logger.info("LIVE EXIT order sent TRANS_ID=" .. transaction["TRANS_ID"])
    emit_message("LIVE EXIT sent " .. Config.sec_code .. " price=" .. tostring(exec_price))

    State.live.position_lots = 0
    State.daily_trade_count = State.daily_trade_count + 1
    Portfolio.clear_position()

    return true
end

----------------------------------------------------------------------
-- 11. SIGNAL HANDLING
----------------------------------------------------------------------

function handle_signal(signal)
    if signal == nil then
        return
    end

    if signal.action == "HOLD" then
        Logger.info(
            "HOLD " .. Config.sec_code ..
            " reason=" .. tostring(signal.reason) ..
            " atr=" .. tostring(signal.atr) ..
            " entry_price=" .. tostring(signal.entry_price) ..
            " trailing_stop=" .. tostring(signal.trailing_stop) ..
            " stop_price=" .. tostring(signal.stop_price)
        )
        return
    end

    -- Не повторять сигнал на одной и той же свече.
    if signal.candle_index ~= nil and State.last_signal_candle == signal.candle_index and State.last_action == signal.action then
        Logger.info("Duplicate signal ignored on candle " .. tostring(signal.candle_index))
        return
    end

    Logger.signal(signal)

    local ok, reason = Risk.check(signal)

    if not ok then
        Logger.warn("Risk blocked signal: " .. tostring(reason))
        emit_message("RISK BLOCKED: " .. tostring(reason))
        return
    end

    State.last_signal_candle = signal.candle_index or 0
    State.last_action = signal.action

    if Config.trading_mode == "SIGNALS_ONLY" then
        emit_message(
            "SIGNAL " .. signal.action ..
            " " .. Config.sec_code ..
            " price=" .. tostring(signal.price) ..
            " stop=" .. tostring(signal.stop_price) ..
            " atr=" .. tostring(signal.atr) ..
            " reason=" .. tostring(signal.reason)
        )

        -- В SIGNALS_ONLY после EXIT-сигнала внутреннюю позицию очищаем,
        -- чтобы не генерировать один и тот же выход постоянно.
        if signal.action == "EXIT" then
            Portfolio.clear_position()
        end

        return
    end

    if Config.trading_mode == "PAPER_TRADING" then
        Orders.paper_execute(signal)
        return
    end

    if Config.trading_mode == "LIVE" then
        Orders.send_live_order(signal)
        return
    end

    Logger.error("Unknown trading mode: " .. tostring(Config.trading_mode))
end

----------------------------------------------------------------------
-- 12. INIT / SHUTDOWN
----------------------------------------------------------------------

function validate_config()
    if Config.atr_period <= 1 then
        return false, "atr_period must be greater than 1"
    end

    if Config.atr_multiplier <= 0 then
        return false, "atr_multiplier must be positive"
    end

    if Config.manual_entry_lots <= 0 then
        return false, "manual_entry_lots must be positive"
    end

    if Config.lots <= 0 then
        return false, "lots must be positive"
    end

    if Config.trading_mode ~= "SIGNALS_ONLY" and
       Config.trading_mode ~= "PAPER_TRADING" and
       Config.trading_mode ~= "LIVE" then
        return false, "unknown trading_mode: " .. tostring(Config.trading_mode)
    end

    local required_min = Config.atr_period + 5

    if Config.min_candles < required_min then
        return false, "min_candles must be at least atr_period + 5"
    end

    if Config.candles_to_read < Config.min_candles then
        return false, "candles_to_read must be >= min_candles"
    end

    if Config.trading_mode == "LIVE" and Config.manual_entry_enabled then
        Logger.warn("LIVE with manual_entry_enabled=true is dangerous; prefer syncing real position before using LIVE")
    end

    return true, "ok"
end

function init()
    Logger.init_files()
    Logger.info("Robot init started")
    Logger.info("Mode=" .. Config.trading_mode)
    Logger.info("Instrument=" .. Config.class_code .. "." .. Config.sec_code)
    Logger.info(
        "ATR period=" .. tostring(Config.atr_period) ..
        " multiplier=" .. tostring(Config.atr_multiplier) ..
        " trailing_enabled=" .. bool_to_string(Config.trailing_enabled) ..
        " manual_entry_enabled=" .. bool_to_string(Config.manual_entry_enabled)
    )
    Logger.info("allow_real_orders=" .. bool_to_string(Config.allow_real_orders))

    local ok, reason = validate_config()
    if not ok then
        Logger.error("Config validation failed: " .. reason)
        emit_message("Config validation failed: " .. reason)
        State.is_run = false
        return false
    end

    local live_ok, live_reason = Risk.check_config_for_live()
    if not live_ok then
        Logger.warn("LIVE config check: " .. live_reason)
    end

    local ds, err = MarketData.create_datasource()
    if ds == nil then
        Logger.error(err)
        emit_message(err)
        State.is_run = false
        return false
    end

    State.ds = ds
    State.last_candle_size = MarketData.datasource_size()

    Logger.info("Datasource created, size=" .. tostring(State.last_candle_size))
    emit_message("Started: " .. Config.class_code .. "." .. Config.sec_code .. " mode=" .. Config.trading_mode)

    return true
end

function shutdown()
    Logger.info("Shutdown started")

    if State.ds ~= nil and Config.close_datasource_on_stop then
        pcall(function()
            State.ds:Close()
        end)
        Logger.info("Datasource closed")
    end

    Logger.info("Robot stopped")
    emit_message("Stopped")
end

----------------------------------------------------------------------
-- 13. MAIN LOOP
----------------------------------------------------------------------

function process_new_candle(size)
    local candles, err = MarketData.get_candles(Config.candles_to_read)

    if candles == nil then
        Logger.warn("Cannot get candles: " .. tostring(err))
        return
    end

    if #candles < Config.min_candles then
        Logger.warn("Not enough candles: " .. tostring(#candles) .. "/" .. tostring(Config.min_candles))
        return
    end

    local signal = Strategy.evaluate(candles)

    Logger.info(
        "Candle processed size=" .. tostring(size) ..
        " close=" .. tostring(candles[#candles].close) ..
        " action=" .. tostring(signal.action) ..
        " atr=" .. tostring(signal.atr) ..
        " entry_price=" .. tostring(signal.entry_price) ..
        " initial_stop=" .. tostring(signal.initial_stop) ..
        " trailing_stop=" .. tostring(signal.trailing_stop) ..
        " stop_price=" .. tostring(signal.stop_price) ..
        " reason=" .. tostring(signal.reason)
    )

    handle_signal(signal)
end

function main()
    local ok = init()

    if not ok then
        shutdown()
        return
    end

    while State.is_run do
        Risk.reset_daily_if_needed()

        local is_new, size = MarketData.is_new_candle()

        if is_new then
            State.last_candle_size = size
            process_new_candle(size)
        end

        sleep(Config.cycle_sleep_ms)
    end

    shutdown()
end

function OnStop()
    State.is_run = false
    Logger.warn("OnStop called")
    return 1000
end
