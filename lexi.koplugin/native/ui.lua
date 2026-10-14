--[[--
Lexi's window over the Kindle UI. Firmware 5.18 replaced pillow's HTML dialogs (its customDialog
now only opens Amazon's own), so Lexi shows its pages (native/*.html) itself: a GTK2 window with a
WebKitGTK 1.0 view, both part of the firmware, driven through LuaJIT's FFI.

Run from /mnt/us/koreader with KOReader's LuaJIT:
  ./luajit plugins/lexi.koplugin/native/ui.lua dialog|setup   JSON params on stdin, one per line;
                                                             exits when stdin closes
  ./luajit plugins/lexi.koplugin/native/ui.lua notice <text>  one message; exits when it closes

A page drives the window through native/bridge.js (pillow's nativeBridge API: size, position, show,
hide), and the events it sends come out on stdout as `lexiAsk "<value>"`, one per line, for
native/lexid.lua or native/cli.lua.

Deliberately doesn't load setupkoenv: stdout carries the events, and KOReader's loader logs there.
--]]

-- GTK and WebKit call back into Lua from C, and a compiled trace that gets called back panics.
jit.off()

local ffi = require("ffi")
local PLUGIN = "plugins/lexi.koplugin"
package.path = PLUGIN .. "/?.lua;" .. package.path
local Native = require("lexi_native")

local PAGES = { dialog = true, setup = true, notice = true }
local PAGE_DIR = "/mnt/us/koreader/" .. PLUGIN .. "/native/"
-- WebKit keeps caches under $HOME: somewhere writable that a reboot clears.
local HOME = "/var/tmp/lexi-ui"
local NOTICE_TIMEOUT_MS = 15000

ffi.cdef[[
typedef int gint; typedef int gboolean; typedef unsigned int guint; typedef unsigned long gulong;
typedef char gchar; typedef void *gpointer;
typedef struct _GtkWidget GtkWidget;
typedef struct _GIOChannel GIOChannel;
typedef void (*GCallback)(void);
typedef gboolean (*GSourceFunc)(gpointer);
typedef gboolean (*GIOFunc)(GIOChannel *source, int condition, gpointer data);
typedef void (*sighandler_t)(int);
sighandler_t signal(int signum, sighandler_t handler);
long read(int fd, void *buf, unsigned long count);
int setenv(const char *name, const char *value, int overwrite);
int mkdir(const char *path, unsigned int mode);
void g_thread_init(gpointer vtable);
gboolean gtk_init_check(int *argc, char ***argv);
GtkWidget *gtk_window_new(int type);
void gtk_window_set_title(GtkWidget *window, const gchar *title);
void gtk_window_move(GtkWidget *window, gint x, gint y);
void gtk_window_resize(GtkWidget *window, gint width, gint height);
void gtk_window_set_decorated(GtkWidget *window, gboolean setting);
void gtk_window_set_accept_focus(GtkWidget *window, gboolean setting);
void gtk_widget_set_size_request(GtkWidget *widget, gint width, gint height);
void gtk_widget_realize(GtkWidget *widget);
void gtk_widget_queue_draw(GtkWidget *widget);
void gtk_container_add(GtkWidget *container, GtkWidget *widget);
void gtk_widget_show_all(GtkWidget *widget);
void gtk_widget_hide(GtkWidget *widget);
void gtk_main(void);
void gtk_main_quit(void);
GtkWidget *webkit_web_view_new(void);
void webkit_web_view_load_uri(GtkWidget *view, const gchar *uri);
void webkit_web_view_execute_script(GtkWidget *view, const gchar *script);
gulong g_signal_connect_data(gpointer instance, const gchar *signal, GCallback handler, gpointer data,
                             gpointer destroy_data, int flags);
GIOChannel *g_io_channel_unix_new(int fd);
guint g_io_add_watch(GIOChannel *channel, int condition, GIOFunc func, gpointer data);
guint g_idle_add(GSourceFunc function, gpointer data);
guint g_timeout_add(guint interval, GSourceFunc function, gpointer data);
]]

local G_IO_IN, G_IO_ERR, G_IO_HUP, G_IO_NVAL = 1, 8, 16, 32
local GTK_WINDOW_TOPLEVEL, GTK_WINDOW_POPUP = 0, 1
local SIGPIPE = 13

local function log(...)
    io.stderr:write("ui: ", table.concat({ ... }, " "), "\n")
end

local page, notice_text = arg[1], arg[2]
if not PAGES[page] then
    io.stderr:write("Usage: ui.lua dialog | setup | notice <text>\n")
    os.exit(2)
end
local one_shot = page == "notice"

-- A reader that went away must not kill us with SIGPIPE: the failed write says so instead.
ffi.C.signal(SIGPIPE, ffi.cast("sighandler_t", 1)) -- SIG_IGN
-- Scriptlets and su don't pass the X display on.
ffi.C.setenv("DISPLAY", os.getenv("DISPLAY") or ":0", 1)
ffi.C.mkdir(HOME, 448) -- 0700
ffi.C.setenv("HOME", HOME, 1)

-- KOReader's luajit has RPATH $ORIGIN/libs, which holds KOReader's builds of some libraries the
-- firmware also has. GTK and WebKit need the firmware's (KOReader's SQLite, for one, lacks
-- sqlite3_open16): load those first, by path, so every later lookup by name finds them.
for _, name in ipairs{ "libz.so.1", "libzstd.so.1", "libstdc++.so.6", "libpng16.so.16", "libjpeg.so.8",
        "libfreetype.so.6", "libharfbuzz.so.0", "libfribidi.so.0", "libsqlite3.so.0" } do
    local ok, err = pcall(ffi.load, "/usr/lib/" .. name, true)
    if not ok then log("can't preload", name, tostring(err)) end
