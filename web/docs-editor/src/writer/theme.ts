// Atlantis: the Writer took its colours from the BetterSEQTA+ theme. Here it follows the Mac's
// light/dark setting with plain system greys and the system blue (until Atlantis's design tokens
// land). A media-query listener, not a timer, so idle stays idle.

const LIGHT = {
  "--text-primary": "#1d1d1f",
  "--background-primary": "#ffffff",
  "--background-secondary": "#f5f5f4",
  "--ob-solid": "#ffffff",
  "--ob-accent": "#0a66e4",
};
const DARK = {
  "--text-primary": "#f2f2f2",
  "--background-primary": "#1e1e1e",
  "--background-secondary": "#171717",
  "--ob-solid": "#262626",
  "--ob-accent": "#3b8cff",
};

export function followTheme(target: HTMLElement): () => void {
  const media = window.matchMedia("(prefers-color-scheme: dark)");
  const apply = () => {
    const dark = media.matches;
    for (const [k, v] of Object.entries(dark ? DARK : LIGHT)) target.style.setProperty(k, v);
    target.classList.toggle("is-dark", dark);
    document.documentElement.classList.toggle("dark", dark);
  };
  apply();
  media.addEventListener("change", apply);
  return () => media.removeEventListener("change", apply);
}
