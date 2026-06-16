# org-to-reveal — render an Org workbook as a reveal deck

# org-to-reveal — workbook → presentation
  When the content already lives as an Org workbook and the user wants to
  *present* it, render it as reveal.js instead of the document viewer.

  The mapping is mechanical (Org is already slide-shaped):
  - Each top-level heading (`*`) → one `<section class`"slide">=.
  - `:slide:`-tagged nodes are explicit slides; sub-headings (`**`) become
    vertical stacks (reveal nested `<section>`) or fragments.
  - Wrap the rendered sections in `.reveal>.slides`, add the reveal CDN css/js,
    and init with =Reveal.initialize({controls:true,progress:true,hash:true,
    transition:"none"})=.

  The renderer (org→HTML, in the runtime kernel) takes a presentation mode that
  applies this wrap; the same Org renders as a document (the viewer) OR a deck
  (reveal) — one source, two surfaces. For a from-scratch designed deck with a
  palette + slide types, prefer the `deck` skill (brandnana book).