end
-- GLib older than 2.32 (the firmware has 2.29) needs this before anything else uses threads.
ffi.load("libgthread-2.0.so.0").g_thread_init(nil)
local glib = ffi.load("libglib-2.0.so.0")
local gobject = ffi.load("libgobject-2.0.so.0")
local gtk = ffi.load("libgtk-x11-2.0.so.0")
local webkit = ffi.load("libwebkitgtk-1.0.so.0")

if gtk.gtk_init_check(nil, nil) == 0 then
    log("can't open the display (DISPLAY=" .. tostring(os.getenv("DISPLAY")) .. ")")
    os.exit(1)
end

-- Callbacks live as long as the process: casting one per call would run out of callback slots.
local callbacks = {}
local function callback(ctype, fn, default)
    local cb = ffi.cast(ctype, function(...)
        local ok, ret = pcall(fn, ...)
        if not ok then
            log("error:", tostring(ret))
            return default
        end
        if ret == nil then return default end
        return ret
    end)
    table.insert(callbacks, cb)
    return cb
end

local function connect(object, signal, ctype, fn, default)
    gobject.g_signal_connect_data(object, signal, ffi.cast("GCallback", callback(ctype, fn, default)), nil, nil, 0)
end

-- Runs fn from the main loop, outside whatever callback we are in.
local idle_fn = {}
local idle_cb = callback("GSourceFunc", function()
    local fns = idle_fn
    idle_fn = {}
    for _, fn in ipairs(fns) do fn() end
    return 0
end, 0)
local function later(fn)
    table.insert(idle_fn, fn)
    if #idle_fn == 1 then glib.g_idle_add(idle_cb, nil) end
end

local function quit()
    later(function() gtk.gtk_main_quit() end)
end

-- The window -------------------------------------------------------------------------------------

-- An override-redirect popup: the window manager leaves it alone, so it stays exactly where the
-- page puts it, above the reader and its dictionary popup, and never takes the focus from them.
local window_type = os.getenv("LEXI_UI_WINDOW") == "toplevel" and GTK_WINDOW_TOPLEVEL or GTK_WINDOW_POPUP
local win = gtk.gtk_window_new(window_type)
gtk.gtk_window_set_title(win, "L:D_N:dialog_ID:lexi")
gtk.gtk_window_set_decorated(win, 0)
gtk.gtk_window_set_accept_focus(win, 0)

