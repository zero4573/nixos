-- CPU package power, sampled by the root cpu-power service (the RAPL counter
-- itself is root-only) and drawn like the built-in sysmon graphs. The service
-- keeps the history, oldest first, one sample per line: widgets are rebuilt on
-- every noctalia config reload, so history kept here would reset each time.
local WATTS = "/run/cpu-power/watts"
local FLOOR_W = 15 -- graph scale never shrinks below this, so idle stays flat

noctalia.setUpdateInterval(2000)

local function render(history)
  local children = { ui.glyph({ name = "bolt" }) }

  if noctalia.getConfig("graph") then
    local peak = FLOOR_W
    for _, w in history do
      peak = math.max(peak, w)
    end
    local values = table.create(#history)
    for i, w in history do
      values[i] = w / peak
    end
    table.insert(children, ui.graph({
      values = values,
      color = "on_surface",
      lineWidth = 0.75, -- sysmon's graph line and fill
      fillOpacity = 0.15,
      width = 50,
      height = 18,
    }))
  end
  table.insert(children, ui.label({ text = string.format("%.1fW", history[#history]) }))

  local container = barWidget.isVertical() and ui.column or ui.row
  barWidget.render(container({ gap = 4, align = "center", tooltip = "CPU package power" }, children))
end

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
      render(history)
    elseif not noctalia.fileExists(WATTS) then
      -- No RAPL zone (VM) or the service isn't running. A one-off bad read
      -- just keeps the last render rather than blinking the widget out.
      barWidget.setVisible(false)
    end
  end)
end

-- Draw now instead of waiting a full interval after a reload
update()
