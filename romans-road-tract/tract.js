(() => {
  const card = document.getElementById("flip-card");
  const buttons = document.querySelectorAll(".side-btn");

  const setSide = (side) => {
    const showEn = side === "en";
    card.classList.toggle("is-flipped", showEn);

    buttons.forEach((btn) => {
      if (!btn.dataset.side) return;
      const active = btn.dataset.side === side;
      btn.classList.toggle("is-active", active);
      btn.setAttribute("aria-pressed", active ? "true" : "false");
    });
  };

  buttons.forEach((btn) => {
    btn.addEventListener("click", () => {
      const action = btn.dataset.action;
      if (action === "print") {
        window.print();
        return;
      }
      if (action === "flip") {
        const next = card.classList.contains("is-flipped") ? "jp" : "en";
        setSide(next);
        return;
      }
      if (btn.dataset.side) setSide(btn.dataset.side);
    });
  });

  // Keyboard: F to flip, P to print
  window.addEventListener("keydown", (e) => {
    if (e.target.matches("input, textarea, select")) return;
    if (e.key === "f" || e.key === "F") {
      setSide(card.classList.contains("is-flipped") ? "jp" : "en");
    }
    if (e.key === "p" || e.key === "P") {
      if (!e.metaKey && !e.ctrlKey) {
        e.preventDefault();
        window.print();
      }
    }
  });
})();
