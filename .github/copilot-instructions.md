# KOReader AI Coding Instructions

## Project Overview

KOReader is a feature-rich document viewer optimized for e-ink readers and embedded devices (Kindle, Kobo, PocketBook, reMarkable, etc.), supporting PDF, EPUB, DjVu, CBZ and other formats. The frontend is Lua-based with C/C++ backend (mupdf, cre engine). Key strengths: fast rendering, customizable typography, multi-format support, plugin ecosystem.

**Repository**: https://github.com/koreader/koreader | **Docs**: http://koreader.rocks/doc/

---

## Architecture & Key Components

### Core Layers

1. **Backend (C/C++/luajit ffi)** (`base/`): Rendering engines (mupdf, cre, djvu), BlitBuffer, input handling
2. **Frontend (Lua)** (`frontend/`): UI framework, reader modules, document abstraction
3. **Plugins** (`plugins/`): Extensible features via `.koplugin` directories
4. **Platform Abstraction** (`platform/`, `frontend/device/`): Device-specific code (Kindle, Kobo, SDL)

### Frontend Architecture

```
frontend/
├── ui/             # UI framework (widgets, events, input, screen)
├── apps/
│   ├── reader/     # Reader app (ReaderUI + 30+ modules)
│   └── filemanager/# File browser
├── document/       # Document abstraction (PDF, EPUB, CRE, DjVu, etc.)
└── [Configurable]  # Settings system (luasettings.lua)
```

**Data Flow**: Device input → Input event → Widget:handleEvent() → Event propagation (children first) → Module reactions → UI refresh via UIManager

---

## Critical Patterns & Conventions

### 1. **Widget System** (`frontend/ui/widget/`)

KOReader uses a **prototype-based OOP** pattern with prototypal inheritance:

```lua
local Widget = require("ui/widget/widget")
local MyWidget = Widget:extend{
    _init = function(self) end,  -- Instance initialization
    init = function(self) end,   -- Higher-level setup
}

function MyWidget:paintTo(bb, x, y)
    -- Draw to BlitBuffer (bb)
end

function MyWidget:handleEvent(event)
    return self["on"..event.name](self, unpack(event.args))
end
```

**Key methods**:
- `Widget:extend(prototype)` — Creates class (no initialization)
- `Widget:new(o)` — Creates instance & calls init methods
- `paintTo(bb, x, y)` — Renders to screen
- `handleEvent(event)` — Consumes events, return `true` to stop propagation

**Container pattern**: `WidgetContainer` children receive events **before parent**. Child returning `true` prevents parent from handling.

### 2. **Event System** (`frontend/ui/event.lua`)

Events are simple objects dispatched through widget tree:

```lua
local Event = require("ui/event")
Event:new("GotoPage", 1)        -- Creates {handler="onGotoPage", args={1}}
widget:handleEvent(event)       -- Calls widget:onGotoPage(1)
UIManager:sendEvent(event)      -- Propagates from top widget
UIManager:broadcastEvent(event) -- Sends to all active_widgets
```

**Convention**: Event name → handler method (`on` + EventName). Return `true` to consume.

### 3. **Settings & Configuration** (`frontend/configurable.lua`, `luasettings.lua`)

Two-layer system for persistent settings:

```lua
-- Per-document settings (doc_settings.lua)
local DocSettings = require("docsettings")
local settings = DocSettings:open(file_path)
settings:saveSetting("font_size", 24)

-- Global settings (stored in G_reader_settings, defaults.lua)
local config_options = {
    name = "font_size",
    category = "typesetting",
    event = "SetFont",
    default_value = 18,
    values = {12, 14, 16, 18, 20, 22, 24},
}
```

**Pattern**: Modules with `self.configurable` use `loadDefaults()`, `loadSettings()`, `saveSettings()` to manage options via config dialogs.

### 4. **Module Registration in ReaderUI** (`frontend/apps/reader/readerui.lua`)

Reader modules extend `EventListener` and register with `ReaderUI:registerModule()`:

```lua
local ReaderUI = InputContainer:extend{ active_widgets = {} }

function ReaderUI:registerModule(name, module, always_active)
    self[name] = module
    table.insert(self, module)
    if always_active then
        table.insert(self.active_widgets, module)
    end
end
```

**Modules receive events even when hidden** if registered with `always_active=true`. Examples: ReaderMenu, ReaderConfig, ReaderStatus.

### 5. **Document Interface** (`frontend/document/document.lua`)

Abstract interface; subclasses for PDF, EPUB (CRE), DjVu, images:

```lua
local Document = {}

function Document:new(o)
    o = self:extend(o)
    if o._init then o:_init() end      -- Backend init
    if o.init then o:init() end        -- Frontend init
    return o
end

function Document:drawPage(pageno, rect, zoom, rotation, gamma)
    -- Returns BlitBuffer (bitmap)
end

function Document:renderPage(pageno, rect, zoom, rotation, gamma)
    -- Backend rendering; result cached by drawPage
end
```

**Caching**: `DocCache` caches rendered pages; `Document.drawPage()` checks cache before calling `renderPage()`.

### 6. **Plugin Architecture** (`frontend/pluginloader.lua`)

Plugins are `.koplugin` directories with mandatory `metadata.lua`:

