# Guide de l'API des Plugins KOReader

## Introduction

Ce document décrit l'architecture et l'API pour développer des plugins pour KOReader, un lecteur de documents open-source principalement destiné aux liseuses à encre électronique.

KOReader est écrit en **Lua** et utilise un système de widgets basé sur des événements pour son interface utilisateur. Les plugins sont entièrement scriptés en Lua et peuvent étendre les fonctionnalités de KOReader de manière modulaire.

## Structure d'un Plugin

### Organisation des Fichiers

Chaque plugin KOReader est un dossier avec l'extension `.koplugin` contenant au minimum :

```
myplugin.koplugin/
├── _meta.lua        # Métadonnées du plugin (nom, description)
└── main.lua         # Code principal du plugin
```

### Fichier _meta.lua

Ce fichier contient les métadonnées affichées dans l'interface :

```lua
local _ = require("gettext")
return {
    name = "myplugin",
    fullname = _("My Plugin"),
    description = _([[This plugin does something useful.]]),
}
```

### Fichier main.lua

Le fichier principal doit retourner une classe héritant de `WidgetContainer` :

```lua
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local _ = require("gettext")

local MyPlugin = WidgetContainer:extend{
    name = "myplugin",
    is_doc_only = false,  -- true si le plugin ne fonctionne qu'avec un document ouvert
}

function MyPlugin:init()
    self.ui.menu:registerToMainMenu(self)
end

function MyPlugin:addToMainMenu(menu_items)
    menu_items.my_plugin = {
        text = _("My Plugin"),
        callback = function()
            -- Action du plugin
        end,
    }
end

return MyPlugin
```

## Architecture de Base

### Héritage de WidgetContainer

Tous les plugins héritent de `WidgetContainer`, qui fournit :
- La gestion des événements
- L'intégration dans la hiérarchie de widgets
- Les mécanismes de dessin et de mise à jour

```lua
local MyPlugin = WidgetContainer:extend{
    name = "myplugin",
    is_doc_only = false,
}
```

### Cycle de Vie d'un Plugin

1. **Découverte** : Le `PluginLoader` scanne les dossiers `.koplugin`
2. **Chargement** : Le fichier `main.lua` est chargé
3. **Initialisation** : La méthode `:init()` est appelée
4. **Enregistrement** : Le plugin s'enregistre dans les menus/événements
5. **Exécution** : Les callbacks et handlers sont appelés selon les interactions utilisateur

### Méthodes Principales

#### :init()
Appelée au chargement du plugin. C'est ici qu'on initialise le plugin :

```lua
function MyPlugin:init()
    self:onDispatcherRegisterActions()
    self.ui.menu:registerToMainMenu(self)
end
```

#### :addToMainMenu(menu_items)
Ajoute des entrées au menu principal :

```lua
function MyPlugin:addToMainMenu(menu_items)
    menu_items.my_action = {
        text = _("My Action"),
        sorting_hint = "more_tools",  -- Position dans le menu
        callback = function()
            -- Code exécuté lors du tap
        end,
    }
end
```

Options pour les entrées de menu :
- `text` : Texte affiché
- `callback` : Fonction appelée au tap
- `hold_callback` : Fonction appelée au long appui
- `sorting_hint` : Catégorie du menu ("more_tools", "navigation", etc.)
- `keep_menu_open` : true pour garder le menu ouvert après l'action
- `enabled` : boolean ou fonction retournant boolean
- `checked_func` : fonction retournant boolean pour une coche
- `sub_item_table` : table pour créer un sous-menu

## Système d'Événements

### Dispatcher - Actions Globales

Le Dispatcher permet d'enregistrer des actions globales accessibles via les gestes et raccourcis :

```lua
local Dispatcher = require("dispatcher")

function MyPlugin:onDispatcherRegisterActions()
    Dispatcher:registerAction("my_action", {
        category = "none",
        event = "MyEvent",
        title = _("My Action"),
        general = true,
    })
end
```

Catégories d'actions :
- `"none"` : Appel direct d'événement
- `"arg"` : Événement avec argument
- `"string"` : Liste de choix (args + toggle)
- `"absolutenumber"` : Définit un nombre
- `"incrementalnumber"` : Incrémente un nombre

Portées :
- `general = true` : Action disponible partout
- `reader = true` : Uniquement dans le lecteur
- `device = true` : Actions liées au device
- `filemanager = true` : Uniquement dans le gestionnaire de fichiers

