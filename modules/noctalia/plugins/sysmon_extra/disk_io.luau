-- Disk read/write throughput from /proc/diskstats, summed over physical
-- disks only: partitions and dm/LUKS layers would count the same I/O twice.
-- Widgets are rebuilt on every noctalia config reload, so the counters and
-- history are saved to the (tmpfs) runtime dir and picked back up on load.
local bar = require("./lib/bar.luau")

local HISTORY = 60 -- samples on the graph, 2 minutes at 2s
local SECTOR = 512 -- /proc/diskstats sectors are always 512 bytes
local CACHE = (noctalia.getenv("XDG_RUNTIME_DIR") or "/tmp") .. "/noctalia-disk-io.json"

noctalia.setUpdateInterval(2000)

-- Whole physical disks are the /sys/block entries backed by a device
local disks = {}
for _, name in noctalia.listDir("/sys/block") or {} do
  if noctalia.fileExists("/sys/block/" .. name .. "/device") then
    disks[name] = true
  end
end

local state = noctalia.json.decode(noctalia.readFile(CACHE) or "") or {}
state.reads = state.reads or {}
state.writes = state.writes or {}

local function formatRate(bytes)
  local units = { "B/s", "KB/s", "MB/s", "GB/s" }
  local i = 1
  while bytes >= 1000 and i < #units do
    bytes /= 1000
    i += 1
  end
  return string.format(i == 1 and "%.0f %s" or "%.1f %s", bytes, units[i])
end

function update()
  noctalia.readFileAsync("/proc/diskstats", function(raw)
    if not raw then
      return
    end
    local readBytes, writeBytes = 0, 0
    for line in string.gmatch(raw, "[^\n]+") do
      local fields = {}
      for f in string.gmatch(line, "%S+") do
        table.insert(fields, f)
      end
      -- major minor name reads merged sectors_read ms writes merged sectors_written ...
      if disks[fields[3]] then
        readBytes += tonumber(fields[6]) * SECTOR
        writeBytes += tonumber(fields[10]) * SECTOR
      end
    end

    local now = noctalia.nowMs()
    local seconds = state.ms and (now - state.ms) / 1000 or 0
    -- Skip the rate after a long gap (suspend, noctalia down): it'd be an
    -- average over minutes, not the last interval
    if seconds > 0 and seconds < 10 and readBytes >= state.read and writeBytes >= state.write then
      local r = (readBytes - state.read) / seconds
      local w = (writeBytes - state.write) / seconds
      bar.push(state.reads, r, HISTORY)
      bar.push(state.writes, w, HISTORY)
      bar.render({
        glyph = "device-floppy",
        series = state.reads,
        series2 = state.writes,
        floor = 1e6,
        label = formatRate(r + w),
        tooltip = { { "Read", formatRate(r) }, { "Write", formatRate(w) } },
      })
    end

    state.read, state.write, state.ms = readBytes, writeBytes, now
    noctalia.writeFile(CACHE, noctalia.json.encode(state))
  end)
end

-- Draw the saved history now instead of after a full interval
if #state.reads > 0 then
  bar.render({
    glyph = "device-floppy",
    series = state.reads,
    series2 = state.writes,
    floor = 1e6,
    label = formatRate(state.reads[#state.reads] + state.writes[#state.writes]),
    tooltip = "Disk I/O",
  })
end
update()
