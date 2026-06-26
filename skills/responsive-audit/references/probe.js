/**
 * The responsive audit probe.
 *
 * Load into the target page via `agent-browser eval "$(cat probe.js)" --json`.
 * Returns structured data on three failure modes:
 *
 *  - docOverflow:        page wider than viewport (real layout bug)
 *  - offenders:          interactive elements bleeding past viewport edge,
 *                        EXCLUDING those inside intentional overflow-x
 *                        scrollers or [role=dialog] portals
 *  - unannouncedScrollers: overflow-x containers with off-screen content
 *                        but no aria-roledescription and no sibling fade
 *                        gradient — looks broken to the user
 */
(() => {
  const isScroller = (start) => {
    let el = start.parentElement;
    while (el && el !== document.body) {
      const ox = getComputedStyle(el).overflowX;
      if (ox === "auto" || ox === "scroll") return true;
      el = el.parentElement;
    }
    return false;
  };

  const findScrollers = () => {
    const out = [];
    const all = document.querySelectorAll("main *, header *");
    for (const el of Array.from(all)) {
      const ox = getComputedStyle(el).overflowX;
      if (ox !== "auto" && ox !== "scroll") continue;
      if (el.scrollWidth <= el.clientWidth + 1) continue;
      const announces =
        el.getAttribute("aria-roledescription") ||
        el.querySelector("[aria-roledescription]");
      const hasFadeSibling =
        !!el.parentElement &&
        Array.from(el.parentElement.children).some(
          (sib) =>
            sib !== el &&
            /pointer-events-none/.test(sib.className || "") &&
            /(bg-gradient|from-background|from-card)/.test(
              sib.className || "",
            ),
        );
      if (!announces && !hasFadeSibling) {
        out.push({
          tag: el.tagName.toLowerCase(),
          cls: (el.className || "").toString().slice(0, 60),
          scrollW: el.scrollWidth,
          clientW: el.clientWidth,
        });
      }
    }
    return out.slice(0, 5);
  };

  return {
    url: location.pathname,
    docScrollW: document.documentElement.scrollWidth,
    innerW: window.innerWidth,
    docOverflow: document.documentElement.scrollWidth - window.innerWidth,
    offenders: Array.from(
      document.querySelectorAll(
        "main button, main a[href], main [role='button'], main input, main select",
      ),
    )
      .map((e) => ({
        tag: e.tagName.toLowerCase(),
        text: (
          e.textContent ||
          e.getAttribute("aria-label") ||
          e.getAttribute("placeholder") ||
          ""
        )
          .trim()
          .slice(0, 40),
        right: Math.round(e.getBoundingClientRect().right),
        inScroller: isScroller(e),
      }))
      .filter((o) => o.right > window.innerWidth + 4 && !o.inScroller)
      .slice(0, 10),
    unannouncedScrollers: findScrollers(),
  };
})();
