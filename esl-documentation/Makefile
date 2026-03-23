# ESL Documentation — Build

D2_THEME   := 0
D2_LAYOUT  := dagre
TEMPLATE   := template.typ

# Phase 1
P1_DIR     := phase-1
P1_D2_SRC  := $(wildcard $(P1_DIR)/diagrams/*.d2)
P1_D2_SVG  := $(P1_D2_SRC:.d2=.svg)
P1_MD      := $(P1_DIR)/01-introduction.md $(P1_DIR)/02-architecture.md \
              $(P1_DIR)/03-database.md $(P1_DIR)/04-datapipeline.md \
              $(P1_DIR)/05-datafetch.md $(P1_DIR)/06-deployment.md \
              $(P1_DIR)/07-operations.md
P1_PDF     := $(P1_DIR)/esl-orchestrator-documentation-phase1.pdf

.PHONY: all phase-1 clean

all: phase-1

phase-1: $(P1_D2_SVG) $(P1_PDF)

$(P1_DIR)/diagrams/%.svg: $(P1_DIR)/diagrams/%.d2
	d2 --theme $(D2_THEME) --layout $(D2_LAYOUT) $< $@

$(P1_PDF): $(P1_D2_SVG) $(P1_MD)
	pandoc $(P1_MD) \
		--pdf-engine=typst \
		--template=$(TEMPLATE) \
		--syntax-highlighting=tango \
		-o $@

clean:
	rm -f $(P1_D2_SVG) $(P1_PDF)
