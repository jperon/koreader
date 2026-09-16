-- vatican.koplugin — browse, search and download magisterial documents from
-- vatican.va, converted to EPUB.

ConfirmBox = require "ui/widget/confirmbox"
DataStorage = require "datastorage"
Device = require "device"
InfoMessage = require "ui/widget/infomessage"
InputDialog = require "ui/widget/inputdialog"
Menu = require "ui/widget/menu"
NetworkMgr = require "ui/network/manager"
Trapper = require "ui/trapper"
UIManager = require "ui/uimanager"
WidgetContainer = require "ui/widget/container/widgetcontainer"
filemanagerutil = require "apps/filemanager/filemanagerutil"
lfs = require "libs/libkoreader-lfs"
logger = require "logger"
util = require "util"
ffiutil = require "ffi/util"
_ = require "gettext"
T = ffiutil.template

catalog = require "vatican_catalog"
epub = require "vatican_epub"
parser = require "vatican_parser"
search = require "vatican_search"
search_external = require "vatican_search_external"

SETTINGS_KEY = "vatican"
REFRESH_INTERVAL = 24 * 60 * 60

-- Languages vatican.va publishes in, with their site codes.
LANGUAGES = {
    { code: "la", name: "Latina" }
    { code: "fr", name: "Français" }
    { code: "en", name: "English" }
    { code: "it", name: "Italiano" }
    { code: "es", name: "Español" }
    { code: "pt", name: "Português" }
    { code: "de", name: "Deutsch" }
}

languageName = (code) ->
    for lang in *LANGUAGES
        return lang.name if lang.code == code
    code

-- ------------------------------------------------------------------ browser --

Browser = Menu\extend{
    name: "vatican_browser"
    is_borderless: true
    is_popout: false
    covers_fullscreen: true
    title: _("Vatican")
}

Browser.init = =>
    @stack = {}
    Menu.init @