local view = webkit.webkit_web_view_new()
gtk.gtk_container_add(win, view)
-- WebKit asks for the window's position while the page loads, before the first show.
gtk.gtk_widget_realize(win)

local screen_w, screen_h = 1272, 1696
local state = { w = 10, h = 10, x = nil, y = nil, shown = false, ready = false, queue = {} }

local function place()
    gtk.gtk_widget_set_size_request(win, state.w, state.h)
    gtk.gtk_window_resize(win, state.w, state.h)
    -- Pages that don't say where are centered, as pillow did with its dialogs.
    local x = state.x or math.floor((screen_w - state.w) / 2)
    local y = state.y or math.floor((screen_h - state.h) / 2)
    gtk.gtk_window_move(win, x, y)
end

local function deliver(json)
    webkit.webkit_web_view_execute_script(view, "__lexiParams(" .. Native.jsString(json) .. ")")
end

local function emit(name, value)
    local ok = io.stdout:write(string.format('%s "%s"\n', name, value)) and io.stdout:flush()
    if not ok then
        log("output closed, exiting")
        quit()
    end
end

local OPS = {
    ready = function()
        state.ready = true
        local queued = state.queue
        state.queue = {}
        later(function()
            for _, json in ipairs(queued) do deliver(json) end
        end)
    end,
    size = function(op)
        state.w, state.h = math.max(1, op.w), math.max(1, op.h)
        if state.shown then place() end
    end,
    pos = function(op)
        state.x, state.y = op.x, op.y
        if state.shown then place() end
    end,
    show = function()
        place()
        gtk.gtk_widget_show_all(win)
        state.shown = true
    end,
    hide = function()
        gtk.gtk_widget_hide(win)
        state.shown = false
        state.x, state.y = nil, nil
        if one_shot then quit() end
    end,
    redraw = function()
        gtk.gtk_widget_queue_draw(view)
    end,
    event = function(op)
        emit(op.name, op.value)
    end,
}

connect(view, "console-message", "gboolean(*)(GtkWidget*, const gchar*, gint, const gchar*, gpointer)",
    function(_, message)
        local text = ffi.string(message)
        local op = Native.parseUiOp(text)
        if op then
            OPS[op.op](op)
        else
            log("page:", text)
        end
        return 1 -- handled: don't let WebKit print it too
    end, 1)

-- Input: one JSON object per line, for the page's registerClientParamsCallback --------------------

local pending = ""
local buf = ffi.new("char[?]", 65536)
local function onLine(line)
    if line == "" then return end
    if state.ready then deliver(line) else table.insert(state.queue, line) end
end

if one_shot then
    onLine('{"text":' .. Native.jsString(notice_text or "") .. "}")
    glib.g_timeout_add(NOTICE_TIMEOUT_MS, callback("GSourceFunc", function()
        log("notice timed out")
        gtk.gtk_main_quit()
        return 0
    end, 0), nil)
else
    local channel = glib.g_io_channel_unix_new(0)
    glib.g_io_add_watch(channel, G_IO_IN + G_IO_ERR + G_IO_HUP + G_IO_NVAL,
        callback("GIOFunc", function()
            local n = tonumber(ffi.C.read(0, buf, 65536))
            if n <= 0 then
                gtk.gtk_main_quit()
                return 0
            end
            pending = pending .. ffi.string(buf, n)
            for line in pending:gmatch("([^\n]*)\n") do onLine(line) end
            pending = pending:match("[^\n]*$")
            return 1
        end, 0), nil)
end

webkit.webkit_web_view_load_uri(view, "file://" .. PAGE_DIR .. page .. ".html")
gtk.gtk_main()
gtk.gtk_widget_hide(win)
