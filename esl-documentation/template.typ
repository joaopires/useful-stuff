#import "@preview/hydra:0.6.2": hydra

// ===== Title Page =====

#let titlepage(
  doc-category,
  doc-title,
  author,
  affiliation,
  logo,
  heading-font,
  heading-color,
  info-size,
  datetime-fmt,
) = {
  set page(
    paper: "a4",
    margin: (top: 3cm, left: 2cm, right: 2cm, bottom: 4.5cm),
  )

  place(top + right, logo)

  v(6cm)

  align(
    left,
    text(font: heading-font, weight: "regular", size: 14pt,
      doc-category),
  )

  text(font: heading-font, weight: "light", size: 36pt, fill: heading-color,
    doc-title,
  )

  set par(leading: 1em)

  place(
    bottom + left,
    text(
      font: heading-font, weight: "regular", size: info-size, fill: black,
      datetime.today().display(datetime-fmt) + str("\n") +
      author + str("\n") +
      affiliation),
  )
}

// ===== Compact Title =====

#let compact-title(
  doc-category,
  doc-title,
  author,
  affiliation,
  logo,
  heading-font,
  heading-color,
  info-size,
  body-size,
  label-size,
  datetime-fmt,
) = {
  stack(
    v(1.5cm - 0.6cm),
    box(height: 1.5cm,
      text(font: heading-font, size: 1 * body-size,
        top-edge: "ascender",
        doc-category)),
    box(height: 6cm,
      par(leading: 0.5em,
        text(font: heading-font, weight: "bold",
          size: 2 * body-size, fill: luma(40%).mix(heading-color),
          top-edge: "ascender",
          hyphenate: false,
          doc-title) + "\n\n") +
      text(font: heading-font, size: label-size,
        author + "\n" +
        affiliation + ", " +
        datetime.today().display(datetime-fmt)
      )
    ),
  )
}

// ===== Main Template =====

#let basic-report(
  doc-category: none,
  doc-title: none,
  author: none,
  affiliation: none,
  logo: none,
  language: "de",
  show-outline: true,
  compact-mode: false,
  heading-color: blue,
  heading-font: "Ubuntu",
  datetime-fmt: "[day].[month].[year]",
  body,
) = {

  set document(title: doc-title, author: author)
  set text(lang: language)

  let body-font = "Vollkorn"
  let body-size = 11pt
  let info-size = 10pt
  let label-size = 9pt
  let in-outline = state("in-outline", if compact-mode {false} else {true})

  // ----- Title Page -----

  if (not compact-mode) {
    counter(page).update(0)
    titlepage(
      doc-category,
      doc-title,
      author,
      affiliation,
      logo,
      heading-font,
      heading-color,
      info-size,
      datetime-fmt,
    )
  }

  // ----- Text & Page Setup -----

  set text(
    font: body-font,
    size: body-size,
    fill: luma(50)
  )

  set par(
    justify: true,
    leading: 0.75em,
    spacing: 1.65em,
    first-line-indent: 0em,
  )

  set page(
    paper: "a4",
    margin: (top: 3.6cm, left: 2cm, right: 2cm, bottom: 3cm),
    header: context {
      if compact-mode and (counter(page).get().first() == 1) {
        none
      } else {
        grid(
          columns: (1fr, 1fr),
          align: (left, right),
          row-gutter: 0.5em,
          text(font: heading-font, size: label-size,
            context {hydra(1, use-last: false, skip-starting: false)},),
          text(font: heading-font, size: label-size,
            number-type: "lining",
            context {if in-outline.get() {
                counter(page).display("i")
              } else {
                counter(page).display("1")
              }
            }
          ),
          grid.cell(colspan: 2, line(length: 100%, stroke: 0.5pt)),
        )
      }
    },
    header-ascent: 1.5em
  )

  // ----- Headings -----

  set heading(numbering: "1.")
  show heading: set text(font: heading-font, fill: heading-color,
      weight: if compact-mode {"bold"} else {"regular"})
  show heading: set par(justify: false)

  show heading.where(level: 1): it => {
    v(3.8 * body-size, weak: true) + text(it) + v(0.2 * body-size)
  }
  show heading.where(level: 2): it => {
    v(0.8 * body-size) + text(it) + v(0.2 * body-size)
  }
  show heading.where(level: 3): it => {
    v(0.8 * body-size) + text(it) + v(0.2 * body-size)
  }

  set figure(numbering: "1")
  show figure.caption: it => {
    set text(font: heading-font, size: label-size)
    block(it)
  }

  // ----- Table of Contents -----

  show outline: it => {
    in-outline.update(true)
    it
    in-outline.update(false)
  }

  show outline.entry.where(level: 1): it => {
    set block(above: 2 * body-size)
    set text(font: heading-font, weight: "bold", size: info-size)
    link(
      it.element.location(),
      it.indented(it.prefix(), it.body() + box(width: 1fr,) + strong(it.page()))
    )
  }

  show outline.entry.where(level: 2).or(outline.entry.where(level: 3)): it => {
    set block(above: 0.8 * body-size)
    set text(font: heading-font, size: info-size)
    link(
      it.element.location(),
      it.indented(
          it.prefix(),
          it.body() + "  " +
            box(width: 1fr, repeat([.], gap: 2pt)) +
            "  " + it.page()
      )
    )
  }

  if (show-outline and not compact-mode) {
    outline(
      title: if language == "de" {
        "Inhalt"
      } else if language == "fr" {
        "Table des matières"
      } else if language == "es" {
        "Contenido"
      } else if language == "it" {
        "Indice"
      } else if language == "nl" {
        "Inhoud"
      } else if language == "pt" {
        "Índice"
      } else if language == "zh" {
        "目录"
      } else if language == "ja" {
        "目次"
      } else if language == "ru" {
        "Содержание"
      } else if language == "ar" {
        "المحتويات"
      } else {
        auto
      },
      indent: auto,
    )
    counter(page).update(0)
  } else {
    in-outline.update(false)
    counter(page).update(1)
  }

  if (not compact-mode) {
    pagebreak()
  }

  // ----- Body -----

  if compact-mode {
    compact-title(
      doc-category,
      doc-title,
      author,
      affiliation,
      logo,
      heading-font,
      heading-color,
      info-size,
      body-size,
      label-size,
      datetime-fmt,
    )
  }

  body
}

// ===== Pandoc Template =====

#let horizontalrule = line(start: (25%,0%), end: (75%,0%))

#show terms.item: it => block(breakable: false)[
  #text(weight: "bold")[#it.term]
  #block(inset: (left: 1.5em, top: -0.4em))[#it.description]
]

#set table(
  inset: 6pt,
  stroke: 0.5pt + luma(180),
)

#show table.cell: set text(size: 10pt)

#show figure.where(
  kind: table
): set figure.caption(position: top)

#show figure.where(
  kind: image
): set figure.caption(position: bottom)

$if(highlighting-definitions)$
$highlighting-definitions$

// Override Skylighting to use full width
#let _original_Skylighting = Skylighting
#let Skylighting(fill: none, number: false, start: 1, sourcelines) = {
  block(width: 100%, _original_Skylighting(fill: fill, number: number, start: start, sourcelines))
}

$endif$

$for(header-includes)$
$header-includes$

$endfor$

#show: basic-report.with(
  doc-title: [$title$],
  doc-category: [$subtitle$],
  author: "$author$",
  affiliation: "$affiliation$",
  language: "$if(lang)$$lang$$else$en$endif$",
)

#show table: set block(width: 100%)

$body$