### Handlers d'Événements

Les méthodes préfixées par `on` sont automatiquement enregistrées comme handlers :

```lua
function MyPlugin:onMyEvent()
    UIManager:show(InfoMessage:new{
        text = _("Event received!"),
    })
    return true  -- true = événement consommé, false = propagation continue
end
```

Événements système courants :
- `onShow` : Widget affiché
- `onCloseWidget` : Widget fermé
- `onClose` : Fermeture manuelle
- `onSuspend` : Mise en veille
- `onResume` : Sortie de veille

## Interface Utilisateur

### UIManager

Le `UIManager` gère l'affichage et les rafraîchissements :

```lua
local UIManager = require("ui/uimanager")

-- Afficher un widget
UIManager:show(widget)

-- Fermer un widget
UIManager:close(widget)

-- Marquer une zone pour rafraîchissement
UIManager:setDirty(widget, "ui")  -- Types: "ui", "partial", "full", "flashui"
```

### Widgets Courants

#### InfoMessage - Messages d'Information

```lua
local InfoMessage = require("ui/widget/infomessage")

UIManager:show(InfoMessage:new{
    text = _("Hello World"),
    timeout = 3,  -- Auto-fermeture après 3 secondes
})
```

#### ConfirmBox - Boîtes de Confirmation

```lua
local ConfirmBox = require("ui/widget/confirmbox")

UIManager:show(ConfirmBox:new{
    text = _("Are you sure?"),
    ok_callback = function()
        -- Action si OK
    end,
    cancel_callback = function()
        -- Action si annulé
    end,
})
```

#### InputDialog - Saisie de Texte

```lua
local InputDialog = require("ui/widget/inputdialog")

local input = InputDialog:new{
    title = _("Enter text"),
    input = "",  -- Texte initial
    buttons = {
        {
            {
                text = _("Cancel"),
                callback = function()
                    UIManager:close(input)
                end,
            },
            {
                text = _("OK"),
                is_enter_default = true,
                callback = function()
                    local text = input:getInputText()
                    -- Utiliser le texte
                    UIManager:close(input)
                end,
            },
        },
    },
}
UIManager:show(input)
input:onShowKeyboard()
```

#### KeyValuePage - Affichage de Données

```lua
local KeyValuePage = require("ui/widget/keyvaluepage")

UIManager:show(KeyValuePage:new{
    title = _("Statistics"),
    kv_pairs = {
        {_("Key 1"), "Value 1"},
        {_("Key 2"), "Value 2"},
    },
})
```

#### ButtonDialog - Dialogue avec Boutons

```lua
local ButtonDialog = require("ui/widget/buttondialog")

local dialog = ButtonDialog:new{
    title = _("Choose action"),
    buttons = {
        {
            {
                text = _("Action 1"),
                callback = function()
                    -- Action 1
                    UIManager:close(dialog)
                end,
            },
        },
        {
            {
                text = _("Action 2"),
                callback = function()
                    -- Action 2
                    UIManager:close(dialog)
                end,
            },
        },
    },
}
UIManager:show(dialog)
```

### Gestion des Gestes

Pour capturer des gestes tactiles, définir `ges_events` :

```lua
local GestureRange = require("ui/gesturerange")
local Geom = require("ui/geometry")

function MyWidget:init()
    self.ges_events = {
        TapSelect = {
            GestureRange:new{
                ges = "tap",
                range = self.dimen,
            },
        },
        HoldSelect = {
            GestureRange:new{
                ges = "hold",
                range = self.dimen,
            },
        },
    }
end

function MyWidget:onTapSelect(arg, ges)
    -- ges.pos contient la position du tap
    return true
end

function MyWidget:onHoldSelect(arg, ges)
    -- Long appui
    return true
end
```

Gestes disponibles :
- `"tap"` : Tap simple
- `"hold"` : Long appui
- `"swipe"` : Balayage
- `"pan"` : Glissement
- `"spread"` : Écartement (zoom)
- `"pinch"` : Pincement (dézoom)
- `"multiswipe"` : Geste multi-doigts

## Persistance des Données

### LuaSettings - Paramètres Simples

```lua
local DataStorage = require("datastorage")
local LuaSettings = require("luasettings")

-- Créer/ouvrir un fichier de paramètres
local settings = LuaSettings:open(
    DataStorage:getSettingsDir() .. "/myplugin.lua"
)

-- Lire
local value = settings:readSetting("key")

-- Écrire
settings:saveSetting("key", "value")

-- Flush vers le disque
settings:flush()
```