```
plugins/myplugin.koplugin/
├── metadata.lua     # Required: name, description, author, depends
├── main.lua         # Entry point
└── ...
```

**Loading**: PluginLoader scans `DEFAULT_PLUGIN_PATH` and `extra_plugin_paths`. Disabled plugins skipped. Providers (named `provider_*.koplugin`) load first.

**Integration**:
```lua
if PluginLoader:isEnabled("plugin_name") then
    local plugin = PluginLoader:loadPlugin("plugin_name")
    plugin:start()  -- or plugin:stop()
end
```

---

## Developer Workflows

### Building & Running

```bash
# Setup environment (one-time)
make -C base all

# Run emulator with SDL
./kodev build emulator
./kodev run emulator

# Build for target (e.g., Kobo)
./kodev build kobo
./kodev release kobo

# Run tests
./kodev check  # Lint with luacheck
make -C spec test  # Run unit tests (busted framework, spec/unit/*_spec.lua)
```

**kodev** (`./kodev`) is the main CLI tool. Common targets: `emulator`, `kindle`, `kobo`, `pocketbook`, `android`.

### Testing Patterns

Tests use **busted** framework in `spec/unit/`:

```lua
describe("Module name", function()
    it("should do something", function()
        local obj = require("module")
        assert.is_true(obj:method())
    end)
end)
```

**Mock time**: Import `spec/unit/mock_time.lua` for tests requiring time manipulation.

### Debugging

```lua
local logger = require("logger")
logger.info("message")     -- Info level
logger.warn("message")     -- Warning
logger.err("message")      -- Error
logger.dbg("message")      -- Debug (controlled by DEBUG env var)

local dbg = require("dbg")
dbg:dumpTable(table_obj)   -- Pretty-print tables
```

**In-app**: Access debug console via menu → Tools → Developer options (if enabled).

---

## Project-Specific Patterns

### Geometry & Dimensions

Positions/sizes use `Geom` objects (immutable):

```lua
local Geom = require("ui/geometry")
local g = Geom:new{x=10, y=20, w=100, h=50}
local g2 = g:shrink(5)  -- Returns new Geom
local g3 = g:offsetBySize(g2)
```

All coordinates are integer pixels. **E-ink considerations**: Avoid frequent redraws; batch updates via `UIManager:setDirty()`.

### Blitting & Screen Updates

```lua
local Screen = Device.screen
local bb = Screen:newBB(Screen:getWidth(), Screen:getHeight())
widget:paintTo(bb, 0, 0)
Screen:refresh(0, 0, Screen:getWidth(), Screen:getHeight())
```

**Pattern**: Create BlitBuffer → paint widgets → refresh screen. Refreshes are expensive on e-ink.

### Input Events

Mapped via `Device.input` (platform-specific):

```lua
local Input = Device.input
Input:registerEventAdjustHook(function(event)
    if event.type == "Gesture" and event.gesture == "swipe" then
        -- Custom handling
    end
end)
```

Gesture types: swipe, tap, pinch, etc. Handled by `GestureDetector` → dispatcher → widgets.

### Language & i18n

Lua strings wrapped with `_()` for translation:

```lua
local _ = require("gettext")
local text = _("Settings")  -- Translatable string
local plural = _("1 file|%1 files", count)  -- Plural forms
```

Translations managed via Weblate → `l10n/` directory.

---

## Critical Files Reference

| Path | Purpose |
|------|---------|
| `frontend/ui/uimanager.lua` | Main event loop, screen refresh orchestration |
| `frontend/apps/reader/readerui.lua` | Reader app, module registration |
| `frontend/device.lua` | Device detection/probing |
| `frontend/luasettings.lua` | Settings persistence |
| `frontend/configurable.lua` | Config options abstraction |
| `defaults.lua` | Global defaults |
| `Makefile` / `kodev` | Build system |
| `spec/unit/` | Unit tests |
| `doc/Development_guide.md` | Architecture overview |
| `doc/Events.md` | Event system details |

---

## Common Pitfalls & Solutions

1. **"Infinite redraws"**: Avoid calling `UIManager:setDirty()` in `paintTo()`. Set dirty flags in event handlers.
2. **Lost settings**: Settings only persisted via `saveSetting()`. Changes in-memory don't auto-save.
3. **Memory leaks**: Unreference large objects in `onCloseWidget()` hooks; avoid circular references.
4. **Event not propagating**: Check `handleEvent()` returns `true` to consume. Returning `nil` = `false` = event continues.
5. **Plugin disabled silently**: Check `metadata.lua` structure and `plugins_disabled` setting.
6. **Cross-module communication**: Use events, not direct module calls. Prevents circular dependencies.

---

## When Adding Features

- **New menu option**: Add to `frontend/ui/data/` or module config, use `ConfigDialog`
- **New gesture**: Handle in `frontend/ui/gesturedetector.lua`, dispatch as event
- **New document format**: Extend `Document` in `frontend/document/`
- **New reader module**: Extend `EventListener`, register with `ReaderUI:registerModule()`
- **Plugin feature**: Create `.koplugin` with `metadata.lua`, use `PluginLoader`
- **Settings persistence**: Use `DocSettings` (per-doc) or `G_reader_settings` (global)

---

**Last updated**: December 2025 | KOReader master branch
