-- ============================================================
-- scrn.brd — a break-off window for the clipboard shelf.
--
-- Open it from the ▦ button in the shelf and it stays up as a real, resizable
-- window of its own. Every screenshot (or copied image) taken WHILE IT IS OPEN
-- lands in it, each with a notes field beside it. When you're done, one button
-- writes a folder to ~/Downloads holding every shot on its own PLUS a single
-- composite image with each shot and its note laid out side by side.
--
-- It's a separate file on purpose: init.lua's main chunk sits at Lua's hard
-- ceiling of 200 locals, so anything with this much state has to live outside it.
-- The only things it borrows from init.lua are the globals cbHistory / cbFavExport
-- / cbSaveNow, and they're all called defensively.
-- ============================================================
local M = {}

-- 🚨 Hammerspoon runs LSUIElement (no Dock icon, no window server activation
-- of its own). wv:bringToFront() + w2:focus() only reorder the WINDOW — macOS
-- still treats whichever regular app was frontmost (Second Brain's Claude Code
-- tab, Terminal, anything) as the active app, so the board never actually
-- rises above it. Proven live: bringToFront()+focus() left frontmostApplication
-- unchanged; explicitly activating Hammerspoon's own process is what flips it.
local function activateSelf()
  local me = hs.application.get(hs.processInfo.bundleID)
  if me then me:activate() end
end

-- 🚨 activateSelf() is necessary but NOT sufficient, and this is the other half.
-- Proven live: after a ⌘⇧B, hs.application.frontmostApplication() came back
-- "Hammerspoon" while hs.window.frontmostWindow() came back "Claude", and a
-- screenshot of the board's own rectangle showed a Finder window still painted
-- over it. The app activates; the WINDOW never rises. That is what an
-- LSUIElement app's panel does — it has no Dock tile and no regular-app window
-- ordering, so bringToFront()/focus() reorder it only among Hammerspoon's own
-- windows and it stays under everybody else's.
--
-- Setting the level DOES order it (verified: at floating the board drew fully
-- over both Claude and Finder). So the raise bounces the level up and puts it
-- straight back — the window server keeps the new front-of-its-level position
-- after the drop, verified still fully visible 3 seconds later with the pin
-- reading off. On-top therefore stays exactly what it was: an option, on the ⇧
-- pin, and not something every summon quietly turns on.
-- The timer is HELD on M, never a bare local: a dropped hs.timer handle is
-- collected and never fires, which here would leave the board pinned for good.
local function raiseHard()
  if not wv then return end
  wv:level(hs.drawing.windowLevels.floating)
  if M.raiseTimer then M.raiseTimer:stop() end
  M.raiseTimer = hs.timer.doAfter(0.25, function()
    if not wv then return end
    wv:level(M.topOn() and hs.drawing.windowLevels.floating
                        or hs.drawing.windowLevels.normal)
  end)
end

local HOME    = os.getenv("HOME")
local DIR     = HOME .. "/.hammerspoon/shot-board"          -- our own copies, so history
local FILE    = HOME .. "/.hammerspoon/shotboard.json"      -- pruning can't delete them
local HTML    = HOME .. "/.hammerspoon/shotboard.html"
local ARCH    = HOME .. "/.hammerspoon/shot-board/archive"   -- its own copies, so
local ARCH_DAYS = 30                                          -- clearing the board
local ARCH_SHOW = 120                                         -- can't touch them
local SHOT_W  = 900                                          -- every shot is normalised to
local NOTE_W  = 460                                          -- this width in the composite
local PAD     = 28

-- the macOS title bar on this window, in points: hs.webview frames INCLUDE it
-- while the page's own coordinates do not, so anything mapping one to the other
-- goes through this (the rec region does the same sum from innerHeight).
local TITLEBAR = 28

-- 🚨 ONE SHAPE, ALWAYS. The board is a vertical 4:3 — three wide to four tall,
-- measured on the CONTENT, not the window, so the title bar never counts toward
-- the picture. He resizes it freely; the moment he lets go of the edge it snaps
-- back onto the ratio, which is what stops it "jumping to different
-- resolutions" every time it reopens. Only a real drag triggers it (frameChange
-- never fires for a programmatic frame), so a ⌘-arrow snap and the parked strip
-- are both left exactly as they were asked for.
-- 🚨 BACK TO THE SHAPE IT ALWAYS WAS (his call). A true 3:4 made it visibly
-- taller than the window he had been using all along, which was 740x880 of
-- content. That is the ratio now — the lock stays, because the lock is what
-- stopped it opening at a different size every time; only the number changed.
local RATIO_W, RATIO_H = 740, 880
local function ratioH(w) return math.floor(w * RATIO_H / RATIO_W + 0.5) end

local TRASH   = HOME .. "/.hammerspoon/shot-board/.trash"   -- deleted shots wait here
local UNDO_MAX = 20

local board, wv, ucc, thumbs = {}, nil, nil, {}
-- 🚨 ASSETS ARE REFERENCES, NOT COPIES. Everything else in this app is copied
-- into its own folder on purpose (the clipboard shelf deletes its files when a
-- clip expires, and a board that loses its pictures is useless). Assets are the
-- deliberate exception, his call: the file stays where it lives — a project
-- folder, an external drive — and this list only remembers the PATH. Move the
-- file and the entry goes grey rather than the app quietly hoarding a duplicate.
local assets = {}
-- Every removal goes on this stack instead of straight to os.remove, so ↺ can put
-- it back — including the wipe that runs itself after a send. It rides along in
-- the json, so the undo survives a reload/restart too.
local undo = {}
-- ▤ the archive: every shot that lands on the board is copied in here as well and
-- kept for a month, so a board that gets cleared (or sent) doesn't take the last
-- four weeks of screenshots with it. Its own files, its own folder — the board's
-- copy can be trashed, undone and re-trashed without the archive noticing.
local arch = {}
-- ▣ the photo strip: what pic. has taken, newest first, shown along the bottom
-- of the rec tab the way Photo Booth shows its filmstrip. SEPARATE FROM THE
-- BOARD on purpose (his call) — a photo is a thing you took just now and mean to
-- glance at, not a shot you are writing a note on, and mixing them meant every
-- burst of five photos buried the board. Xing one off the strip is a tidy-up,
-- never a delete: the archive already has its own copy by then, filed under
-- photos. rather than shots., and that is the copy that keeps for 30 days.
local pics = {}
-- ● every finished take, so the archive can list them. Only a pointer and how
-- long it ran: the .mov itself stays wherever the save folder was pointing when
-- it was recorded, and an entry whose file has gone is dropped on load.
local recs = {}
-- forward declaration: render() (above) hands the page the shortcut list, and a
-- local declared further down the file is NOT in scope inside it
local keyCfg
-- 🚨 FORWARD DECLARED. render() reads the clipboard shelf's favourites, but the
-- function that lists them lives hundreds of lines below render() — so without
-- this the name resolved to a global nil and EVERY render threw, which is what
-- emptied the shortcuts guide, the accent swatches and the board all at once.
-- Same trap that caught ringRepaint. Assigned, not defined, further down.
local shelfItems
-- 🚨 FOUR MORE, ALL THE SAME TRAP. Each of these is called from a function that
-- sits ABOVE its definition, so without a forward declaration the name resolves
-- to a global nil and the call dies at run time — silently, inside a callback.
-- note() from openIn, render() from the thumbnail task, easeTo() from aimBack
-- and escOn() from recStart. Found by scanning the file for locals used above
-- where they are defined; if you add a helper here, run that check again.
local note, render, easeTo, escOn
-- 🚨 forward declared for the same reason: aimClear and aimBack both call
-- snapSync, and after the ring block was rewritten the snap code ended up BELOW
-- them. Third time this file has caught me with a local used above its
-- definition — if you add a helper here, check who calls it and where.
local snapSync
-- The board's own title and general notes — about the whole set, as opposed to
-- the per-shot notes. Both ride along into every export.
local meta = { title = "", notes = "" }

-- ── storage ──────────────────────────────────────────────────────────
-- 🚨 The board is only ever empty on purpose. Every legitimate removal goes
-- through toTrash() — a single delete, cmb., ▣ arch., the clear, the self-wipe
-- after a send — and sets this. An empty board that got there any OTHER way is
-- a bug, and writing it out would destroy the shots the json is still holding.
-- So save() refuses that one write. It cost nothing to add and it would have
-- turned the aliasing bug above from "his board is gone" into "his board is
-- back after a reload", which is why it stays even now that the bug is fixed.
local emptiedOnPurpose = false
local function save()
  -- 🚨 …and #pics == 0 with it. This guard exists to stop an empty board being
  -- written over a file that still has shots in it — but it used to fire on the
  -- board alone, so with the board empty every photo taken went unsaved.
  if #board == 0 and #pics == 0 and not emptiedOnPurpose then
    local d = hs.fs.attributes(FILE) and hs.json.read(FILE)
    if type(d) == "table" and type(d.shots) == "table" and #d.shots > 0 then
      hs.settings.set("sbOpen", wv ~= nil)
      return                              -- the file keeps the shots. Reload gets them back.
    end
  end
  hs.json.write({ title = meta.title, notes = meta.notes, shots = board, undo = undo,
                  arch = arch, recs = recs, assets = assets, pics = pics }, FILE, false, true)
  hs.settings.set("sbOpen", wv ~= nil)
end
-- 🚨 EVERY list comes out of the json through here, and never by reference.
-- hs.json.read hands back ONE Lua table for two EQUAL json arrays: LuaSkin's
-- cycle-detection cache is an NSDictionary, so it keys on isEqual: rather than
-- on pointer identity, and two arrays with the same contents collapse into one.
-- An empty board and an empty recs list are equal — so the moment both were []
-- (a fresh install, or any board cleared while nothing had been recorded), the
-- next load made `recs` and `board` THE SAME TABLE. From then on every shot
-- added to the board also showed up as a recording, save() wrote the two arrays
-- identically forever, and on the following load the recs prune — which drops
-- anything without a `.file` — deleted every shot off the board. Nothing saved
-- during load(), so the json kept the shots and the loss looked impossible:
-- count() 0, file N, and a second load "not recovering" because it aliased them
-- straight back. Copying is the whole fix; it is also cheap at these sizes.
local function copyOut(v, depth)
  if type(v) ~= "table" or (depth or 0) > 6 then return v end
  local out = {}
  for k, x in pairs(v) do out[k] = copyOut(x, (depth or 0) + 1) end
  return out
