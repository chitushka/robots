--[[
donchian_volume_filter_robot.lua

Торговый робот для терминала QUIK на чистом QLua.
Стратегия: Donchian + Volume Filter — пробой диапазона с подтверждением объёмом.

Логика стратегии:
1. BUY:
   Close текущей закрытой свечи > максимум High за предыдущие entry_period свечей
   И
   Volume текущей свечи > средний Volume за предыдущие volume_period свечей * volume_multiplier.

2. EXIT:
   Close текущей закрытой свечи < минимум Low за предыдущие exit_period свечей.

3. Шорты в первой версии запрещены.
4. Повторный BUY при уже открытой позиции запрещён.
5. Стоп-заявки QUIK в этой версии не используются. Выход выполняется сигналом EXIT.

ВАЖНО:
1. По умолчанию робот работает в режиме SIGNALS_ONLY и НЕ отправляет реальные заявки.
2. LIVE-режим включается только если:
   Config.trading_mode = "LIVE"
   Config.allow_real_orders = true
3. Перед LIVE-запуском обязательно заполнить ACCOUNT, CLIENT_CODE и проверить параметры брокерского счёта.
4. Используйте сначала SIGNALS_ONLY, затем PAPER_TRADING, и только потом LIVE на минимальном объёме.
5. Скрипт предназначен для QLua в QUIK. Никаких require, внешних библиотек, БД и API не используется.

Файлы, которые создаёт робот:
- donchian_volume_filter_robot.log
- donchian_volume_filter_signals.csv
- donchian_volume_filter_trades.csv

Аварийная остановка:
- Если рядом с терминалом/рабочей директорией скрипта создать файл STOP,
  робот перестанет открывать новые позиции. EXIT-сигналы разрешены.

Это учебно-инженерный шаблон, а не инвестиционная рекомендация.
Перед реальной торговлей код нужно тестировать на вашем QUIK, счёте и инструментах.
]]

----------------------------------------------------------------------
-- 1. CONFIG
----------------------------------------------------------------------

