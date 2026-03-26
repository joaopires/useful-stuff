# ESL Documentation — Build

TEMPLATE   := template.typ

# Phase 1
P1_DIR     := phase-1
P1_SVG     := $(wildcard $(P1_DIR)/diagrams/*.svg)
P1_MD      := $(P1_DIR)/01-introduction.md $(P1_DIR)/02-architecture.md \
              $(P1_DIR)/03-database.md $(P1_DIR)/04-datapipeline.md \
              $(P1_DIR)/05-datafetch.md $(P1_DIR)/06-deployment.md \
              $(P1_DIR)/07-operations.md
P1_PDF     := $(P1_DIR)/esl-orchestrator-documentation-phase1.pdf

# Phase 2
P2_DIR     := phase-2
P2_SVG     := $(wildcard $(P2_DIR)/diagrams/*.svg)
P2_MD      := $(P2_DIR)/01-introduction.md $(P2_DIR)/02-architecture.md \
              $(P2_DIR)/03-database.md
P2_PDF     := $(P2_DIR)/esl-orchestrator-documentation-phase2.pdf

.PHONY: all phase-1 phase-2 clean

all: phase-1 phase-2

phase-1: $(P1_PDF)

$(P1_PDF): $(P1_SVG) $(P1_MD) $(TEMPLATE)
	pandoc $(P1_MD) \
		--pdf-engine=typst \
		--template=$(TEMPLATE) \
		--syntax-highlighting=tango \
		--resource-path=$(P1_DIR) \
		--lua-filter=auto-columns.lua \
		-o $@

phase-2: $(P2_PDF)

$(P2_PDF): $(P2_SVG) $(P2_MD) $(TEMPLATE)
	pandoc $(P2_MD) \
		--pdf-engine=typst \
		--template=$(TEMPLATE) \
		--syntax-highlighting=tango \
		--resource-path=$(P2_DIR) \
		--lua-filter=auto-columns.lua \
		-o $@

clean:
	rm -f $(P1_PDF) $(P2_PDF)
