// The sender's id, passed straight through to the app's own scheme. It is only
// ever put in a link: the page never reads it back, stores it, or sends it
// anywhere, and following the link creates no connection by itself.
//
// In its own file so the site's CSP can refuse inline script outright; the page's <style> stays inline (see
// its comment), costing only style-src 'unsafe-inline'.
(function () {
  var from = new URLSearchParams(window.location.search).get("from");
  var open = document.getElementById("open");
  var target = "freebnb://invite";
  if (from) target += "?from=" + encodeURIComponent(from);
  open.setAttribute("href", target);
  open.hidden = false;
})();
