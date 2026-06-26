/**
 * Mobile navigation — hamburger toggle, escape to close, focus trap.
 * Expects: .nav-toggle, .nav-links, .nav-header
 */
(function () {
  "use strict";

  function initNav() {
    var toggle = document.querySelector(".nav-toggle");
    var panel = document.querySelector(".nav-links");
    if (!toggle || !panel) return;

    var focusable =
      'a[href], button:not([disabled]), input:not([disabled]), select:not([disabled]), textarea:not([disabled])';

    function setOpen(open) {
      toggle.setAttribute("aria-expanded", open ? "true" : "false");
      toggle.setAttribute("aria-label", open ? "Close menu" : "Open menu");
      panel.classList.toggle("is-open", open);
      document.body.classList.toggle("nav-open", open);
      if (open) {
        var items = panel.querySelectorAll(focusable);
        if (items.length) items[0].focus();
      }
    }

    function close() {
      setOpen(false);
    }

    toggle.addEventListener("click", function () {
      var isOpen = toggle.getAttribute("aria-expanded") === "true";
      setOpen(!isOpen);
    });

    panel.querySelectorAll("a").forEach(function (link) {
      link.addEventListener("click", close);
    });

    document.addEventListener("keydown", function (e) {
      if (e.key === "Escape") close();
    });

    document.addEventListener("click", function (e) {
      if (!panel.classList.contains("is-open")) return;
      if (toggle.contains(e.target) || panel.contains(e.target)) return;
      close();
    });

    panel.addEventListener("keydown", function (e) {
      if (e.key !== "Tab" || !panel.classList.contains("is-open")) return;
      var items = panel.querySelectorAll(focusable);
      if (!items.length) return;
      var first = items[0];
      var last = items[items.length - 1];
      if (e.shiftKey && document.activeElement === first) {
        e.preventDefault();
        last.focus();
      } else if (!e.shiftKey && document.activeElement === last) {
        e.preventDefault();
        first.focus();
      }
    });
  }

  if (document.readyState === "loading") {
    document.addEventListener("DOMContentLoaded", initNav);
  } else {
    initNav();
  }
})();
