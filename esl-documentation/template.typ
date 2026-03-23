#import "@preview/basic-report:0.4.0": basic-report

#let horizontalrule = line(start: (25%,0%), end: (75%,0%))

#show terms.item: it => block(breakable: false)[
  #text(weight: "bold")[#it.term]
  #block(inset: (left: 1.5em, top: -0.4em))[#it.description]
]

#set table(
  inset: 6pt,
  stroke: none
)

#show figure.where(
  kind: table
): set figure.caption(position: top)

#show figure.where(
  kind: image
): set figure.caption(position: bottom)

$if(highlighting-definitions)$
$highlighting-definitions$

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

$body$