### G_reader_settings - Paramètres Globaux

```lua
-- Paramètres globaux de KOReader
local value = G_reader_settings:readSetting("key")
G_reader_settings:saveSetting("key", value)
```

### DocSettings - Paramètres par Document

```lua
local DocSettings = require("docsettings")

local doc_settings = DocSettings:open(document_path)
local value = doc_settings:readSetting("key")
doc_settings:saveSetting("key", value)
doc_settings:flush()
```

### Base de Données SQLite

```lua
local SQ3 = require("lua-ljsqlite3/init")

local db = SQ3.open(db_path)
local stmt = db:prepare("SELECT * FROM table WHERE id = ?")
stmt:bind1(1)

for row in stmt:rows() do
    -- Traiter les lignes
end

stmt:finalize()
db:close()
```

## Utilitaires Courants

### Traduction (i18n)

```lua
local _ = require("gettext")
local T = require("ffi/util").template

-- Traduction simple
local text = _("Hello")

-- Traduction avec paramètres
local text = T(_("Hello %1"), name)

-- Pluriels
local N_ = _.ngettext
local text = N_("1 book", "%1 books", count)
```

### Journalisation

```lua
local logger = require("logger")

logger.dbg("Debug message", variable)
logger.info("Info message")
logger.warn("Warning message")
logger.err("Error message")
```

### Utilitaires Fichiers

```lua
local util = require("util")
local lfs = require("libs/libkoreader-lfs")

-- Vérifier existence
if util.pathExists(path) then end

-- Attributs fichier
local attr = lfs.attributes(path)
if attr.mode == "file" then end

-- Lister répertoire
for file in lfs.dir(path) do
    -- Traiter fichier
end

-- Opérations de chemin
local dir, name = util.splitFilePathName(path)
local base, ext = util.splitFileNameType(name)
```

### Réseau

```lua
local UIManager = require("ui/uimanager")
local NetworkMgr = require("ui/network/manager")

NetworkMgr:runWhenOnline(function()
    -- Code exécuté une fois en ligne
end)

-- HTTP
local HTTPClient = require("httpclient")
local response = HTTPClient:get(url, {headers = {}})
```

### Notifications

```lua
local Notification = require("ui/widget/notification")

UIManager:show(Notification:new{
    text = _("Operation complete"),
})
```

## Plugin Patterns Avancés

### Plugin avec Switch (Activation/Désactivation)

```lua
local SwitchPlugin = require("ui/plugin/switch_plugin")

local MyPlugin = SwitchPlugin:extend{
    name = "myplugin",
    menu_item = "my_plugin",
    menu_text = _("My Plugin"),
    confirm_message = _("Enable My Plugin?"),
    default_enable = false,
}

function MyPlugin:_start()
    -- Démarrage du plugin
end

function MyPlugin:_stop()
    -- Arrêt du plugin
end
```

### Plugin Lecteur Only

```lua
local MyPlugin = WidgetContainer:extend{
    name = "myplugin",
    is_doc_only = true,  -- Actif uniquement avec document ouvert
}

-- Accès au document
function MyPlugin:onSomeAction()
    local doc = self.ui.document
    local current_page = self.ui.paging:getCurrentPage()
end
```

### Intégration au Menu Highlight

```lua
function MyPlugin:init()
    if self.ui.highlight then
        self.ui.highlight:addToHighlightDialog("my_action", function(this)
            return {
                text = _("My Action"),
                callback = function()
                    local selected_text = this.selected_text.text
                    -- Traiter le texte sélectionné
                end,
            }
        end)
    end
end
```

### Tâches en Arrière-Plan

```lua
UIManager:scheduleIn(5, function()
    -- Exécuté après 5 secondes
end)

-- Tick suivant
UIManager:nextTick(function()
    -- Exécuté au prochain tick
end)

-- Idle (quand rien à faire)
UIManager:whenIdle(function()
    -- Exécuté quand idle
end)
```

## Debugging

### Logger Debug

```lua
local logger = require("logger")
local dbg = require("dbg")

-- Activer debug verbose
dbg:turnOn()

logger.dbg("Variable:", variable)
```

### WBuilder - Test de Widgets

Utiliser `tools/wbuilder.lua` pour tester des widgets isolément :

```bash
./kodev wbuilder
```

### Stacktraces

