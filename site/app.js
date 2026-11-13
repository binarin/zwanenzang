// zwanenzang static site: list and detail panes over window.ZWANENZANG_DATA,
// which data.js defines. Hand-written, no dependencies, works from file://.
// Prose HTML in the data was rendered and escaped by the generator; every
// other value is inserted as text.
(function () {
  "use strict";

  var data = window.ZWANENZANG_DATA;
  if (!data) {
    document.getElementById("detail").textContent = "data.js is missing or failed to load.";
    return;
  }
  var tracker = data.tracker;
  var tickets = data.tickets;
  var byId = {};
  var byDisplay = {};
  tickets.forEach(function (t, i) {
    t.order = i;
    t.haystack = (t.display + " " + t.title).toLowerCase();
    var parts = [t.display, t.title, t.status, t.kind || ""].concat(t.tags);
    t.documents.forEach(function (d) { parts.push(d.name, d.text); });
    t.comments.forEach(function (c) { parts.push(c.actor, c.text || ""); });
    t.fulltext = parts.join("\n");
    t.fulltextLower = t.fulltext.toLowerCase();
    byId[t.id] = t;
    byDisplay[t.display.toUpperCase()] = t;
  });

  var ui = {
    statuses: {},
    tags: {},
    archived: false,
    sort: "number",
    filter: "",
    search: "",
  };
  tracker.statuses.forEach(function (s) {
    ui.statuses[s] = tracker.hidden_statuses.indexOf(s) < 0;
  });

  function $(id) { return document.getElementById(id); }

  // el("a", {href: "#x", class: "row"}, child, "text", ...)
  function el(tag, attrs) {
    var node = document.createElement(tag);
    if (attrs) {
      Object.keys(attrs).forEach(function (k) {
        if (attrs[k] === null || attrs[k] === undefined) return;
        if (k === "class") node.className = attrs[k];
        else if (k === "html") node.innerHTML = attrs[k];
        else node.setAttribute(k, attrs[k]);
      });
    }
    for (var i = 2; i < arguments.length; i++) {
      var c = arguments[i];
      if (c === null || c === undefined || c === false) continue;
      node.appendChild(typeof c === "string" ? document.createTextNode(c) : c);
    }
    return node;
  }

  // Every whitespace-separated word of the query must occur in order as a
  // subsequence of number and title.
  function fuzzy(query, hay) {
    var words = query.toLowerCase().split(/\s+/).filter(Boolean);
    return words.every(function (w) {
      var j = 0;
      for (var i = 0; i < hay.length && j < w.length; i++) {
        if (hay[i] === w[j]) j++;
      }
      return j === w.length;
    });
  }

  function searchWords() {
    return ui.search.toLowerCase().split(/\s+/).filter(Boolean);
  }

  function passesChips(t) {
    if (!ui.statuses[t.status]) return false;
    if (t.archived && !ui.archived) return false;
    return Object.keys(ui.tags).every(function (g) {
      return !ui.tags[g] || t.tags.indexOf(g) >= 0;
    });
  }

  function compare(a, b) {
    if (ui.sort === "activity") {
      if (a.activity !== b.activity) return a.activity < b.activity ? 1 : -1;
    }
    return a.order - b.order;
  }

  function statusBadge(s) {
    return el("span", { class: "status s-" + s }, s);
  }

  function currentId() {
    var h = decodeURIComponent(location.hash.replace(/^#/, ""));
    var t = byDisplay[h.toUpperCase()] || byId[h.toUpperCase()];
    return t ? t.id : null;
  }

  function row(t, context, snippet) {
    var a = el("a", {
      href: "#" + t.display,
      class: "row" + (context ? " context" : "") + (t.id === currentId() ? " selected" : ""),
      "data-id": t.id,
    },
      el("span", { class: "num" }, t.display),
      el("span", { class: "title" }, t.title, snippet || null),
      statusBadge(t.status));
    return a;
  }

  // A tree of the tickets that pass the filters, with the ancestors of
  // each shown dimmed so the hierarchy stays readable.
  function renderTree() {
    var shown = {};
    var matched = 0;
    var query = ui.filter.trim();
    tickets.forEach(function (t) {
      if (passesChips(t) && (!query || fuzzy(query, t.haystack))) {
        shown[t.id] = "match";
        matched++;
      }
    });
    Object.keys(shown).forEach(function (id) {
      var p = byId[id].parent;
      while (p && byId[p] && !shown[p]) {
        shown[p] = "context";
        p = byId[p].parent;
      }
    });
    function children(parentId) {
      return tickets.filter(function (t) {
        var p = t.parent && byId[t.parent] ? t.parent : null;
        return p === parentId && shown[t.id];
      }).sort(compare);
    }
    function list(items) {
      var ul = el("ul");
      items.forEach(function (t) {
        var kids = children(t.id);
        ul.appendChild(el("li", null, row(t, shown[t.id] === "context"),
          kids.length ? list(kids) : null));
      });
      return ul;
    }
    var tree = $("tree");
    tree.textContent = "";
    tree.appendChild(list(children(null)));
    $("count").textContent = matched + " of " + tickets.length + " tickets";
  }

  function snippetOf(t, words) {
    var text = t.fulltext;
    var lower = t.fulltextLower;
    var at = lower.indexOf(words[0]);
    var start = Math.max(0, at - 40);
    var end = Math.min(text.length, at + words[0].length + 60);
    var span = el("span", { class: "snippet" });
    span.appendChild(document.createTextNode((start > 0 ? "…" : "") +
      text.slice(start, at).replace(/\s+/g, " ")));
    span.appendChild(el("mark", null, text.slice(at, at + words[0].length)));
    span.appendChild(document.createTextNode(
      text.slice(at + words[0].length, end).replace(/\s+/g, " ") + (end < text.length ? "…" : "")));
    return span;
  }

  // Full-text results: a flat list, still subject to the filter chips.
  function renderSearch() {
    var words = searchWords();
    var hits = tickets.filter(function (t) {
      return words.every(function (w) { return t.fulltextLower.indexOf(w) >= 0; });
    });
    var visible = hits.filter(passesChips).sort(compare);
    var tree = $("tree");
    tree.textContent = "";
    var ul = el("ul");
    visible.forEach(function (t) {
      ul.appendChild(el("li", null, row(t, false, snippetOf(t, words))));
    });
    tree.appendChild(ul);
    var hidden = hits.length - visible.length;
    $("count").textContent = visible.length + " matching" +
      (hidden ? ", " + hidden + " more hidden by filters" : "");
  }

  function renderList() {
    if (searchWords().length) renderSearch();
    else renderTree();
    var off = tracker.statuses.filter(function (s) { return !ui.statuses[s]; });
    var on = Object.keys(ui.tags).filter(function (g) { return ui.tags[g]; });
    var parts = [];
    if (off.length) parts.push("hiding " + off.join(", "));
    if (!ui.archived) parts.push("no archived");
    if (on.length) parts.push("#" + on.join(" #"));
    $("filter-summary").textContent = parts.length ? "(" + parts.join("; ") + ")" : "";
  }

  function chip(label, pressed, onToggle, cls) {
    var b = el("button", { type: "button", class: "chip" + (cls ? " " + cls : ""),
      "aria-pressed": String(pressed) }, label);
    b.addEventListener("click", function () {
      var now = b.getAttribute("aria-pressed") !== "true";
      b.setAttribute("aria-pressed", String(now));
      onToggle(now);
      renderList();
    });
    return b;
  }

  function renderChips() {
    var sc = $("status-chips");
    tracker.statuses.forEach(function (s) {
      sc.appendChild(chip(s, ui.statuses[s], function (v) { ui.statuses[s] = v; }));
    });
    var tc = $("tag-chips");
    tracker.tags.forEach(function (g) {
      ui.tags[g] = false;
      tc.appendChild(chip(g, false, function (v) { ui.tags[g] = v; }, "tag"));
    });
    var ac = $("archived-chip");
    ac.addEventListener("click", function () {
      ui.archived = !ui.archived;
      ac.setAttribute("aria-pressed", String(ui.archived));
      renderList();
    });
  }

  function ticketLink(id) {
    var t = byId[id];
    if (!t) return null;
    return el("a", { href: "#" + t.display }, t.display + " " + t.title + " ",
      statusBadge(t.status));
  }

  function when(ts) {
    return ts ? ts.replace("T", " ").replace(/:\d\d(\.\d+)?Z$/, "Z") : "";
  }

  function renderDetail() {
    var id = currentId();
    var box = $("detail");
    box.textContent = "";
    document.body.classList.toggle("show-detail", !!id);
    Array.prototype.forEach.call(document.querySelectorAll(".row"), function (r) {
      r.classList.toggle("selected", r.getAttribute("data-id") === id);
    });
    if (!id) {
      box.appendChild(el("p", { class: "empty" }, "Select a ticket."));
      document.title = tracker.name;
      return;
    }
    var t = byId[id];
    document.title = t.display + " " + t.title + " – " + tracker.name;
    box.appendChild(el("h2", null, el("span", { class: "num" }, t.display), t.title));
    var meta = el("div", { class: "meta" },
      el("span", null, "status ", el("b", null, t.status)),
      t.kind ? el("span", null, "kind ", el("b", null, t.kind)) : null,
      t.priority ? el("span", null, "priority ", el("b", null, t.priority)) : null,
      t.archived ? el("span", { class: "archived-note" }, "archived") : null,
      el("span", null, "created " + when(t.created)),
      el("span", null, "active " + when(t.activity)));
    box.appendChild(meta);
    if (t.tags.length) {
      var tags = el("div", { class: "meta tags" });
      t.tags.forEach(function (g) { tags.appendChild(el("span", { class: "tag" }, g)); });
      box.appendChild(tags);
    }

    var rel = el("dl", { class: "relations" });
    function relation(label, ids) {
      var links = ids.map(ticketLink).filter(Boolean);
      if (!links.length) return;
      var dd = el("dd");
      links.forEach(function (a) { dd.appendChild(a); });
      rel.appendChild(el("dt", null, label));
      rel.appendChild(dd);
    }
    relation("Parent", t.parent ? [t.parent] : []);
    relation("Children", t.children);
    relation("Depends on", t.depends_on);
    relation("Blocks", t.blocks);
    relation("Related", t.related);
    if (t.branches.length) {
      var bd = el("dd");
      t.branches.forEach(function (b) {
        bd.appendChild(el("div", null,
          b.repo_url ? el("a", { href: b.repo_url }, b.repo) : b.repo, ": ", el("code", null, b.name)));
      });
      rel.appendChild(el("dt", null, "Branches"));
      rel.appendChild(bd);
    }
    if (t.mrs.length) {
      var md = el("dd");
      t.mrs.forEach(function (m) {
        md.appendChild(el("a", { href: /^https?:\/\//i.test(m.url) ? m.url : null },
          m.repo + ": " + m.url));
      });
      rel.appendChild(el("dt", null, "Merge requests"));
      rel.appendChild(md);
    }
    if (rel.childNodes.length) box.appendChild(rel);

    t.documents.forEach(function (d) {
      box.appendChild(el("section", { class: "doc" },
        el("h3", { class: "section" }, d.name,
          el("span", { class: "by" }, d.actor + ", " + when(d.ts))),
        el("div", { class: "prose", html: d.html })));
    });

    if (t.comments.length) {
      var cs = el("section", { class: "comments" },
        el("h3", { class: "section" }, "Comments (" + t.comments.length + ")"));
      t.comments.forEach(function (c) {
        var link = null;
        if (c.link) {
          link = el("p", { class: "attachment" }, "Attachment: ",
            c.link.href ? el("a", { href: c.link.href }, c.link.label) : c.link.label);
        }
        cs.appendChild(el("div", { class: "comment" },
          el("span", { class: "by" }, c.actor + ", " + when(c.ts)),
          c.html !== null ? el("div", { class: "prose", html: c.html })
            : el("p", { class: "empty" }, "(text unavailable)"),
          link));
      });
      box.appendChild(cs);
    }
    $("detail-pane").scrollTop = 0;
    if (window.innerWidth <= 760) window.scrollTo(0, 0);
  }

  $("tracker-name").textContent = tracker.name;
  document.title = tracker.name;
  renderChips();
  $("filter").addEventListener("input", function (e) { ui.filter = e.target.value; renderList(); });
  $("search").addEventListener("input", function (e) { ui.search = e.target.value; renderList(); });
  $("sort").addEventListener("change", function (e) { ui.sort = e.target.value; renderList(); });
  $("back").addEventListener("click", function (e) {
    e.preventDefault();
    history.pushState(null, "", location.pathname + location.search);
    renderDetail();
  });
  document.addEventListener("keydown", function (e) {
    var typing = /^(INPUT|SELECT|TEXTAREA)$/.test(document.activeElement.tagName);
    if (e.key === "/" && !typing) {
      e.preventDefault();
      $("filter").focus();
    } else if (e.key === "Escape" && typing) {
      document.activeElement.value = "";
      ui.filter = $("filter").value;
      ui.search = $("search").value;
      renderList();
    }
  });
  window.addEventListener("hashchange", renderDetail);
  window.addEventListener("popstate", renderDetail);
  renderList();
  renderDetail();
})();