end
local function load()
  if hs.fs.attributes(FILE) then
    local d = hs.json.read(FILE)
    if type(d) == "table" then
      if d.shots then                       -- current format
        board = copyOut(d.shots)
        undo  = copyOut(d.undo) or {}
        arch  = copyOut(d.arch) or {}
        recs  = copyOut(d.recs) or {}
        -- copyOut, not d.pics: see the note above it. An empty pics list and an
        -- empty board are EQUAL, and hs.json.read hands equal arrays back as one
        -- table — which would alias the strip to the board on a fresh install.
        pics  = copyOut(d.pics) or {}
        assets = copyOut(d.assets) or {}
        meta.title, meta.notes = d.title or "", d.notes or ""
      else
        board = copyOut(d)                  -- the original format was a bare array
      end
    end
  end
  -- drop anything whose file has gone missing, so the UI never shows a dead card
  for i = #board, 1, -1 do
    if not (board[i].img and hs.fs.attributes(board[i].img)) then table.remove(board, i) end
  end
  for i = #pics, 1, -1 do
    if not (pics[i].img and hs.fs.attributes(pics[i].img)) then table.remove(pics, i) end
  end
  -- a take you have since deleted or moved is not a take any more. The
  -- type check is deliberate belt-and-braces: this loop is what emptied the
  -- board when the two lists were aliased, and anything in here that is not a
  -- take is now dropped as junk rather than silently taken for a dead one.
  for i = #recs, 1, -1 do
    local r = recs[i]
    if type(r) ~= "table" or not r.file or not hs.fs.attributes(r.file) then
      table.remove(recs, i)
    end
  end
  -- and anything scrn.brd recorded before it kept a list — or that was recorded
  -- while a different save folder was pointed at — gets picked up off disk, so
  -- the section is never emptier than the takes that actually exist
  local seen = {}
  for _, r in ipairs(recs) do seen[r.file] = true end
  for _, dir in ipairs({ M.dest(), HOME .. "/Downloads" }) do
    if hs.fs.attributes(dir, "mode") == "directory" then
      for f in hs.fs.dir(dir) do
        if f:match("^scrn%.brd%-rec.*%.mov$") then
          local full = dir .. "/" .. f
          if not seen[full] then
            local a = hs.fs.attributes(full)
            seen[full] = true
            recs[#recs + 1] = { file = full, t = (a and a.modification) or os.time(), secs = 0 }
          end
        end
      end
    end
  end
  table.sort(recs, function(x, y) return (x.t or 0) < (y.t or 0) end)
  -- the archive keeps a month, then lets go: anything older than that (or whose
  -- file has gone) is dropped here rather than by a timer, because the only time
  -- it matters is the moment somebody is about to look at it
  local cutoff = os.time() - ARCH_DAYS * 24 * 3600
  for i = #arch, 1, -1 do
    local it = arch[i]
    local gone = not (it.img and hs.fs.attributes(it.img))
    -- 🚨 A FAVOURITE NEVER AGES OUT. That is the whole point of the star: the
    -- archive is a rolling month, and the one thing he marks to keep has to
    -- outlive it. A file that has actually gone still drops — a listing row
    -- pointing at nothing is worse than no row.
    if gone then
      table.remove(arch, i)
    elseif (it.t or 0) < cutoff and not it.fav then
      os.remove(it.img); table.remove(arch, i)
    end
  end
  -- same for the undo stack: an entry that can't actually be restored is worse
  -- than no entry, because ↺ would silently do nothing
  for k = #undo, 1, -1 do
    local e = undo[k]
    local ok = type(e) == "table" and type(e.items) == "table" and #e.items > 0
    if ok then
      for _, it in ipairs(e.items) do
        if not (it.img and hs.fs.attributes(it.img)) then ok = false end
      end
    end
    if not ok then table.remove(undo, k) end
  end
  emptiedOnPurpose = false
end

-- ── undo ─────────────────────────────────────────────────────────────
-- 🚨 Nothing here calls os.remove on a shot any more. Removing moves the PNG into
-- .trash and remembers where it sat; ↺ moves it back. Files only really die when
-- their entry falls off the bottom of the stack.
local function toTrash(it)
  emptiedOnPurpose = true                 -- see save(): this is what makes an empty board honest
  hs.execute(("/bin/mkdir -p %q"):format(TRASH))
  local name = it.img:match("([^/]+)$") or "shot.png"
  local dst  = TRASH .. "/" .. name
  hs.execute(("/bin/mv %q %q"):format(it.img, dst))
  it.img = dst
  return it
end

local function pushUndo(entry)
  if not entry or #entry.items == 0 then return end
  undo[#undo + 1] = entry
  while #undo > UNDO_MAX do
    for _, it in ipairs(undo[1].items) do os.remove(it.img) end
    table.remove(undo, 1)
  end
end

function M.undoCount() return #undo end

-- ── the page ─────────────────────────────────────────────────────────
-- Where saved boards go. Downloads until he points it somewhere else in ⚙;
-- both save buttons obey it, so there is exactly one destination to reason about.
function M.dest()
  local d = hs.settings.get("sbDest")
  if d and hs.fs.attributes(d, "mode") == "directory" then return d end
  return HOME .. "/Downloads"
end
function M.setDest(d)
  if d and hs.fs.attributes(d, "mode") == "directory" then hs.settings.set("sbDest", d); return true end
  return false
end
-- 🚨 TAKES CAN LAND SOMEWHERE ELSE. A .mov is a different animal from a board
-- of pngs — different size, different app opens it, often a different drive. So
-- there are two folders, and leaving the takes one unset simply means "same
-- place as the shots", which is what it always was.
function M.recDest()
  local d = hs.settings.get("sbRecDest")
  if d and hs.fs.attributes(d, "mode") == "directory" then return d end
  return M.dest()
end
function M.setRecDest(d)
  if d and hs.fs.attributes(d, "mode") == "directory" then hs.settings.set("sbRecDest", d); return true end
  return false
end

-- ↗ open it somewhere else. Two standing preferences: one app for pictures,
-- one for takes. Photoshop and Resolve are only the DEFAULTS — both are pickable
-- in ⚙, and either an app name or a full bundle path works because that is what
-- `open -a` takes. Stored, so they survive a reload like every other preference.
local function appLabel(p)
  return (tostring(p or ""):match("([^/]+)%.app$")) or tostring(p or "")
end
function M.imgApp() return hs.settings.get("sbImgApp") or "Adobe Photoshop 2026" end
function M.vidApp() return hs.settings.get("sbVidApp") or "DaVinci Resolve" end
local function openIn(app, file)
  if not (file and hs.fs.attributes(file)) then note("that file is not there any more", 2.4); return end
  local _, ok = hs.execute(("/usr/bin/open -a %q %q"):format(app, file))
  if not ok then note(("%s wouldn't open it"):format(appLabel(app)), 3) end
end

-- ⚙ the picker. An .app is a bundle, so it comes back as a FILE, not a folder.
local function pickApp(key)
  local r = hs.dialog.chooseFileOrFolder("open shots in…", "/Applications", true, false, false, { "app" })
  local path = r and (r["1"] or r[1])
  if not path then return false end
  hs.settings.set(key, path)
  if wv then
    wv:evaluateJavaScript(("SB.apps(%q,%q)"):format(appLabel(M.imgApp()), appLabel(M.vidApp())))
  end
  note(appLabel(path) .. ".", 1.8)
  return true
end

-- ⇧ always on top. Floating keeps the board over whatever you're shooting;
-- normal lets it fall behind like any other window. It's a preference, not a
-- per-session mood, so it sticks across restarts.
function M.topOn() return hs.settings.get("sbTop") == true end
-- 🎞 "full ui." — a standing preference for what the NEXT recording captures,
-- same shape as the pin: stored, so it survives a reload, and read fresh by
-- recStart every time rather than threaded through as an argument.
function M.recFullOn() return hs.settings.get("sbRecFull") == true end
function M.setRecFull(on)
  on = on and true or false
  hs.settings.set("sbRecFull", on)
  if wv then wv:evaluateJavaScript("SB.recFull(" .. tostring(on) .. ")") end
  return on
end
-- ☀ the off-white look. A preference, so it sticks; the page owns what it means.
function M.lightOn() return hs.settings.get("sbLight") == true end
function M.setLight(on)
  on = on and true or false
  hs.settings.set("sbLight", on)
  -- the macOS title bar is chrome, not page: it only goes light if the window's
  -- appearance does. Without this the top strip stayed black over a beige page.
  if wv then wv:darkMode(not on) end
  if wv then wv:evaluateJavaScript("SB.light(" .. tostring(on) .. ")") end
  -- M.ringRepaint, not the local: setLight is defined hundreds of lines ABOVE
  -- where the ring lives, so the upvalue does not exist yet at this point in the
  -- file. Reaching for it through M is what makes the call resolve at run time.
  if M.ringRepaint then M.ringRepaint() end
  -- the clipboard shelf is the same app as far as he is concerned, so it flips
  -- with us — live if it happens to be open, and on its next open either way
  if _G.cbEval then
    cbEval(("document.body.classList.toggle('light',%s)"):format(tostring(on)))
  end
  return on
end
-- ⬤ the accent. One colour drives every green in the page; Lua only remembers
-- it. It is stored, so it survives a reload, and the shelf is told too — the
-- two windows are one app as far as he is concerned.
function M.accent() return hs.settings.get("sbAccent") or "#AACC00" end
function M.setAccent(hex)
  if type(hex) ~= "string" or not hex:match("^#%x%x%x%x%x%x$") then return M.accent() end
  hex = hex:upper()
  hs.settings.set("sbAccent", hex)
  if wv then wv:evaluateJavaScript(("SB.accent(%q)"):format(hex)) end
  if M.ringRepaint then M.ringRepaint() end     -- the frame is drawn in the accent too
  if _G.cbEval then
    cbEval(("document.documentElement.style.setProperty('--ac',%q)"):format(hex))
  end
  return hex
end
function M.setTop(on)
  on = on and true or false
  hs.settings.set("sbTop", on)
  if wv then
    -- parked on the rectangle the strip owns its level (overlay, so Quick Look
    -- and friends cannot bury the controls); the pin only sets it when it isn't
    if not M.clearOn() then
      wv:level(on and hs.drawing.windowLevels.floating or hs.drawing.windowLevels.normal)
    end
    wv:evaluateJavaScript("SB.top(" .. tostring(on) .. ")")
  end
  -- the pin owns click-to-summon too — see frontTapOn
  if M.frontTapSet then M.frontTapSet(on) end
  return on
end

-- ── the toast ────────────────────────────────────────────────────────
-- hs.alert's default is a fat 27pt slab in the middle of the screen, which is
-- the opposite of this app. This one is small, mono, lime on near-black, and
-- sits at the bottom edge out of the way.
local NOTE_STYLE = {
  fillColor   = { hex = "#0A0A0A", alpha = 0.96 },
  strokeColor = { hex = "#AACC00", alpha = 0.85 }, strokeWidth = 1,
  radius = 7, textColor = { hex = "#AACC00" }, textSize = 12,
  textFont = "Menlo", padding = 9, atScreenEdge = 2,
}
-- a path is only ever shown as its own last component: the folder it went to is
-- already on the ⚙ sheet, and a full path blows the toast back up to a slab
local function short(path) return (tostring(path):match("([^/]+)$") or tostring(path)) end
note = function(msg, secs)
  hs.alert.closeAll()
  hs.alert.show(msg, NOTE_STYLE, hs.screen.mainScreen(), secs or 2.2)
end

local function q(s)
  s = tostring(s or "")
     :gsub("\\", "\\\\"):gsub('"', '\\"')
     :gsub("\n", "\\n"):gsub("\r", "\\r"):gsub("\t", "\\t")
     :gsub("%c", function(c) return string.format("\\u%04x", c:byte()) end)
  return '"' .. s .. '"'
end

-- Cards get a downscaled data: URI. A full-res 4K shot base64s into megabytes and
-- would stall the window on every render — same reason the shelf downscales.
local function thumb(p)
  if thumbs[p] == nil then
    local img = hs.image.imageFromPath(p)
    thumbs[p] = img and img:setSize({ w = 520, h = math.floor(520 * (img:size().h / img:size().w)) })
                            :encodeAsURLString() or false
  end
  return thumbs[p] or nil
end

-- 🚨 A TAKE GETS A PICTURE TOO. A row of filenames tells him nothing about
-- which take is which; a poster frame tells him instantly. qlmanage is the
-- macOS thumbnailer — no ffmpeg, no dependency — but it takes about a second per
-- file, so it NEVER runs on the render thread: the first render draws the row
-- without a picture, the task lands, and render() is called again with it. The
-- png is cached next to the board's own copies, so it happens once per take.
local RECTHUMBS = DIR .. "/.recthumbs"
local recthumbs = {}                       -- file -> data-url, or false while it is being made
local function recThumb(file)
  if not (file and hs.fs.attributes(file)) then return nil end
  local cached = recthumbs[file]
  if cached ~= nil then return cached or nil end
  local png = ("%s/%s.png"):format(RECTHUMBS, file:match("([^/]+)$") or "take")
  if hs.fs.attributes(png) then
    local img = hs.image.imageFromPath(png)
    recthumbs[file] = img and img:setSize({ w = 320, h = 180 }):encodeAsURLString() or false
    return recthumbs[file] or nil
  end
  recthumbs[file] = false                  -- one attempt per take per session
  hs.execute(("/bin/mkdir -p %q"):format(RECTHUMBS))
  local t = hs.task.new("/usr/bin/qlmanage", function()
    recthumbs[file] = nil                  -- forget the "in progress" mark; next read loads it
    if wv then render() end
  end, { "-t", "-s", "480", "-o", RECTHUMBS, file })
  if t then t:start() end
  return nil
end

render = function()
  if not wv then return end
  -- ★ one source of truth for a starred SHOT: the archive copy. Every shot that
  -- lands on the board is archived in the same breath, so the board card and the
  -- archive tile are two views of one thing and starring either marks the same
  -- entry. The board item carries its archive path in .arch, so this is the map
  -- from one to the other.
  local favImg = {}
  for _, a in ipairs(arch) do if a.fav and a.img then favImg[a.img] = true end end
  local items = {}
  -- 🚨 NEWEST AT THE TOP, the same way the archive below already does it: the
  -- shot he just took is the one he is about to write a note on, and on a full
  -- board it was landing off the bottom of the scroll. The card keeps its real
  -- board NUMBER (#1 is still the first one taken) — only the order is flipped.
  for i = #board, 1, -1 do
    local it = board[i]
    items[#items + 1] = { i = i, note = it.note or "", thumb = thumb(it.img),
                 fav = (it.arch and favImg[it.arch]) and true or false,
                 dim = (it.w or 0) .. "×" .. (it.h or 0),
                 -- 🚨 "%H", never "%-H": Lua 5.4 rejects the glibc zero-strip
                 -- extension outright ("invalid conversion specifier")
                 when = os.date("%H:%M", it.t or os.time()) }
  end
  -- ▣ the strip. Newest FIRST, like Photo Booth: the one you just took is the
  -- one you are looking for, and it lands where your eye already is.
  local pitems = {}
  for i = #pics, 1, -1 do
    local it = pics[i]
    pitems[#pitems + 1] = { i = i, thumb = thumb(it.img), path = it.img,
                            dim = (it.w or 0) .. "×" .. (it.h or 0),
                            when = os.date("%H:%M", it.t or os.time()) }
  end
  -- newest first, and only the most recent ARCH_SHOW get a thumbnail: a month of
  -- screenshots base64'd into one page would stall the window on every render.
  -- 🚨 ONE WALK, TWO PILES, and the SHARED thumbnail budget still counted once
  -- across both: the cap is there because a month of base64'd screenshots stalls
  -- the window on every render, and that cost does not care which heading a tile
  -- ends up under. `k` is the real arch index in both piles, so every button on
  -- a photo tile is the identical button the shot tiles already use.
  local aitems, apics, shown = {}, {}, 0
  local nshots, npics = 0, 0
  for k = #arch, 1, -1 do
    local it = arch[k]
    local isPic = it.kind == "pic"
    if isPic then npics = npics + 1 else nshots = nshots + 1 end
    shown = shown + 1
    if shown <= ARCH_SHOW then
      local tile = { k = k, note = it.note or "", fav = it.fav and true or false,
                     thumb = thumb(it.img), path = it.img,
                     dim = (it.w or 0) .. "×" .. (it.h or 0),
                     when = os.date("%b %d · %H:%M", it.t or os.time()) }
      if isPic then apics[#apics + 1] = tile else aitems[#aitems + 1] = tile end
    end
  end
  local ritems = {}
  for k = #recs, 1, -1 do
    local r = recs[k]
    ritems[#ritems + 1] = { k = k, name = short(r.file), fav = r.fav and true or false,
                            thumb = recThumb(r.file), path = r.file,
                            when = os.date("%b %d · %H:%M", r.t or os.time()),
                            dur = ("%d:%02d"):format(math.floor((r.secs or 0) / 60), (r.secs or 0) % 60) }
  end
  -- ★ the fav. tab is a VIEW, never a third copy: starred archive tiles and
  -- starred takes, drawn with the same two renderers the other tabs use.
  local fshots, ftakes = {}, {}
  for k = #arch, 1, -1 do
    local it = arch[k]
    if it.fav then
      fshots[#fshots + 1] = { k = k, note = it.note or "", fav = true, thumb = thumb(it.img),
                              path = it.img,
                              dim = (it.w or 0) .. "×" .. (it.h or 0),
                              when = os.date("%b %d · %H:%M", it.t or os.time()) }
    end
  end
  for k = #recs, 1, -1 do
    local r = recs[k]
    if r.fav then
      ftakes[#ftakes + 1] = { k = k, name = short(r.file), fav = true, thumb = recThumb(r.file),
                              path = r.file,
                              when = os.date("%b %d · %H:%M", r.t or os.time()),
                              dur = ("%d:%02d"):format(math.floor((r.secs or 0) / 60), (r.secs or 0) % 60) }
    end
  end
  local aitems2 = {}
  for k = #assets, 1, -1 do
    local a = assets[k]
    local here = a.path and hs.fs.attributes(a.path) ~= nil
    local ext  = (a.path or ""):match("%.(%w+)$") or ""
    aitems2[#aitems2 + 1] = {
      k = k, name = (a.path or ""):match("([^/]+)$") or "?",
      where = (a.path or ""):gsub("/[^/]+$", ""):gsub(HOME, "~"),
      ext = ext:upper(), here = here, path = a.path,
      thumb = here and ext:lower():match("^(png|jpg|jpeg|gif|heic|tiff|bmp|webp)$") and thumb(a.path) or nil,
      when = os.date("%b %d", a.t or os.time()) }
  end
  local sitems = shelfItems()
  for _, it in ipairs(sitems) do
    it.when = os.date("%b %d", it.t or os.time()); it.t = nil
  end
  -- SB.apps BEFORE SB.render/SB.arch/SB.recs: the cards label their open button
  -- from it, so the names have to be there before the cards are drawn.
  wv:evaluateJavaScript(("SB.accent(%q);SB.light(%s);SB.keys(%s);SB.apps(%q,%q);SB.recs(%s);SB.render(%s,%s,%s);SB.dest(%s,%s);SB.top(%s);SB.undo(%d);SB.arch(%s,%d);SB.strip(%s);SB.archpics(%s,%d);SB.favs(%s,%s);SB.assets(%s);SB.shelf(%s);SB.audio(%s,%s);SB.recFull(%s);SB.photo(%s,%s)"):format(
    M.accent(), tostring(M.lightOn()), hs.json.encode(keyCfg()),
    appLabel(M.imgApp()), appLabel(M.vidApp()), hs.json.encode(ritems),
    hs.json.encode(items), q(meta.title), q(meta.notes),
    q(M.dest():gsub(HOME, "~")), q(M.recDest():gsub(HOME, "~")),
    tostring(M.topOn()), #undo, hs.json.encode(aitems), nshots,
    hs.json.encode(pitems), hs.json.encode(apics), npics,
    hs.json.encode(fshots), hs.json.encode(ftakes), hs.json.encode(aitems2),
    hs.json.encode(sitems), tostring(M.micOn()), tostring(M.sysOn()),
    tostring(M.recFullOn()), tostring(M.picTimerOn()), tostring(M.picFlashOn())))
end

-- One shot into the archive, as its own file. Silent: this runs on every capture
-- and a toast per screenshot would be unbearable.
-- `kind` is the archive's only distinction: nil for a screenshot, "pic" for a
-- photograph. One list, one prune, one star, two headings on the page — which is
-- the whole of what he asked for ("a separate section to where the screenshots
-- are"), with none of the second archive that a second list would have meant.
local function archAdd(it, kind)
  if not (it and it.img and hs.fs.attributes(it.img)) then return nil end
  hs.execute(("/bin/mkdir -p %q"):format(ARCH))
  local dst = ("%s/%s-%04d.png"):format(ARCH, os.date("%Y%m%d-%H%M%S"), math.random(0, 9999))
  hs.execute(("/bin/cp %q %q"):format(it.img, dst))
  if not hs.fs.attributes(dst) then return nil end
  arch[#arch + 1] = { img = dst, w = it.w, h = it.h, note = it.note or "",
                      t = it.t or os.time(), kind = kind }
  it.arch = dst                      -- the link, so a note typed later follows it in
  return arch[#arch]
end
function M.archCount() return #arch end

-- ── adding a shot ────────────────────────────────────────────────────
-- Called from init.lua's image capture. We copy the PNG into our own folder:
-- the clipboard history deletes its image files when a clip expires, and a board
-- that loses its pictures a week later is worse than useless.
function M.add(srcPath, w, h)
  --  IT COLLECTS WHETHER OR NOT THE WINDOW IS UP (his call, Aug 25 2026).
  -- This used to bail when the board was closed, so a shot taken with the window
  -- shut went nowhere: scrn.brd is where every screenshot lives now, so the data
  -- takes it either way and render() simply does nothing until there is a window
  -- to draw into.
  if not (srcPath and hs.fs.attributes(srcPath)) then return false end
  hs.execute(("/bin/mkdir -p %q"):format(DIR))
  local dst = ("%s/%s-%04d.png"):format(DIR, os.date("%Y%m%d-%H%M%S"), math.random(0, 9999))
  hs.execute(("/bin/cp %q %q"):format(srcPath, dst))
  if not hs.fs.attributes(dst) then return false end
  board[#board + 1] = { img = dst, w = w, h = h, note = "", t = os.time() }
  archAdd(board[#board])
  save(); render()
  return true
end

-- The same thing for a photograph, and deliberately NOT M.add with a flag: the
-- only lines these two share are the copy and the archive call, and every other
-- line differs (no undo, no board number, a different list, a different heading
-- in the archive). The strip is capped because it is a glance, not a gallery —
-- the archive is where all of them live.
local PIC_KEEP = 24
function M.picAdd(srcPath, w, h)
  if not (srcPath and hs.fs.attributes(srcPath)) then return false end
  hs.execute(("/bin/mkdir -p %q"):format(DIR))
  local dst = ("%s/%s-%04d.png"):format(DIR, os.date("%Y%m%d-%H%M%S"), math.random(0, 9999))
  hs.execute(("/bin/cp %q %q"):format(srcPath, dst))
  if not hs.fs.attributes(dst) then return false end
  pics[#pics + 1] = { img = dst, w = w, h = h, t = os.time() }
  archAdd(pics[#pics], "pic")
  -- over the cap the oldest falls off the STRIP only — its archive copy, filed
  -- moments ago, is untouched, so nothing is actually lost by this line
  while #pics > PIC_KEEP do toTrash(table.remove(pics, 1)) end
  save(); render()
  return true
end
function M.picCount() return #pics end

-- Pictures you already have: references, photos off the phone, anything on disk.
-- Everything is re-encoded to PNG into our own folder rather than copied, so a
-- JPEG/HEIC doesn't end up sitting behind a .png name that the composite can't read.
function M.addFiles()
  if not wv then return 0 end
  local picked = hs.dialog.chooseFileOrFolder(
    "Add pictures to the board", HOME .. "/Pictures", true, false, true,
    { "png", "jpg", "jpeg", "heic", "gif", "tiff", "bmp", "webp" })
  if not picked then return 0 end
  -- chooseFileOrFolder hands back { ["1"] = "file:///…" } — string keys, URL values
  local paths = {}
  for _, v in pairs(picked) do paths[#paths + 1] = (tostring(v):gsub("^file://", "")) end
  table.sort(paths)
  return M.addImages(paths)
end

-- the half of addFiles that has nothing to do with a file dialog, so the import
-- itself can be exercised without one
function M.addImages(paths)
  if not wv then return 0 end
  hs.execute(("/bin/mkdir -p %q"):format(DIR))
  local n = 0
  for _, src in ipairs(paths) do
    local url = src:gsub("%%(%x%x)", function(h) return string.char(tonumber(h, 16)) end)
    local img = hs.image.imageFromPath(url)
    if img then
      local dst = ("%s/%s-%04d.png"):format(DIR, os.date("%Y%m%d-%H%M%S"), math.random(0, 9999))
      if img:saveToFile(dst, "PNG") and hs.fs.attributes(dst) then
        local sz = img:size()
        board[#board + 1] = { img = dst, w = math.floor(sz.w), h = math.floor(sz.h), note = "", t = os.time() }
        archAdd(board[#board])
        n = n + 1
      end
    end
  end
  if n > 0 then save(); render() end
  note(n > 0 and ("+ " .. n .. (n == 1 and " picture" or " pictures")) or "nothing added", 1.8)
  return n
end

-- Empty the board. `all` also drops the title and the board notes, which is what
-- "start a new one" means after a send — the broom only takes the shots.
local function wipe(all)
  local e = { items = {}, at = {} }
  if all then e.meta = { title = meta.title, notes = meta.notes } end
  for i = 1, #board do e.items[i] = board[i]; e.at[i] = i end
  for i = #board, 1, -1 do toTrash(board[i]); table.remove(board, i) end
  pushUndo(e)
  if all then meta.title, meta.notes = "", "" end
  save(); render()
end

-- ↺ — put the last removal back exactly where it was. Restoring in reverse index
-- order is what makes a whole-board wipe come back in its original order.
local function undoLast()
  local e = table.remove(undo)
  if not e then note("nothing to undo", 1.6); return false end
  for k = #e.items, 1, -1 do
    local it   = e.items[k]
    local name = it.img:match("([^/]+)$") or "shot.png"
    local back = DIR .. "/" .. name
    hs.execute(("/bin/mkdir -p %q"):format(DIR))
    hs.execute(("/bin/mv %q %q"):format(it.img, back))
    it.img = back
    table.insert(board, math.min(e.at[k] or (#board + 1), #board + 1), it)
  end
  if e.meta then
    if meta.title == "" then meta.title = e.meta.title or "" end
    if meta.notes == "" then meta.notes = e.meta.notes or "" end
  end
  save(); render()
  note(("↺ %d shot%s back"):format(#e.items, #e.items == 1 and "" or "s"), 1.8)
  return true
end

-- ⤓ out of the way without dying: minimised, the window is still open as far as
-- M.add is concerned, so the next board starts collecting the moment this one is
-- gone. Falls back to hiding it if AppKit won't hand us the window.
-- 🚨 hide(), NEVER minimize(). A miniaturised hs.webview drops out of hs.window
-- ENTIRELY — hswindow() returns nil and nothing can pull it back — so the only
-- way home was to delete the webview and build a new one, reloading the page off
-- disk. Every send stashes, so every summon after a send paid for that: measured
-- at 3101ms from keypress, against 57-100ms for an unstashed board. That is the
-- whole "it takes a long time to load up".
--
-- hide() keeps the window object alive, so wv:show() puts it straight back. The
-- only thing lost is the Dock tile while it is away, and that was never the way
-- back in anyway — the ▦ tray mark and ⌘⇧B both are, and both are instant now.
function M.stash()
  if not wv then return false end
  wv:hide()
  return true
end

-- ── export ───────────────────────────────────────────────────────────
-- Filename-safe, and NO SPACES anywhere (his ask): words join with dashes, so a
-- saved board can be typed, tab-completed and pasted into a shell without quotes.
local function slug(s)
  s = tostring(s or ""):gsub("[^%w%-%._ ]", ""):gsub("%s+", "-")
                       :gsub("%-+", "-"):gsub("^%-+", ""):gsub("%-+$", "")
  if utf8.len(s) and utf8.len(s) > 32 then s = s:sub(1, utf8.offset(s, 32) - 1) end
  return (s:gsub("%-+$", ""))
end

-- Height a shot takes once it's normalised to SHOT_W. Everything is scaled to the
-- same width so the sheet reads as one document rather than a pile of odd sizes.
local function rowHeight(it)
  local img = hs.image.imageFromPath(it.img)
  local sz  = img and img:size() or { w = 16, h = 9 }
  local h   = math.floor(SHOT_W * (sz.h / sz.w))
  return math.max(h, 140), h
end

-- One tall PNG: a title and the general notes across the top, then each shot on
-- the left at a uniform width with its own note beside it.
local function composite(items)
  items = items or board
  if #items == 0 then return nil end
  local W = PAD + SHOT_W + PAD + NOTE_W + PAD
  local rows, total = {}, PAD
  -- header height, estimated from the text: hs.canvas won't measure a wrapped
  -- string for us, and a frame that's too short silently clips the tail off.
  local head = 0
  local hasHead = (meta.title ~= "" or meta.notes ~= "")
  if hasHead then
    head = (meta.title ~= "" and 44 or 0)
    if meta.notes ~= "" then
      local perLine = math.floor((W - PAD * 2) / 9.7)          -- Menlo 16 is ~9.7px per char
      local lines = 0
      for chunk in (meta.notes .. "\n"):gmatch("([^\n]*)\n") do
        lines = lines + math.max(1, math.ceil(#chunk / math.max(1, perLine)))
      end
      head = head + lines * 22 + 8
    end
    head = head + 18
    total = total + head
  end
  for i, it in ipairs(items) do
    local rh, ih = rowHeight(it)
    rows[i] = { h = rh, ih = ih }
    total = total + rh + PAD
  end
  local c = hs.canvas.new({ x = 0, y = 0, w = W, h = total })
  c[1] = { type = "rectangle", action = "fill", fillColor = { white = 1 },
           frame = { x = 0, y = 0, w = W, h = total } }
  local y, n = PAD, 1
  if hasHead then
    local hy = y
    if meta.title ~= "" then
      n = n + 1
      c[n] = { type = "text", text = meta.title, textSize = 30, textFont = "Helvetica-Bold",
               textColor = { white = 0.05 }, frame = { x = PAD, y = hy, w = W - PAD * 2, h = 40 } }
      hy = hy + 44
    end
    if meta.notes ~= "" then
      n = n + 1
      -- 🚨 Menlo, not Helvetica: the sheet is read as a PICTURE (by him and by a
      -- model), and a mono face with a big x-height keeps 0/O, 1/l/I, rn/m apart
      -- when it's downscaled. Typeface is irrelevant to plain text; here it isn't.
      c[n] = { type = "text", text = meta.notes, textSize = 16, textFont = "Menlo",
               textColor = { white = 0.25 },
               frame = { x = PAD, y = hy, w = W - PAD * 2, h = head - (hy - y) } }
    end
    n = n + 1
    c[n] = { type = "rectangle", action = "fill", fillColor = { white = 0.82 },
             frame = { x = PAD, y = y + head - 12, w = W - PAD * 2, h = 1 } }
    y = y + head
  end
  for i, it in ipairs(items) do
    local r = rows[i]
    n = n + 1
    c[n] = { type = "image", image = hs.image.imageFromPath(it.img),
             imageScaling = "scaleProportionally", imageAlignment = "topLeft",
             frame = { x = PAD, y = y, w = SHOT_W, h = r.ih } }
    n = n + 1
    c[n] = { type = "text", text = tostring(i),
             textSize = 13, textColor = { white = 0.45 }, textFont = "Helvetica-Bold",
             frame = { x = PAD + SHOT_W + PAD, y = y, w = NOTE_W, h = 20 } }
    n = n + 1
    c[n] = { type = "text", text = (it.note or "") ~= "" and it.note or "—",
             textSize = 15, textColor = { white = 0.1 }, textFont = "Menlo",
             frame = { x = PAD + SHOT_W + PAD, y = y + 22, w = NOTE_W, h = r.h - 22 } }
    n = n + 1                                        -- hairline between rows
    c[n] = { type = "rectangle", action = "fill", fillColor = { white = 0.88 },
             frame = { x = PAD, y = y + r.h + PAD / 2 - 1, w = W - PAD * 2, h = 1 } }
    y = y + r.h + PAD
  end
  local img = c:imageFromCanvas()
  c:delete()
  return img
end

-- ── the board as text ────────────────────────────────────────────────
-- Markdown, deliberately: it is the format a model parses most reliably, the
-- headings make "which note belongs to which picture" unambiguous, and it still
-- reads fine as plain text in any editor.
-- 🚨 EVERY EXPORT NOW TAKES A LIST, and defaults to the whole board when it is
-- given none. That default is the entire compatibility story: every existing
-- caller passes nothing and gets exactly what it always got, while a picked run
-- of shots travels through the same four functions as a shorter list. There is
-- no second code path for "selected" anywhere in this file, which is the point —
-- a sheet of three is a sheet, not a special case.
local function markdown(intro, items)
  items = items or board
  local out = {}
  out[#out + 1] = "# scrn.brd" .. (meta.title ~= "" and (" — " .. meta.title) or "")
  out[#out + 1] = ""
  if intro then out[#out + 1] = intro; out[#out + 1] = "" end
  if meta.notes ~= "" then
    out[#out + 1] = "## board notes"
    out[#out + 1] = meta.notes
    out[#out + 1] = ""
  end
  out[#out + 1] = "## shots"
  if #items == 0 then out[#out + 1] = "(none)" end
  for i, it in ipairs(items) do
    out[#out + 1] = ""
    -- a take has no dimensions to give, so it gives its length instead: "0×0"
    -- on every video row was the export quietly admitting it had been written
    -- for pictures only
    out[#out + 1] = it.vid
      and ("### %d · %s · %d:%02d"):format(i, os.date("%Y-%m-%d %H:%M", it.t or os.time()),
                                           math.floor((it.secs or 0) / 60), (it.secs or 0) % 60)
      or  ("### %d · %s · %d×%d"):format(i, os.date("%Y-%m-%d %H:%M", it.t or os.time()),
                                         it.w or 0, it.h or 0)
    out[#out + 1] = (it.note or "") ~= "" and it.note or "_(no note)_"
  end
  return table.concat(out, "\n") .. "\n"
end

-- The stem every save is named from: the board's title if it has one.
-- Dash-joined end to end — no spaces in anything scrn.brd writes.
local function stem()
  local t = slug(meta.title)
  return "scrn.brd" .. (t ~= "" and ("-" .. t) or "") .. os.date("-%Y-%m-%d-%H%M%S")
end

-- ── what "selected" means ────────────────────────────────────────────
-- The page picks tiles on whatever tab he is looking at and sends {tab, idx}.
-- This is the only place that knows which Lua list a tab is showing, and it is
-- the reason selecting works the same on all four: a shot, an archived shot, a
-- photo and a take all come back as items, and everything downstream just sees
-- a list.
--
-- 🚨 A TAKE IS NOT A PICTURE. recs entries carry .file (a .mov) where the other
-- three carry .img, so they are normalised here — .img stays nil and .vid holds
-- the path. Nothing that stitches or pastes can use a video, so the exports below
-- each say plainly what they did with them rather than dropping them in silence.
local function subset(sel)
  if type(sel) ~= "table" or type(sel.idx) ~= "table" or #sel.idx == 0 then return nil end
  local tab = sel.tab
  local src = (tab == "arch" or tab == "archpic" or tab == "fav") and arch
           or (tab == "pics" and pics)
           or (tab == "recs" or tab == "favrec") and recs
           or board
  local out = {}
  for _, i in ipairs(sel.idx) do
    local it = src[tonumber(i) or 0]
    if it then
      out[#out + 1] = it.file and { vid = it.file, note = it.note or "",
                                    t = it.t, secs = it.secs, w = 0, h = 0 } or it
    end
  end
  return #out > 0 and out or nil
end

-- images and videos, split — every export wants the two apart
local function split(items)
  local pics_, vids = {}, {}
  for _, it in ipairs(items or board) do
    if it.vid then vids[#vids + 1] = it else pics_[#pics_ + 1] = it end
  end
  return pics_, vids
end

-- SEPARATE saves, on purpose: sometimes you want the shots as files to work
-- with, sometimes just the one sheet to hand to somebody. Both write into
-- whatever destination ⚙ is pointing at.
-- 🚨 A SHEET IS A PICTURE, so a take cannot be in one. Selecting a mix stitches
-- the pictures and SAYS how many takes it left out — the one thing worse than
-- refusing a video here would be quietly pretending it went in.
function M.saveSheet(items)
  items = items or board
  local imgs, vids = split(items)
  if #imgs == 0 then
    note(#vids > 0 and "takes can't be stitched into a sheet — try sv.sep" or "nothing to save", 2.6)
    return nil
  end
  local sheet = composite(imgs)
  if not sheet then note("couldn't build the sheet"); return nil end
  local path = M.dest() .. "/" .. stem() .. ".png"
  sheet:saveToFile(path)
  hs.execute(("/usr/bin/open -R %q"):format(path))     -- reveal the file, not a folder
  note(("sv.as.one · %d → %s%s"):format(#imgs, short(path),
    #vids > 0 and ("  (" .. #vids .. " take" .. (#vids == 1 and "" or "s") .. " left out)") or ""))
  return path
end

-- ⚙: point the saves somewhere else. The dialog BLOCKS Hammerspoon, so the
-- window is left alone until he answers it.
local function pushDests()
  if wv then wv:evaluateJavaScript(("SB.dest(%s,%s)"):format(
    q(M.dest():gsub(HOME, "~")), q(M.recDest():gsub(HOME, "~")))) end
end
M.pushDests = pushDests

-- which = "shots" or "takes"; they are the same picker with a different home
function M.pickDest(which)
  local takes = which == "takes"
  local r = hs.dialog.chooseFileOrFolder(
    takes and "Where should recordings go?" or "Where should shots go?",
    takes and M.recDest() or M.dest(), false, true, false)
  local new = r and (r["1"] or r[1])
  if new then
    new = new:gsub("^file://", "")
             :gsub("%%(%x%x)", function(c) return string.char(tonumber(c, 16)) end)
             :gsub("/+$", "")
    if (takes and M.setRecDest(new) or (not takes and M.setDest(new))) then
      pushDests()
      note((takes and "takes → " or "shots → ") .. new:gsub(HOME, "~"))
    end
  end
end

-- ⤓ one shot, straight to the save folder — the picture as it is, full res,
-- named from its note like the ones saveShots writes.
function M.saveOne(i)
  local it = board[i]
  if not it then return nil end
  local sl = slug(it.note)
  local path = ("%s/%s-%02d%s.png"):format(M.dest(), stem(), i, sl ~= "" and ("-" .. sl) or "")
  hs.execute(("/bin/cp %q %q"):format(it.img, path))
  if not hs.fs.attributes(path) then note("couldn't save that shot", 2); return nil end
  hs.execute(("/usr/bin/open -R %q"):format(path))
  note(("shot %d → %s"):format(i, short(path)))
  return path
end

-- ▢ combine: two or more shots stitched into ONE picture, in board order.
-- Landscape shots stack (one under the other), anything else sits side by side —
-- which is the layout that keeps a pair of phone screenshots readable instead of
-- squashing them into a letterbox. The originals come off the board as one undo
-- entry; the archive still has them either way.
local COMBINE_MAX = 1800                    -- long edge of the stitched picture
function M.combine(idx)
  if type(idx) ~= "table" or #idx < 2 then return nil end
  local items, imgs = {}, {}
  for _, i in ipairs(idx) do
    local it = board[i]
    local img = it and hs.image.imageFromPath(it.img)
    if not img then return nil end
    items[#items + 1] = it
    imgs[#imgs + 1] = img
  end
  local stack = true                        -- vertical unless something is portrait
  for _, img in ipairs(imgs) do
    local z = img:size()
    if z.h > z.w then stack = false end
  end
  local frames, W, H = {}, 0, 0
  if stack then
    W = COMBINE_MAX
    for k, img in ipairs(imgs) do
      local z = img:size()
      local h = math.floor(W * (z.h / z.w))
      frames[k] = { x = 0, y = H, w = W, h = h }
      H = H + h
    end
  else
    H = COMBINE_MAX
    for k, img in ipairs(imgs) do
      local z = img:size()
      local w = math.floor(H * (z.w / z.h))
      frames[k] = { x = W, y = 0, w = w, h = H }
      W = W + w
    end
  end
  local c = hs.canvas.new({ x = 0, y = 0, w = W, h = H })
  c[1] = { type = "rectangle", action = "fill", fillColor = { white = 0 },
           frame = { x = 0, y = 0, w = W, h = H } }
  for k, img in ipairs(imgs) do
    c[k + 1] = { type = "image", image = img, imageScaling = "scaleToFit", frame = frames[k] }
  end
  local out = c:imageFromCanvas()
  c:delete()
  if not out then return nil end
  hs.execute(("/bin/mkdir -p %q"):format(DIR))
  local dst = ("%s/%s-%04d-cmb.png"):format(DIR, os.date("%Y%m%d-%H%M%S"), math.random(0, 9999))
  if not (out:saveToFile(dst) and hs.fs.attributes(dst)) then return nil end
  local notes = {}
  for _, it in ipairs(items) do
    if (it.note or "") ~= "" then notes[#notes + 1] = it.note end
  end
  -- take the originals off the board, highest index first so the lower ones keep
  -- their positions while we go, and put the stitched one where the first was
  local gone, at = {}, {}
  for k = #idx, 1, -1 do
    gone[#gone + 1] = toTrash(table.remove(board, idx[k]))
    at[#at + 1] = idx[k]
  end
  pushUndo({ items = gone, at = at })
  table.insert(board, idx[1], { img = dst, w = W, h = H, t = os.time(),
                                note = table.concat(notes, " / ") })
  archAdd(board[idx[1]])
  save(); render()
  note(("▢ combined %d shots"):format(#idx))
  return dst
end

-- ✈ flung at the screen edge: the same full-res PNG as ⤓ save, but it lands on
-- the Desktop and nothing is revealed in Finder — the point of the gesture is
-- that the file is just THERE when you look.
function M.toDesktop(i)
  local it = board[i]
  if not it then return nil end
  local sl = slug(it.note)
  local path = ("%s/Desktop/%s-%02d%s.png"):format(HOME, stem(), i, sl ~= "" and ("-" .. sl) or "")
  hs.execute(("/bin/cp %q %q"):format(it.img, path))
  if not hs.fs.attributes(path) then note("couldn't put that on the desktop", 2); return nil end
  note(("shot %d → desktop"):format(i))
  return path
end

-- sv.sep is the one export that takes EVERYTHING, videos included: it is a
-- folder of files, and a .mov is a file. It keeps its own extension.
function M.saveShots(items)
  items = items or board
  if #items == 0 then note("nothing to save"); return nil end
  local dir = M.dest() .. "/" .. stem()
  hs.execute(("/bin/mkdir -p %q"):format(dir))
  for i, it in ipairs(items) do
    local s = slug(it.note)
    local ext = it.vid and ((it.vid:match("%.(%w+)$") or "mov"):lower()) or "png"
    local name = ("%02d%s.%s"):format(i, s ~= "" and ("-" .. s) or "", ext)
    hs.execute(("/bin/cp %q %q"):format(it.vid or it.img, dir .. "/" .. name))
  end
  -- the notes as markdown too — searchable, readable without opening a picture,
  -- and the shape a model can consume without being told how to read it
  local f = io.open(dir .. "/notes.md", "w")
  if f then
    f:write(markdown(("%d file%s, saved %s. The numbered headings below match the "
      .. "numbered files in this folder."):format(
      #items, #items == 1 and "" or "s", os.date("%Y-%m-%d %H:%M")), items))
    f:close()
  end
  hs.execute(("/usr/bin/open %q"):format(dir))
  note(("sv.sep · %d → %s"):format(#items, short(dir)))
  return dir
end

-- ── screen recording ─────────────────────────────────────────────────
-- The rec tab turns the window itself into the viewfinder: the chrome up top
-- stays solid, everything below it goes see-through with a 10% white wash so the
-- area being aimed at is obvious without hiding it.
--
-- 🚨 The wash can never be ON while recording — screencapture -R grabs the
-- COMPOSITED screen, so anything this window paints over that rect lands in the
-- file. So the moment recording starts the window collapses to just its bar
-- (which also frees the clicks underneath, so the app being recorded is still
-- usable) and the only marker left is an accent ring drawn 2px OUTSIDE the
-- recorded rect, where the capture can't see it.
--
-- Engine is the same one ⌘⇧R uses: /usr/sbin/screencapture -v -R. 🚨 The fifo is
-- not decoration — `screencapture -v` stops on ANY stdin activity including the
-- EOF hs.task hands it, which finalizes every take at ~0.07s. A fifo opened
-- read-write always has a writer, so it never EOFs; `exec` keeps the pid real.
local SCAP = "/usr/sbin/screencapture"

-- ── sound: his mic, the screen, or both ──────────────────────────────
-- 🚨 LIFTED FROM THE ⌘⇧R RECORDER THAT USED TO LIVE IN init.lua, which did this
-- and did it correctly. That code is deleted; this is the same logic, and the
-- same three pieces on disk it depends on: bin/srbus, the BlackHole 2ch driver,
-- and the two virtual devices srbus builds out of them.
--
-- screencapture takes -g (whatever the default input is) or -G <uid> (a named
-- device). System sound therefore means routing the Mac's OUTPUT through
-- BlackHole and capturing that — which on its own would leave him deaf to his own
-- screen, so the real speakers and BlackHole are stacked into one "SR Monitor"
-- device and that becomes the default while the take runs.
--
-- 🚨 THE PREVIOUS OUTPUT IS PERSISTED, NOT HELD IN A LOCAL. A reload mid-take
-- would take an in-memory copy with it and leave his sound stranded on SR
-- Monitor with nothing left that knows what it used to be. It goes to
-- hs.settings, and a guard at load time puts it back if that ever happens.
local BH_UID = "BlackHole2ch_UID"
local SRBUS  = HOME .. "/.hammerspoon/bin/srbus"
local SR_MON, SR_IN = "SR Monitor", "SR Input"

function M.micOn()  return hs.settings.get("sbMic") == true end
function M.sysOn()  return hs.settings.get("sbSys") == true end

-- the flag screencapture gets, built fresh per take: srbus rebuilds the
-- aggregate around whatever mic happens to be default at this moment, which is
-- why this is not cached.
local function audioFlag()
  local mic, sys = M.micOn(), M.sysOn()
  if not (mic or sys) then return "" end
  if mic and not sys then return " -g" end
  if sys and not mic then return " -G " .. BH_UID end
  local input = hs.audiodevice.defaultInputDevice()
  local uid = input and input:uid()
  if not uid then return " -G " .. BH_UID end          -- no mic to fold in
  local _, ok = hs.execute(string.format('%q make %q aggregate %q %q', SRBUS, SR_IN, BH_UID, uid))
  return ok and " -G srbus.SR-Input" or " -G " .. BH_UID
end

-- stack the real speakers and BlackHole into one device and make it default, so
-- the screen's sound is captured AND still audible. Returns true if it switched.
local function sysAudioOn()
  if not M.sysOn() then return false end
  local out = hs.audiodevice.defaultOutputDevice()
  local prev = out and out:uid()
  if not prev then return false end
  if out:name() ~= SR_MON then hs.settings.set("sbPrevOut", prev) end
  local _, ok = hs.execute(string.format('%q make %q stacked %q %q', SRBUS, SR_MON, prev, BH_UID))
  if not ok then note("couldn't build the monitor device — recording without system sound", 3.5) end
  return ok and true or false
end

-- 🚨 BUILDING IT IS NOT SELECTING IT. Caught on the first live test: the stacked
-- device was created, the previous output was saved, and the default output never
-- moved — so BlackHole received nothing and the take's audio track was silence.
-- srbus destroys and recreates the device, so this cannot run in the same breath
-- as the build; it runs after the beat CoreAudio needs to make it selectable.
local function sysAudioSelect()
  local mon = hs.audiodevice.findOutputByName(SR_MON)
  if mon then mon:setDefaultOutputDevice(); return true end
  note("the monitor device never appeared — no system sound in this take", 3.5)
  return false
end

-- 🚨 AND ALWAYS PUT IT BACK. Called from recStop, from the load-time guard, and
-- it is safe to call when nothing was ever switched.
local function sysAudioOff()
  local prev = hs.settings.get("sbPrevOut")
  if not prev then return end
  local d = hs.audiodevice.findDeviceByUID(prev)
  if d then d:setDefaultOutputDevice() end
  hs.settings.clear("sbPrevOut")
end
M.sysAudioOff = sysAudioOff
local rec = { pid = nil, task = nil, file = nil, t0 = nil, ring = nil, frame = nil, tick = nil }
-- 🚨 AIMING is the other half of "get out of the way". Recording already
-- parks the window on its own controls so the area stays clickable mid-take, but
-- until you press rec. the rectangle IS the window, so every click inside it
-- landed on the webview and he could not touch the thing he was framing. Clear
-- mode moves that same park up front: the window drops onto its controls, a
-- canvas ring holds the frame (a canvas with no tracking element does not take
-- clicks, which is the whole trick), and the rect lives HERE rather than in the
-- page's layout — dragging the parked box moves it, rec. records it as-is.
-- 🚨 3, NOT 5, AND THAT NUMBER IS NOT FREE. The rectangle is inset exactly
-- INSET (3px) from the window, so a 3px stroke laid in that gutter has its OUTER
-- edge flush with the window's own side — which is what makes the green verticals
-- line up with the strip above them instead of sitting two pixels proud of it —
-- while its inner edge still stops short of the recorded rect, where
-- screencapture would have caught it.
local RING_M = 3
local aim = { rect = nil, frame = nil, ring = nil, titleH = TITLEBAR, off = nil, strip = nil }

-- 🚨 ONE THING DRAWS THE WHOLE OUTLINE. It used to be split: the rec row's CSS
-- border drew the top and this canvas drew the other three sides. They could
-- never meet, because the window's own bottom corners are rounded by macOS and
-- a straight canvas line has no idea — so every corner showed a notch where the
-- cream curved away from the green. Now the canvas draws a rounded rectangle,
-- all four sides, all four corners, one stroke weight, and the page draws no
-- green at all. Nothing has to line up with anything.
--
-- RING_M is 3 and that is not free: the rectangle is inset exactly INSET (3px)
-- from the window, so a 3px stroke laid in that gutter has its outer edge flush
-- with the window's side while its inner edge stops short of the recorded rect,
-- where screencapture would have caught it.
local RING_R    = 10                             -- the window's own corner radius
-- 🚨 THE ROUNDED CORNERS GO WHERE THEY CANNOT BE SEEN. macOS rounds a window's
-- bottom corners and no page can square them, so the window simply does not END
-- at the strip any more: it runs RING_TAIL px further down and that tail is
-- TRANSPARENT. The chrome paints itself (header, tabs and the rec row each carry
-- their own background); the body does not, so the last few pixels of window,
-- corners included, are invisible. What you see ending is #recbar's own bottom
-- edge, and that is square because it is a CSS box. Nothing is painted over
-- anything and there is no colour left to mismatch.
local RING_TAIL = 16

-- 🚨 NO PATCHES. NO PAINTING OVER ANYTHING. The window's bottom corners are
-- rounded by macOS and that is simply a fact about the window — the previous
-- attempt laid a small square of the strip's own colour over each corner to fake
-- a square edge, and all that produced was two little blocks sitting above the
-- text where the colour did not quite match. Fighting the platform for two
-- pixels is not worth two visible artefacts.
--
-- So the outline follows the window instead. It is still a U — no top edge,
-- because the strip's own bottom edge is that line — but both ENDS now curve
-- inward on the same radius the window uses, so each vertical runs into the
-- corner along the same arc the cream (or the black) is already tracing. It
-- lines up because it is the same curve, not because something is covering
-- something else. Same 3px weight the whole way round.
local function recRing(x, y, w, h)
  local m = RING_M
  local cw, ch = w + m * 2, h + m * 2
  local c = hs.canvas.new({ x = x - m, y = y - m, w = cw, h = ch })
  c:level(hs.canvas.windowLevels.overlay)
  -- 🚨 THE BOX IS ONE OBJECT, AND IT STAYS ON ITS OWN DESKTOP. This used to
  -- be canJoinAllSpaces while the strip above it was an ordinary window on one
  -- Space -- so switching desktops tore the box in half: the two verticals and
  -- the bottom followed you everywhere, over pages that had no box on them and
  -- with no bar left to close them from. Default behaviour keeps the ring where
  -- clear. was pressed, next to the strip that owns it. Another desktop shows
  -- nothing until clear. is pressed over THAT one.
  c:behavior(hs.canvas.windowBehaviors.default)
  local L, R, T, B = 1.5, cw - 1.5, 1.5, ch - 1.5
  local r = math.max(0, math.min(RING_R, math.floor(w / 4), math.floor(h / 4)))
  local k = r * 0.5523                           -- quarter-circle bezier constant
  c[1] = { type = "segments", action = "stroke", strokeWidth = 3, closed = false,
           strokeColor = { hex = (M.accent and M.accent()) or "#AACC00", alpha = 0.95 },
           strokeCapStyle = "butt", strokeJoinStyle = "round",
           -- 🚨 SQUARE AT THE TOP, ROUNDED AT THE BOTTOM. The tops used to curl
           -- inward to trace the window's rounded corner — but the strip does not
           -- have a rounded corner any more, so a curve there was the outline
           -- bending away from a square edge. They run straight up into it now.
           coordinates = {
             { x = L,     y = T },
             { x = L,     y = B - r },
             { x = L + r, y = B, c1x = L,         c1y = B - r + k, c2x = L + r - k, c2y = B },
             { x = R - r, y = B },
             { x = R,     y = B - r, c1x = R - r + k, c1y = B,     c2x = R,         c2y = B - r + k },
             { x = R,     y = T },
           } }
  c:show()
  return c
end

-- 🚨 the stroke is the accent, so it has to be repainted when the accent moves.
-- Nothing else in here is a theme colour any more, which is the point.
local function ringRepaint()
  if not aim.ring then return end
  pcall(function()
    aim.ring[1].strokeColor = { hex = (M.accent and M.accent()) or "#AACC00", alpha = 0.95 }
  end)
end
M.ringRepaint = ringRepaint

local ringMoveTimer, ringHidden = nil, false
local function ringFollow()
  -- 🚨 HIDE ONCE PER DRAG, not once per EVENT. frameChange fires about sixty
  -- times a second and this was calling hide() on every one of them — sixty
  -- window-server round trips a second, on the same thread animating the drag,
  -- to hide a window that was already hidden after the first. That is what made
  -- the strip lag behind the pointer. One hide, one show, and the flag is what
  -- makes the difference.
  if aim.ring and not ringHidden then aim.ring:hide(); ringHidden = true end
  if ringMoveTimer then ringMoveTimer:stop() end
  ringMoveTimer = hs.timer.doAfter(0.12, function()
    ringMoveTimer = nil
    if aim.ring and aim.rect then
      aim.ring:topLeft({ x = aim.rect.x - RING_M, y = aim.rect.y - RING_M })
      aim.ring:show()
    end
    ringHidden = false
  end)
end

function M.recOn() return rec.pid ~= nil end

-- 🚨 The page CANNOT work out where it is on screen. In a WKWebView
-- window.screenX/screenY report nonsense (0 / the screen height), so the region
-- arrives here in viewport coordinates and the screen maths is done from the
-- window's own frame: x is the frame's, y is the frame's plus the title bar,
-- which is exactly frame.h minus the viewport height.
function M.recFromPage(d)
  if not (wv and type(d) == "table") then return false end
  -- clear mode already parked the window somewhere else entirely; the page's
  -- own rectangle no longer means anything, the stored one is the take
  if aim.rect then
    return M.recStart(aim.rect.x, aim.rect.y, aim.rect.w, aim.rect.h, nil, d.innerH)
  end
  local f  = wv:frame()
  local tb = f.h - (d.innerH or f.h)
  return M.recStart(f.x + (d.left or 0), f.y + tb + (d.top or 0),
                    d.w or 0, d.h or 0, d.chrome, d.innerH)
end

-- ── the clipboard shelf's ★, shown here as its own shelf ─────────────
-- 🚨 NOTHING IS DUPLICATED (his call). The shelf already keeps its favourites
-- as real files in clip-favorites/; this reads that folder and lists what is in
-- it. Opening one opens the file the shelf owns. scrn.brd never copies it, never
-- moves it and never deletes it — the shelf is the owner, this is a window onto it.
local function shelfDir()
  local d = _G.cbFavDir and cbFavDir() or (HOME .. "/.hammerspoon/clip-favorites")
  return d
end
shelfItems = function()
  local out, dir = {}, shelfDir()
  if hs.fs.attributes(dir, "mode") ~= "directory" then return out end
  local function scan(base, label)
    local ok = pcall(function()
      for f in hs.fs.dir(base) do
        if not f:match("^%.") then
          local full = base .. "/" .. f
          local a = hs.fs.attributes(full)
          if a and a.mode == "directory" then
            scan(full, f)
          elseif a and a.mode == "file" then
            local ext = f:match("%.(%w+)$") or ""
            out[#out + 1] = { path = full, name = f, folder = label or "",
                              ext = ext:upper(), t = a.modification or os.time(),
                              thumb = ext:lower():match("^(png|jpg|jpeg|gif|heic|tiff|bmp|webp)$")
                                      and thumb(full) or nil }
          end
        end
      end
    end)
    return ok
  end
  scan(dir, nil)
  table.sort(out, function(x, y) return (x.t or 0) > (y.t or 0) end)
  return out
end

-- ── assets: files that live somewhere else ───────────────────────────
function M.addAssets()
  local r = hs.dialog.chooseFileOrFolder("keep a reference to…", HOME, true, false, true)
  if type(r) ~= "table" then return 0 end
  local n = 0
  for _, path in pairs(r) do
    path = tostring(path):gsub("^file://", "")
                         :gsub("%%(%x%x)", function(c) return string.char(tonumber(c, 16)) end)
    if hs.fs.attributes(path) then
      local dupe = false
      for _, a in ipairs(assets) do if a.path == path then dupe = true end end
      if not dupe then
        assets[#assets + 1] = { path = path, t = os.time() }
        n = n + 1
      end
    end
  end
  if n > 0 then save(); render(); note(("%d asset%s referenced"):format(n, n == 1 and "" or "s"), 2) end
  return n
end

-- ── clear mode: the window steps off the rectangle before the take ────
function M.clearOn() return aim.rect ~= nil end

-- d is the same viewport rect rec. sends, converted here the same way — see the
-- note on recFromPage for why the screen maths cannot happen in the page.
function M.aimClear(d)
  if not (wv and type(d) == "table") or aim.rect then return false end
  local f  = wv:frame()
  local tb = f.h - (d.innerH or f.h)
  local r  = { x = math.floor(f.x + (d.left or 0)), y = math.floor(f.y + tb + (d.top or 0)),
               w = math.floor(d.w or 0), h = math.floor(d.h or 0) }
  if r.w < 40 or r.h < 40 then note("that area is too small to frame", 2); return false end
  aim.rect, aim.titleH, aim.strip = r, tb, math.floor(d.chrome or 120) + tb
  -- how far the rectangle sits inside the window: the ONLY way back from a rect
  -- to the window that frames it, and the parked box gets dragged around, so the
  -- frame aim. restores has to be worked out from where the rect ended up —
  -- never from where the window was when clear. was pressed.
  aim.off   = { left = d.left or 0, top = d.top or 0 }
  aim.frame = { w = f.w, h = f.h }                     -- the size aim. puts back
  aim.ring, ringHidden = recRing(r.x, r.y, r.w, r.h), false
  aim.zoomAsk = nil
  -- 🚨 THE WHOLE UI COMES WITH IT (his call). The window does not shrink to a
  -- 176px readout any more — it becomes a STRIP: header, tabs and the rec row,
  -- full width, sitting directly ABOVE the rectangle instead of on top of it.
  -- Everything he can normally reach is still there, and the rectangle below is
  -- a canvas ring with nothing over it, so every click inside lands on the app
  -- he is framing. `chrome` is the strip's height, measured in the page — it is
  -- the one number this side cannot work out for itself.
  --
  -- Opaque while parked: proven live, a transparent window does not composite
  -- its content once it is this short. Transparency is only wanted while the
  -- window is actually OVER the rectangle, which parked it never is.
  wv:frame({ x = r.x - (d.left or 0), y = r.y - aim.strip,
             w = r.w + (d.left or 0) * 2, h = aim.strip + RING_TAIL })
  -- 🚨 THE STRIP RIDES AT THE RING'S LEVEL. floating is 3, and Quick Look's
  -- panel outranks it -- so previewing anything over the box buried the header,
  -- the tabs and the rec row under the preview while the green outline (overlay,
  -- 102) went on drawing over the top of it. Half the box in front, half behind.
  -- Both halves are overlay now: the controls stay reachable, whatever is being
  -- framed stays behind them, and the box reads as one object again.
  wv:level(hs.canvas.windowLevels.overlay)   -- or the first click he makes buries it

  wv:evaluateJavaScript("SB.clear(true)")
  snapSync()                          -- no snapping onto a parked box
  return true
end

-- the ring is a real window: drop it on every way out of clear mode, including
-- the ones where the webview is already going away.
local function aimDrop()
  if aim.ring then aim.ring:delete(); aim.ring = nil end
  aim.rect, aim.frame, aim.off = nil, nil, nil
end

function M.aimBack()
  if not aim.rect then return false end
  if wv then
    -- back around the rectangle where it is NOW, at the size the window had
    if aim.frame and not rec.pid then
      easeTo({ x = aim.rect.x - (aim.off and aim.off.left or 0),
               y = aim.rect.y - (aim.off and aim.off.top or 0) - (aim.titleH or TITLEBAR),
               w = aim.frame.w, h = aim.frame.h }, 0.20)
      wv:transparent(true)                     -- back over the rectangle: see-through again
    end
    wv:level(M.topOn() and hs.drawing.windowLevels.floating
                        or hs.drawing.windowLevels.normal)
    wv:evaluateJavaScript("SB.clear(false)")
  end
  aimDrop()
  snapSync()
  return true
end


-- ── Magnet's shortcuts, on this window too ────────────────────
-- 🚨 Magnet WILL NOT TOUCH THIS WINDOW and never will: it is an NSPanel owned
-- by an LSUIElement app, which every window manager skips. So the board keeps
-- his own bindings for itself, read straight off Magnet's preferences so there
-- is one set of keys to learn: ⌘← ⌘→ halves, ⌘↓ bottom, ⌘↑ maximise, and
-- ⌘⇧↑ ⌘⇧← ⌘⇧→ for the top half and the top quarters.
--
-- An eventtap, NOT hs.hotkey: Magnet has these same combos registered as Carbon
-- hotkeys since login, and two registrations of one combo is a coin toss. A
-- session tap sees the keystroke before Carbon dispatch, so swallowing it here
-- means ours runs and Magnet's does not — and the tap only exists while the
-- board is the focused window, so every other app's ⌘← is untouched.
--
-- 🚨 …and not while he is TYPING. ⌘← is "start of line" in a note, ⌘↑ is "top
-- of the note". The page says when a field takes focus and the tap goes off.
local snapTap, snapFocus, snapTyping = nil, false, false

local function snapRect(where)
  if not wv then return nil end
  local f = wv:frame()
  local scr = hs.screen.find(hs.geometry.point(f.x + f.w / 2, f.y + f.h / 2)) or hs.screen.mainScreen()
  local s = scr:frame()                       -- menu bar and Dock already taken off
  local hw, hh = math.floor(s.w / 2), math.floor(s.h / 2)
  if where == "left"   then return { x = s.x,      y = s.y,      w = hw,       h = s.h } end
  if where == "right"  then return { x = s.x + hw, y = s.y,      w = s.w - hw, h = s.h } end
  if where == "top"    then return { x = s.x,      y = s.y,      w = s.w,      h = hh } end
  if where == "bottom" then return { x = s.x,      y = s.y + hh, w = s.w,      h = s.h - hh } end
  if where == "tl"     then return { x = s.x,      y = s.y,      w = hw,       h = hh } end
  if where == "tr"     then return { x = s.x + hw, y = s.y,      w = s.w - hw, h = hh } end
  if where == "max"    then return { x = s.x,      y = s.y,      w = s.w,      h = s.h } end
  return nil
end

local function snapKeyFor(e)
  local f, c, K = e:getFlags(), e:getKeyCode(), hs.keycodes.map
  if f:containExactly({ "cmd" }) then
    if c == K.left then return "left"   elseif c == K.right then return "right"
    elseif c == K.down then return "bottom" elseif c == K.up then return "max" end
  elseif f:containExactly({ "cmd", "shift" }) then
    if c == K.up then return "top" elseif c == K.left then return "tl"
    elseif c == K.right then return "tr" end
  end
  return nil
end

snapSync = function()
  -- never while a take is running or the window is parked on the rectangle:
  -- moving it then would either move the readout out of the shot or desync the
  -- frame, since a programmatic wv:frame() fires no frameChange to follow.
  local want = snapFocus and not snapTyping and not rec.pid and not aim.rect and wv ~= nil
  if want and not snapTap then
    snapTap = hs.eventtap.new({ hs.eventtap.event.types.keyDown }, function(e)
      local where = snapKeyFor(e); if not where then return false end
      local r = snapRect(where); if not r then return false end
      if wv then wv:frame(r); hs.settings.set("sbFrame",
        { x = r.x, y = r.y + TITLEBAR, w = r.w, h = r.h - TITLEBAR }) end
      return true                                   -- swallowed, so Magnet stays out of it
    end)
    snapTap:start()
  elseif not want and snapTap then
    snapTap:stop(); snapTap = nil
  end
end

-- chromeH/innerH come from the page: chromeH is the solid bar the window shrinks
-- to, innerH its viewport height, and the difference from the window frame is the
-- title bar. Doing the arithmetic there means nothing here has to guess at it.
--
-- 🚨 "full ui." (M.recFullOn) is the second capture mode, alongside the
-- "clear area" one above: instead of the transparent #region rect the page
-- measured, record the whole app — chrome, tabs, the rec. row, the green
-- outline, all of it — and let the framed area go on showing whatever is
-- underneath it. Nothing here has to fight the window for room because
-- nothing moves.
--
-- 🚨 IT OUTRANKS CLEAR MODE NOW, it does not defer to it (his call: "it just
-- records this entire app and whatever is underneath it in the transparent
-- box"). Parked, the app is TWO objects on screen — the strip up top and the
-- green box under it — so "the window" alone would record the strip and drop
-- the framed area on the floor, which is why full ui. used to look like it did
-- nothing at all whenever clear. had been pressed. The take is the rectangle
-- that CONTAINS the pair, ring included: exactly what he is looking at.
function M.recStart(x, y, w, h, chromeH, innerH)
  if rec.pid then return false end
  local keepUI = M.recFullOn()
  if keepUI and wv then
    local f = wv:frame()
    local l, t, r2, b = f.x, f.y, f.x + f.w, f.y + f.h
    -- RING_M out on every side, because the green outline is part of the app as
    -- he sees it and has to land INSIDE the shot, not a hair outside it. Grown
    -- from aim.rect rather than read off aim.ring: the canvas lags a drag by the
    -- 120ms move debounce, and the rect never does.
    local g = aim.rect
    if g then
      l,  t = math.min(l, g.x - RING_M),         math.min(t, g.y - RING_M)
      r2, b = math.max(r2, g.x + g.w + RING_M),  math.max(b, g.y + g.h + RING_M)
    end
    x, y, w, h = l, t, r2 - l, b - t
  end
  x, y, w, h = math.floor(x or 0), math.floor(y or 0), math.floor(w or 0), math.floor(h or 0)
  if w < 40 or h < 40 then note("that area is too small to record", 2); return false end
  hs.execute(("/bin/mkdir -p %q"):format(M.recDest()))
  rec.file = ("%s/%s.mov"):format(M.recDest(), (stem():gsub("^scrn%.brd", "scrn.brd-rec")))
  -- 🚨 THE MONITOR DEVICE HAS TO EXIST BEFORE THE CAPTURE LAUNCHES, and srbus
  -- destroys and recreates it, so CoreAudio needs a beat before it is selectable.
  -- That is the one reason this is not a straight-through function any more.
  local switched = sysAudioOn()
  local cmd = string.format(
    'F=$(mktemp -u); mkfifo "$F"; exec 3<>"$F"; rm -f "$F"; exec %s -v%s -R%d,%d,%d,%d \'%s\' <&3',
    SCAP, audioFlag(), x, y, w, h, (rec.file:gsub("'", "'\\''")))
  local function launch()
    if rec.file == nil then return end                -- stopped before it ever began
    rec.task = hs.task.new("/bin/sh", nil, { "-c", cmd })
    rec.task:start()
    rec.pid = rec.task:pid()
  end
  rec.t0 = os.time()
  rec.pid = -1                                        -- claimed, so a second press cannot race
  if switched then
    M.audioTimer = hs.timer.doAfter(0.35, function() sysAudioSelect(); launch() end)
  else
    launch()
  end
  escOn()                                             -- esc stops it from anywhere
  -- clear mode's ring is already on it, and full ui. needs none: the recorded
  -- rect IS the window, whose own accent border is the outline, in the shot
  rec.ring = (aim.ring or keepUI) and nil or recRing(x, y, w, h)
  if wv and (aim.rect or keepUI) then
    -- nothing to move, either way: clear mode parked the window on its own
    -- controls before the take, and full ui. wants it left exactly where it is.
    -- rec.frame stays nil, so recStop has nothing to restore.
    wv:evaluateJavaScript("SB.rec(true,0)")
  elseif wv then
    local f = wv:frame()
    rec.frame = { x = f.x, y = f.y, w = f.w, h = f.h }
    -- 🚨 GET OUT OF THE WAY. screencapture -R records a SCREEN rectangle — this
    -- window never had to be over it. Leaving the window full size meant the
    -- transparent region swallowed every click in the recorded area and he could
    -- not use his Mac while a take was running. So the window shrinks onto just
    -- the rec. button and its clock, parked at the top-left INSIDE the rectangle
    -- (the page hides everything else while `recording`): the controls stay in
    -- the take, and the entire rest of the area is his again.
    local titleH = (innerH and innerH > 0) and (f.h - innerH) or 28
    wv:frame({ x = x, y = y - titleH, w = 176, h = titleH + 60 })
    wv:transparent(false)                      -- same reason as clear mode: it must draw
    wv:evaluateJavaScript("SB.rec(true,0)")
  end
  rec.tick = hs.timer.doEvery(1, function()
    if wv and rec.t0 then
      wv:evaluateJavaScript(("SB.rec(true,%d)"):format(os.time() - rec.t0))
    end
  end)
  return true
end

-- 🚨 ESC IS ONLY BOUND WHILE THE CAMERA IS ROLLING. Grabbing Escape globally
-- for the life of the app would steal it from every other window; bound at the
-- start of a take and deleted at the end, it costs nothing the rest of the time.
local escKey = nil
escOn = function()
  if escKey then return end
  escKey = hs.hotkey.bind({}, "escape", function() M.recStop(); M.aimBack() end)
end
local function escOff()
  if escKey then pcall(function() escKey:delete() end); escKey = nil end
end
M.escOff = escOff

-- 🚨 EASED, NOT SNAPPED (his words: "shrink down with like a nice animation").
-- hs.webview:frame() has no duration — hs.window:setFrame() does, so the animation
-- goes through the AX window. Falling back to the instant set matters: hswindow()
-- returns nil whenever the window is hidden or miniaturised, and a frame that
-- silently never got restored is worse than one that arrives without the ease.
easeTo = function(f, secs)
  if not (wv and f) then return end
  local w = wv:hswindow()
  if w then w:setFrame(f, secs or 0.22) else wv:frame(f) end
end
M.easeTo = easeTo

function M.recStop()
  if not rec.pid then return false end
  escOff()
  sysAudioOff()                        -- his speakers come back before anything else
  if M.audioTimer then M.audioTimer:stop(); M.audioTimer = nil end
  if rec.pid > 0 then
    os.execute("kill -INT " .. rec.pid .. " 2>/dev/null") -- SIGINT finalizes the .mov
  end
  local secs, file = os.time() - (rec.t0 or os.time()), rec.file
  rec.pid, rec.task, rec.t0 = nil, nil, nil
  if rec.tick then rec.tick:stop(); rec.tick = nil end
  if rec.ring then rec.ring:delete(); rec.ring = nil end
  if wv then
    if rec.frame then easeTo(rec.frame, 0.22); wv:transparent(true) end
    wv:evaluateJavaScript("SB.rec(false,0)")
  end
  rec.frame = nil
  -- screencapture writes the moov atom after the signal; don't judge it instantly
  M.recTimer = hs.timer.doAfter(1.0, function()
    local a = file and hs.fs.attributes(file)
    if a and (a.size or 0) > 0 then
      recs[#recs + 1] = { file = file, t = os.time(), secs = secs }
      save(); render()                      -- it shows up in arch. the moment it lands
      if wv then wv:evaluateJavaScript(("SB.recdone(%s,%d)"):format(q(short(file)), secs)) end
      note(("● rec · %ds → %s"):format(secs, short(file)), 2.6)
    else
      -- the one failure that looks like nothing happening at all
      note("no file written — grant Hammerspoon Screen Recording", 4.5)
    end
  end)
  return true
end

function M.recReveal()
  if rec.file and hs.fs.attributes(rec.file) then
    hs.execute(("/usr/bin/open -R %q"):format(rec.file))
  end
end

-- ── the still camera ─────────────────────────────────────────────────
-- pic. is the rec. tab's OTHER shutter: the same framed rectangle, one PNG
-- instead of a take. It lands on the board through M.add, which means the
-- archive, the star, the note field and the trash all already work on it —
-- nothing here has to know what a shot is or where shots live.
--
-- Two standing preferences, both on the row with mic./sys. rather than buried
-- in ⚙, because that is what Photo Booth puts on screen: 3s. counts down in the
-- frame before the shutter, flash. washes the screen white after it.
--
-- 🚨 THE FLASH FIRES AFTER THE GRAB, NEVER BEFORE. Photo Booth's flash lights
-- the ROOM, for a camera pointed at you; this camera is pointed at the screen,
-- so a white wash thrown before the shutter would BE the picture. It is the
-- confirmation that the shutter went, not a light to shoot by.
function M.picTimerOn() return hs.settings.get("sbPicTimer") == true end
function M.picFlashOn() return hs.settings.get("sbPicFlash") ~= false end  -- on until turned off

local pic = { busy = false }

--  A TIMER NOBODY HOLDS IS A TIMER THE COLLECTOR EATS. This fired the
-- flash and then handed the doAfter that takes it down to nobody: Lua collected
-- the timer before it ever ran, the canvas had no other way off the screen, and
-- the Mac was left painted white until Hammerspoon was reloaded. Every timer in
-- here is parked on `pic` for exactly that reason, and the canvas with it — so
-- there is always a handle on the white, from the moment it goes up.
local function flashOff()
  if pic.flashT then pic.flashT:stop(); pic.flashT = nil end
  if pic.flash  then pic.flash:delete(); pic.flash = nil end
end
M.flashOff = flashOff
_G.sbFlashOff = flashOff              -- the way out if it ever gets stuck again

local function picFlash(x, y, w, h)
  flashOff()                          -- never two sheets of white at once
  local scr = hs.screen.find(hs.geometry.point(x + w / 2, y + h / 2)) or hs.screen.mainScreen()
  local c = hs.canvas.new(scr:fullFrame())
  c:level(hs.canvas.windowLevels.screenSaver)
  c[1] = { type = "rectangle", action = "fill", fillColor = { white = 1, alpha = 0.92 } }
  c:show()
  pic.flash = c
-- 🚨 SOLID LONG ENOUGH TO SEE. At 50ms + a 0.3s fade this was over before it
  -- registered as anything — invisible on the screen and impossible to catch in
  -- a screenshot, which is not a flash, it is a flicker. Photo Booth's is about
  -- half a second end to end and that is what this is now.
  pic.flashT = hs.timer.doAfter(0.12, function()
    pic.flashT = nil
    if pic.flash then pic.flash:delete(0.45); pic.flash = nil end
  end)
  --  AND A DEAD MAN'S SWITCH. Whatever happens above — a fade that never
  -- completes, an exception in between — this second timer takes the canvas away
  -- by force. The white is the one failure in this app that stops him using the
  -- computer at all, so it gets two independent ways down.
  pic.deadT = hs.timer.doAfter(1.6, function()
    pic.deadT = nil
    if pic.flash then pic.flash:delete(); pic.flash = nil end
  end)
end

-- 3 · 2 · 1, big, in the middle of the frame — and DELETED before the shutter,
-- or the number is what gets photographed.
local function picCount(x, y, w, h, from, done)
  local s = math.max(48, math.min(200, math.floor(math.min(w, h) * 0.4)))
  local c = hs.canvas.new({ x = math.floor(x + w / 2 - s), y = math.floor(y + h / 2 - s * 0.72),
                            w = s * 2, h = math.floor(s * 1.45) })
  c:level(hs.canvas.windowLevels.overlay)
  c[1] = { type = "text", text = tostring(from), textAlignment = "center",
           textSize = s, textFont = "Helvetica-Bold",
           textColor = { white = 1, alpha = 0.9 } }
  c:show()
  local n = from
  pic.tick = hs.timer.doEvery(1, function()
    n = n - 1
    if n <= 0 then
      if pic.tick then pic.tick:stop(); pic.tick = nil end
      c:delete(); done()
    else
      c[1].text = tostring(n)
    end
  end)
end

function M.picShoot(x, y, w, h)
  if rec.pid then note("not while a take is rolling", 2); return false end
  if pic.busy then return false end
  -- full ui. means the same thing it means for a take: the picture is the app
  -- itself, green ring and all, not the hole in the middle of it.
  local keepUI = M.recFullOn()
  if keepUI and wv then
    local f = wv:frame()
    local l, t, r2, b = f.x, f.y, f.x + f.w, f.y + f.h
    local g = aim.rect
    if g then
      l,  t = math.min(l, g.x - RING_M),        math.min(t, g.y - RING_M)
      r2, b = math.max(r2, g.x + g.w + RING_M), math.max(b, g.y + g.h + RING_M)
    end
    x, y, w, h = l, t, r2 - l, b - t
  end
  x, y, w, h = math.floor(x or 0), math.floor(y or 0), math.floor(w or 0), math.floor(h or 0)
  if w < 20 or h < 20 then note("that area is too small to photograph", 2); return false end
  pic.busy = true
  local function shutter()
    -- 🚨 GET OUT OF THE WAY, the still version. A take does it by shrinking the
    -- window onto its own controls and leaving it there; a photo is over in a
    -- frame, so the window simply goes to alpha 0 for the length of the grab and
    -- comes straight back. NOT hide(): that reorders the window and takes the
    -- focus with it. Skipped entirely in full ui., where the window IS the photo.
    local step = (not keepUI) and wv or nil
    if step then wv:alpha(0) end
    -- held on `pic` for the same reason the flash is: an unheld doAfter here
    -- would leave the window at alpha 0 — invisible, with no way back.
    pic.shotT = hs.timer.doAfter(step and 0.13 or 0, function()
      pic.shotT = nil
      local tmp = ("%sscrnbrd-pic-%d-%04d.png"):format(os.getenv("TMPDIR") or "/tmp/",
                                                       os.time(), math.random(0, 9999))
      -- no -x on purpose: screencapture's own shutter click is the sound a
      -- photograph makes, and it is the only feedback a no-flash shot gets.
      -- 🚨 HELD, like everything else in here. An hs.task nobody references can be
      -- collected mid-run, and this one's callback is what brings the window back
      -- from alpha 0 and files the photo — losing it loses both.
      pic.task = hs.task.new(SCAP, function()
        pic.task = nil
        if step then wv:alpha(1) end
        if M.picFlashOn() then picFlash(x, y, w, h) end
        pic.busy = false
        local img = hs.fs.attributes(tmp) and hs.image.imageFromPath(tmp)
        if img then
          local sz = img:size()
          M.picAdd(tmp, math.floor(sz.w + 0.5), math.floor(sz.h + 0.5))
          os.remove(tmp)
          note(("▣ pic · %d × %d"):format(w, h), 1.4)
        else
          -- the one failure that looks like nothing happening at all
          note("no picture written — grant Hammerspoon Screen Recording", 4.5)
        end
      end, { ("-R%d,%d,%d,%d"):format(x, y, w, h), tmp })
      pic.task:start()
    end)
  end
  if M.picTimerOn() then picCount(x, y, w, h, 3, shutter) else shutter() end
  return true
end

-- The rectangle, worked out exactly the way rec. works it out: in clear mode the
-- page's own rect means nothing any more and the stored one is the frame.
function M.picFromPage(d)
  if not (wv and type(d) == "table") then return false end
  if aim.rect then
    return M.picShoot(aim.rect.x, aim.rect.y, aim.rect.w, aim.rect.h)
  end
  local f  = wv:frame()
  local tb = f.h - (d.innerH or f.h)
  return M.picShoot(f.x + (d.left or 0), f.y + tb + (d.top or 0), d.w or 0, d.h or 0)
end

-- ── hand the board to Claude ─────────────────────────────────────────
-- Three destinations: a NEW conversation, whatever is already open, or a named
-- one picked off the list in Claude's own sidebar. There is no API for that list,
-- but the sidebar rows are real accessibility elements once AXManualAccessibility
-- is switched on, so we can both READ their titles and press the right one.
-- Text and picture go in through Claude's Edit ▸ Paste menu item rather than a
-- synthetic ⌘V — more reliable, and it doesn't trip the clipboard shelf's ⌘V tap.
-- 🚨 This one DOES send (his ask): after the paste lands, we press Return.
local CLAUDE_ID = "com.anthropic.claudefordesktop"

-- Rows in the sidebar list, as { raw = <exact AX title>, label = <cleaned> }.
-- Claude prefixes each row with a status word ("Idle …"); the raw title is what
-- we press with, the cleaned one is what the dropdown shows.
local STATUS_WORDS = { Idle = 1, Running = 1, Working = 1, Queued = 1, Paused = 1,
                       Error = 1, Failed = 1, Done = 1, Waiting = 1, Thinking = 1, Active = 1 }
local function claudeRows()
  local app = hs.application.get(CLAUDE_ID)
  if not app then return {} end
  local ax = hs.axuielement
  local root = ax.applicationElement(app)
  -- Electron only publishes its web content to accessibility once a client asks
  root:setAttributeValue("AXManualAccessibility", true)
  local win = root:attributeValue("AXFocusedWindow")
  if not win then win = (root:attributeValue("AXWindows") or {})[1] end
  if not win then return {} end
  local found, n = {}, 0
  local function walk(e, d)
    -- 🚨 DEPTH 60, not 20. Claude nests its sidebar deeper than twenty levels
    -- and the walk was stopping above it: measured 38 nodes visited and ZERO
    -- rows found before the cap bit, on a tree that yields rows fine at 60. That
    -- is what made the conversation list come back empty at random — and an
    -- empty list is how a send ends up in the wrong conversation. The node
    -- budget is the real guard (a node costs ~0.2ms, so 6000 is about a second
    -- worst case); depth is only here to stop a cycle.
    n = n + 1; if d > 60 or n > 6000 then return end
    if e:attributeValue("AXRole") == "AXButton" then
      local t = e:attributeValue("AXTitle") or e:attributeValue("AXDescription") or ""
      local f = e:attributeValue("AXFrame")
      -- a real row is full sidebar width and actually laid out; the section
      -- headers above it sit one group shallower, which is what depth sorts out
      if #t > 1 and f and f.w and f.w >= 300 and f.h and f.h >= 20 then
        found[#found + 1] = { d = d, raw = t, el = e }
      end
    end
    for _, c in ipairs(e:attributeValue("AXChildren") or {}) do walk(c, d + 1) end
  end
  walk(win, 0)
  local deepest = 0
  for _, r in ipairs(found) do if r.d > deepest then deepest = r.d end end
  local rows = {}
  for _, r in ipairs(found) do
    if r.d == deepest then
      local first, rest = r.raw:match("^(%a+)%s+(.+)$")
      rows[#rows + 1] = { raw = r.raw, el = r.el,
                          label = (first and STATUS_WORDS[first] and rest) or r.raw }
    end
  end
  return rows
end

-- titles only, for the page's dropdown
function M.chatList()
  local out = {}
  for _, r in ipairs(claudeRows()) do out[#out + 1] = { raw = r.raw, label = r.label } end
  return out
end

-- press the sidebar row whose exact title we were handed
-- 🚨 The rows are re-read HERE, not reused from the dropdown — and their titles
-- carry a live status word ("Idle …", and it changes while a conversation runs).
-- So the raw string captured when he opened the list is routinely NOT the raw
-- string by the time he presses send, and an exact match on it silently misses.
-- Match the raw first, then the label the status word was stripped off, then a
-- contains either way round. Returns whether it actually pressed something.
local function openChat(raw)
  if not raw or raw == "" then return false end
  local rows = claudeRows()
  local want = raw:lower()
  local function press(r) r.el:performAction("AXPress"); return true end
  for _, r in ipairs(rows) do if r.raw == raw then return press(r) end end
  for _, r in ipairs(rows) do if (r.label or "") == raw then return press(r) end end
  for _, r in ipairs(rows) do
    local a, b = (r.raw or ""):lower(), (r.label or ""):lower()
    if a:find(want, 1, true) or b:find(want, 1, true)
       or (#b > 0 and want:find(b, 1, true)) then return press(r) end
  end
  return false
end

local function claudeText(items)
  items = items or board
  local n = #items
  return markdown(("%d screenshot%s from my scrn.brd, attached above as one "
    .. "stitched sheet. Each panel is numbered in its top-left corner; the "
    .. "numbered headings below are the note for that panel."):format(
    n, n == 1 and "" or "s"), items)
end

-- The intro for ONE shot sent on its own, rather than the whole sheet.
local function oneText(i)
  local it = board[i]; if not it then return "" end
  local out = { "A screenshot from my scrn.brd." }
  if meta.title ~= "" then out[1] = meta.title .. " — a screenshot from my scrn.brd." end
  out[#out + 1] = ""
  out[#out + 1] = (it.note or "") ~= "" and it.note or "(no note)"
  return table.concat(out, "\n")
end

-- where: "new" (File ▸ New Conversation) | "cur" (whatever is open) |
--        "pick" (press the sidebar row named `target`)
-- `only` = a single shot's index: that one picture goes over instead of the
-- stitched sheet, and the board is NOT cleared afterwards — sending one shot is
-- a quick aside, finishing the board is what spends it.
-- `only` is the per-card "send just this one"; `items` is a picked selection.
-- They meet in the same place: ONE picture goes over as itself, more than one
-- goes as a stitched sheet — which is also why picking a single tile and hitting
-- → cld. sends the bare shot rather than a one-panel sheet. Takes cannot be
-- pasted into a conversation at all, so they go over as paths in the text.
function M.toClaude(where, text, target, only, items)
  -- 🚨 WHOLE OR PART, decided here and nowhere else. The board is wiped after a
  -- send because a sent board is spent — but that is only true when the whole
  -- board went. Sending a PICKED three of twenty and then clearing all twenty
  -- would destroy the seventeen he did not send, so the wipe at the bottom asks
  -- this flag rather than asking whether `only` happened to be set.
  local whole = (only == nil and items == nil)
  items = items or (only and board[only] and { board[only] }) or board
  local imgs, vids = split(items)
  if #imgs == 0 and #vids == 0 then note("nothing on the board yet"); return false end
  local png
  if #imgs == 1 then
    png = imgs[1].img
  elseif #imgs > 1 then
    local sheet = composite(imgs)
    if not sheet then note("couldn't build the sheet"); return false end
    png = os.getenv("TMPDIR") .. "scrnbrd-export.png"
    sheet:saveToFile(png)
  end
  if #vids > 0 then
    -- 🚨 named, not attached. A .mov has no clipboard flavour Claude can take,
    -- and a take silently missing from a send is worse than a path he can open.
    local lines = { text, "", ("%d screen recording%s, by path:"):format(
      #vids, #vids == 1 and "" or "s") }
    for _, v in ipairs(vids) do lines[#lines + 1] = "- " .. v.vid end
    text = table.concat(lines, "\n")
  end

  local app = hs.application.launchOrFocusByBundleID(CLAUDE_ID) and hs.application.get(CLAUDE_ID)
  if not app then note("claude isn't running"); return false end
  app:activate()

  M.exportTimer = hs.timer.doAfter(0.8, function()
    local a = hs.application.get(CLAUDE_ID)
    if not a then return end
    if where == "new" then a:selectMenuItem({ "File", "New Conversation" })
    elseif where == "pick" and target and target ~= "" then
      -- 🚨 ABORT, do not carry on. This used to only toast and then fall through:
      -- it pasted the sheet and the message into whatever conversation happened
      -- to be open, pressed Return, and WIPED THE BOARD — so a send that went to
      -- the wrong chat also took the shots and notes with it. If we cannot put
      -- it where he asked, nothing is sent and nothing is cleared.
      if not openChat(target) then
        note("couldn't find that conversation — nothing sent, board kept", 4)
        return
      end
    end
    -- switching conversations re-renders the whole pane; give it the same head
    -- start a new conversation gets, or the paste lands in the old composer
    local settle = (where == "cur") and 0.2 or 1.2
    M.exportTimer2 = hs.timer.doAfter(settle, function()
      local a2 = hs.application.get(CLAUDE_ID); if not a2 then return end
      -- the picture first, so it attaches above whatever text follows. png is
      -- nil when the pick was takes only — there is nothing to attach, and the
      -- paths in the text are the whole message.
      local fh = png and io.open(png, "rb"); local data = fh and fh:read("*a")
      if fh then fh:close() end
      if data and #data > 0 then
        hs.pasteboard.writeDataForUTI("public.png", data)
        if _G.cbClaimPasteboard then cbClaimPasteboard() end   -- our own write; keep it out of history
        a2:selectMenuItem({ "Edit", "Paste" })
      end
      M.exportTimer3 = hs.timer.doAfter(1.4, function()
        local a3 = hs.application.get(CLAUDE_ID); if not a3 then return end
        hs.pasteboard.setContents(text)
        if _G.cbClaimPasteboard then cbClaimPasteboard() end
        a3:selectMenuItem({ "Edit", "Paste" })
        -- 🚨 and SEND. He pressed send on the board; making him press Return in
        -- Claude as well was the whole complaint. The image needs a moment to
        -- finish uploading or Return posts the text on its own, hence the wait.
        M.exportTimer4 = hs.timer.doAfter(1.6, function()
          if hs.application.frontmostApplication():bundleID() ~= CLAUDE_ID then
            note("→ claude · pasted — press ⏎ (claude lost focus)", 3.4); return
          end
          hs.eventtap.keyStroke({}, "return", 0)
          -- 🚨 his ask: the board is SPENT once it's been sent. Clear it, start a
          -- fresh one and get the window out of the way — anything he wanted to
          -- keep, he saved with sv.sep / sv.as.one before pressing send.
          if whole then
            wipe(true)
            M.stash()
            note("→ claude · sent · board cleared", 2.6)
          elseif only then
            note("→ claude · shot " .. only .. " sent", 2.4)
          else
            note(("→ claude · %d sent · board kept"):format(#items), 2.6)
          end
        end)
      end)
    end)
  end)
  return true
end

-- ── hand the board to the main brain ─────────────────────────────────
-- The second-brain app runs its own bridge (src/bridge.js) on this same Mac,
-- 127.0.0.1:8792 — no LAN hop, no host to configure. POST /run takes any
-- model from its catalog and returns text; there is no image field, so unlike
-- the Claude send this one only carries the board's markdown notes over, not
-- the composite sheet.
local BRIDGE_URL = "http://127.0.0.1:8792"
local function bridgeToken()
  local cfg = HOME .. "/.second-brain/supabase.json"
  local d = hs.fs.attributes(cfg) and hs.json.read(cfg)
  return type(d) == "table" and d.bridgeToken or nil
end

-- The catalog, fetched once and cached for the life of this Hammerspoon
-- session — restart it (or `hs.reload()`) to pick up new models.
local brainModelsCache = nil
function M.brainModels()
  if brainModelsCache then return brainModelsCache end
  local token = bridgeToken()
  if not token then return {} end
  local status, body = hs.http.get(BRIDGE_URL .. "/models", { ["x-brain-token"] = token })
  if status ~= 200 then return {} end
  local d = hs.json.decode(body or "")
  local all = (type(d) == "table" and d.models) or {}
  -- 🚨 "local:" models 404 through /run — only the pipeline stages got routed
  -- straight to Ollama, POST /run still sends them at OpenRouter, which has
  -- never heard of them. Verified live (2026-08-24). Leaving them out of the
  -- picker rather than offering an option proven to fail.
  brainModelsCache = {}
  for _, m in ipairs(all) do
    if not tostring(m.id or ""):match("^local:") then brainModelsCache[#brainModelsCache + 1] = m end
  end
  return brainModelsCache
end

-- 🚨 THE BRIDGE IS TEXT ONLY — it always was, which is why this one takes no
-- picture at all. A selection therefore changes only WHICH notes get described,
-- and takes are named by path here for the same reason they are in → cld.
function M.toBrain(model, text, only, items)
  if items == nil and #board == 0 then note("nothing on the board yet"); return false end
  local token = bridgeToken()
  if not token then
    note("brain bridge: no bridgeToken in ~/.second-brain/supabase.json", 3.4); return false
  end
  model = (model and model ~= "") and model or "anthropic/claude-sonnet-5"
  local prompt = (items and claudeText(items)) or (only and oneText(only)) or text
  if items then
    local _, vids = split(items)
    if #vids > 0 then
      local lines = { prompt, "", ("%d screen recording%s, by path:"):format(
        #vids, #vids == 1 and "" or "s") }
      for _, v in ipairs(vids) do lines[#lines + 1] = "- " .. v.vid end
      prompt = table.concat(lines, "\n")
    end
  end
  note("→ brn. · asking " .. model .. "…", 2)
  hs.http.asyncPost(BRIDGE_URL .. "/run", hs.json.encode({ model = model, prompt = prompt }),
    { ["x-brain-token"] = token, ["Content-Type"] = "application/json" },
    function(status, respBody)
      if status ~= 200 then note("→ brn. failed (http " .. tostring(status) .. ")", 3.4); return end
      local d = hs.json.decode(respBody or "")
      if type(d) ~= "table" or not d.ok then
        note("→ brn. error: " .. (type(d) == "table" and tostring(d.error) or "bad response"), 3.8)
        return
      end
      -- the reply is text only and can run long; the console is where he reads
      -- it, the toast just confirms it landed
      print(("[scrn.brd → brain, %s]\n%s"):format(model, d.text or ""))
      note(("→ brn. · %s replied — see the Hammerspoon console"):format(model), 3)
      if only then
        note("→ brn. · shot " .. only .. " sent", 2.4)
      else
        wipe(true)
        M.stash()
      end
    end)
  return true
end

-- Reverse image search, on an archived shot. Google's searchbyimage/Lens both
-- need a URL they can fetch — a local PNG has no such thing, and inventing one
-- would mean uploading his screenshots (which routinely hold personal, medical,
-- financial stuff) to some third-party host just to search them. So instead:
-- the image goes on the clipboard and Lens opens ready for a paste. One ⌘V in
-- the tab that opens, not zero clicks, but nothing of his leaves this Mac to
-- get there. Reuses the /open route the "→ brn." picker already authenticates
-- against — same bridgeToken, same bridge.
function M.revSearch(k)
  local it = k and arch[k]
  if not (it and hs.fs.attributes(it.img)) then note("that shot is gone", 2); return false end
  local img = hs.image.imageFromPath(it.img)
  if not img then note("couldn't read that image", 2); return false end
  hs.pasteboard.writeObjects(img)
  local token = bridgeToken()
  if not token then
    note("brain bridge: no bridgeToken — image is on the clipboard, open lens.google.com yourself", 4)
    return false
  end
  hs.http.asyncPost(BRIDGE_URL .. "/open", hs.json.encode({ url = "https://lens.google.com/" }),
    { ["x-brain-token"] = token, ["Content-Type"] = "application/json" },
    function(status)
      if status == 200 then note("→ brn. · image copied — ⌘V into Lens to search", 3)
      else note("→ brn. couldn't open (http " .. tostring(status) .. ") — image is still on the clipboard", 3.4) end
    end)
  return true
end

-- ★ → a name (his call, Aug 27 2026). Starring a shot fires init.lua's
-- aiNameImage: one headless agent looks at the PNG, answers with a few words,
-- and is gone. It only ever fills an EMPTY note — the note he types on the
-- card (before or after) always wins, so renaming by hand still works.
local function autoName(a, it)
  if not (_G.aiNameImage and a and a.img and (a.note or "") == "") then return end
  _G.aiNameImage(a.img, function(name)
    if a.fav and (a.note or "") == "" then a.note = name end
    if it and (it.note or "") == "" then it.note = name end
    save(); render()
  end)
end

-- ── messages from the page ───────────────────────────────────────────
local function msg(body)
  local what, arg = tostring(body or ""):match("^(%a+):(.*)$")
  if what == "note" then
    local num = arg:match("^(%d+)|")
    local i = tonumber(num)
    -- NOT a "^(%d+)|(.*)$" match: in a Lua pattern "." doesn't match a newline, so
    -- the moment he pressed Enter in a note the whole message stopped matching and
    -- the note silently stopped saving. Take the rest of the string by index.
    local text = num and arg:sub(#num + 2) or ""
    if i and board[i] then
      board[i].note = text
      -- the archive copy wears the same note: it is taken the moment the shot
      -- lands, which is always before he has typed anything about it
      if board[i].arch then
        for _, a in ipairs(arch) do if a.img == board[i].arch then a.note = text end end
      end
      save()                                                   -- no re-render: he's typing
    end
  elseif what == "del" then
    local i = tonumber(arg)
    if i and board[i] then
      pushUndo({ items = { toTrash(table.remove(board, i)) }, at = { i } })
      save(); render()
    end
  elseif what == "copy" then
    local i = tonumber(arg)
    local it = i and board[i]
    if it then
      local fh = io.open(it.img, "rb"); local data = fh and fh:read("*a")
      if fh then fh:close() end
      if data and #data > 0 then
        hs.pasteboard.writeDataForUTI("public.png", data)       -- real PNG bytes, as the shelf does
        -- 🚨 Claim the change, exactly as cbWrite does. Without this the clipboard
        -- poller saw our own write as a brand-new copied image and handed it
        -- straight back to the board — one ⧉ click grew a duplicate shot 3.
        if _G.cbClaimPasteboard then cbClaimPasteboard() end
        note("shot " .. i .. " → clipboard", 1.6)
      end
    end
  elseif what == "fav" then
    local i = tonumber(arg)
    local it = i and board[i]
    -- hand it to the clipboard shelf as a permanent ★ clip, which also exports
    -- the full-res file into the favourites folder
    if it and _G.cbHistory then
      local h = cbHistory()
      table.insert(h, 1, { img = it.img, w = it.w, h = it.h, t = os.time(), pinned = true,
                           app = { name = "scrn.brd" } })
      if _G.cbFavExport then cbFavExport(h[1]) end
      if _G.cbSaveNow then cbSaveNow() end
      note("shot " .. i .. " → ★ favourites", 1.6)
    end
  elseif what == "sel" then
    -- {do=sheet|shots|claude|brain, tab=board|arch|pics|recs|…, idx=[…]}. One
    -- message for all four buttons: they differ only in what they do with the
    -- list, and every one of them already takes one.
    local d = hs.json.decode(arg)
    local items = type(d) == "table" and subset(d) or nil
    local what2 = type(d) == "table" and d["do"] or nil
    if what2 == "sheet" then M.saveSheet(items)
    elseif what2 == "shots" then M.saveShots(items)
    elseif what2 == "claude" and wv then
      -- the review sheet, but pre-counted for the picked list; the page hands
      -- the same selection back on send, so nothing here has to remember it
      wv:evaluateJavaScript(("SB.review(%s,%d)"):format(
        q(claudeText(items or board)), items and #items or #board))
    elseif what2 == "brain" and wv then
      wv:evaluateJavaScript(("SB.review(%s,%d,null,'brain',%s)"):format(
        q(claudeText(items or board)), items and #items or #board,
        hs.json.encode(M.brainModels())))
    end
  elseif what == "send" then
    -- one JSON object: {w=new|cur|pick, t=<sidebar row title>, m=<message>}.
    -- JSON on purpose — it escapes newlines, and a raw newline in the payload is
    -- exactly what used to break the "^(%a+):(.*)$" match above.
    local d = hs.json.decode(arg)
    if type(d) == "table" then
      M.toClaude(d.w or "new", d.m or "", d.t, tonumber(d.o), subset(d.sel))
    end
  elseif what == "sendbrain" then
    -- {model=<catalog id>, m=<message>, o=<single-shot index, or nil>}
    local d = hs.json.decode(arg)
    if type(d) == "table" then
      M.toBrain(d.model, d.m or "", tonumber(d.o), subset(d.sel))
    end
  elseif what == "one" then
    -- → claude on a single card: same review sheet, pre-filled with just that
    -- shot's note, and the send carries the index back so only it goes over.
    local i = tonumber(arg)
    if i and board[i] and wv then
      wv:evaluateJavaScript(("SB.review(%s,1,%d)"):format(q(oneText(i)), i))
    end
  elseif what == "setkey" then
    local d = hs.json.decode(arg)
    if type(d) == "table" and d.id then M.setKey(d.id, d.mods, d.key) end
  elseif what == "shelfopen" then
    local path = arg
    if path ~= "" and hs.fs.attributes(path) then hs.execute(("/usr/bin/open %q"):format(path)) end
  elseif what == "shelfshow" then
    local path = arg
    if path ~= "" and hs.fs.attributes(path) then hs.execute(("/usr/bin/open -R %q"):format(path)) end
  elseif what == "assetopen" then
    local k = tonumber(arg); local a = k and assets[k]
    if a and hs.fs.attributes(a.path) then hs.execute(("/usr/bin/open %q"):format(a.path))
    elseif a then note("that file has moved or gone", 2.4) end
  elseif what == "assetshow" then
    local k = tonumber(arg); local a = k and assets[k]
    if a and hs.fs.attributes(a.path) then hs.execute(("/usr/bin/open -R %q"):format(a.path))
    elseif a then note("that file has moved or gone", 2.4) end
  elseif what == "assetdel" then
    -- forgets the reference, NEVER touches the file: it was never ours
    local k = tonumber(arg)
    if k and assets[k] then table.remove(assets, k); save(); render(); note("off the list", 1.4) end
  elseif what == "favarch" then
    local k = tonumber(arg)
    if k and arch[k] then
      arch[k].fav = not arch[k].fav; save(); render()
      if arch[k].fav then
        local it
        for _, b in ipairs(board) do if b.arch == arch[k].img then it = b end end
        autoName(arch[k], it)
      end
    end
  elseif what == "favbrd" then
    -- the board card stars its archive twin, so one shot has one answer
    local i = tonumber(arg); local it = i and board[i]
    if it and it.arch then
      local twin
      for _, a in ipairs(arch) do if a.img == it.arch then a.fav = not a.fav; twin = a end end
      save(); render()
      if twin and twin.fav then autoName(twin, it) end
    elseif it then
      note("that one was never archived, so it can't be kept", 2.4)
    end
  elseif what == "favrec" then
    local k = tonumber(arg)
    if k and recs[k] then recs[k].fav = not recs[k].fav; save(); render() end
  elseif what == "edit" then
    local i = tonumber(arg); local it = i and board[i]
    if it then openIn(M.imgApp(), it.img) end
  elseif what == "archedit" then
    local k = tonumber(arg); local it = k and arch[k]
    if it then openIn(M.imgApp(), it.img) end
  elseif what == "recedit" then
    local k = tonumber(arg); local r = k and recs[k]
    if r then openIn(M.vidApp(), r.file) end
  elseif what == "recopen" then
    local k = tonumber(arg)
    local r = k and recs[k]
    if r and hs.fs.attributes(r.file) then hs.execute(("/usr/bin/open %q"):format(r.file)) end
  elseif what == "recshow" then
    local k = tonumber(arg)
    local r = k and recs[k]
    if r and hs.fs.attributes(r.file) then hs.execute(("/usr/bin/open -R %q"):format(r.file)) end
  elseif what == "recdel" then
    -- forgets the take, never deletes the file: it was saved where he pointed the
    -- save folder, and quietly binning a recording is not a listing's job
    local k = tonumber(arg)
    if k and recs[k] then table.remove(recs, k); save(); render(); note("off the list", 1.4) end
  elseif what == "combine" then
    local d = hs.json.decode(arg)
    if type(d) == "table" then
      if not M.combine(d) then note("couldn't combine those", 2) end
    end
  elseif what == "desk" then
    local i = tonumber(arg)
    if i then M.toDesktop(i) end
  elseif what == "toarch" then
    -- board → archive. The archive already holds a copy of anything that landed
    -- normally, so this is really "take it off the board" — but archAdd anyway,
    -- because a shot restored FROM the archive has no copy of its own.
    local i = tonumber(arg)
    local it = i and board[i]
    if it then
      local have = false
      for _, a in ipairs(arch) do if a.t == it.t and a.note == (it.note or "") then have = true break end end
      if not have then archAdd(it) end
      pushUndo({ items = { toTrash(table.remove(board, i)) }, at = { i } })
      save(); render()
      note("shot " .. i .. " → ▤ archive", 1.6)
    end
  elseif what == "tobrd" then
    -- archive → board, as a fresh copy: the archive keeps its own, so the board
    -- can trash and undo this one freely.
    local k = tonumber(arg)
    local it = k and arch[k]
    if it and hs.fs.attributes(it.img) then
      hs.execute(("/bin/mkdir -p %q"):format(DIR))
      local dst = ("%s/%s-%04d.png"):format(DIR, os.date("%Y%m%d-%H%M%S"), math.random(0, 9999))
      hs.execute(("/bin/cp %q %q"):format(it.img, dst))
      if hs.fs.attributes(dst) then
        board[#board + 1] = { img = dst, w = it.w, h = it.h, note = it.note or "", t = os.time() }
        save(); render()
        note("▤ → board", 1.6)
      end
    end
  elseif what == "archdel" then
    local k = tonumber(arg)
    if k and arch[k] then
      os.remove(arch[k].img); table.remove(arch, k); save(); render()
      note("gone from the archive", 1.6)
    end
  elseif what == "revsearch" then
    local k = tonumber(arg)
    if k then M.revSearch(k) end
  elseif what == "saveone" then
    local i = tonumber(arg)
    if i then M.saveOne(i) end
  elseif what == "drop" then
    -- Pictures dragged onto the window. WKWebView hands the page bytes, never a
    -- path, so the page base64s each file and we write it back out — then the
    -- normal import path re-encodes it to PNG like every other picture here.
    local d = hs.json.decode(arg)
    if type(d) == "table" and d.b then
      local ext = (tostring(d.n or ""):match("%.(%w+)$") or "png"):lower()
      local tmp = ("%sscrnbrd-drop-%d-%04d.%s"):format(os.getenv("TMPDIR"), os.time(), math.random(0, 9999), ext)
      local f = io.open(tmp, "wb")
      if f then
        f:write(hs.base64.decode(d.b) or ""); f:close()
        M.addImages({ tmp })
        os.remove(tmp)
      end
    end
  elseif what == "rec" then
    M.recFromPage(hs.json.decode(arg))
  elseif what == "pic" then
    M.picFromPage(hs.json.decode(arg))
  elseif what == "picdel" then
    -- 🚨 NOT A DELETE, a tidy-up — and that is why there is no undo behind it.
    -- The archive's copy was made the moment the photo was taken and is not
    -- touched here, so the X takes the tile off the strip and nothing else.
    local i = tonumber(arg)
    if i and pics[i] then toTrash(table.remove(pics, i)); save(); render() end
  elseif what == "picclear" then
    for i = #pics, 1, -1 do toTrash(table.remove(pics, i)) end
    save(); render()
  elseif what == "picedit" then
    local i = tonumber(arg)
    if i and pics[i] then openIn(M.imgApp(), pics[i].img) end
  elseif what == "clr" then
    M.aimClear(hs.json.decode(arg))
  elseif what == "title" then
    meta.title = arg:gsub("[\r\n]", " "); save()       -- one line; it names a folder
  elseif what == "accent" then
    M.setAccent(arg)
  elseif what == "gnote" then
    meta.notes = arg; save()                            -- no re-render: he's typing
  elseif what == "act" then
    if arg == "claude" then
      if wv then
        wv:evaluateJavaScript("SB.review(" .. q(claudeText()) .. "," .. #board .. ")")
      end
    elseif arg == "brain" then
      -- the localhost round-trip is a few ms; fetching the catalog inline here
      -- (rather than a separate act like "chats") keeps this a single click
      if wv then
        wv:evaluateJavaScript(("SB.review(%s,%d,null,'brain',%s)"):format(
          q(claudeText()), #board, hs.json.encode(M.brainModels())))
      end
    elseif arg == "chats" then
      if wv then wv:evaluateJavaScript("SB.chats(" .. hs.json.encode(M.chatList()) .. ")") end
    elseif arg == "add" then M.addFiles()
    elseif arg == "light" then
      note(M.setLight(not M.lightOn()) and "light." or "dark.", 1.4)
    elseif arg == "keysrefresh" then render()      -- redraw the keys after a cancel
    elseif arg == "undo" then undoLast()
    elseif arg == "recstop"   then M.recStop()
    elseif arg == "aimback"   then M.aimBack()
    elseif arg == "assetadd"  then M.addAssets()
    elseif arg == "mic" or arg == "sys" then
      -- 🚨 NOT MID-TAKE. screencapture cannot add or drop an audio track once it
      -- is running; changing it would mean killing the capture and throwing away
      -- everything recorded so far. The toggle simply refuses while it rolls.
      if rec.pid then note("sound can't change mid-take", 2.4)
      else
        local k = arg == "mic" and "sbMic" or "sbSys"
        hs.settings.set(k, not (hs.settings.get(k) == true))
        if wv then wv:evaluateJavaScript(("SB.audio(%s,%s)"):format(
          tostring(M.micOn()), tostring(M.sysOn()))) end
      end
    elseif arg == "pictimer" or arg == "picflash" then
      -- standing preferences, exactly like full ui.: nothing to refuse, because
      -- a still is not a running capture the way a take is
      local k   = arg == "pictimer" and "sbPicTimer" or "sbPicFlash"
      local cur = arg == "pictimer" and M.picTimerOn() or M.picFlashOn()
      hs.settings.set(k, not cur)
      if wv then wv:evaluateJavaScript(("SB.photo(%s,%s)"):format(
        tostring(M.picTimerOn()), tostring(M.picFlashOn()))) end
    elseif arg == "recwhole" then
      -- the frame becomes the entire screen, and the strip parks on top of it
      if aim.rect and aim.zoomScreen then
        local sf = aim.zoomScreen
        aim.rect = { x = sf.x, y = sf.y + (aim.strip or 0), w = sf.w,
                     h = sf.h - (aim.strip or 0) }
        if aim.ring then aim.ring:delete() end
        aim.ring = recRing(aim.rect.x, aim.rect.y, aim.rect.w, aim.rect.h)
        easeTo({ x = sf.x, y = sf.y, w = sf.w, h = (aim.strip or 120) + RING_TAIL }, 0.18)
        note("the whole screen is the frame", 2)
      end
      aim.zoomAsk = nil
    elseif arg == "recunzoom" then
      -- he meant to zoom, not to record everything: put the frame back
      if aim.rect and aim.preZoom then
        aim.rect = aim.preZoom
        if aim.ring then aim.ring:delete() end
        aim.ring = recRing(aim.rect.x, aim.rect.y, aim.rect.w, aim.rect.h)
        easeTo({ x = aim.rect.x - (aim.off and aim.off.left or 0),
                 y = aim.rect.y - (aim.strip or 0),
                 w = aim.rect.w + (aim.off and aim.off.left or 0) * 2,
                 h = (aim.strip or 120) + RING_TAIL }, 0.18)
      end
      aim.zoomAsk = nil
    elseif arg == "typing1"   then snapTyping = true;  snapSync()
    elseif arg == "typing0"   then snapTyping = false; snapSync()
    elseif arg == "pickimg"   then pickApp("sbImgApp")
    elseif arg == "pickvid"   then pickApp("sbVidApp")
    elseif arg == "recreveal" then M.recReveal()
    elseif arg == "tabrec" then
      -- nothing to do any more: the window is transparent for its whole life and
      -- the page's own body background is what makes the other tabs solid
    elseif arg == "tabboard" then
      M.recStop()
      M.aimBack()
    elseif arg == "top" then
      note(M.setTop(not M.topOn()) and "always on top" or "normal window", 1.6)
    elseif arg == "recfull" then
      note(M.setRecFull(not M.recFullOn())
        and "next take keeps the whole window" or "next take clears the area", 1.8)
    elseif arg == "shots" then M.saveShots()
    elseif arg == "sheet" then M.saveSheet()
    elseif arg == "dest"  then M.pickDest("shots")
    elseif arg == "recdest" then M.pickDest("takes")
    elseif arg == "downloads" then
      hs.settings.set("sbDest", HOME .. "/Downloads")
      hs.settings.clear("sbRecDest")            -- back to one folder for both
      pushDests()
    elseif arg == "clear" then
      -- only ever reached on an EMPTY board now: the page owns the confirm, so
      -- that it can be styled and can open at the pointer. hs.dialog.blockAlert
      -- could do neither — it is a system alert, always centred, always grey.
      note("nothing to clear", 1.6)
    elseif arg == "clearok" then
      if #board > 0 then wipe(false) end
    elseif arg == "archrecclearok" then
      msg("act:archclearok"); msg("act:recclearok")   -- one answer, both lists
    elseif arg == "favclearshots" then
      local n = 0
      for _, a in ipairs(arch) do if a.fav then a.fav = nil; n = n + 1 end end
      save(); render(); note(("%d shot%s unstarred"):format(n, n == 1 and "" or "s"), 2)
    elseif arg == "favcleartakes" then
      local n = 0
      for _, r in ipairs(recs) do if r.fav then r.fav = nil; n = n + 1 end end
      save(); render(); note(("%d take%s unstarred"):format(n, n == 1 and "" or "s"), 2)
    elseif arg == "archclearok" then
      -- 🚨 the archive's own broom, reached only from the arch. tab. Same rule as
      -- the ✕ on a single tile: the copy this app made is deleted for real, and
      -- the board is not touched. There is no undo for it, and the confirm says so.
      local n = #arch
      for i = n, 1, -1 do
        if arch[i] and arch[i].img then os.remove(arch[i].img) end
        arch[i] = nil
      end
      save(); render()
      note(n > 0 and ("archive cleared · %d gone"):format(n) or "nothing archived", 2)
    elseif arg == "favclearok" then
      -- unstars, deletes nothing: the shots go back to ageing out with the rest
      -- of the archive and the takes stay on their own list
      local n = 0
      for _, a in ipairs(arch) do if a.fav then a.fav = nil; n = n + 1 end end
      for _, r in ipairs(recs) do if r.fav then r.fav = nil; n = n + 1 end end
      save(); render()
      note(n > 0 and ("%d unstarred — nothing deleted"):format(n) or "nothing starred", 2.2)
    elseif arg == "recclearok" then
      -- the LIST, never the files: same promise the ✕ on one take makes
      local n = #recs
      for i = n, 1, -1 do recs[i] = nil end
      save(); render()
      note(n > 0 and ("%d take%s off the list — the files stay"):format(n, n == 1 and "" or "s")
                  or "no takes listed", 2.4)
    elseif arg == "close" then M.hide() end
  end
end

-- ── shortcuts ────────────────────────────────────────────────────────
-- Every hotkey scrn.brd owns, in one place, each one rebindable from the ⚙ sheet.
-- The actions that need the window just press the button in the page — the page
-- already knows how to do the thing, and there is no second code path to keep in
-- step. Overrides live in hs.settings under sbKeys; anything not overridden falls
-- back to the default in this table.
-- 🚨 EVERY ONE OF THESE IS EDITABLE, and adding one here is all it takes —
-- keyCfg merges the saved overrides, bindKeys rebinds, and the settings sheet
-- draws whatever is in this table. `group` is only there so the guide reads as a
-- guide instead of a flat list of eight rows.
local KEYS_DEF = {
  { group = "the window.",
    id = "board", label = "show the board.",              mods = { "cmd", "shift" }, key = "b" },
  { id = "arch",  label = "jump to the archive.",         mods = { "cmd", "alt" },   key = "a" },
  { id = "fav",   label = "jump to the favourites.",      mods = { "cmd", "alt" },   key = "f" },

  { group = "recording.",
    id = "rec",   label = "start / stop recording.",      mods = { "cmd", "alt" },   key = "r" },
  { id = "clr",   label = "clear the area / aim again.",  mods = { "cmd", "alt" },   key = "e" },

  { group = "the board.",
    id = "cld",   label = "send the board to claude.",    mods = { "cmd", "alt" },   key = "c" },
  { id = "one",   label = "save the board as one picture.", mods = { "cmd", "alt" }, key = "s" },
  { id = "sep",   label = "save every shot separately.",  mods = { "cmd", "alt" },   key = "d" },
  { id = "undo",  label = "put back the last removal.",   mods = { "cmd", "alt" },   key = "z" },
}
local hotkeys = {}

keyCfg = function()
  local saved = hs.settings.get("sbKeys") or {}
  local out = {}
  for _, d in ipairs(KEYS_DEF) do
    local sv = saved[d.id]
    out[#out + 1] = { id = d.id, label = d.label, group = d.group,
                      mods = (sv and sv.mods) or d.mods,
                      key  = (sv and sv.key) or d.key,
                      custom = sv ~= nil }
  end
  return out
end

local function press(id)                      -- the page's own button, whatever it does
  return function()
    -- 🚨 SUMMON, never toggle. The board key is how he calls the board up; when it
    -- also closed one that was already in front, pressing it looked like the board
    -- had been cleared. Closing is what the window's own ✕ (and the shelf's ▦) do.
    if id == "board" then M.show(); return end
    if not wv then M.show() end
    if wv then
      wv:evaluateJavaScript(({
        rec  = "document.getElementById('recgo').click()",
        cld  = "document.getElementById('claude').click()",
        one  = "document.getElementById('oneboard').click()",
        sep  = "document.getElementById('shots').click()",
        undo = "document.getElementById('undo').click()",
        arch = "setTab('arch')",
        fav  = "setTab('fav')",
        -- one key for both halves of the same idea: park the window off the
        -- rectangle, or bring it back over it
        clr  = "(function(){ if (curTab !== 'rec') { setTab('rec'); return; }"
            .. " var b = document.body.classList.contains('clear')"
            .. " ? document.getElementById('recaim') : document.getElementById('recclear');"
            .. " if (b) b.click(); })()",
      })[id] or "")
    end
  end
end

local function bindKeys()
  for _, h in ipairs(hotkeys) do pcall(function() h:delete() end) end
  hotkeys = {}
  for _, k in ipairs(keyCfg()) do
    local ok, hk = pcall(hs.hotkey.bind, k.mods, k.key, press(k.id))
    if ok and hk then hotkeys[#hotkeys + 1] = hk end
  end
end

-- id = which shortcut, mods = { "cmd", "shift", … }, key = "b". key nil resets it.
function M.setKey(id, mods, key)
  local saved = hs.settings.get("sbKeys") or {}
  if key == nil or key == "" then saved[id] = nil
  else saved[id] = { mods = mods or {}, key = key } end
  hs.settings.set("sbKeys", saved)
  bindKeys()
  render()
  return true
end
function M.keys() return keyCfg() end

-- ── the tray ─────────────────────────────────────────────────────────
-- A menubar mark that exists for as long as the board does. Click = bring the
-- board to the front, wherever it is: behind everything, on another space, or
-- sat in the Dock. It is the second way in, next to the shelf's ▦ button — and
-- the only one that works while the window is minimised.
local tray = nil
local function trayOn()
  if tray then return end
  tray = hs.menubar.new()
  if not tray then return end
  tray:setTitle("▦")                 -- monoline glyph: no colour emoji anywhere
  tray:setTooltip("scrn.brd — click to bring the board to the front")
  tray:setClickCallback(function() M.show() end)
end
local function trayOff()
  if tray then tray:delete(); tray = nil end
end
-- setTop is defined above these, so it reaches them through M
function M.frontTapSet(on)
  if on then M.frontTapOn() else M.frontTapOff() end
end

-- ── click any sliver of it and it comes forward ──────────────────────
-- 🚨 A window that is not key does NOT hand its first click to the page, and on
-- the rec tab the webview is transparent besides — so the board could not ask
-- for this itself, and clicking the bit of it poking out from behind another
-- app did nothing but eat the click. This watches left mouse-downs instead.
--
-- It is cheap on purpose: the point has to be inside the board's own frame
-- before anything else runs, which is almost never, and only then does it pay
-- for the ordered-window scan that proves the board really is the thing on top
-- at that point (otherwise clicking a window merely OVERLAPPING the board's
-- rectangle would yank the board forward).
local frontTap = nil
local function frontTapOff()
  if frontTap then frontTap:stop(); frontTap = nil end
end
local function inRect(p, f)
  return f and p.x >= f.x and p.x <= f.x + f.w and p.y >= f.y and p.y <= f.y + f.h
end
-- 🚨 OPT-IN, and tied to the ⇧ pin. Summoning the board on a click inside its
-- rectangle is a springboard behaviour: useful when he has deliberately parked
-- the thing on top of everything, and meddlesome the rest of the time, because
-- it raises a window in response to a click he may have meant for whatever is
-- under it. The pin is the switch for "this window plays by its own rules", so
-- it is the switch for this too. Pin off, no tap, no raising: a normal window.
local function frontTapOn()
  if not M.topOn() then frontTapOff(); return end
  if frontTap then return end
  frontTap = hs.eventtap.new({ hs.eventtap.event.types.leftMouseDown }, function()
    if not wv then return false end
    local f, p = wv:frame(), hs.mouse.absolutePosition()
    if not inRect(p, f) then return false end       -- not us: nothing paid for either
    -- 🚨 NEVER the title bar. That strip is the DRAG HANDLE, and macOS already
    -- raises a window when you grab it — so summoning here was pure sabotage:
    -- every attempt to drag the board out from behind something began with a
    -- show() + bringToFront() + focus() + level re-assert landing on a drag the
    -- window server had only just started, and the window lurched instead of
    -- following the pointer. This is the whole "moving around chaotically".
    if p.y < f.y + TITLEBAR then return false end
    -- 🚨 And NO window queries in here. An event tap holds the event until its
    -- callback returns, so every AX call is felt on the click itself. Everything
    -- below happens a frame later — which is also what makes it CORRECT: by
    -- then macOS has finished raising whatever was really on top at that point,
    -- so we can read the outcome instead of trying to predict it.
    hs.timer.doAfter(0.05, function()
      if not wv then return end
      local w = wv:hswindow()
      if not w or w:isMinimized() then return end
      local front = hs.window.frontmostWindow()
      if front then
        if front:id() == w:id() then return end     -- the click already brought us up
        -- something else is in front AND covers the point he clicked: that window
        -- was on top there, he clicked IT, and dragging the board over would be
        -- us stealing the click. (hs.window.orderedWindows() cannot answer this —
        -- AX orders windows per app and apps by activation, so a panel belonging
        -- to a background Hammerspoon always sorts below the fullscreen window it
        -- is visibly sitting on top of. Watching what the click DID is honest.)
        if inRect(p, front:frame()) then return end
      end
      M.show()
    end)
    return false                                    -- never swallow the click
  end)
  frontTap:start()
end
M.frontTapOn, M.frontTapOff = frontTapOn, frontTapOff

-- ── the window ───────────────────────────────────────────────────────
-- Unlike the shelf, this is a NORMAL window: titled, resizable, and it takes key
-- focus — which is exactly what makes typing notes and clicking cards work
-- natively here, with none of the cbHit hit-testing the shelf needs.
function M.show()
  if wv then
    -- 🚨 NOT ONE wv:hswindow() ON THIS PATH. That call is an AX round-trip —
    -- measured 20-90ms idle and far worse under load — and it returns nil
    -- whenever the window is hidden OR miniaturised, which is exactly when a
    -- summon happens. Gating the raise on it meant every summon after a send
    -- looked like "the window is gone", deleted the webview and rebuilt it from
    -- disk: 3101ms from keypress, against 57-100ms otherwise.
    --
    -- The webview object is the source of truth; hswindow() is only an AX view
    -- of it. wv:show() restores a hidden window on its own, and the level bounce
    -- in raiseHard() is what actually orders it. So the blocking path does only
    -- the cheap things, and everything that needs the AX window happens a beat
    -- later, off the clock he can feel.
    activateSelf()
    wv:show()
    wv:bringToFront()
    M.setTop(M.topOn())
    raiseHard()
    trayOn(); frontTapOn()
    -- 🚨 Rebuilding is the LAST resort and never happens on the first miss: AX
    -- hands back nil for a moment after a raise, so a single nil proves nothing.
    -- Look again, and only after several misses accept the window is really
    -- gone. But a flat 0.18s BEFORE the first look, then another flat 0.45s
    -- before the second, was dead time left over from before the AX lookup
    -- itself was measured at 12ms (see the summon-cost commit) — the window
    -- was visually up and NOT taking clicks (not key) for up to 0.63s of pure
    -- waiting. Poll every 0.03s instead: each miss costs one cheap AX call,
    -- not a fixed wait, so focus() lands the moment the window is really
    -- there rather than on an arbitrary clock.
    if M.reviveTimer then M.reviveTimer:stop() end
    local tries = 0
    M.reviveTimer = hs.timer.doEvery(0.03, function()
      tries = tries + 1
      if not wv then M.reviveTimer:stop(); return end
      local w = wv:hswindow()
      if w then
        M.reviveTimer:stop()
        if w:isMinimized() then w:unminimize() end
        w:focus()
        return
      end
      if tries >= 20 then                  -- ~0.6s of misses: genuinely gone
        M.reviveTimer:stop()
        -- (a yellow-button miniaturise drops it out of hs.window for good.
        -- The board lives in the json, so a fresh window comes back with
        -- everything on it.)
        wv:delete(); wv, ucc = nil, nil
        M.show()
      end
    end)
    return
  end
  load()
  local scr = hs.screen.mainScreen():frame()
  local f = hs.settings.get("sbFrame") or
            { x = scr.x + scr.w - 700, y = scr.y + 60, w = 660, h = math.min(760, scr.h - 120) }
  -- Clamp onto the screen. A remembered frame can outlive the display it was
  -- saved on (or be pushed off the edge by a resize), and a window whose header
  -- buttons sit past the bezel is a window with dead controls.
  --
  -- 🚨 IT COMES BACK THE SAME SHAPE. The clamp used to squash width and height
  -- INDEPENDENTLY, so a frame that was a little too tall for the screen came
  -- back at a different aspect ratio — and on the rec tab that matters: the
  -- rectangle is the window, so a window that reopens a different shape frames a
  -- different area than the one he set up, and nothing lines up with the strip
  -- above it. Scale BOTH sides by the same factor instead, and account for the
  -- title bar in the fit (this is a content rect; AppKit hangs the bar above it
  -- and will shrink the window itself if the pair does not fit).
  f.h = ratioH(f.w)                        -- whatever was remembered, it opens 3:4
  local fit = math.min(1, scr.w / f.w, (scr.h - TITLEBAR) / f.h)
  if fit < 1 then f.w = math.floor(f.w * fit) end
  f.w = math.max(380, f.w)
  f.h = ratioH(f.w)
  f.x = math.max(scr.x, math.min(f.x, scr.x + scr.w - f.w))
  f.y = math.max(scr.y + TITLEBAR, math.min(f.y, scr.y + scr.h - f.h))
  ucc = hs.webview.usercontent.new("shotboard")
  ucc:setCallback(function(m) msg(m.body) end)
  wv = hs.webview.new(f, { developerExtrasEnabled = false }, ucc)
  wv:windowStyle({ "titled", "closable", "resizable", "miniaturizable" })
  wv:windowTitle("scrn.brd")
  -- 🚨 TRANSPARENT FROM BIRTH, and never toggled again. Proven live on this
  -- WebKit: transparent(true) called for the first time AFTER the page has
  -- painted does NOTHING — the window keeps an opaque white backing — while an
  -- identically built window made transparent BEFORE its first content is
  -- see-through and stays that way through any number of later toggles. That is
  -- why the rec tab went white: the flag was flipped on the first visit to the
  -- tab, long after first paint. So the window is transparent for its whole life
  -- and the PAGE decides what shows: body paints --bg on every tab except rec,
  -- which paints nothing, so the rectangle is a real hole through to the screen.
  wv:allowTextEntry(true)            -- MUST be true here: the notes are typed in
  wv:allowNewWindows(false)
  wv:darkMode(not M.lightOn())        -- title bar matches the theme from the start
  -- 🚨 (action, webview, frame) — ACTION FIRST. This was written as
  -- (_, action, _, frame), which bound `action` to the webview object and `frame`
  -- to nil, so NOTHING in here ever ran: the window's position was never
  -- remembered on a drag, and closing it never stopped a take or cleared the
  -- tray. Every branch below is only now actually reachable.
  wv:windowCallback(function(action, _, frame)
    if action == "closing" then
      M.recStop()
      aimDrop()                       -- the ring would outlive the window otherwise
      snapFocus = false; snapSync()
      trayOff(); frontTapOff()
      wv, ucc = nil, nil
      hs.settings.set("sbOpen", false)
    elseif action == "focusChange" then
      snapFocus = frame and true or false        -- for this action the 3rd arg IS the state
      snapSync()
    elseif action == "frameChange" and frame and aim.rect then
      -- 🚨 the parked box is a handle on the RECTANGLE, not a window position
      -- worth remembering: drag it and the frame goes with it. The ring is moved,
      -- never rebuilt — a drag fires this sixty times a second.
      if not rec.pid then
        -- 🚨 THE GREEN BUTTON IS CAUGHT HERE, NOT IN A BRANCH OF ITS OWN. macOS
        -- gives an hs.webview no zoom event — the button just resizes the window —
        -- so a zoom is recognised by its shape: a frame that suddenly covers
        -- almost the whole screen while the strip was parked on something much
        -- shorter. It has to be checked INSIDE this branch: as a separate elseif
        -- ahead of it, it matched every frameChange and swallowed them all, and
        -- the frame stopped following the strip entirely.
        local scr = hs.screen.find(hs.geometry.point(frame.x + frame.w / 2, frame.y + frame.h / 2))
                    or hs.screen.mainScreen()
        local sf = scr:frame()
        if aim.zoomAsk ~= false and aim.strip and frame.h > aim.strip * 2
           and frame.w >= sf.w * 0.94 and frame.h >= sf.h * 0.80 then
          aim.zoomAsk = false                  -- one ask per zoom, not one per event
          aim.preZoom = { x = aim.rect.x, y = aim.rect.y, w = aim.rect.w, h = aim.rect.h }
          aim.zoomScreen = { x = sf.x, y = sf.y, w = sf.w, h = sf.h }
          if wv then wv:evaluateJavaScript("SB.askWhole()") end
          return
        end
        -- the strip IS the top edge of the rectangle: the rect starts where the
        -- window ends, and takes the window's width. Drag it and the frame moves;
        -- pull its side and the frame gets wider.
        local off = (aim.off and aim.off.left or 0)
        local w   = math.floor(frame.w - off * 2)
        local rebuild = w ~= aim.rect.w
        aim.rect.x = math.floor(frame.x + off)
        aim.rect.y = math.floor(frame.y + (aim.strip or (frame.h - RING_TAIL)))
        aim.rect.w = w
        if rebuild then
          if aim.ring then aim.ring:delete() end
          aim.ring = recRing(aim.rect.x, aim.rect.y, aim.rect.w, aim.rect.h)
        else
          ringFollow()
        end
      end
    elseif action == "frameChange" and frame and not rec.pid then
      -- not while recording: the window is deliberately collapsed to its bar, and
      -- remembering THAT is how it reopens as a sliver next time.
      -- 🚨 Written straight through, NOT debounced. A debounce here looks like
      -- free speed — sixty user-defaults writes a second during a drag, to
      -- store thirty-nine frames nobody wants — but the write costs 0.24ms and
      -- frameChange only fires for a REAL drag, never for a programmatic
      -- wv:frame() or hs.window:setFrame(). That makes the debounce impossible
      -- to test without a hand on the mouse, and the thing it would silently
      -- break is where his window comes back. Not worth it for 1.4% of a frame.
      -- 🚨 STORED AS THE CONTENT RECT, not the window frame. hs.webview.new()
      -- reads this back as the CONTENT rect and hangs the title bar above it, so
      -- writing wv:frame() straight through hands back a window 28pt taller
      -- every single time — the board grew a title bar per launch. Proven live:
      -- stored {y=60,h=880} came back as a window at {y=32,h=908}. Take the bar
      -- off on the way in and the round trip is exact.
      hs.settings.set("sbFrame", { x = frame.x, y = frame.y + TITLEBAR,
                                   w = frame.w, h = frame.h - TITLEBAR })
      -- …and settle back onto 3:4. Debounced on purpose: correcting DURING a
      -- live resize fights the drag (AppKit keeps resizing from its own anchor
      -- and the window judders). One shot after the last frameChange lands it
      -- the moment he lets go, which is the only moment it matters.
      if M.ratioTimer then M.ratioTimer:stop() end
      M.ratioTimer = hs.timer.doAfter(0.18, function()
        if not wv or aim.rect or rec.pid then return end
        local g = wv:frame()
        local want = ratioH(g.w) + TITLEBAR
        if math.abs(g.h - want) > 2 then
          wv:frame({ x = g.x, y = g.y, w = g.w, h = want })
          hs.settings.set("sbFrame", { x = g.x, y = g.y + TITLEBAR, w = g.w, h = want - TITLEBAR })
        end
      end)
    end
  end)
  wv:transparent(true)              -- LAST thing before the content loads
  wv:url("file://" .. HTML)
  activateSelf()
  wv:show():bringToFront()
  -- 🚨 AFTER bringToFront, never before. bringToFront() leaves the window at the
  -- FLOATING level even with its default argument, so a level set at build time
  -- is immediately overwritten: the board was always-on-top with the pin reading
  -- off, and it took two clicks (on, then off) to get an honest normal window.
  M.setTop(M.topOn())
  raiseHard()                          -- a fresh window needs the same lift
  trayOn(); frontTapOn()
  hs.settings.set("sbOpen", true)
  -- the page loads asynchronously; anything sent before SB exists is dropped
  local tries = 0
  M.readyTimer = hs.timer.doEvery(0.06, function()
    tries = tries + 1
    if not wv or tries > 60 then M.readyTimer:stop(); return end
    wv:evaluateJavaScript("typeof SB === 'object'", function(ok)
      if ok == true and M.readyTimer then M.readyTimer:stop(); render() end
    end)
  end)
end

function M.hide()
  trayOff(); frontTapOff()
  -- 🚨 STOP THE RECORDER FIRST — a hidden window still recording would orphan
  -- the screencapture process still writing to disk.
  M.recStop()
  M.aimBack()                        -- never leave the parked strip as the window
  -- 🚨 and drop the key tap. focusChange normally does this, but a window that
  -- is hidden while focused is the one route where it may not fire, and a
  -- keyDown tap left running with no window to move is a tap on every keystroke
  -- in every app for nothing.
  snapFocus = false; snapSync()
  -- 🚨 HIDE, NEVER DELETE. This used to wv:delete() the whole webview, which is
  -- exactly the cold path M.show()'s fast reuse branch exists to avoid — its own
  -- comments say a hidden-or-minimised window is "exactly when a summon
  -- happens" and that wv:show() restores one on its own. Deleting here meant
  -- EVERY ⌘⇧B close forced the next open through the full rebuild: reload the
  -- HTML from disk, recreate usercontent, poll for `typeof SB` at 60ms a tick.
  -- That is the "opens but won't take a click for a long moment" he saw — the
  -- window painted before the page inside it had finished booting. wv:hide()
  -- keeps the same webview alive, so the next M.show() takes the fast branch
  -- (the one that made summon-after-a-send 12ms) instead of rebuilding.
  if wv then wv:hide() end
  hs.settings.set("sbOpen", false)
end

-- 🚨 Calling the board RAISES it. It only closes when it is already the window
-- in front — anything else (behind another app, minimised, on the far screen)
-- means he asked for it, not that he asked to get rid of it. Toggling shut a
-- board that was merely buried is what made ⌘⇧B and the shelf's ▦ chip look dead.
function M.toggle()
  if not wv then M.show(); return end
  local w = wv:hswindow()
  local front = hs.window.frontmostWindow()
  local isFront = w and front and front:id() == w:id()
  if isFront then M.hide() else M.show() end
end
-- run something in the board's page (used to drive it while testing)
function M.js(code) if wv then wv:evaluateJavaScript(code) end end
function M.isOpen() return wv ~= nil end
function M.count() return #board end

-- test handles (the board table is a file-level local, unreachable from `hs -c`)
_G.sbBoard  = function() return board end
_G.sbMsg    = msg
_G.sbRender = render
_G.sbEval   = function(js) if wv then wv:evaluateJavaScript(js, function(r) _G.__sbjs = tostring(r) end) end end
_G.sbLevel  = function() return wv and wv:level() end
_G.sbTrans  = function(on) if wv then wv:transparent(on and true or false) end return on end
_G.sbSnap   = function()                  -- is the ⌘-arrow key tap alive, and why
  return string.format("tap=%s focus=%s typing=%s rec=%s parked=%s",
    tostring(snapTap ~= nil), tostring(snapFocus), tostring(snapTyping),
    tostring(rec.pid ~= nil), tostring(aim.rect ~= nil))
end
_G.sbAimRect = function()                 -- the framed rect while clear mode holds it
  return aim.rect and string.format("%d,%d,%d,%d", aim.rect.x, aim.rect.y, aim.rect.w, aim.rect.h)
end
-- the AX lookup behind every raise — exposed because its COST is the thing
-- worth watching, not its value (see the single-lookup note in M.show)
_G.sbWin    = function() return wv and wv:hswindow() end
_G.sbTray   = function()                  -- 🚨 a menubar item on a FULL bar is PARKED
  if not tray then return "no tray" end    -- off-screen (x ≈ -3893), not missing
  local f = tray:frame()
  return f and ("%d,%d,%d,%d"):format(f.x, f.y, f.w, f.h) or "no frame"
end
_G.sbFrame  = function()                  -- position too, for screen-region capture
  if not wv then return nil end
  local f = wv:frame()
  return ("%d,%d,%d,%d"):format(f.x, f.y, f.w, f.h)
end
_G.sbRec    = function(x, y, w, h) return M.recStart(x, y, w, h) end
_G.sbRecStop = function() return M.recStop() end
_G.sbUndo   = function() return #undo end
-- targeting is the part of the send that silently misses, so it gets its own
-- handle: it answers "would this title find a row?" without sending anything
_G.sbOpenChat = function(t) return openChat(t) end
_G.sbSize   = function(w, h)              -- hs.window.find can't see this webview
  if not wv then return nil end
  local f = wv:frame()
  wv:frame({ x = f.x, y = f.y, w = w or f.w, h = h or f.h })
  return wv:frame().w .. "x" .. wv:frame().h
end

load()
bindKeys()
-- 🚨 THE GUARD. If Hammerspoon reloaded or crashed mid-take, the default output
-- is still the stacked SR Monitor and the only record of what it used to be is
-- the setting — so put it back at load time, before he notices his speakers are
-- routed through a virtual device. Costs one comparison on a normal start.
do
  local prev = hs.settings.get("sbPrevOut")
  if prev then
    local cur = hs.audiodevice.defaultOutputDevice()
    if cur and cur:name() == SR_MON then
      local d = hs.audiodevice.findDeviceByUID(prev)
      if d then d:setDefaultOutputDevice() end
      note("sound put back — a take was interrupted", 3)
    end
    hs.settings.clear("sbPrevOut")
  end
end
-- it called itself persistent, so it comes back after a reload/login if it was up
if hs.settings.get("sbOpen") then M.bootTimer = hs.timer.doAfter(3, function() M.show() end) end

return M