Les handlers de plugins sont automatiquement wrappés pour fournir des stacktraces en cas d'erreur dans `crash.log`.

## Exemples de Plugins

### Plugin Hello World Minimal

```lua
-- plugins/hello.koplugin/_meta.lua
local _ = require("gettext")
return {
    name = "hello",
    fullname = _("Hello World"),
    description = _([[A simple hello world plugin.]]),
}
```

```lua
-- plugins/hello.koplugin/main.lua
local InfoMessage = require("ui/widget/infomessage")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local _ = require("gettext")

local Hello = WidgetContainer:extend{
    name = "hello",
    is_doc_only = false,
}

function Hello:init()
    self.ui.menu:registerToMainMenu(self)
end

function Hello:addToMainMenu(menu_items)
    menu_items.hello_world = {
        text = _("Hello World"),
        sorting_hint = "more_tools",
        callback = function()
            UIManager:show(InfoMessage:new{
                text = _("Hello, plugin world!"),
            })
        end,
    }
end

return Hello
```

### Plugin avec Paramètres

```lua
local DataStorage = require("datastorage")
local LuaSettings = require("luasettings")
local SpinWidget = require("ui/widget/spinwidget")

local MyPlugin = WidgetContainer:extend{
    name = "myplugin",
}

function MyPlugin:init()
    self.settings = LuaSettings:open(
        DataStorage:getSettingsDir() .. "/myplugin.lua"
    )
    self.value = self.settings:readSetting("value") or 10
    self.ui.menu:registerToMainMenu(self)
end

function MyPlugin:addToMainMenu(menu_items)
    menu_items.myplugin = {
        text = _("My Plugin"),
        sub_item_table = {
            {
                text = _("Set Value"),
                keep_menu_open = true,
                callback = function()
                    local spin = SpinWidget:new{
                        value = self.value,
                        value_min = 1,
                        value_max = 100,
                        title_text = _("Set value"),
                        callback = function(spin)
                            self.value = spin.value
                            self.settings:saveSetting("value", self.value)
                        end,
                    }
                    UIManager:show(spin)
                end,
            },
        },
    }
end
```

## Ressources et Documentation

### Documentation API
- Générée via LDoc : `http://koreader.rocks/doc/`
- Code source : `https://github.com/koreader/koreader`

### Fichiers Clés
- `frontend/pluginloader.lua` : Chargement des plugins
- `frontend/dispatcher.lua` : Système de dispatch
- `frontend/ui/uimanager.lua` : Gestion UI
- `frontend/ui/widget/` : Widgets de base

### Exemples de Plugins
- `plugins/hello.koplugin/` : Hello world (debug)
- `plugins/statistics.koplugin/` : Plugin complexe avec DB
- `plugins/gestures.koplugin/` : Gestion avancée des gestes
- `plugins/calibre.koplugin/` : Intégration réseau
- `plugins/systemstat.koplugin/` : Plugin système simple

### Build et Test
```bash
# Émulateur
./kodev build
./kodev run

# Tests
./kodev test front

# Documentation
cd doc && make
```

## Checklist pour un Nouveau Plugin

- [ ] Créer le dossier `myplugin.koplugin/`
- [ ] Créer `_meta.lua` avec name, fullname, description
- [ ] Créer `main.lua` héritant de `WidgetContainer`
- [ ] Implémenter `:init()` et enregistrer le plugin
- [ ] Implémenter `:addToMainMenu()` pour l'interface
- [ ] (Optionnel) Implémenter `:onDispatcherRegisterActions()` pour les actions globales
- [ ] (Optionnel) Gérer les paramètres avec `LuaSettings`
- [ ] Tester avec l'émulateur
- [ ] Gérer les traductions avec `_()`
- [ ] Logger avec `logger.dbg()` pour debug
- [ ] Documenter le plugin

## Conventions de Code

1. **Indentation** : 4 espaces
2. **Nommage** :
   - Variables : `snake_case`
   - Classes : `PascalCase`
   - Constantes : `UPPER_CASE`
3. **Retour des handlers** : `true` si événement consommé, `false` ou `nil` sinon
4. **Cleanup** : Implémenter `:onCloseWidget()` si nécessaire
5. **i18n** : Toujours utiliser `_()` pour les chaînes visibles

---

**Ce guide couvre les fondamentaux de l'API des plugins KOReader. Pour des cas d'usage avancés, consultez le code source des plugins existants et la documentation générée.**
