// Background instance for the USBGuard plugin.
//
// Responsibilities:
//  - Run `usbguard watch` as a long-lived process and parse its line-based output.
//  - Maintain a ListModel of currently known devices (keyed by rule id from the daemon).
//  - On startup, hydrate the model from `usbguard list-devices` so devices already
//    connected before noctalia started are visible.
//  - Expose imperative methods (allow/block/reject) used by Panel.qml.
//  - Fire a notification when a new device is inserted in `block` state.

import QtQuick
import Quickshell
import Quickshell.Io

QtObject {
    id: root

    // Injected by noctalia.
    property var pluginApi: null

    // --- Public model consumed by BarWidget.qml and Panel.qml ---------------
    //
    // Each row: {
    //   ruleId:   int      // daemon's internal id (first column of list-devices)
    //   target:   string   // "allow" | "block" | "reject"
    //   event:    string   // last event seen ("Insert" | "Update" | "Remove" | "")
    //   vendorId: string   // e.g. "13fe"
    //   productId:string   // e.g. "3600"
    //   name:     string
    //   serial:   string
    //   port:     string   // via-port
    //   hash:     string
    //   raw:      string   // the full rule line, useful for tooltips
    // }
    property ListModel devices: ListModel {}

    // Number of currently-blocked devices — drives the bar badge color.
    readonly property int blockedCount: {
        let n = 0;
        for (let i = 0; i < devices.count; i++) {
            if (devices.get(i).target === "block") n++;
        }
        return n;
    }

    readonly property bool watchRunning: watchProc.running

    // --- Settings convenience accessor --------------------------------------
    readonly property var settings: pluginApi ? pluginApi.pluginSettings : null
    readonly property string usbguardCmd: settings && settings.usbguardCommand
                                           ? settings.usbguardCommand
                                           : "usbguard"

    // --- Long-running watcher -----------------------------------------------
    //
    // `usbguard watch -w` waits for the IPC socket if the daemon isn't up yet,
    // so we don't race against `usbguard.service` at session start.
    //
    // IMPORTANT: usbguard's watch output puts each *field* of an event on its
    // own line (event=, target=, device_rule=...). We can't dispatch per-line.
    // Instead, we accumulate lines into _eventBuf and flush whenever we see a
    // new record header ("[device]" or "[IPC]"), or when the stream goes idle
    // for a moment.
    property string _eventBuf: ""

    property Timer flushTimer: Timer {
        id: flushTimer
        interval: 150   // ms of inactivity that signal "event is complete"
        repeat: false
        onTriggered: root._flushBuffer()
    }

    property Process watchProc: Process {
        id: watchProc
        // Use sh -c so we can splice in the configurable command name.
        command: ["sh", "-c", root.usbguardCmd + " watch -w"]
        running: true

        stdout: SplitParser {
            onRead: line => root._ingestWatchLine(line)
        }
        stderr: SplitParser {
            onRead: line => console.warn("[usbguard plugin] watch stderr:", line)
        }

        // If the daemon restarts, `watch` exits. Auto-restart with a small delay
        // so we don't busy-loop if usbguard is permanently gone.
        onRunningChanged: {
            if (!running) {
                console.warn("[usbguard plugin] watch exited, restarting in 2s");
                restartTimer.start();
            }
        }
    }

    property Timer restartTimer: Timer {
        id: restartTimer
        interval: 2000
        repeat: false
        onTriggered: watchProc.running = true
    }

    // --- One-shot processes for actions and hydration -----------------------

    // Used for the initial `list-devices` dump.
    property Process listProc: Process {
        id: listProc
        command: ["sh", "-c", root.usbguardCmd + " list-devices"]
        stdout: StdioCollector {
            onStreamFinished: root._handleListOutput(this.text)
        }
    }

    // Generic action runner. We don't keep state between actions; if multiple
    // are fired rapidly Quickshell will queue them via separate Process instances
    // created inline (see _runAction below).

    // --- Lifecycle ----------------------------------------------------------
    Component.onCompleted: {
        // Kick off hydration. We do this whether or not watch has started; any
        // events that arrive between hydrate and list-devices completing will
        // just upsert correctly.
        listProc.running = true;
    }

    // --- Public API ---------------------------------------------------------

    function allowDevice(ruleId, permanent) {
        const args = permanent
            ? [root.usbguardCmd, "allow-device", "-p", String(ruleId)]
            : [root.usbguardCmd, "allow-device",      String(ruleId)];
        _runAction(args, "allow");
    }

    function blockDevice(ruleId, permanent) {
        const args = permanent
            ? [root.usbguardCmd, "block-device", "-p", String(ruleId)]
            : [root.usbguardCmd, "block-device",      String(ruleId)];
        _runAction(args, "block");
    }

    function rejectDevice(ruleId, permanent) {
        const args = permanent
            ? [root.usbguardCmd, "reject-device", "-p", String(ruleId)]
            : [root.usbguardCmd, "reject-device",      String(ruleId)];
        _runAction(args, "reject");
    }

    function refresh() {
        if (!listProc.running) listProc.running = true;
    }

    // --- Internals ----------------------------------------------------------

    function _runAction(argv, label) {
        // Dynamically spawn a Process so concurrent clicks don't fight over one.
        const proc = actionComponent.createObject(root, { "argv": argv, "label": label });
        proc.start();
    }

    property Component actionComponent: Component {
        QtObject {
            id: holder
            property var argv: []
            property string label: ""
            property Process p: Process {
                id: p
                stdout: StdioCollector { onStreamFinished: { /* swallow */ } }
                stderr: StdioCollector {
                    onStreamFinished: {
                        if (this.text && this.text.length)
                            console.warn("[usbguard plugin]", holder.label, "stderr:", this.text);
                    }
                }
                onRunningChanged: {
                    if (!running) {
                        // After any action, re-sync from the daemon — the
                        // policy may have changed in ways `watch` won't echo
                        // (e.g. a rule appended by `-p`).
                        root.refresh();
                        holder.destroy();
                    }
                }
            }
            function start() {
                p.command = argv;
                p.running = true;
            }
        }
    }

    // Accumulates lines into a single record. `usbguard watch` may split
    // an event's fields across multiple lines (Remove events do this on
    // recent versions; Insert events sometimes do too). A new record starts
    // when we see a "[device]" or "[IPC]" header, so on every header we flush
    // whatever we'd accumulated so far. We also flush on a short timer in
    // case the last event of a burst isn't followed by another header.
    function _ingestWatchLine(line) {
        if (line === undefined || line === null) return;
        const trimmed = line.trim();
        const isHeader = trimmed.startsWith("[device]") || trimmed.startsWith("[IPC]");

        if (isHeader) {
            // Flush whatever was pending before starting a new record.
            _flushBuffer();
            _eventBuf = trimmed;
        } else if (_eventBuf.length > 0) {
            // Continuation line — join with a space so the regex/field parsing
            // sees a normal single-line event.
            _eventBuf += " " + trimmed;
        }
        // No active buffer and no header → ignore.

        // (Re)arm the idle flush so the final event in a burst gets handled.
        flushTimer.restart();
    }

    function _flushBuffer() {
        const ev = _eventBuf;
        _eventBuf = "";
        if (!ev) return;
        _handleWatchEvent(ev);
    }

    // Parser for a single (now-coalesced) `usbguard watch` event.
    //
    // Coalesced events look like:
    //   [device] PresenceChanged: id=36 event=Insert target=block device_rule=block id 13fe:3600 serial "..." name "..." hash "..." parent-hash "..." via-port "2-4" with-interface 08:06:50 with-connect-type "hotplug"
    //   [device] PolicyChanged:   id=36 target_old=block target_new=allow device_rule=allow id 13fe:3600 ...
    //   [device] PresenceChanged: id=33 event=Remove target=block device_rule=block id 0951:1666 ...
    //
    // Other events we just log and ignore.
    function _handleWatchEvent(line) {
        if (!line) return;
        if (line.indexOf("PresenceChanged") < 0 && line.indexOf("PolicyChanged") < 0)
            return;

        const fields = _parseEventLine(line);
        if (!fields || fields.ruleId < 0) return;

        const isInsert = fields.event === "Insert";
        const isRemove = fields.event === "Remove";

        if (isRemove) {
            _removeByRuleId(fields.ruleId);
            return;
        }

        const existed = _upsertDevice(fields);

        // Notify on a freshly-inserted device that the daemon decided to block.
        if (isInsert && !existed && fields.target === "block"
                && root.settings && root.settings.notifyOnInsert) {
            _notify(fields);
        }
    }

    function _handleListOutput(text) {
        if (!text) return;
        // Each line: "<id>: <target> id VID:PID serial ... name ... hash ... via-port ..."
        const lines = text.split("\n");
        const seen = {};
        for (const raw of lines) {
            const line = raw.trim();
            if (!line) continue;
            const m = line.match(/^(\d+):\s+(allow|block|reject)\s+(.*)$/);
            if (!m) continue;
            const ruleId = parseInt(m[1], 10);
            const target = m[2];
            const rest = m[3];
            const attrs = _parseRuleAttrs(rest);
            _upsertDevice({
                ruleId: ruleId,
                target: target,
                event: "",
                vendorId: attrs.vendorId,
                productId: attrs.productId,
                name: attrs.name,
                serial: attrs.serial,
                port: attrs.port,
                hash: attrs.hash,
                raw: rest
            });
            seen[ruleId] = true;
        }
        // Drop anything the daemon no longer knows about.
        for (let i = devices.count - 1; i >= 0; i--) {
            if (!seen[devices.get(i).ruleId]) devices.remove(i);
        }
    }

    // Parses one PresenceChanged / PolicyChanged line into a flat object.
    function _parseEventLine(line) {
        const ruleId = _intField(line, "id");
        const event  = _wordField(line, "event") || "";
        // target may come through as either `target=` (PresenceChanged) or
        // `target_new=` (PolicyChanged).
        let target = _wordField(line, "target");
        if (!target) target = _wordField(line, "target_new");
        if (!target) target = "";

        // The rule body (the part after "device_rule=<target>") contains the
        // attributes we want to display.
        let ruleBody = "";
        const drIdx = line.indexOf("device_rule=");
        if (drIdx >= 0) {
            // Skip past "device_rule=<word> "
            const tail = line.substring(drIdx + "device_rule=".length);
            const spaceIdx = tail.indexOf(" ");
            ruleBody = spaceIdx >= 0 ? tail.substring(spaceIdx + 1) : "";
        }
        const attrs = _parseRuleAttrs(ruleBody);

        return {
            ruleId: isNaN(ruleId) ? -1 : ruleId,
            target: target,
            event: event,
            vendorId: attrs.vendorId,
            productId: attrs.productId,
            name: attrs.name,
            serial: attrs.serial,
            port: attrs.port,
            hash: attrs.hash,
            raw: ruleBody
        };
    }

    // Extract a "key=value" word (unquoted).
    function _wordField(line, key) {
        const re = new RegExp("(?:^|\\s)" + key + "=([^\\s]+)");
        const m = line.match(re);
        return m ? m[1] : "";
    }

    function _intField(line, key) {
        const v = _wordField(line, key);
        return v ? parseInt(v, 10) : NaN;
    }

    // Parses a USBGuard rule body of the form:
    //   id 13fe:3600 serial "07A7..." name "USB DISK 2.0" hash "..." parent-hash "..." via-port "2-4" with-interface ...
    function _parseRuleAttrs(body) {
        const out = { vendorId: "", productId: "", name: "", serial: "", port: "", hash: "" };
        if (!body) return out;

        // id VID:PID
        const idMatch = body.match(/(?:^|\s)id\s+([0-9a-fA-F]{4}):([0-9a-fA-F]{4})/);
        if (idMatch) { out.vendorId = idMatch[1]; out.productId = idMatch[2]; }

        // Quoted-string attributes. We grab name, serial, hash, via-port.
        const grab = (k) => {
            const m = body.match(new RegExp("(?:^|\\s)" + k + "\\s+\"([^\"]*)\""));
            return m ? m[1] : "";
        };
        out.name   = grab("name");
        out.serial = grab("serial");
        out.hash   = grab("hash");
        out.port   = grab("via-port");
        return out;
    }

    function _findIndex(ruleId) {
        for (let i = 0; i < devices.count; i++) {
            if (devices.get(i).ruleId === ruleId) return i;
        }
        return -1;
    }

    // Returns true if the device already existed in the model.
    function _upsertDevice(d) {
        const idx = _findIndex(d.ruleId);
        if (idx >= 0) {
            // Merge: don't overwrite known attributes with empty strings.
            const cur = devices.get(idx);
            const merged = {
                ruleId:    d.ruleId,
                target:    d.target || cur.target,
                event:     d.event  || cur.event,
                vendorId:  d.vendorId  || cur.vendorId,
                productId: d.productId || cur.productId,
                name:      d.name   || cur.name,
                serial:    d.serial || cur.serial,
                port:      d.port   || cur.port,
                hash:      d.hash   || cur.hash,
                raw:       d.raw    || cur.raw
            };
            devices.set(idx, merged);
            return true;
        }
        devices.append(d);
        return false;
    }

    function _removeByRuleId(ruleId) {
        const idx = _findIndex(ruleId);
        if (idx >= 0) devices.remove(idx);
    }

    function _notify(d) {
        // Use noctalia's notification service if exposed via pluginApi; otherwise
        // fall back to notify-send. We probe both lazily to stay compatible
        // across noctalia versions.
        const title = "USB device blocked";
        const vidpid = (d.vendorId && d.productId) ? (d.vendorId + ":" + d.productId) : "";
        const body = (d.name ? d.name : "Unknown device")
                   + (vidpid ? "  [" + vidpid + "]" : "")
                   + (d.port ? "  via " + d.port : "");

        if (pluginApi && typeof pluginApi.notify === "function") {
            pluginApi.notify(title, body);
            return;
        }
        notifyProc.command = ["notify-send", "-a", "USBGuard", "-i", "drive-removable-media-usb", title, body];
        notifyProc.running = true;
    }

    property Process notifyProc: Process {
        id: notifyProc
        stdout: StdioCollector {}
        stderr: StdioCollector {}
    }
}
