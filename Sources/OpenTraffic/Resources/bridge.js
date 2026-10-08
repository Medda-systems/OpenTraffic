/*
 * OpenTraffic localhost bridge, served at /__opentraffic/bridge.js after one generated line:
 *   window.__opentrafficBridge = {"appPort":5173,"ports":[7880,3001]};
 * Runs first in <head>. On a page reached through a tunnel, calls the app makes to other local
 * services (http://localhost:3001, ws://127.0.0.1:7880...) go through the tunnel instead:
 *   - the app's own port      -> same origin, same path;
 *   - an allowed port         -> /__opentraffic/port/<port>/...;
 *   - any other loopback port -> unchanged, reported once so the host can allow it.
 * Spec: specs/collab-plan.md, "3.1 Localhost bridge". ES2017, no dependencies, never throws.
 */
(function () {
  "use strict";
  try {
    var w = window;
    if (w.__opentrafficBridgeInfo) return; // injected twice

    var cfg = w.__opentrafficBridge;
    var validPort = function (n) { return typeof n === "number" && n % 1 === 0 && n >= 1 && n <= 65535; };
    if (!cfg || typeof cfg !== "object" || !validPort(cfg.appPort)) return;
    if (cfg.ports !== undefined && !Array.isArray(cfg.ports)) return;
    var appPort = cfg.appPort;
    var allowed = new Set();
    var ports = [];
    (cfg.ports || []).slice(0, 256).forEach(function (p) {
      if (validPort(p) && p !== appPort && !allowed.has(p)) { allowed.add(p); ports.push(p); }
    });

    var loc = w.location;
    var page = String(loc.hostname).toLowerCase();
    var active = !(page === "localhost" || page === "127.0.0.1" || page === "[::1]" || page === "::1" ||
      page === "0.0.0.0" || /\.localhost\.?$/.test(page) || /^127\.\d+\.\d+\.\d+$/.test(page));

    Object.defineProperty(w, "__opentrafficBridgeInfo", {
      value: Object.freeze({ active: active, appPort: appPort, ports: Object.freeze(ports.slice()) }),
    });
    if (!active) return;

    // Exact loopback hosts only; a Set, so names like "constructor" or "__proto__" never match.
    var TARGETS = new Set(["localhost", "127.0.0.1", "[::1]", "::1", "0.0.0.0"]);
    var origFetch = typeof w.fetch === "function" ? w.fetch : null;
    var wanted = new Set();
    var wantCount = 0;

    // Tells the proxy this page tried to reach a local port nobody allowed yet (once per port).
    function want(port) {
      if (wanted.has(port) || wantCount >= 32 || !origFetch) return;
      wanted.add(port);
      wantCount++;
      try {
        var p = origFetch.call(w, "/__opentraffic/bridge/want?port=" + port, { method: "POST", keepalive: true });
        if (p && typeof p.catch === "function") p.catch(function () {});
      } catch (e) { /* ignore */ }
    }

    // The URL to use instead of `raw`, or null to leave it alone.
    function rewrite(raw) {
      var u;
      try { u = new URL(String(raw), document.baseURI || loc.href); } catch (e) { return null; }
      var proto = u.protocol;
      var socket = proto === "ws:" || proto === "wss:";
      if (!socket && proto !== "http:" && proto !== "https:") return null;
      if (!TARGETS.has(u.hostname)) return null;
      var port = u.port ? Number(u.port) : proto === "https:" || proto === "wss:" ? 443 : 80;
      var secure = loc.protocol === "https:";
      var base = (socket ? (secure ? "wss:" : "ws:") : secure ? "https:" : "http:") + "//" + loc.host;
      if (port === appPort) return base + u.pathname + u.search + u.hash;
      if (allowed.has(port)) return base + "/__opentraffic/port/" + port + u.pathname + u.search;
      want(port);
      return null;
    }

    // Makes a wrapper look like the function it replaces (name, length, toString).
    function disguise(fn, orig) {
      try {
        Object.defineProperty(fn, "name", { value: orig.name, configurable: true });
        Object.defineProperty(fn, "length", { value: orig.length, configurable: true });
        Object.defineProperty(fn, "toString", {
          value: function toString() { return Function.prototype.toString.call(orig); },
          configurable: true, writable: true,
        });
      } catch (e) { /* ignore */ }
      return fn;
    }

    // ---- fetch: strings, URL objects, Request objects (rebuilt with the new URL)
    var NativeRequest = typeof w.Request === "function" ? w.Request : null;
    function rebuild(req, url) {
      var init = {
        method: req.method, headers: req.headers, credentials: req.credentials, cache: req.cache,
        redirect: req.redirect, referrer: req.referrer, referrerPolicy: req.referrerPolicy,
        integrity: req.integrity, keepalive: req.keepalive, signal: req.signal,
      };
      if (req.mode && req.mode !== "navigate") init.mode = req.mode;
      if (req.method === "GET" || req.method === "HEAD" || req.body === null) {
        return new NativeRequest(url, init);
      }
      // Streaming request bodies aren't portable; buffer the body like fetch would send it.
      return req.arrayBuffer().then(function (buf) {
        init.body = buf;
        return new NativeRequest(url, init);
      });
    }
    if (origFetch) {
      w.fetch = disguise(function fetch(input, init) {
        var args = Array.prototype.slice.call(arguments);
        var req = null;
        try {
          if (NativeRequest && input instanceof NativeRequest) {
            var to = rewrite(input.url);
            if (to) req = rebuild(input, to);
          } else if (input != null) {
            var s = rewrite(input);
            if (s) args[0] = s;
          }
        } catch (e) { req = null; }
        if (req && typeof req.then === "function") {
          return req.then(function (r) { args[0] = r; return origFetch.apply(w, args); });
        }
        if (req) args[0] = req;
        return origFetch.apply(w, args);
      }, origFetch);
    }

    // ---- XMLHttpRequest.prototype.open (argument count matters: open(m, u, undefined) is sync)
    var XHR = w.XMLHttpRequest;
    if (XHR && XHR.prototype && typeof XHR.prototype.open === "function") {
      var origOpen = XHR.prototype.open;
      XHR.prototype.open = disguise(function open(method, url) {
        var args = Array.prototype.slice.call(arguments);
        if (args.length > 1) {
          try { var s = rewrite(url); if (s) args[1] = s; } catch (e) { /* leave it */ }
        }
        return origOpen.apply(this, args);
      }, origOpen);
    }

    // ---- navigator.sendBeacon
    var navProto = w.Navigator && w.Navigator.prototype;
    var beaconHost = navProto && typeof navProto.sendBeacon === "function" ? navProto
      : w.navigator && typeof w.navigator.sendBeacon === "function" ? w.navigator : null;
    if (beaconHost) {
      var origBeacon = beaconHost.sendBeacon;
      beaconHost.sendBeacon = disguise(function sendBeacon(url, data) {
        var args = Array.prototype.slice.call(arguments);
        if (args.length) {
          try { var s = rewrite(url); if (s) args[0] = s; } catch (e) { /* leave it */ }
        }
        return origBeacon.apply(this, args);
      }, origBeacon);
    }

    // ---- WebSocket and EventSource: same constructor identity as far as pages can tell
    // (instanceof, prototype, static constants, name, length), only the URL changes.
    function wrapClass(name) {
      var Orig = w[name];
      if (typeof Orig !== "function" || typeof Reflect !== "object" || !Reflect.construct) return;
      var Bridged = function () {
        if (!new.target) return Orig.apply(this, arguments); // throws like the original
        var args = Array.prototype.slice.call(arguments);
        if (args.length) {
          try { var s = rewrite(args[0]); if (s) args[0] = s; } catch (e) { /* leave it */ }
        }
        return Reflect.construct(Orig, args, new.target); // Bridged.prototype === Orig.prototype
      };
      Object.getOwnPropertyNames(Orig).forEach(function (k) {
        if (k === "prototype" || k === "name" || k === "length" || k === "arguments" || k === "caller") return;
        try { Object.defineProperty(Bridged, k, Object.getOwnPropertyDescriptor(Orig, k)); } catch (e) { /* ignore */ }
      });
      Object.defineProperty(Bridged, "prototype", { value: Orig.prototype, writable: false, enumerable: false, configurable: false });
      try { Object.setPrototypeOf(Bridged, Object.getPrototypeOf(Orig)); } catch (e) { /* ignore */ }
      disguise(Bridged, Orig);
      try {
        Object.defineProperty(Orig.prototype, "constructor", { value: Bridged, writable: true, enumerable: false, configurable: true });
      } catch (e) { /* ignore */ }
      w[name] = Bridged;
    }
    wrapClass("WebSocket");
    wrapClass("EventSource");
  } catch (e) {
    // Never break the page.
  }
})();
