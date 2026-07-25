// The sender's id, passed straight through to the app's own scheme. It is only
// ever put in a link: the page never reads it back, stores it, or sends it
// anywhere, and following the link creates no connection by itself.
//
// In its own file rather than inline so the site's Content-Security-Policy can
// refuse inline script outright. The page's <style> stays inline on purpose —
// see the comment on it — which costs style-src 'unsafe-inline' and nothing
// else; an inline stylesheet cannot execute.
(function () {
  var from = new URLSearchParams(window.location.search).get("from");
  var open = document.getElementById("open");
  var target = "freebnb://invite";
  if (from) target += "?from=" + encodeURIComponent(from);
  open.setAttribute("href", target);
  open.hidden = false;
})();