Config = {
    robot_name = "DONCHIAN_VOLUME_FILTER_ROBOT",

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

    -- Параметры Donchian + Volume.
    -- entry_period: пробой максимума за N предыдущих свечей.
    -- exit_period: выход при пробое минимума за M предыдущих свечей.
    -- volume_period: средний объём за K предыдущих свечей.
    -- volume_multiplier: во сколько раз текущий объём должен превышать средний.
    entry_period = 20,
    exit_period = 10,
    volume_period = 20,
    volume_multiplier = 1.5,

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
    log_file = "donchian_volume_filter_robot.log",
    signals_file = "donchian_volume_filter_signals.csv",
    trades_file = "donchian_volume_filter_trades.csv",

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

    trans_id = 300000,

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
        tostring(signal.entry_high or ""),
        tostring(signal.exit_low or ""),
        tostring(signal.current_volume or ""),
        tostring(signal.avg_volume or ""),
        tostring(signal.volume_ratio or ""),
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
            "datetime;strategy;class_code;sec_code;action;price;lots;entry_high;exit_low;current_volume;avg_volume;volume_ratio;reason"
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

-- Максимум High за period свечей, заканчивая на end_index включительно.
function Indicators.highest_high(candles, period, end_index)
    if candles == nil then
        return nil
    end

    if end_index == nil then
        end_index = #candles
    end

    local start_index = end_index - period + 1

    if start_index < 1 then
        return nil
    end

    local max_high = nil

    for i = start_index, end_index do
        local h = candles[i].high
        if h == nil then
            return nil
        end

        if max_high == nil or h > max_high then
            max_high = h
        end
    end

    return max_high
end

-- Минимум Low за period свечей, заканчивая на end_index включительно.
function Indicators.lowest_low(candles, period, end_index)
    if candles == nil then
        return nil
    end

    if end_index == nil then
        end_index = #candles
    end

    local start_index = end_index - period + 1

    if start_index < 1 then
        return nil
    end

    local min_low = nil

    for i = start_index, end_index do
        local l = candles[i].low
        if l == nil then
            return nil
        end

        if min_low == nil or l < min_low then
            min_low = l
        end
    end

    return min_low
end

-- Средний объём за period свечей, заканчивая на end_index включительно.
function Indicators.average_volume(candles, period, end_index)
    if candles == nil then
        return nil
    end

    if end_index == nil then
        end_index = #candles
    end

    local start_index = end_index - period + 1

    if start_index < 1 then
        return nil
    end

    local sum = 0
    local count = 0

    for i = start_index, end_index do
        local v = candles[i].volume
        if v == nil then
            return nil
        end

        sum = sum + v
        count = count + 1
    end

    if count == 0 then
        return nil
    end

    return sum / count
end

----------------------------------------------------------------------
-- 7. STRATEGY: DONCHIAN + VOLUME FILTER
----------------------------------------------------------------------

Strategy = {}

function Strategy.evaluate(candles)
    if candles == nil or #candles < Config.min_candles then
        return {
            strategy = "donchian_volume_filter",
            action = "HOLD",
            reason = "not enough candles"
        }
    end

    local i = #candles

    -- Каналы и средний объём считаются по ПРЕДЫДУЩИМ свечам, без текущей.
    -- Это исключает look-ahead bias и не даёт текущей свече самой формировать свой уровень пробоя.
    local previous_index = i - 1

    local entry_high = Indicators.highest_high(candles, Config.entry_period, previous_index)
    local exit_low = Indicators.lowest_low(candles, Config.exit_period, previous_index)
    local avg_volume = Indicators.average_volume(candles, Config.volume_period, previous_index)

    if entry_high == nil or exit_low == nil or avg_volume == nil then
        return {
            strategy = "donchian_volume_filter",
            action = "HOLD",
            reason = "Donchian or volume filter is not ready"
        }
    end

    local close_price = candles[i].close
    local current_volume = candles[i].volume or 0
    local required_volume = avg_volume * Config.volume_multiplier

    local volume_ratio = 0
    if avg_volume > 0 then
        volume_ratio = current_volume / avg_volume
    end

    local has_price_breakout = close_price > entry_high
    local has_volume_confirm = current_volume > required_volume
    local has_exit_breakout = close_price < exit_low

    local action = "HOLD"
    local reason = "no breakout"

    if has_price_breakout and has_volume_confirm then
        action = "BUY"
        reason = "Close " .. tostring(close_price) ..
                 " > High" .. tostring(Config.entry_period) .. " " .. tostring(entry_high) ..
                 " and Volume " .. tostring(current_volume) ..
                 " > AvgVolume" .. tostring(Config.volume_period) ..
                 "*" .. tostring(Config.volume_multiplier) ..
                 " = " .. tostring(required_volume)
    elseif has_price_breakout and not has_volume_confirm then
        action = "HOLD"
        reason = "price breakout without volume confirmation: volume_ratio=" .. tostring(volume_ratio)
    elseif has_exit_breakout then
        action = "EXIT"
        reason = "Close " .. tostring(close_price) ..
                 " < Low" .. tostring(Config.exit_period) .. " " .. tostring(exit_low)
    end

    return {
        strategy = "donchian_volume_filter",
        action = action,
        class_code = Config.class_code,
        sec_code = Config.sec_code,
        price = close_price,
        lots = Config.lots,
        reason = reason,
        entry_high = entry_high,
        exit_low = exit_low,
        current_volume = current_volume,
        avg_volume = avg_volume,
        required_volume = required_volume,
        volume_ratio = volume_ratio,
        candle_index = candles[#candles].index,
        timestamp = os.time()
    }
end

----------------------------------------------------------------------
-- 8. PORTFOLIO
----------------------------------------------------------------------

Portfolio = {}

function Portfolio.get_current_position_lots()
    if Config.trading_mode == "PAPER_TRADING" or Config.trading_mode == "SIGNALS_ONLY" then
        return State.paper.position_lots
    end

    return State.live.position_lots
end

function Portfolio.has_position()
    return Portfolio.get_current_position_lots() > 0
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
        if current_position > 0 then
            return false, "position already exists"
        end

        if current_position + signal.lots > Config.max_position_lots then
            return false, "max_position_lots exceeded"
        end
    end

    if signal.action == "EXIT" then
        if current_position <= 0 then
            return false, "no position to exit"
        end
    end

    if signal.action ~= "BUY" and signal.action ~= "EXIT" then
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

    if signal.action == "BUY" then
        price = offer
        if step > 0 then
            price = price + step * Config.price_offset_steps
        end
    elseif signal.action == "EXIT" then
        price = bid
        if step > 0 then
            price = price - step * Config.price_offset_steps
        end
    end

    return round_price(price, scale)
end

function Orders.paper_execute(signal)
    local price = signal.price
    local lots = signal.lots
    local commission = price * lots * Config.paper_commission_rate
    local slippage = price * Config.paper_slippage_rate

    if signal.action == "BUY" then
        local exec_price = price + slippage

        State.paper.position_lots = lots
        State.paper.avg_price = exec_price
        State.paper.last_entry_strategy = signal.strategy

        State.daily_trade_count = State.daily_trade_count + 1

        Logger.trade("PAPER", signal.strategy, "BUY", exec_price, lots, -commission, signal.reason)
        emit_message("PAPER BUY " .. Config.sec_code .. " price=" .. tostring(exec_price) .. " lots=" .. tostring(lots))
        return
    end

    if signal.action == "EXIT" then
        if State.paper.position_lots <= 0 then
            Logger.warn("PAPER EXIT ignored: no position")
            return
        end

        local exec_price = price - slippage
        local entry = State.paper.avg_price
        local pos_lots = State.paper.position_lots

        local gross_pnl = (exec_price - entry) * pos_lots
        local exit_commission = exec_price * pos_lots * Config.paper_commission_rate
        local pnl = gross_pnl - exit_commission

        State.paper.position_lots = 0
        State.paper.avg_price = 0
        State.paper.realized_pnl = State.paper.realized_pnl + pnl
        State.daily_realized_pnl = State.daily_realized_pnl + pnl
        State.daily_trade_count = State.daily_trade_count + 1

        Logger.trade("PAPER", signal.strategy, "EXIT", exec_price, pos_lots, pnl, signal.reason)
        emit_message("PAPER EXIT " .. Config.sec_code .. " price=" .. tostring(exec_price) .. " pnl=" .. tostring(pnl))
        return
    end
end

function Orders.send_live_order(signal)
    local exec_price = Orders.get_execution_price(signal)

    if exec_price == nil then
        Logger.error("Cannot send order: execution price is nil")
        return false
    end

    local operation = nil

    if signal.action == "BUY" then
        operation = "B"
    elseif signal.action == "EXIT" then
        operation = "S"
    else
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
        ["OPERATION"] = operation,
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

    Logger.trade("LIVE", signal.strategy, signal.action, exec_price, signal.lots, "", signal.reason)
    Logger.info("LIVE order sent TRANS_ID=" .. transaction["TRANS_ID"])
    emit_message("LIVE " .. signal.action .. " sent " .. Config.sec_code .. " price=" .. tostring(exec_price))

    -- В первой версии состояние LIVE ведётся грубо.
    -- Для production нужно сверять реальные сделки через таблицы QUIK.
    if signal.action == "BUY" then
        State.live.position_lots = State.live.position_lots + signal.lots
    elseif signal.action == "EXIT" then
        State.live.position_lots = 0
    end

    State.daily_trade_count = State.daily_trade_count + 1
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
            " entry_high=" .. tostring(signal.entry_high) ..
            " exit_low=" .. tostring(signal.exit_low) ..
            " current_volume=" .. tostring(signal.current_volume) ..
            " avg_volume=" .. tostring(signal.avg_volume) ..
            " volume_ratio=" .. tostring(signal.volume_ratio)
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
            " entry_high=" .. tostring(signal.entry_high) ..
            " exit_low=" .. tostring(signal.exit_low) ..
            " volume_ratio=" .. tostring(signal.volume_ratio) ..
            " reason=" .. tostring(signal.reason)
        )
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
    if Config.entry_period <= 0 then
        return false, "entry_period must be positive"
    end

    if Config.exit_period <= 0 then
        return false, "exit_period must be positive"
    end

    if Config.volume_period <= 0 then
        return false, "volume_period must be positive"
    end

    if Config.volume_multiplier <= 0 then
        return false, "volume_multiplier must be positive"
    end

    if Config.entry_period <= Config.exit_period then
        Logger.warn("entry_period is usually greater than exit_period, current: entry=" ..
            tostring(Config.entry_period) .. " exit=" .. tostring(Config.exit_period))
    end

    if Config.lots <= 0 then
        return false, "lots must be positive"
    end

    if Config.trading_mode ~= "SIGNALS_ONLY" and
       Config.trading_mode ~= "PAPER_TRADING" and
       Config.trading_mode ~= "LIVE" then
        return false, "unknown trading_mode: " .. tostring(Config.trading_mode)
    end

    local required_min = math.max(Config.entry_period, Config.exit_period, Config.volume_period) + 2

    if Config.min_candles < required_min then
        return false, "min_candles must be at least max(entry_period, exit_period, volume_period) + 2"
    end

    return true, "ok"
end

function init()
    Logger.init_files()
    Logger.info("Robot init started")
    Logger.info("Mode=" .. Config.trading_mode)
    Logger.info("Instrument=" .. Config.class_code .. "." .. Config.sec_code)
    Logger.info(
        "Donchian entry_period=" .. tostring(Config.entry_period) ..
        " exit_period=" .. tostring(Config.exit_period) ..
        " volume_period=" .. tostring(Config.volume_period) ..
        " volume_multiplier=" .. tostring(Config.volume_multiplier)
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
        " volume=" .. tostring(candles[#candles].volume) ..
        " action=" .. tostring(signal.action) ..
        " entry_high=" .. tostring(signal.entry_high) ..
        " exit_low=" .. tostring(signal.exit_low) ..
        " avg_volume=" .. tostring(signal.avg_volume) ..
        " volume_ratio=" .. tostring(signal.volume_ratio) ..
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