-- Menu shows its back arrow based on #self.paths, so the navigation stack is
-- mirrored there.
Browser.pushLevel = (title, items) =>
    table.insert @stack, { :title, :items }
    @paths = [{} for _ = 2, #@stack]
    @switchItemTable title, items

Browser.onReturn = =>
    return true if #@stack <= 1
    table.remove @stack
    level = @stack[#@stack]
    @paths = [{} for _ = 2, #@stack]
    @switchItemTable level.title, level.items
    true

Browser.onMenuSelect = (item) =>
    item.callback! if item.callback
    true

-- ------------------------------------------------------------------- plugin --

Vatican = WidgetContainer\extend{
    name: "vatican"
    is_doc_only: false
}

Vatican.init = =>
    @settings = G_reader_settings\readSetting(SETTINGS_KEY) or {}
    @ui.menu\registerToMainMenu @ if @ui.menu
    @scheduleRefresh 60

Vatican.saveSettings = =>
    G_reader_settings\saveSetting SETTINGS_KEY, @settings
    G_reader_settings\flush!

Vatican.getLang = => @settings.lang or "la"

Vatican.getDownloadDir = =>
    dir = @settings.download_dir
    unless dir
        dir = (G_reader_settings\readSetting("home_dir") or
            DataStorage\getDataDir!) .. "/vatican"
    lfs.mkdir dir unless lfs.attributes dir, "mode"
    dir

-- --------------------------------------------------------- daily refresh --

-- Keeps the roster warm without ever blocking the UI: it only runs when the
-- network is already up, and a failure just means trying again tomorrow.
--
-- The actual HTTP fetch (net.get, in net.moon) is a synchronous LuaSocket
-- call that can block for up to net.TOTAL_TIMEOUT seconds. Running it
-- straight from this scheduled callback would freeze all of KOReader's UI
-- for that long, since UIManager's scheduler runs on the single main loop.
-- Forking it into a real subprocess (ffiutil.runInSubProcess) keeps the
-- fetch off that loop entirely; the child writes straight to the on-disk
-- roster cache (catalog.writeCache, inside catalog.refreshIfStale), so the
-- parent only needs to poll for the child's exit, never touching its result.
Vatican.scheduleRefresh = (delay) =>
    UIManager\unschedule @refresh_task if @refresh_task
    @refresh_task = ->
        @backgroundRefresh!
        @scheduleRefresh REFRESH_INTERVAL
    UIManager\scheduleIn delay, @refresh_task

Vatican.backgroundRefresh = =>
    return unless NetworkMgr\isOnline!
    return if @refresh_pid -- a previous refresh is still running
    lang = @getLang!
    pid = ffiutil.runInSubProcess ->
        pcall catalog.refreshIfStale, lang
    unless pid
        logger.dbg "vatican: background refresh: fork failed"
        return
    @refresh_pid = pid
    @pollBackgroundRefresh!

-- Polls the forked refresh without blocking: reschedules itself every
-- second until the subprocess has exited.
Vatican.pollBackgroundRefresh = =>
    unless ffiutil.isSubProcessDone @refresh_pid
        UIManager\scheduleIn 1, -> @pollBackgroundRefresh!
        return
    logger.dbg "vatican: background refresh done"
    @refresh_pid = nil

Vatican.onCloseWidget = =>
    UIManager\unschedule @refresh_task if @refresh_task
    @refresh_task = nil
    if @refresh_pid
        ffiutil.terminateSubProcess @refresh_pid
        ffiutil.isSubProcessDone @refresh_pid, true -- reap it now, don't leave a zombie
        @refresh_pid = nil

-- --------------------------------------------------------------- main menu --

Vatican.addToMainMenu = (menu_items) =>
    menu_items.vatican = {
        text: _("Vatican library")
        sorting_hint: "search"
        sub_item_table: {
            {
                text: _("Browse by pope")
                keep_menu_open: false
                callback: -> @onBrowse!
            }
            {
                text: _("Search…")
                keep_menu_open: false
                callback: -> @onSearch!
            }
            {
                text: _("External search (web)…")
                keep_menu_open: false
                callback: -> @onExternalSearch!
            }
            {
                text: _("Open a vatican.va address…")
                keep_menu_open: true
                callback: -> @onOpenUrl!
            }
            {
                text: _("Set 'Save as EPUB' folder")
                keep_menu_open: true
                callback: ->
                    title_header = _("Current 'Save as EPUB' folder:")
                    current_path = @settings.download_dir
                    default_path = @getDownloadDir!
                    caller_callback = (path) ->
                        @settings.download_dir = path
                        @saveSettings!
                        lfs.mkdir path unless lfs.attributes path, "mode"
                    filemanagerutil.showChooseDialog title_header, caller_callback,
                        current_path, default_path
            }
            {
                text_func: -> T _("Language: %1"), languageName @getLang!
                keep_menu_open: true
                sub_item_table_func: -> @genLanguageMenu!
                separator: true
            }
            {
                text_func: -> @refreshMenuText!
                keep_menu_open: true
                callback: (touchmenu_instance) -> @onRefreshCatalog touchmenu_instance
            }
            {
                text: _("Clear cached indexes")
                keep_menu_open: true
                callback: (touchmenu_instance) ->
                    catalog.clearCache!
                    touchmenu_instance\updateItems! if touchmenu_instance
                    UIManager\show InfoMessage\new text: _("Cache cleared.")
            }
        }
    }

Vatican.refreshMenuText = =>
    age = catalog.rosterAge @getLang!
    return _("Refresh catalogue (never fetched)") unless age
    days = math.floor age / (24 * 60 * 60)
    if days < 1
        _("Refresh catalogue (updated today)")
    elseif days == 1
        _("Refresh catalogue (updated yesterday)")
    else
        T _("Refresh catalogue (updated %1 days ago)"), days

Vatican.genLanguageMenu = =>
    for lang in *LANGUAGES
        {
            text: lang.name
            checked_func: -> @getLang! == lang.code
            callback: ->
                @settings.lang = lang.code
                @saveSettings!
        }

Vatican.onRefreshCatalog = (touchmenu_instance) =>
    NetworkMgr\runWhenOnline -> Trapper\wrap ->
        Trapper\info _("Refreshing the catalogue…")
        roster, _from_cache, err = catalog.getRoster @getLang!, true
        Trapper\clear!
        if roster
            touchmenu_instance\updateItems! if touchmenu_instance
            UIManager\show InfoMessage\new
                text: T _("Catalogue updated: %1 popes."), #roster.popes
        else
            UIManager\show InfoMessage\new text: err or _("Refresh failed.")

-- ------------------------------------------------------------- navigation --

Vatican.showBrowser = (title, items) =>
    unless @browser
        @browser = Browser\new{
            title: title
            item_table: items
            close_callback: ->
                UIManager\close @browser
                @browser = nil
        }
        @browser.stack = { { :title, :items } }
        UIManager\show @browser
    else
        @browser\pushLevel title, items

Vatican.onBrowse = =>
    NetworkMgr\runWhenOnline -> Trapper\wrap -> @showPopes!

Vatican.showPopes = =>
    lang = @getLang!
    Trapper\info _("Loading the catalogue…")
    roster, _from_cache, err = catalog.getRoster lang
    Trapper\clear!
    unless roster
        UIManager\show InfoMessage\new text: err or _("Could not load the catalogue.")
        return
    items = for slug in *roster.popes
        {
            text: catalog.popeLabel roster, slug
            callback: -> @showSections slug, catalog.popeLabel(roster, slug)
        }
    @showBrowser T(_("Vatican — %1"), languageName lang), items

Vatican.showSections = (pope, pope_label) =>
    lang = @getLang!
    Trapper\info T _("Loading %1…"), pope_label
    sections, _from_cache, err = catalog.getSections pope, lang
    Trapper\clear!
    unless sections
        UIManager\show InfoMessage\new text: err or _("Nothing available for this pope.")
        return
    items = for section in *sections
        {
            text: section.label
            callback: -> @showIndex section.url, section.label,
                { :pope, :pope_label, section_label: section.label }
        }
    @showBrowser pope_label, items

Vatican.showIndex = (url, title, context) =>
    Trapper\info T _("Loading %1…"), title
    index, _from_cache, err = catalog.getIndex url
    Trapper\clear!
    unless index
        UIManager\show InfoMessage\new text: err or _("Nothing found in this index.")
        return
    items = {}
    -- Sub-indexes first: they are the years of a prolific section, and the
    -- documents list, when both are present, is only a leftover of the page.
    for sub in *index.subindexes
        table.insert items, {
            text: sub.label
            callback: -> @showIndex sub.url, sub.label, context
        }
    for doc in *index.documents
        label = doc.date and T("%1 — %2", doc.name, doc.date) or doc.name
        table.insert items, {
            text: label
            mandatory: doc.date and "" or nil
            callback: -> @showDocument doc.url, doc.name, context
        }
    @showBrowser title, items

-- ---------------------------------------------------------------- download --

Vatican.showDocument = (url, name, context) =>
    Trapper\info T _("Fetching %1…"), name or url
    doc, err = catalog.getDocument url
    Trapper\clear!
    unless doc
        UIManager\show InfoMessage\new text: err or _("Could not read this document.")
        return
    doc.pope_label = context and context.pope_label
    doc.section_label = context and context.section_label
    @confirmDownload doc

Vatican.confirmDownload = (doc) =>
    filename = epub.suggestedFilename doc
    path = @getDownloadDir! .. "/" .. filename
    exists = lfs.attributes path, "mode"
    lines = { doc.name or doc.title }
    table.insert lines, T _("Date: %1"), doc.date if doc.date
    if #doc.translations > 1
        codes = [tr.lang\upper! for tr in *doc.translations]
        table.insert lines, T _("Also in: %1"), table.concat codes, ", "
    table.insert lines, _("This file already exists and will be replaced.") if exists

    UIManager\show ConfirmBox\new
        text: table.concat(lines, "\n") .. "\n\n" ..
            T _("Save as EPUB in %1?"), @getDownloadDir!
        ok_text: _("Save")
        ok_callback: -> Trapper\wrap -> @writeDocument doc, path
        other_buttons: { {
            {
                text: _("Save As…")
                callback: -> @onSaveDocumentAs doc, filename
            }
        } }

Vatican.onSaveDocumentAs = (doc, filename) =>
    caller_callback = (dir) ->
        Trapper\wrap -> @writeDocument doc, dir .. "/" .. filename
    filemanagerutil.showChooseDialog _("Choose destination folder:"), caller_callback,
        nil, @getDownloadDir!

Vatican.writeDocument = (doc, path) =>
    Trapper\info _("Building the EPUB…")
    ok, err = epub.build doc, path
    Trapper\clear!
    unless ok
        UIManager\show InfoMessage\new text: err or _("Could not build the EPUB.")
        return
    UIManager\show ConfirmBox\new
        text: T _("Saved to:\n%1\n\nOpen it now?"), path
        ok_text: _("Open")
        ok_callback: ->
            UIManager\close @browser if @browser
            @browser = nil
            ReaderUI = require "apps/reader/readerui"
            ReaderUI\showReader path

-- ------------------------------------------------------------------ search --

Vatican.onSearch = =>
    dialog = nil
    dialog = InputDialog\new
        title: _("Search vatican.va")
        description: _("The site's full-text index only covers the recent pontificates; older documents are reachable by browsing.")
        input: @settings.last_query or ""
        buttons: { {
            {
                text: _("Cancel")
                id: "close"
                callback: -> UIManager\close dialog
            }
            {
                text: _("Search")
                is_enter_default: true
                callback: ->
                    query = dialog\getInputText!
                    UIManager\close dialog
                    return unless query and query\match "%S"
                    @settings.last_query = query
                    @saveSettings!
                    NetworkMgr\runWhenOnline -> Trapper\wrap -> @runSearch query
            }
        } }
    UIManager\show dialog
    dialog\onShowKeyboard!

Vatican.runSearch = (query) =>
    Trapper\info T _("Searching for “%1”…"), query
    lang = @getLang!
    solr_results, _total, err = search.run { :query, :lang }
    cached_results = catalog.searchTitles query, lang
    Trapper\clear!
    unless solr_results or #cached_results > 0
        UIManager\show InfoMessage\new text: err or _("Search failed.")
        return
    results = search.mergeResults solr_results or {}, cached_results
    if #results == 0
        UIManager\show InfoMessage\new
            text: T _("No result for “%1”.\n\nThe site's index does not cover the older pontificates: try browsing by pope instead."), query
        return
    items = for result in *results
        info = parser.parseDocumentPath(result.url) or {}
        {
            text: result.title
            mandatory: info.date
            callback: -> @showDocument result.url, result.title
        }
    @showBrowser T(_("%1 (%2 results)"), query, #results), items

Vatican.onExternalSearch = =>
    dialog = nil
    dialog = InputDialog\new
        title: _("External search (web)")
        description: _("Queries a public search engine (« site:vatican.va … ») to find documents missing from the site's own index.")
        input: @settings.last_external_query or ""
        buttons: { {
            {
                text: _("Cancel")
                id: "close"
                callback: -> UIManager\close dialog
            }
            {
                text: _("Search")
                is_enter_default: true
                callback: ->
                    query = dialog\getInputText!
                    UIManager\close dialog
                    return unless query and query\match "%S"
                    @settings.last_external_query = query
                    @saveSettings!
                    NetworkMgr\runWhenOnline -> Trapper\wrap -> @runExternalSearch query
            }
        } }
    UIManager\show dialog
    dialog\onShowKeyboard!

Vatican.runExternalSearch = (query) =>
    Trapper\info T _("Searching the web for “%1”…"), query
    results, err = search_external.run query, @getLang!
    Trapper\clear!
    unless results
        UIManager\show InfoMessage\new text: err or _("External search failed.")
        return
    if #results == 0
        UIManager\show InfoMessage\new
            text: T _("No external result for “%1”."), query
        return
    items = for result in *results
        info = parser.parseDocumentPath(result.url) or {}
        {
            text: result.title
            mandatory: info.date
            callback: -> @showDocument result.url, result.title
        }
    @showBrowser T(_("%1 (external search, %2 results)"), query, #results), items

-- ---------------------------------------------------------------- open URL --

Vatican.onOpenUrl = =>
    dialog = nil
    dialog = InputDialog\new
        title: _("Open a vatican.va address")
        description: _("Paste the address of a document page.")
        input: "https://www.vatican.va/content/"
        buttons: { {
            {
                text: _("Cancel")
                id: "close"
                callback: -> UIManager\close dialog
            }
            {
                text: _("Open")
                is_enter_default: true
                callback: ->
                    url = util.trim dialog\getInputText!
                    UIManager\close dialog
                    unless url\match "^https?://[%w%.%-]*vatican%.va/"
                        UIManager\show InfoMessage\new
                            text: _("This is not a vatican.va address.")
                        return
                    NetworkMgr\runWhenOnline -> Trapper\wrap -> @showDocument url, url
            }
        } }
    UIManager\show dialog
    dialog\onShowKeyboard!

Vatican
