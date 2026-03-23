# ESL Phase 1 Documentation — Build

D2_THEME   := 0
D2_LAYOUT  := dagre
TEMPLATE   := template.typ

D2_SOURCES := $(wildcard diagrams/*.d2)
D2_SVGS    := $(D2_SOURCES:.d2=.svg)

MD_FILES   := 01-introduction.md 02-architecture.md 03-database.md \
              04-datapipeline.md 05-datafetch.md 06-deployment.md \
              07-operations.md

PDF_OUTPUT := esl-orchesterator-documentation-phase1.pdf

.PHONY: all diagrams pdf clean

all: diagrams pdf

diagrams: $(D2_SVGS)

diagrams/%.svg: diagrams/%.d2
	d2 --theme $(D2_THEME) --layout $(D2_LAYOUT) $< $@

pdf: diagrams
	pandoc $(MD_FILES) \
		--pdf-engine=typst \
		--template=$(TEMPLATE) \
		--syntax-highlighting=tango \
		-o $(PDF_OUTPUT)

clean:
	rm -f $(D2_SVGS) $(PDF_OUTPUT)
