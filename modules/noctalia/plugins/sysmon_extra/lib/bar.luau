-- Shared glyph + graph + label row, styled like the built-in sysmon graphs
local M = {}

-- Pushes value onto a fixed-length history, dropping the oldest
function M.push(history, value, max)
  table.insert(history, value)
  if #history > max then
    table.remove(history, 1)
  end
end

local function normalize(series, peak)
  local values = table.create(#series)
  for i, v in series do
    values[i] = v / peak
  end
  return values
end

-- opts: glyph, label, tooltip, series (and optional series2, drawn in
-- primary), floor (the graph's scale never drops below it, so idle is flat)
function M.render(opts)
  local children = { ui.glyph({ name = opts.glyph }) }

  if noctalia.getConfig("graph") then
    local peak = opts.floor
    for _, series in { opts.series, opts.series2 or {} } do
      for _, v in series do
        peak = math.max(peak, v)
      end
    end
    table.insert(children, ui.graph({
      values = normalize(opts.series, peak),
      values2 = opts.series2 and normalize(opts.series2, peak) or nil,
      color = "on_surface",
      color2 = "primary",
      lineWidth = 0.75, -- sysmon's graph line and fill
      fillOpacity = 0.15,
      width = 50,
      height = 18,
    }))
  end
  table.insert(children, ui.label({ text = opts.label }))

  local container = barWidget.isVertical() and ui.column or ui.row
  barWidget.render(container({ gap = 4, align = "center" }, children))
  barWidget.setTooltip(opts.tooltip)
end

return M
