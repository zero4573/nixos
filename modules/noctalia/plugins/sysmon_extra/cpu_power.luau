-- CPU package power, sampled by the root cpu-power service (the RAPL counter
-- itself is root-only). The service keeps the history, oldest first, one
-- sample per line: widgets are rebuilt on every noctalia config reload, so
-- history kept here would reset each time.
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
      -- No RAPL zone (VM) or the service isn't running. A one-off bad read
      -- just keeps the last render rather than blinking the widget out.
      barWidget.setVisible(false)
    end
  end)
end

-- Draw now instead of waiting a full interval after a reload
update()
