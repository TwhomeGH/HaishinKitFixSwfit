/* 深/淺色主題：在 <head> 同步載入以避免閃爍；切換鈕為 #theme（可選）。 */
(function () {
  var KEY = "theme";
  function preferred() {
    try {
      var t = localStorage.getItem(KEY);
      if (t === "dark" || t === "light") return t;
    } catch (e) {}
    return matchMedia("(prefers-color-scheme:dark)").matches ? "dark" : "light";
  }
  function apply(t) {
    document.documentElement.dataset.theme = t;
    try { localStorage.setItem(KEY, t); } catch (e) {}
    var b = document.getElementById("theme");
    if (b) {
      b.textContent = t === "dark" ? "☀️" : "🌙";
      b.title = t === "dark" ? "切換淺色" : "切換深色";
    }
  }
  apply(preferred());
  window.toggleTheme = function () {
    apply(document.documentElement.dataset.theme === "dark" ? "light" : "dark");
  };
  document.addEventListener("DOMContentLoaded", function () {
    var b = document.getElementById("theme");
    if (b) { b.onclick = window.toggleTheme; apply(document.documentElement.dataset.theme); }
  });
})();
