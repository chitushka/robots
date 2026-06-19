--[[
ema_trend_filter_rsi_robot.lua

Торговый робот для терминала QUIK на чистом QLua.
Стратегия: EMA Trend Filter + RSI — торговля RSI только по направлению старшего тренда.

Логика стратегии:
1. Старший тренд:
   EMA(fast_trend_period) > EMA(slow_trend_period)
   По умолчанию: EMA50 > EMA200.

2. BUY:
   Старший тренд положительный
   И RSI(period) пересёк вниз buy_level.
   По умолчанию: EMA50 > EMA200 и RSI14 пересёк вниз 40.

3. EXIT:
   RSI(period) пересёк вверх exit_level
   ИЛИ старший тренд перестал быть положительным.
   По умолчанию: RSI14 пересёк вверх 60 или EMA50 <= EMA200.

4. Ограничения:
   - шорты запрещены;
   - усреднение запрещено;
   - повторный BUY при открытой позиции запрещён;
   - новые входы блокируются STOP-файлом;
   - максимальное количество сделок в день ограничено;
   - максимальный дневной убыток ограничен.

ВАЖНО:
1. По умолчанию робот работает в режиме SIGNALS_ONLY и НЕ отправляет реальные заявки.
2. LIVE-режим включается только если:
   Config.trading_mode = "LIVE"
   Config.allow_real_orders = true
3. Перед LIVE-запуском обязательно заполнить ACCOUNT, CLIENT_CODE и проверить параметры брокерского счёта.
4. Используйте сначала SIGNALS_ONLY, затем PAPER_TRADING, и только потом LIVE на минимальном объёме.
5. Скрипт предназначен для QLua в QUIK. Никаких require, внешних библиотек, БД и API не используется.

Файлы, которые создаёт робот:
- ema_trend_filter_rsi_robot.log
- ema_trend_filter_rsi_signals.csv
- ema_trend_filter_rsi_trades.csv

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
    robot_name = "EMA_TREND_FILTER_RSI_ROBOT",

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

    -- Фильтр старшего тренда.
    fast_trend_ema_period = 50,
    slow_trend_ema_period = 200,

    -- RSI-сигнал.
    rsi_period = 14,
    buy_level = 40,
    exit_level = 60,

    -- Если true, BUY происходит только при пересечении RSI buy_level сверху вниз.
    -- Если false, BUY разрешён при любом RSI < buy_level.
    use_rsi_cross_for_entry = true,

    -- Если true, EXIT по RSI происходит только при пересечении exit_level снизу вверх.
    -- Если false, EXIT разрешён при любом RSI > exit_level.
    use_rsi_cross_for_exit = true,

    -- Минимальное количество свечей.
    -- Для EMA200 нужно достаточно данных.
    min_candles = 240,
    candles_to_read = 300,

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
    log_file = "ema_trend_filter_rsi_robot.log",
    signals_file = "ema_trend_filter_rsi_signals.csv",
    trades_file = "ema_trend_filter_rsi_trades.csv",

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

    trans_id = 500000,

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
        tostring(signal.fast_ema or ""),
        tostring(signal.slow_ema or ""),
        tostring(signal.rsi or ""),
        tostring(signal.prev_rsi or ""),
        tostring(signal.trend_up or ""),
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
            "datetime;strategy;class_code;sec_code;action;price;lots;fast_ema;slow_ema;rsi;prev_rsi;trend_up;reason"
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

function Indicators.extract_close(candles)
    local values = {}

    for i = 1, #candles do
        values[i] = candles[i].close
    end

    return values
end

function Indicators.sma_at(values, period, index)
    if index < period then
        return nil
    end

    local sum = 0

    for i = index - period + 1, index do
        if values[i] == nil then
            return nil
        end
        sum = sum + values[i]
    end

    return sum / period
end

function Indicators.ema_series(values, period)
    local result = {}

    if values == nil or #values < period then
        return result
    end

    local alpha = 2 / (period + 1)
    local first_sma = Indicators.sma_at(values, period, period)

    if first_sma == nil then
        return result
    end

    result[period] = first_sma

    for i = period + 1, #values do
        result[i] = values[i] * alpha + result[i - 1] * (1 - alpha)
    end

    return result
end

-- RSI по методу Wilder.
-- Возвращает массив RSI, где значения появляются начиная примерно с period + 1.
function Indicators.rsi_series(values, period)
    local result = {}

    if values == nil or #values < period + 1 then
        return result
    end

    local gain_sum = 0
    local loss_sum = 0

    for i = 2, period + 1 do
        local change = values[i] - values[i - 1]

        if change > 0 then
            gain_sum = gain_sum + change
        else
            loss_sum = loss_sum + math.abs(change)
        end
    end

    local avg_gain = gain_sum / period
    local avg_loss = loss_sum / period

    if avg_loss == 0 then
        result[period + 1] = 100
    else
        local rs = avg_gain / avg_loss
        result[period + 1] = 100 - (100 / (1 + rs))
    end

    for i = period + 2, #values do
        local change = values[i] - values[i - 1]
        local gain = 0
        local loss = 0

        if change > 0 then
            gain = change
        else
            loss = math.abs(change)
        end

        avg_gain = ((avg_gain * (period - 1)) + gain) / period
        avg_loss = ((avg_loss * (period - 1)) + loss) / period

        if avg_loss == 0 then
            result[i] = 100
        else
            local rs = avg_gain / avg_loss
            result[i] = 100 - (100 / (1 + rs))
        end
    end

    return result
end

----------------------------------------------------------------------
-- 7. STRATEGY: EMA TREND FILTER + RSI
----------------------------------------------------------------------

Strategy = {}

function Strategy.evaluate(candles)
    if candles == nil or #candles < Config.min_candles then
        return {
            strategy = "ema_trend_filter_rsi",
            action = "HOLD",
            reason = "not enough candles"
        }
    end

    local closes = Indicators.extract_close(candles)

    local fast_ema = Indicators.ema_series(closes, Config.fast_trend_ema_period)
    local slow_ema = Indicators.ema_series(closes, Config.slow_trend_ema_period)
    local rsi = Indicators.rsi_series(closes, Config.rsi_period)

    local i = #closes
    local prev = i - 1

    if fast_ema[i] == nil or slow_ema[i] == nil or
       fast_ema[prev] == nil or slow_ema[prev] == nil or
       rsi[i] == nil or rsi[prev] == nil then
        return {
            strategy = "ema_trend_filter_rsi",
            action = "HOLD",
            reason = "EMA or RSI is not ready"
        }
    end

    local close_price = closes[i]
    local trend_up = fast_ema[i] > slow_ema[i]
    local prev_trend_up = fast_ema[prev] > slow_ema[prev]

    local current_rsi = rsi[i]
    local prev_rsi = rsi[prev]

    local action = "HOLD"
    local reason = "no EMA trend + RSI signal"

    local rsi_entry = false
    local rsi_exit = false

    if Config.use_rsi_cross_for_entry then
        rsi_entry = prev_rsi >= Config.buy_level and current_rsi < Config.buy_level
    else
        rsi_entry = current_rsi < Config.buy_level
    end

    if Config.use_rsi_cross_for_exit then
        rsi_exit = prev_rsi <= Config.exit_level and current_rsi > Config.exit_level
    else
        rsi_exit = current_rsi > Config.exit_level
    end

    -- BUY:
    -- Покупаем откат по RSI только если старший EMA-тренд положительный.
    if trend_up and rsi_entry then
        action = "BUY"
        reason = "Trend UP: EMA" .. tostring(Config.fast_trend_ema_period) ..
                 " " .. tostring(fast_ema[i]) ..
                 " > EMA" .. tostring(Config.slow_trend_ema_period) ..
                 " " .. tostring(slow_ema[i]) ..
                 "; RSI" .. tostring(Config.rsi_period) ..
                 " entry: prev=" .. tostring(prev_rsi) ..
                 " current=" .. tostring(current_rsi) ..
                 " buy_level=" .. tostring(Config.buy_level)
    end

    -- EXIT по RSI:
    -- Фиксируем возврат RSI после отката.
    if rsi_exit then
        action = "EXIT"
        reason = "RSI" .. tostring(Config.rsi_period) ..
                 " exit: prev=" .. tostring(prev_rsi) ..
                 " current=" .. tostring(current_rsi) ..
                 " exit_level=" .. tostring(Config.exit_level)
    end

    -- EXIT по потере старшего тренда:
    -- Если EMA50 стала ниже/равна EMA200, позицию закрываем независимо от RSI.
    if prev_trend_up and not trend_up then
        action = "EXIT"
        reason = "Trend filter broken: EMA" .. tostring(Config.fast_trend_ema_period) ..
                 " " .. tostring(fast_ema[i]) ..
                 " <= EMA" .. tostring(Config.slow_trend_ema_period) ..
                 " " .. tostring(slow_ema[i])
    end

    return {
        strategy = "ema_trend_filter_rsi",
        action = action,
        class_code = Config.class_code,
        sec_code = Config.sec_code,
        price = close_price,
        lots = Config.lots,
        reason = reason,
        fast_ema = fast_ema[i],
        slow_ema = slow_ema[i],
        prev_fast_ema = fast_ema[prev],
        prev_slow_ema = slow_ema[prev],
        rsi = current_rsi,
        prev_rsi = prev_rsi,
        trend_up = trend_up,
        prev_trend_up = prev_trend_up,
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
            " fast_ema=" .. tostring(signal.fast_ema) ..
            " slow_ema=" .. tostring(signal.slow_ema) ..
            " rsi=" .. tostring(signal.rsi) ..
            " trend_up=" .. tostring(signal.trend_up)
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
            " fast_ema=" .. tostring(signal.fast_ema) ..
            " slow_ema=" .. tostring(signal.slow_ema) ..
            " rsi=" .. tostring(signal.rsi) ..
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
    if Config.fast_trend_ema_period <= 0 then
        return false, "fast_trend_ema_period must be positive"
    end

    if Config.slow_trend_ema_period <= 0 then
        return false, "slow_trend_ema_period must be positive"
    end

    if Config.fast_trend_ema_period >= Config.slow_trend_ema_period then
        return false, "fast_trend_ema_period must be less than slow_trend_ema_period"
    end

    if Config.rsi_period <= 1 then
        return false, "rsi_period must be greater than 1"
    end

    if Config.buy_level <= 0 or Config.buy_level >= 100 then
        return false, "buy_level must be between 0 and 100"
    end

    if Config.exit_level <= 0 or Config.exit_level >= 100 then
        return false, "exit_level must be between 0 and 100"
    end

    if Config.buy_level >= Config.exit_level then
        return false, "buy_level must be less than exit_level"
    end

    if Config.lots <= 0 then
        return false, "lots must be positive"
    end

    if Config.trading_mode ~= "SIGNALS_ONLY" and
       Config.trading_mode ~= "PAPER_TRADING" and
       Config.trading_mode ~= "LIVE" then
        return false, "unknown trading_mode: " .. tostring(Config.trading_mode)
    end

    local required_min = math.max(Config.slow_trend_ema_period, Config.rsi_period + 5)

    if Config.min_candles < required_min then
        return false, "min_candles must be at least max(slow_trend_ema_period, rsi_period + 5)"
    end

    if Config.candles_to_read < Config.min_candles then
        return false, "candles_to_read must be >= min_candles"
    end

    return true, "ok"
end

function init()
    Logger.init_files()
    Logger.info("Robot init started")
    Logger.info("Mode=" .. Config.trading_mode)
    Logger.info("Instrument=" .. Config.class_code .. "." .. Config.sec_code)
    Logger.info(
        "EMA trend fast=" .. tostring(Config.fast_trend_ema_period) ..
        " slow=" .. tostring(Config.slow_trend_ema_period) ..
        " RSI period=" .. tostring(Config.rsi_period) ..
        " buy_level=" .. tostring(Config.buy_level) ..
        " exit_level=" .. tostring(Config.exit_level)
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
        " fast_ema=" .. tostring(signal.fast_ema) ..
        " slow_ema=" .. tostring(signal.slow_ema) ..
        " rsi=" .. tostring(signal.rsi) ..
        " trend_up=" .. tostring(signal.trend_up) ..
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
