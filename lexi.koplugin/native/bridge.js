// Lexi's stand-in for pillow's nativeBridge. Firmware 5.18 replaced pillow's HTML dialogs, so
// native/ui.lua shows Lexi's pages in a window of its own and listens to their console messages:
// "lexi:<op> <args>" (parsed by lexi_native.lua, Native.parseUiOp). ES5: WebKitGTK 1.x.
(function () {
    function op(s) { console.log("lexi:" + s); }
    var callback = null;

    // native/ui.lua calls this with each JSON line it receives on stdin.
    window.__lexiParams = function (json) {
        if (callback) callback(json);
    };

    window.nativeBridge = {
        registerClientParamsCallback: function (fn) {
            callback = fn;
            op("ready");
        },
        setWindowSize: function (w, h) { op("size " + Math.round(w) + " " + Math.round(h)); },
        // Without it the window is centered.
        setWindowPosition: function (x, y) { op("pos " + Math.round(x) + " " + Math.round(y)); },
        showMe: function () { op("show"); },
        dismissMe: function () { op("hide"); },
        redraw: function () { op("redraw"); },
        // The source is ignored: the event goes to whoever reads native/ui.lua's output.
        sendLipcEvent: function (source, name, value) {
            op("event " + name + " " + String(value === undefined || value === null ? "" : value));
        }
    };
})();
