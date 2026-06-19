function getParamNumber(class_code, sec_code, param_name)
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

function getLastPrice(class_code, sec_code)
    return getParamNumber(class_code, sec_code, "LAST")
end

function testSberLastPrice()
    local price, err = getLastPrice("TQBR", "SBER")

    if err ~= nil then
        message("Error: " .. err)
        return
    end

    message("SBER LAST = " .. tostring(price))
end

function testGmknLastPrice()
    local price, err = getLastPrice("TQBR", "GMKN")

    if err ~= nil then
        message("Error: " .. err)
        return
    end

    message("Норильский никель = " .. tostring(price))
end

function main()
    message("Robot data test started")

    testGmknLastPrice()
    sleep(5000)

    message("Robot data test finished")
end