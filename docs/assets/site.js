// Lowpoly Terrain Editor documentation: section highlight in the sidebar,
// copy buttons on code blocks, sidebar open on wide screens.
(function () {
  // The sidebar is a <details>: open on wide screens, folded on phones.
  var toc = document.querySelector(".toc details");
  if (toc && window.matchMedia("(min-width: 901px)").matches) toc.open = true;

  // Highlight the section being read.
  var links = Array.prototype.slice.call(document.querySelectorAll(".toc a[href^='#']"));
  if (links.length && "IntersectionObserver" in window) {
    var byId = {};
    links.forEach(function (a) { byId[a.getAttribute("href").slice(1)] = a; });
    var visible = {};
    var observer = new IntersectionObserver(function (entries) {
      entries.forEach(function (e) { visible[e.target.id] = e.isIntersecting; });
      var current = null;
      for (var i = links.length - 1; i >= 0; i--) {
        var id = links[i].getAttribute("href").slice(1);
        if (visible[id]) { current = id; break; }
      }
      if (!current) return;
      links.forEach(function (a) { a.classList.remove("active"); a.removeAttribute("aria-current"); });
      byId[current].classList.add("active");
      byId[current].setAttribute("aria-current", "location");
    }, { rootMargin: "-80px 0px -55% 0px" });
    Object.keys(byId).forEach(function (id) {
      var section = document.getElementById(id);
      if (section) observer.observe(section);
    });
  }

  // Copy buttons.
  document.querySelectorAll("pre").forEach(function (pre) {
    var code = pre.querySelector("code");
    if (!code || !navigator.clipboard) return;
    var button = document.createElement("button");
    button.type = "button";
    button.className = "copy";
    button.textContent = "Copy";
    button.addEventListener("click", function () {
      navigator.clipboard.writeText(code.textContent).then(function () {
        button.textContent = "Copied";
        setTimeout(function () { button.textContent = "Copy"; }, 1600);
      }, function () {
        button.textContent = "Select and copy";
      });
    });
    pre.appendChild(button);
  });
})();
