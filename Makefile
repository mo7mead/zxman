.DEFAULT_GOAL := run
.PHONY: install link unlink run public clean help

BINDIR ?= $(HOME)/.local/bin

install:            ## Install dependencies (webrick)
	bundle install

link:               ## Install the `zxman` command (default ~/.local/bin)
	@mkdir -p $(BINDIR)
	@ln -sf $(CURDIR)/bin/zxman $(BINDIR)/zxman
	@echo "linked $(BINDIR)/zxman -> $(CURDIR)/bin/zxman"
	@case ":$$PATH:" in *":$(BINDIR):"*) ;; \
		*) echo "note: $(BINDIR) is not on your PATH — add it to use 'zxman'";; esac

unlink:             ## Remove the `zxman` command from your PATH
	rm -f $(BINDIR)/zxman

run:                ## Start zxman (the request catcher)
	./bin/zxman

public:             ## Start without the cloudflared tunnel
	TUNNEL=0 ./bin/zxman

clean:              ## Remove captured requests and logs
	rm -rf hits requests.log

help:               ## List the available targets
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | \
		awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-10s\033[0m %s\n", $$1, $$2}'
