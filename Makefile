

.PHONY: deps-update
deps-update: ; $(info  Updating dependencies...) @ ## Update dependencies
	go mod tidy

PHONY: build test

build:
	./hack/build-go.sh

test:
	sudo ./hack/test-go.sh

# Documentation (GitBook layout in docs/, built with mdBook; see book.toml)
DOCS_DIR ?= docs
DOCS_PORT ?= 3000
DOCS_OUT ?= _book
MDBOOK ?= mdbook

# svgdog renders the diagrams embedded in the pages. Override with SVGDOG=/path/to/svgdog
SVGDOG ?= $(shell command -v svgdog 2>/dev/null)

.PHONY: docs-serve docs-build docs-clean docs-diagrams docs-diagrams-check docs-diagrams-if-available svgdog-required

svgdog-required:
	@test -n "$(SVGDOG)" && test -x "$(SVGDOG)" || { echo "svgdog not found: put it on PATH or run 'make $(MAKECMDGOALS) SVGDOG=/path/to/svgdog'"; exit 1; }

docs-diagrams: svgdog-required ## Render the svgdog diagrams embedded in the Markdown pages
	$(SVGDOG) docs $(DOCS_DIR)

docs-diagrams-check: svgdog-required ## Fail if any svgdog diagram is out of date
	$(SVGDOG) docs $(DOCS_DIR) --check

docs-diagrams-if-available:
	@if [ -n "$(SVGDOG)" ] && [ -x "$(SVGDOG)" ]; then $(SVGDOG) docs $(DOCS_DIR); \
	else echo "warning: svgdog not found, serving the committed diagrams (set SVGDOG=/path/to/svgdog to re-render)"; fi

docs-serve: docs-diagrams-if-available ## Serve documentation at http://localhost:$(DOCS_PORT) with live reload
	$(MDBOOK) serve --port $(DOCS_PORT) --dest-dir $(DOCS_OUT)

docs-build: docs-diagrams-if-available ## Build static documentation into $(DOCS_OUT)
	$(MDBOOK) build --dest-dir $(DOCS_OUT)

docs-clean: ## Remove built documentation
	rm -rf $(DOCS_OUT)
	