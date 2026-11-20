-- noctalia rebuilds widgets on every config reload, so the history is kept by the cpu-power service
local bar = require("./lib/bar.luau")

local WATTS = "/run/cpu-power/watts"

noctalia.setUpdateInterval(2000)

function update()
  noctalia.readFileAsync(WATTS, function(raw)
    local history = {}
    for line in string.gmatch(raw or "", "[^\n]+") do
      local w = tonumber(line)
      if w then
        table.insert(history, w)
      end
    end

    if #history > 0 then
      barWidget.setVisible(true)
      bar.render({
        glyph = "bolt",
        series = history,
        floor = 15,
        label = string.format("%.1fW", history[#history]),
        tooltip = "CPU package power",
      })
    elseif not noctalia.fileExists(WATTS) then
      barWidget.setVisible(false)
    end
  end)
end

update()
